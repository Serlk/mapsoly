import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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

/// A compass of this device, as opposed to a stand-in: it may be missing,
/// and holds resources to release.
abstract class LocalCompass implements CompassSource {
  /// True when the device has the sensors for it.
  Future<bool> available();

  Future<void> dispose();
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

/// Where the device points, from one magnetometer and one accelerometer
/// reading in the device frame (x to the right of the screen, y to its
/// top, z out of it — the frame phone sensor hubs report in).
///
/// Lying flat or tilted, it is the direction of the top edge; held
/// upright (in a car mount), the direction the back of the device faces.
/// Null when the readings cannot give a direction (free fall, or the
/// field parallel to gravity).
double? compassHeading(
  ({double x, double y, double z}) magnet,
  ({double x, double y, double z}) accel,
) {
  // East = magnet × up, north = up × east; `accel` at rest points up.
  final ax = accel.x, ay = accel.y, az = accel.z;
  final an = math.sqrt(ax * ax + ay * ay + az * az);
  if (an < 1e-6) return null;
  final ux = ax / an, uy = ay / an, uz = az / an;
  var ex = magnet.y * uz - magnet.z * uy;
  var ey = magnet.z * ux - magnet.x * uz;
  var ez = magnet.x * uy - magnet.y * ux;
  final en = math.sqrt(ex * ex + ey * ey + ez * ez);
  if (en < 1e-9) return null;
  ex /= en;
  ey /= en;
  ez /= en;
  final ny = uz * ex - ux * ez;
  final nz = ux * ey - uy * ex;
  // Upright: the top edge points at the sky and has no compass direction;
  // the driver looks along the back of the device instead.
  final upright = uy.abs() > 0.8;
  final east = upright ? -ez : ey;
  final north = upright ? -nz : ny;
  final deg = math.atan2(east, north) * 180 / math.pi;
  return (deg + 360) % 360;
}

/// A compass made of the kernel's IIO magnetometer and accelerometer,
/// read from sysfs. For devices whose magnetometer iio-sensor-proxy does
/// not offer as a compass (the Titan 2's sensor hub is one).
class IioCompass implements CompassSource {
  IioCompass({
    this.root = defaultRoot,
    this.interval = const Duration(milliseconds: 120),
    this.magnetName,
    this.accelName,
  });

  static const defaultRoot = '/sys/bus/iio/devices';

  final String root;
  final Duration interval;

  /// IIO names of the sensors to use ("hub-magn"); null takes the first
  /// one of the kind.
  final String? magnetName, accelName;

  /// Names of the IIO devices under [root] that measure [axis] ("magn" or
  /// "accel"), for choosing one by hand.
  static List<String> sensors(String axis, {String root = defaultRoot}) => [
    for (final d in _all(root, axis)) _nameOf(d),
  ];

  static String _nameOf(Directory d) {
    try {
      final name = File('${d.path}/name').readAsStringSync().trim();
      if (name.isNotEmpty) return name;
    } on FileSystemException {
      // No name attribute: the directory name will do.
    }
    return d.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  }

  static List<Directory> _all(String root, String axis) {
    final dir = Directory(root);
    if (!dir.existsSync()) return const [];
    final found = <Directory>[
      // Entries of /sys/bus/iio/devices are links to directories.
      for (final e in dir.listSync())
        if (File('${e.path}/in_${axis}_x_raw').existsSync()) Directory(e.path),
    ];
    return found..sort((a, b) => a.path.compareTo(b.path));
  }

  final _headings = StreamController<double>.broadcast();
  Timer? _timer;
  Directory? _magnet, _accel;
  bool _reading = false;
  ({double x, double y, double z})? _smoothMagnet, _smoothAccel;

  static ({double x, double y, double z}) _blend(
    ({double x, double y, double z})? old,
    ({double x, double y, double z}) next,
  ) {
    if (old == null) return next;
    const k = 0.25;
    return (
      x: old.x + (next.x - old.x) * k,
      y: old.y + (next.y - old.y) * k,
      z: old.z + (next.z - old.z) * k,
    );
  }

  @override
  Stream<double> get headings => _headings.stream;

  static Directory? _find(String root, String axis, String? name) {
    final all = _all(root, axis);
    if (name == null) return all.firstOrNull;
    return all.where((d) => _nameOf(d) == name).firstOrNull;
  }

  /// True when both sensors are there.
  bool available() {
    _magnet ??= _find(root, 'magn', magnetName);
    _accel ??= _find(root, 'accel', accelName);
    return _magnet != null && _accel != null;
  }

  static Future<({double x, double y, double z})?> _read(
    Directory device,
    String axis,
  ) async {
    Future<double?> value(String name) async {
      try {
        final text = await File('${device.path}/$name').readAsString();
        return double.tryParse(text.trim());
      } on FileSystemException {
        return null;
      }
    }

    final x = await value('in_${axis}_x_raw');
    final y = await value('in_${axis}_y_raw');
    final z = await value('in_${axis}_z_raw');
    return x == null || y == null || z == null ? null : (x: x, y: y, z: z);
  }

  Future<void> _tick() async {
    if (_reading) return;
    _reading = true;
    try {
      final m = await _read(_magnet!, 'magn');
      final a = await _read(_accel!, 'accel');
      if (m == null || a == null || _headings.isClosed) return;
      // The magnetometer is noisy (a few degrees from reading to reading):
      // both vectors are low-pass filtered before the direction is taken.
      // Raw counts are enough: only directions matter here.
      final magnet = _smoothMagnet = _blend(_smoothMagnet, m);
      final accel = _smoothAccel = _blend(_smoothAccel, a);
      final heading = compassHeading(magnet, accel);
      if (heading != null) _headings.add(heading);
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> start() async {
    if (_timer != null || !available()) return;
    _timer = Timer.periodic(interval, (_) => _tick());
    await _tick();
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _smoothMagnet = null;
    _smoothAccel = null;
  }
}

/// Which compass to use.
enum CompassChoice {
  /// The system's, where it has one, else the raw sensors.
  auto,

  /// Only the system service (iio-sensor-proxy).
  system,

  /// Only the raw magnetometer and accelerometer.
  raw,
}

/// The device compass, as chosen: by default the system's, where it has
/// one, else the raw sensors.
class DeviceCompass implements LocalCompass {
  DeviceCompass({
    this.choice = CompassChoice.auto,
    SensorProxyCompass? proxy,
    IioCompass? iio,
  }) : _proxy = proxy ?? SensorProxyCompass(),
       _iio = iio ?? IioCompass();

  final CompassChoice choice;
  final SensorProxyCompass _proxy;
  final IioCompass _iio;
  final _headings = StreamController<double>.broadcast();
  StreamSubscription<double>? _sub;
  CompassSource? _active;

  @override
  Stream<double> get headings => _headings.stream;

  Future<CompassSource?> _pick() async {
    if (choice != CompassChoice.raw && await _proxy.available()) return _proxy;
    if (choice != CompassChoice.system && _iio.available()) return _iio;
    return null;
  }

  /// True when the chosen kind of compass is there.
  @override
  Future<bool> available() async => await _pick() != null;

  /// What is in use, for showing to the user: "system", "raw" or null.
  Future<String?> describe() async {
    final source = await _pick();
    return source == null ? null : (source == _proxy ? 'system' : 'raw');
  }

  @override
  Future<void> start() async {
    if (_active != null) return;
    final source = await _pick();
    if (source == null) return;
    _active = source;
    _sub = source.headings.listen(_headings.add);
    await source.start();
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final source = _active;
    _active = null;
    await source?.stop();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _headings.close();
    await _proxy.dispose();
  }
}
