import 'dart:async';
import 'dart:io';

import 'elm327.dart';
import 'obd_data.dart';
import 'transport.dart';

export 'obd_data.dart';

enum ObdState { disconnected, connecting, connected }

/// One speed reading from the vehicle.
class ObdSpeedSample {
  const ObdSpeedSample(this.speedMps, this.time);

  /// Speed over ground in m/s. The ECU reports whole km/h, so the
  /// resolution is about 0.28 m/s.
  final double speedMps;
  final DateTime time;
}

/// What to read besides speed. Everything is off by default: each extra
/// request slows the speed polling a little.
class ObdOptions {
  const ObdOptions({
    this.fuel = false,
    this.vehicleInfo = false,
    this.logDirectory,
    this.position,
  });

  /// Fuel flow, consumption and tank level.
  final bool fuel;

  /// VIN, fuel type, warning lamp and trouble codes once per connection;
  /// engine speed, coolant temperature and battery voltage while driving.
  final bool vehicleInfo;

  /// When set, a CSV trip log is written there, one row per second.
  final Directory? logDirectory;

  /// Current position for the trip log (lat, lon), if the caller has one.
  final ({double lat, double lon})? Function()? position;
}

/// Keeps a connection to an ELM327 adapter, streams the vehicle speed and,
/// when asked, fuel and engine data.
///
/// Reconnects on its own with a growing delay: adapters drop the link when
/// the ignition is switched off.
class ObdSession {
  ObdSession(
    this._connect, {
    this.options = const ObdOptions(),
    this.pollInterval = const Duration(milliseconds: 200),
    this.maxRetryDelay = const Duration(seconds: 30),
  });

  final ObdConnector _connect;
  final ObdOptions options;

  /// Minimum time between speed requests; slow adapters poll less often.
  final Duration pollInterval;
  final Duration maxRetryDelay;

  final _samples = StreamController<ObdSpeedSample>.broadcast();
  final _states = StreamController<ObdState>.broadcast();
  final _telemetryUpdates = StreamController<ObdTelemetry>.broadcast();
  ObdState _state = ObdState.disconnected;
  bool _running = false;
  Elm327? _elm;

  Stream<ObdSpeedSample> get samples => _samples.stream;
  Stream<ObdState> get states => _states.stream;
  ObdState get state => _state;

  /// Reason of the last failed connection attempt, for the status screen.
  String? lastError;

  /// Adapter identification once connected.
  String? adapter;

  /// Vehicle facts read after connecting (empty unless
  /// [ObdOptions.vehicleInfo] is on).
  VehicleInfo vehicle = const VehicleInfo();

  /// Latest fuel and engine readings (all null unless the options ask).
  ObdTelemetry telemetry = const ObdTelemetry();
  Stream<ObdTelemetry> get telemetryUpdates => _telemetryUpdates.stream;

  // Live values behind [telemetry].
  double? _rpm, _fuelLevel, _fuelRate, _volts;
  int? _coolant;
  bool _fuelEstimated = false;
  double _tripFuelL = 0, _tripKm = 0;
  double? _lastSpeedMps;
  DateTime? _lastSampleAt;
  IOSink? _log;
  DateTime? _lastLogAt;

  void _set(ObdState s) {
    if (s == _state) return;
    _state = s;
    _states.add(s);
  }

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> stop() async {
    _running = false;
    await _elm?.close();
    _elm = null;
    await _log?.close();
    _log = null;
    _set(ObdState.disconnected);
  }

  Future<void> dispose() async {
    await stop();
    await _samples.close();
    await _states.close();
    await _telemetryUpdates.close();
  }

  Future<void> _run() async {
    var delay = const Duration(seconds: 1);
    while (_running) {
      _set(ObdState.connecting);
      try {
        final elm = _elm = Elm327(await _connect());
        await elm.initialize();
        adapter = elm.version;
        lastError = null;
        final extras = await _prepare(elm);
        _set(ObdState.connected);
        delay = const Duration(seconds: 1);
        await _poll(elm, extras);
      } on Exception catch (e) {
        lastError = '$e';
      }
      await _elm?.close().catchError((Object _) {});
      _elm = null;
      if (!_running) break;
      _set(ObdState.disconnected);
      await Future<void>.delayed(delay);
      delay = delay * 2 > maxRetryDelay ? maxRetryDelay : delay * 2;
    }
  }

  /// Reads the one-off vehicle facts and decides which extra PIDs to poll.
  Future<List<int>> _prepare(Elm327 elm) async {
    if (!options.fuel && !options.vehicleInfo) return const [];
    final supported = await elm.readSupportedPids();
    var fuelType = FuelType.unknown;
    if (supported.contains(0x51)) {
      final d = await elm.query(0x51);
      if (d != null && d.isNotEmpty) fuelType = fuelTypeFromCode(d[0]);
    }
    if (options.vehicleInfo) {
      bool? mil;
      var codes = const <String>[];
      final status = await elm.query(0x01);
      if (status != null && status.isNotEmpty) {
        final s = monitorStatusFrom(status);
        mil = s.milOn;
        if (s.codes > 0) codes = await elm.readTroubleCodes();
      }
      vehicle = VehicleInfo(
        vin: await elm.readVin(),
        fuelType: fuelType,
        milOn: mil,
        troubleCodes: codes,
        adapter: elm.version,
        protocol: elm.protocol,
      );
    } else {
      vehicle = VehicleInfo(fuelType: fuelType, adapter: elm.version);
    }
    return [
      if (options.fuel) ...[
        // Prefer the ECU's own fuel rate; fall back to air flow.
        if (supported.contains(0x5E))
          0x5E
        else if (supported.contains(0x10) &&
            fuelRateFromMaf(1, fuelType) != null)
          0x10,
        if (supported.contains(0x2F)) 0x2F,
      ],
      if (options.vehicleInfo) ...[
        if (supported.contains(0x0C)) 0x0C,
        if (supported.contains(0x05)) 0x05,
      ],
    ];
  }

