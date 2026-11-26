/// The facade the UI talks to: owns the sources, the database, the
/// estimator, the fusion filter and the wardriving collector.
library;

import 'dart:async';
import 'dart:io';

import 'estimator.dart';
import 'fusion.dart';
import 'gnss_sanity.dart';
import 'importers.dart';
import 'location_db.dart';
import 'models.dart';
import 'online/resolver.dart';
import 'sources/linux_cell.dart';
import 'sources/linux_wifi.dart';
import 'sources/nmea_socket_gnss.dart';
import 'sources/sources.dart';
import 'wardriving.dart';

/// Engine settings.
class PositioningConfig {
  const PositioningConfig({
    this.wifiScanInterval = const Duration(seconds: 5),
    this.cellPollInterval = const Duration(seconds: 5),
    this.outputInterval = const Duration(seconds: 1),
    this.onlineLookups = false,
    this.wardriving = false,
    this.estimator = const EstimatorConfig(),
    this.fusion = const FusionConfig(),
    this.sanity = const GnssSanityConfig(),
    this.wardrivingConfig = const WardrivingConfig(),
    this.onlineMinInterval = const Duration(seconds: 20),
    this.repeatRadioFixAfter = const Duration(seconds: 15),
  });

  /// How often a Wi-Fi scan is requested and the AP list read. The platform
  /// may scan less often (NetworkManager: every 10-15 s).
  final Duration wifiScanInterval;
  final Duration cellPollInterval;

  /// Period of the smoothed output on [PositioningEngine.estimates].
  final Duration outputInterval;

  /// Initial state of online lookups. OFF by default: every lookup tells
  /// Apple / beaconDB which transmitters are around the user.
  final bool onlineLookups;

  /// Initial state of the wardriving collector.
  final bool wardriving;
  final EstimatorConfig estimator;
  final FusionConfig fusion;
  final GnssSanityConfig sanity;
  final WardrivingConfig wardrivingConfig;

  /// Minimum time between automatic online resolution rounds.
  final Duration onlineMinInterval;

  /// An unchanged radio fix is fed to the filter again only after this long.
  final Duration repeatRadioFixAfter;
}

/// Snapshot of the engine state for the UI.
class PositioningStatus {
  const PositioningStatus({
    this.running = false,
    this.estimate,
    this.wifiVisible = 0,
    this.wifiKnown = 0,
    this.wifiUsed = 0,
    this.cellsVisible = 0,
    this.cellsKnown = 0,
    this.bleVisible = 0,
    this.wifiBackend,
    this.wifiReportsDbm = false,
    this.gnssConnected = false,
    this.gnssHealth = const GnssHealth(verdict: GnssVerdict.noFix),
    this.satellitesInView = 0,
    this.satellitesUsed = 0,
    this.wardriving = false,
    this.wardrivingSamples = 0,
    this.onlineLookups = false,
    this.onlineError,
    this.wifiCellConflict = false,
  });

  final bool running;

  /// Latest fused estimate (same as [PositioningEngine.current]).
  final PositionEstimate? estimate;

  /// Source of the current estimate, null when there is none.
  PositionSource? get source => estimate?.source;

  /// Access points in the last scan / of those, present in the database /
  /// of those, used after outlier rejection.
  final int wifiVisible;
  final int wifiKnown;
  final int wifiUsed;
  final int cellsVisible;
  final int cellsKnown;
  final int bleVisible;

  /// "wpa_supplicant" or "NetworkManager"; null before the first scan.
  final String? wifiBackend;
  final bool wifiReportsDbm;
  final bool gnssConnected;
  final GnssHealth gnssHealth;
  final int satellitesInView;
  final int satellitesUsed;

  /// True when GNSS is being ignored as probably spoofed.
  bool get spoofingSuspected => gnssHealth.spoofingSuspected;
  bool get jammingSuspected => gnssHealth.jammingSuspected;

  final bool wardriving;

  /// Samples stored by the collector in this session.
  final int wardrivingSamples;
  final bool onlineLookups;
  final String? onlineError;

  /// Wi-Fi estimate contradicted the cells and was discarded.
  final bool wifiCellConflict;
}

