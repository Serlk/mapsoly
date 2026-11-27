import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'obd_session.dart';
import 'rfcomm_transport.dart';
import 'transport.dart';

/// How the adapter is reached.
enum ObdLink { bluetooth, wifi, serial }

/// The user's ELM327 choices, as stored in the settings.
@immutable
class ObdConfig {
  const ObdConfig({
    this.enabled = false,
    this.link = ObdLink.bluetooth,
    this.address = '',
    this.fuel = false,
    this.vehicleInfo = false,
    this.tripLog = false,
  });

  final bool enabled;
  final ObdLink link;

  /// Bluetooth: `AA:BB:CC:DD:EE:FF`. Wi-Fi: `host:port` (port 35000 when
  /// omitted). Serial: a device path such as `/dev/ttyUSB0`.
  final String address;

  final bool fuel, vehicleInfo, tripLog;

  /// True when there is enough to try a connection.
  bool get usable => enabled && address.trim().isNotEmpty;

  ObdConfig copyWith({
    bool? enabled,
    ObdLink? link,
    String? address,
    bool? fuel,
    bool? vehicleInfo,
    bool? tripLog,
  }) => ObdConfig(
    enabled: enabled ?? this.enabled,
    link: link ?? this.link,
    address: address ?? this.address,
    fuel: fuel ?? this.fuel,
    vehicleInfo: vehicleInfo ?? this.vehicleInfo,
    tripLog: tripLog ?? this.tripLog,
  );

  factory ObdConfig.fromJson(Map<String, dynamic> json) => ObdConfig(
    enabled: json['enabled'] == true,
    link: ObdLink.values.firstWhere(
      (l) => l.name == json['link'],
      orElse: () => ObdLink.bluetooth,
    ),
    address: json['address'] as String? ?? '',
    fuel: json['fuel'] == true,
    vehicleInfo: json['vehicleInfo'] == true,
    tripLog: json['tripLog'] == true,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'link': link.name,
    'address': address,
    'fuel': fuel,
    'vehicleInfo': vehicleInfo,
    'tripLog': tripLog,
  };

  @override
  bool operator ==(Object other) =>
      other is ObdConfig &&
      other.enabled == enabled &&
      other.link == link &&
      other.address == address &&
      other.fuel == fuel &&
      other.vehicleInfo == vehicleInfo &&
      other.tripLog == tripLog;

  @override
  int get hashCode =>
      Object.hash(enabled, link, address, fuel, vehicleInfo, tripLog);
}

/// Opens the transport described by [config].
ObdConnector connectorFor(ObdConfig config) {
  final address = config.address.trim();
  switch (config.link) {
    case ObdLink.bluetooth:
      return () => RfcommObdTransport.connect(address);
    case ObdLink.wifi:
      final parts = address.split(':');
      final port = parts.length > 1 ? int.tryParse(parts.last) : null;
      final host = port == null
          ? address
          : parts.sublist(0, parts.length - 1).join(':');
      return () => TcpObdTransport.connect(host, port ?? 35000);
    case ObdLink.serial:
      return () => SerialObdTransport.open(address);
  }
}

/// Keeps the adapter session in line with the settings and exposes what the
/// car reports to the UI.
class ObdService extends ChangeNotifier {
  ObdService({
    required this.logDirectory,
    this.position,
    this.onSpeed,
    ObdConnector Function(ObdConfig config)? connector,
  }) : _connector = connector ?? connectorFor;

  /// Where trip logs go when that option is on.
  final Directory logDirectory;

  /// Position for the trip log; return null to leave coordinates out (no
  /// fix, or inside a privacy zone).
  final ({double lat, double lon})? Function()? position;

  /// Every speed reading, for the positioning engine.
  final void Function(ObdSpeedSample sample)? onSpeed;

  final ObdConnector Function(ObdConfig config) _connector;
  ObdConfig _config = const ObdConfig();
  ObdSession? _session;
  final _subs = <StreamSubscription<Object?>>[];
  double? _speedMps;

  ObdConfig get config => _config;
  ObdState get state => _session?.state ?? ObdState.disconnected;
  bool get connected => state == ObdState.connected;

  /// Why the last connection attempt failed (technical; for the settings).
  String? get lastError => _session?.lastError;
  String? get adapter => _session?.adapter;
  VehicleInfo get vehicle => _session?.vehicle ?? const VehicleInfo();
  ObdTelemetry get telemetry => _session?.telemetry ?? const ObdTelemetry();

  /// Latest speed in m/s while connected.
  double? get speedMps => connected ? _speedMps : null;

  /// Applies new settings: (re)connects, or stops when switched off.
  Future<void> apply(ObdConfig config) async {
    if (config == _config) return;
    _config = config;
    await _stop();
    if (config.usable) {
      final session = _session = ObdSession(
        _connector(config),
        options: ObdOptions(
          fuel: config.fuel,
          vehicleInfo: config.vehicleInfo,
          logDirectory: config.tripLog ? logDirectory : null,
          position: position,
        ),
      );
      _subs
        ..add(session.states.listen((_) => notifyListeners()))
        ..add(session.telemetryUpdates.listen((_) => notifyListeners()))
        ..add(
          session.samples.listen((sample) {
            _speedMps = sample.speedMps;
            onSpeed?.call(sample);
            // Without extras there are no telemetry updates to ride on.
            if (!config.fuel && !config.vehicleInfo) notifyListeners();
          }),
        );
      session.start();
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final session = _session;
    _session = null;
    _speedMps = null;
    await session?.dispose();
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }
}
