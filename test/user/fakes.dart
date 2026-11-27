/// Stand-ins for the radio and GNSS sources, and a synthetic neighbourhood.
library;

import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:mapsoly/positioning/positioning.dart';

/// Palace Square, St Petersburg: the origin of the test neighbourhood.
const lat0 = 59.9390, lon0 = 30.3158;
const origin = LatLng(lat0, lon0);
final proj = LocalProjection(lat0, lon0);

/// The point [east], [north] metres from the origin.
LatLng at(double east, double north) => LatLng(proj.lat(north), proj.lon(east));

class FakeWifi implements WifiScanner {
  List<WifiObservation> scan = [];
  @override
  String get backend => 'fake';
  @override
  bool get reportsDbm => true;
  @override
  Future<bool> requestScan() async => true;
  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async => scan;
  @override
  Future<void> close() async {}
}

class FakeCells implements CellSource {
  List<CellObservation> cells = [];
  @override
  String get backend => 'fake';
  @override
  Future<List<CellObservation>> getCells() async => cells;
  @override
  Future<void> close() async {}
}

class FakeGnss implements GnssSource {
  final controller = StreamController<GnssFix>.broadcast(sync: true);
  bool started = false;
  @override
  Stream<GnssFix> get fixes => controller.stream;
  @override
  bool get connected => started;
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => started = false;
}

/// Synthetic identifiers: locally administered-looking MACs, made-up cells.
String mac(int i) => 'aa:bb:cc:00:00:${i.toRadixString(16).padLeft(2, '0')}';

CellObservation cell(int id, {double? signalDbm}) => CellObservation(
  radio: RadioType.lte,
  mcc: 999,
  mnc: 7,
  area: 4242,
  cellId: id,
  signalDbm: signalDbm,
  serving: true,
);

const _sky = [47.0, 44.0, 41.0, 39.0, 36.0, 33.0, 30.0, 27.0];

/// A healthy fix [east], [north] metres from the origin.
GnssFix fixAt(
  DateTime time,
  double east,
  double north, {
  double accuracyM = 5,
  double speed = 0,
}) => GnssFix(
  valid: true,
  receivedAt: time,
  lat: proj.lat(north),
  lon: proj.lon(east),
  accuracyM: accuracyM,
  speedMps: speed,
  time: time,
  satellitesUsed: _sky.length,
  satellites: [
    for (var i = 0; i < _sky.length; i++)
      GnssSatellite(
        system: GnssSystem.gps,
        prn: i + 1,
        cn0: _sky[i],
        used: true,
      ),
  ],
);

TransmitterRecord record(
  TransmitterKind kind,
  String id,
  LatLng p, {
  TransmitterSource source = TransmitterSource.apple,
  double accuracyM = 20,
  DateTime? updated,
}) => TransmitterRecord(
  kind: kind,
  id: id,
  lat: p.latitude,
  lon: p.longitude,
  accuracyM: accuracyM,
  source: source,
  updated: updated ?? DateTime.utc(2026, 11, 26, 12),
);

/// One wardriving sample of [id] taken at [p].
TransmitterSample sample(
  TransmitterKind kind,
  String id,
  LatLng p, {
  double signalDbm = -60,
  DateTime? time,
}) => TransmitterSample(
  kind: kind,
  id: id,
  lat: p.latitude,
  lon: p.longitude,
  weight: 1,
  fixAccuracyM: 5,
  signalDbm: signalDbm,
  rangeM: 15,
  time: time ?? DateTime.utc(2026, 11, 26, 12),
);