/// Positioning engine.
///
/// Typical use:
/// ```dart
/// final engine = PositioningEngine.linux(dbPath: '$dir/positioning.db');
/// engine.estimates.listen((e) => ...);   // 1 Hz smoothed position
/// engine.statusStream.listen((s) => ...); // counters, flags
/// await engine.start();
/// ...
/// await engine.dispose();
/// ```
class PositioningEngine {
  PositioningEngine({
    required this.db,
    this.wifi,
    this.cells,
    this.gnss,
    this.ble,
    OnlineResolver? resolver,
    this.config = const PositioningConfig(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _resolver = resolver,
       _online = config.onlineLookups,
       _wardriving = config.wardriving,
       _estimator = RadioEstimator(config: config.estimator),
       _filter = FusionFilter(config: config.fusion),
       _sanity = GnssSanityChecker(config: config.sanity) {
    _collector = WardrivingCollector(
      db,
      config: config.wardrivingConfig,
      model: config.estimator.model,
    );
  }

  /// Engine with the Linux sources: NetworkManager / wpa_supplicant,
  /// ModemManager and the NMEA socket. Opens (creates) the database at
  /// [dbPath].
  factory PositioningEngine.linux({
    required String dbPath,
    String gnssSocketPath = '/run/t2-gnss/nmea.sock',
    PositioningConfig config = const PositioningConfig(),
  }) {
    final db = LocationDb.open(dbPath);
    return PositioningEngine(
      db: db,
      wifi: LinuxWifiScanner(),
      cells: ModemManagerCellSource(),
      gnss: NmeaSocketGnssSource(path: gnssSocketPath),
      resolver: OnlineResolver(db),
      config: config,
    );
  }

  final LocationDb db;
  final WifiScanner? wifi;
  final CellSource? cells;
  final GnssSource? gnss;
  final BleScanner? ble;
  final PositioningConfig config;
  final DateTime Function() _now;
  final OnlineResolver? _resolver;
  final RadioEstimator _estimator;
  final FusionFilter _filter;
  final GnssSanityChecker _sanity;
  late final WardrivingCollector _collector;

  final _estimates = StreamController<PositionEstimate>.broadcast();
  final _statuses = StreamController<PositioningStatus>.broadcast();

  bool _running = false;
  bool _disposed = false;
  bool _online;
  bool _wardriving;
  Timer? _wifiTimer, _cellTimer, _outTimer;
  StreamSubscription<GnssFix>? _gnssSub;
  bool _wifiBusy = false, _cellBusy = false, _onlineBusy = false;
  Future<void>? _wifiPoll, _cellPoll;

  List<WifiObservation> _lastWifi = const [];
  List<CellObservation> _lastCells = const [];
  List<BleObservation> _lastBle = const [];
  RadioEstimate _radio = const RadioEstimate();
  GnssFix? _lastFix;
  PositionEstimate? _current;
  DateTime? _lastOnline;
  String? _lastFedKey;
  DateTime? _lastFedAt;
  PositioningStatus _status = const PositioningStatus();

  /// Last error raised while polling a source (diagnostics), or null.
  String? lastSourceError;

  /// Smoothed position at [PositioningConfig.outputInterval].
  Stream<PositionEstimate> get estimates => _estimates.stream;

  /// Emits whenever counters, flags or the estimate change.
  Stream<PositioningStatus> get statusStream => _statuses.stream;

  /// Latest estimate, null until the first fix of any kind.
  PositionEstimate? get current => _current;

  /// Latest status snapshot.
  PositioningStatus get status => _status;

  bool get isRunning => _running;

  /// Latest raw observations (for a diagnostics screen).
  List<WifiObservation> get lastWifiScan => _lastWifi;
  List<CellObservation> get lastCells => _lastCells;
  GnssFix? get lastGnssFix => _lastFix;

  /// Latest unfiltered radio estimate with its counters.
  RadioEstimate get lastRadioEstimate => _radio;

  /// Whether transmitter observations are written to the database while a
  /// trusted GNSS fix is available.
  bool get wardriving => _wardriving;
  set wardriving(bool on) {
    if (_wardriving == on) return;
    _wardriving = on;
    if (!on) _collector.reset();
    _publishStatus();
  }

  /// Whether unknown transmitters may be looked up online (Apple WPS,
  /// beaconDB). Off by default for privacy.
  bool get onlineLookups => _online;
  set onlineLookups(bool on) {
    if (_online == on) return;
    _online = on;
    _publishStatus();
  }

  /// Starts all sources and the output timer.
  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    final g = gnss;
    if (g != null) {
      _gnssSub = g.fixes.listen(_onGnss);
      await g.start();
    }
    _wifiTimer = Timer.periodic(config.wifiScanInterval, (_) => _pollWifi());
    _cellTimer = Timer.periodic(config.cellPollInterval, (_) => _pollCells());
    _outTimer = Timer.periodic(config.outputInterval, (_) => _emit());
    unawaited(_pollWifi());
    unawaited(_pollCells());
    _publishStatus();
  }

  /// Stops the sources; the database stays open and the engine can be
  /// started again.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _wifiTimer?.cancel();
    _cellTimer?.cancel();
    _outTimer?.cancel();
    await _gnssSub?.cancel();
    _gnssSub = null;
    await gnss?.stop();
    _collector.reset();
    _publishStatus();
  }

  /// Stops everything and releases the sources and the database.
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await wifi?.close();
    await cells?.close();
    await ble?.close();
    _resolver?.close();
    await _estimates.close();
    await _statuses.close();
    db.close();
  }