  Future<void> _poll(Elm327 elm, List<int> extras) async {
    var silent = 0, cycle = 0, next = 0;
    while (_running) {
      final started = DateTime.now();
      final kmh = await elm.readSpeedKmh();
      if (kmh == null) {
        // The ECU stops answering when the ignition is off: reconnect later
        // rather than hammer a sleeping bus.
        if (++silent >= 10) throw ElmException('vehicle stopped answering');
      } else {
        silent = 0;
        _onSpeed(kmh / 3.6, DateTime.now());
      }
      // Speed keeps priority: one extra value every second cycle.
      if (extras.isNotEmpty && cycle.isOdd) {
        final pid = extras[next++ % extras.length];
        final d = await elm.query(pid);
        if (d != null) _onExtra(pid, d);
      }
      if (options.vehicleInfo && cycle % 50 == 0) {
        _volts = await elm.readBatteryVolts() ?? _volts;
      }
      cycle++;
      _publish();
      final wait = pollInterval - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
  }

  void _onSpeed(double mps, DateTime now) {
    final last = _lastSampleAt;
    if (last != null) {
      // Gaps (reconnects) are not integrated.
      final dt = now.difference(last).inMicroseconds / 1e6;
      if (dt > 0 && dt < 2) {
        _tripKm += (_lastSpeedMps ?? mps) * dt / 1000;
        final rate = _fuelRate;
        if (rate != null) _tripFuelL += rate * dt / 3600;
      }
    }
    _lastSampleAt = now;
    _lastSpeedMps = mps;
    _samples.add(ObdSpeedSample(mps, now));
  }

  void _onExtra(int pid, List<int> d) {
    switch (pid) {
      case 0x5E when d.length >= 2:
        _fuelRate = fuelRateFrom(d);
        _fuelEstimated = false;
      case 0x10 when d.length >= 2:
        _fuelRate = fuelRateFromMaf(mafFrom(d), vehicle.fuelType);
        _fuelEstimated = true;
      case 0x2F when d.isNotEmpty:
        _fuelLevel = fuelLevelFrom(d);
      case 0x0C when d.length >= 2:
        _rpm = rpmFrom(d);
      case 0x05 when d.isNotEmpty:
        _coolant = coolantFrom(d);
    }
  }

  void _publish() {
    final speed = _lastSpeedMps, rate = _fuelRate;
    final kmh = speed == null ? null : speed * 3.6;
    telemetry = ObdTelemetry(
      rpm: _rpm,
      coolantC: _coolant,
      fuelLevelPercent: _fuelLevel,
      fuelRateLph: rate,
      fuelRateEstimated: _fuelEstimated,
      // Per-distance consumption is meaningless at a crawl.
      consumptionLPer100km: rate == null || kmh == null || kmh < 5
          ? null
          : rate / kmh * 100,
      tripFuelL: _tripFuelL,
      tripDistanceKm: _tripKm,
      batteryVolts: _volts,
    );
    if (options.fuel || options.vehicleInfo) _telemetryUpdates.add(telemetry);
    _writeLog();
  }

  void _writeLog() {
    final dir = options.logDirectory;
    if (dir == null) return;
    final now = DateTime.now();
    final last = _lastLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastLogAt = now;
    try {
      var log = _log;
      if (log == null) {
        dir.createSync(recursive: true);
        final stamp = now
            .toIso8601String()
            .substring(0, 19)
            .replaceAll(':', '')
            .replaceAll('-', '');
        log = _log = File('${dir.path}/trip-$stamp.csv').openWrite()
          ..writeln(
            'time,speed_kmh,rpm,coolant_c,fuel_lph,fuel_level_pct,'
            'battery_v,trip_km,trip_fuel_l,lat,lon',
          );
      }
      String n(num? v, [int digits = 1]) =>
          v == null ? '' : v.toStringAsFixed(digits);
      final t = telemetry;
      final p = options.position?.call();
      final speed = _lastSpeedMps;
      log.writeln(
        [
          now.toIso8601String(),
          n(speed == null ? null : speed * 3.6, 0),
          n(t.rpm, 0),
          t.coolantC ?? '',
          n(t.fuelRateLph, 2),
          n(t.fuelLevelPercent),
          n(t.batteryVolts),
          n(t.tripDistanceKm, 3),
          n(t.tripFuelL, 3),
          n(p?.lat, 6),
          n(p?.lon, 6),
        ].join(','),
      );
    } on FileSystemException catch (e) {
      // A full or read-only disk must not stop the speed stream.
      lastError = 'trip log: ${e.message}';
    }
  }
}
