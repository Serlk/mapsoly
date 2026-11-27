import 'dart:async';

import 'package:dbus/dbus.dart';

/// Device compass: where the top of the device points, in degrees clockwise
/// from magnetic north.
///
/// Inside a car a magnetometer can be tens of degrees off (steel body,
/// speakers, magnetic mounts): good enough to orient a map while standing,
/// not to steer by.
abstract class CompassSource {
  /// Headings as they change. Empty when the device has no compass.
  Stream<double> get headings;

  Future<void> start();
  Future<void> stop();
}

/// Reads the compass that iio-sensor-proxy exposes on the system bus
/// (`net.hadess.SensorProxy.Compass`), which already fuses the
/// magnetometer with the accelerometer.
class SensorProxyCompass implements CompassSource {
  SensorProxyCompass({DBusClient? client})
    : _client = client ?? DBusClient.system(),
      _ownsClient = client == null;

  static const _name = 'net.hadess.SensorProxy';
  static const _interface = 'net.hadess.SensorProxy.Compass';
  static final _path = DBusObjectPath('/net/hadess/SensorProxy/Compass');

  final DBusClient _client;
  final bool _ownsClient;
  final _headings = StreamController<double>.broadcast();
  StreamSubscription<DBusSignal>? _changes;
  bool _claimed = false;

  @override
  Stream<double> get headings => _headings.stream;

  /// True when the system reports a compass at all.
  Future<bool> available() async {
    try {
      final v = await _property('HasCompass');
      return v is DBusBoolean && v.value;
    } on Exception {
      return false; // no sensor proxy on this system
    }
  }

  Future<DBusValue> _property(String name) async {
    final reply = await _client.callMethod(
      destination: _name,
      path: _path,
      interface: 'org.freedesktop.DBus.Properties',
      name: 'Get',
      values: [const DBusString(_interface), DBusString(name)],
      replySignature: DBusSignature('v'),
    );
    return reply.returnValues[0].asVariant();
  }

  void _emit(DBusValue? value) {
    if (value is DBusDouble && value.value >= 0) _headings.add(value.value);
  }

  @override
  Future<void> start() async {
    if (_claimed || !await available()) return;
    // The proxy only powers the sensor while somebody has claimed it.
    await _client.callMethod(
      destination: _name,
      path: _path,
      interface: _interface,
      name: 'ClaimCompass',
      replySignature: DBusSignature(''),
    );
    _claimed = true;
    _changes =
        DBusSignalStream(
          _client,
          sender: _name,
          path: _path,
          interface: 'org.freedesktop.DBus.Properties',
          name: 'PropertiesChanged',
        ).listen((signal) {
          if (signal.values.length < 2) return;
          final changed = signal.values[1].asStringVariantDict();
          _emit(changed['CompassHeading']);
        });
    _emit(await _property('CompassHeading'));
  }

  @override
  Future<void> stop() async {
    await _changes?.cancel();
    _changes = null;
    if (!_claimed) return;
    _claimed = false;
    try {
      await _client.callMethod(
        destination: _name,
        path: _path,
        interface: _interface,
        name: 'ReleaseCompass',
        replySignature: DBusSignature(''),
      );
    } on Exception {
      // The proxy went away: nothing left to release.
    }
  }

  Future<void> dispose() async {
    await stop();
    await _headings.close();
    if (_ownsClient) await _client.close();
  }
}

/// Smooths compass or course readings for rotating a map: small wobbles are
/// ignored, larger changes are followed gradually, always the short way
/// round.
class HeadingSmoother {
  HeadingSmoother({this.deadbandDeg = 3, this.gain = 0.25});

  /// Changes below this are treated as noise.
  final double deadbandDeg;

  /// Share of the remaining difference applied per reading (0..1).
  final double gain;

  double? _value;

  /// The smoothed heading, null before the first reading.
  double? get value => _value;

  /// Feeds a reading and returns the smoothed heading in 0..360.
  double add(double headingDeg) {
    final current = _value;
    if (current == null) return _value = headingDeg % 360;
    final diff = ((headingDeg - current + 540) % 360) - 180;
    if (diff.abs() < deadbandDeg) return current;
    return _value = (current + diff * gain) % 360;
  }

  void reset() => _value = null;
}