  /// External speed-over-ground input in m/s (OBD, wheel sensor).
  void addSpeedSample(double speedMps, {DateTime? time}) {
    _filter.addSpeed(speedMps, time ?? _now());
  }

  /// External speed and heading (OBD speed plus gyro heading): advances the
  /// position between radio fixes.
  void addVelocitySample(
    double speedMps,
    double headingDeg, {
    double headingSigmaDeg = 10,
    DateTime? time,
  }) {
    _filter.addVelocity(
      speedMps,
      headingDeg,
      time ?? _now(),
      headingSigmaDeg: headingSigmaDeg,
    );
  }

  /// Database statistics.
  DbStats dbStats() => db.stats();

  /// Imports a WiGLE CSV export (`WigleWifi-1.x`).
  Future<ImportResult> importWigleCsvFile(String path) =>
      importWigleCsv(db, csvLines(File(path)));

  /// Imports a generic transmitter CSV (see `importGenericCsv`).
  Future<ImportResult> importCsvFile(String path) =>
      importGenericCsv(db, csvLines(File(path)));

  /// Downloads the Wi-Fi APs of [bounds] into the database for offline use
  /// (Apple WPS snowball). Seeds default to the current scan. Requires
  /// network; works regardless of [onlineLookups] because it is an explicit
  /// user action.
  Future<PreloadProgress> preloadRegion(
    GeoBounds bounds, {
    Iterable<String>? seeds,
    int maxRequests = 300,
    int maxAps = 100000,
    void Function(PreloadProgress)? onProgress,
    bool Function()? isCancelled,
  }) {
    final r = _resolver;
    if (r == null) {
      return Future.value(PreloadProgress()..finished = 'noResolver');
    }
    return r.preloadRegion(
      bounds,
      seeds: seeds ?? _lastWifi.map((o) => o.bssid),
      maxRequests: maxRequests,
      maxAps: maxAps,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// Runs one Wi-Fi/cell poll immediately (also used by tests).
  Future<void> pollNow() async {
    // Let polls that are already in flight finish, then run fresh ones.
    await _wifiPoll;
    await _cellPoll;
    await _pollWifi();
    await _pollCells();
    _emit();
  }

  // ---------------------------------------------------------------------

  Future<void> _pollWifi() {
    if (wifi == null || _wifiBusy) return Future.value();
    return _wifiPoll = _doPollWifi(wifi!);
  }

  Future<void> _doPollWifi(WifiScanner w) async {
    _wifiBusy = true;
    try {
      // Read first (results of the previous request), then ask for the next
      // scan so it is ready by the next tick.
      final scan = await w.getObservations(maxAge: config.estimator.maxWifiAge);
      _lastWifi = scan;
      if (_running) unawaited(w.requestScan());
      final b = ble;
      if (b != null) _lastBle = await b.getObservations();
      _afterObservations(wifiChanged: true);
    } on Object catch (e) {
      // Source hiccup: keep the previous scan.
      lastSourceError = 'wifi: $e';
    } finally {
      _wifiBusy = false;
    }
  }

  Future<void> _pollCells() {
    if (cells == null || _cellBusy) return Future.value();
    return _cellPoll = _doPollCells(cells!);
  }

  Future<void> _doPollCells(CellSource c) async {
    _cellBusy = true;
    try {
      _lastCells = await c.getCells();
      _afterObservations(wifiChanged: false);
    } on Object catch (e) {
      lastSourceError = 'cells: $e';
    } finally {
      _cellBusy = false;
    }
  }

  void _afterObservations({required bool wifiChanged}) {
    if (_disposed) return;
    final now = _now();
    _radio = _estimator.estimate(
      db: db,
      wifi: _lastWifi,
      cells: _lastCells,
      now: now,
    );
    final best = _radio.best;
    if (best != null) {
      // Polls are more frequent than real scans; feeding the very same fix
      // again and again would only convince the filter that we stand still.
      final key =
          '${best.source.index}:${best.lat.toStringAsFixed(5)}:'
          '${best.lon.toStringAsFixed(5)}';
      final fedAt = _lastFedAt;
      if (key != _lastFedKey ||
          fedAt == null ||
          now.difference(fedAt) >= config.repeatRadioFixAfter) {
        _filter.addPosition(best);
        _lastFedKey = key;
        _lastFedAt = now;
      }
    }

    if (_wardriving && _sanity.health.usable) {
      if (wifiChanged) {
        _collector.addWifi(_lastWifi, now);
        if (_lastBle.isNotEmpty) _collector.addBle(_lastBle, now);
      } else {
        _collector.addCells(_lastCells, now);
      }
    }
    _maybeResolveOnline();
    _publishStatus();
  }

  void _maybeResolveOnline() {
    final r = _resolver;
    if (r == null || !_online || _onlineBusy) return;
    final now = _now();
    final last = _lastOnline;
    if (last != null && now.difference(last) < config.onlineMinInterval) {
      return;
    }
    final needWifi = _lastWifi.length > _radio.wifiKnown;
    final needCells =
        _lastCells.where((c) => c.hasFullId).length > _radio.cellsKnown;
    if (!needWifi && !needCells && _radio.best != null) return;
    _lastOnline = now;
    _onlineBusy = true;
    final scan = _lastWifi, towers = _lastCells;
    () async {
      try {
        var changed = 0;
        if (needWifi) changed += await r.resolveWifi(scan);
        if (needCells) changed += await r.resolveCells(towers);
        if (_disposed) return;
        if (changed > 0) {
          _afterObservations(wifiChanged: false);
        } else if (_radio.best == null) {
          // Nothing cacheable: ask for a one-off fix of the whole scan.
          final fix = await r.geolocate(wifi: scan, cells: towers);
          if (fix != null && !_disposed) _filter.addPosition(fix);
        }
      } finally {
        _onlineBusy = false;
      }
    }();
  }

  void _onGnss(GnssFix fix) {
    _lastFix = fix;
    final radio = _radio.best;
    final wasSuspect = _sanity.health.spoofingSuspected;
    final health = _sanity.check(fix, radio: radio);
    if (health.usable) {
      _filter.addGnss(fix);
      if (_wardriving) _collector.addFix(fix);
    } else if (health.spoofingSuspected) {
      // Do not let a lying receiver teach the database.
      _collector.reset();
      if (!wasSuspect) {
        // The filter may already have followed the receiver for a while
        // (slow drag-off): restart it from the radio estimate alone.
        _filter.reset();
        _lastFedKey = null;
        if (radio != null) {
          _filter.addPosition(radio);
          _lastFedAt = _now();
        }
      }
    }
    _publishStatus();
  }

  void _emit() {
    if (_disposed) return;
    final e = _filter.estimateAt(_now());
    if (e == null) return;
    _current = e;
    if (!_estimates.isClosed) _estimates.add(e);
    _publishStatus();
  }

  void _publishStatus() {
    if (_disposed) return;
    final fix = _lastFix;
    _status = PositioningStatus(
      running: _running,
      estimate: _current,
      wifiVisible: _lastWifi.length,
      wifiKnown: _radio.wifiKnown,
      wifiUsed: _radio.wifiUsed,
      cellsVisible: _lastCells.length,
      cellsKnown: _radio.cellsKnown,
      bleVisible: _lastBle.length,
      wifiBackend: wifi?.backend,
      wifiReportsDbm: wifi?.reportsDbm ?? false,
      gnssConnected: gnss?.connected ?? false,
      gnssHealth: _sanity.health,
      satellitesInView: fix?.satellites.length ?? 0,
      satellitesUsed:
          fix?.satellitesUsed ??
          (fix?.satellites.where((s) => s.used).length ?? 0),
      wardriving: _wardriving,
      wardrivingSamples: _collector.samplesWritten,
      onlineLookups: _online,
      onlineError: _resolver?.lastError,
      wifiCellConflict: _radio.wifiCellConflict,
    );
    if (!_statuses.isClosed) _statuses.add(_status);
  }
}
