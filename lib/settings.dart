import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'map/position_arrow.dart';
import 'obd/obd_service.dart';
import 'positioning/sources/linux_compass.dart';
import 'traffic/traffic.dart';

/// Map server used unless the user enters another one in the settings.
const defaultCatalogUrl = 'https://mp.srlk-dd.ru/catalog.json';

/// Turns what a user typed into a catalog address, or returns null when it
/// cannot be one. A bare host gets `https://` and `/catalog.json`.
String? normalizeCatalogUrl(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'https://$text';
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final path = uri.path.isEmpty || uri.path == '/' ? '/catalog.json' : uri.path;
  return uri.replace(path: path).toString();
}

/// User choices that survive restarts, kept in a small JSON file.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._file);

  final File? _file;
  ThemeMode _themeMode = ThemeMode.system;
  TrafficSource _traffic = TrafficSource.off;
  LatLng? _center;
  bool _onlineLocation = false;
  bool _wardriving = false;
  String? _catalogUrl;
  ObdConfig _obd = const ObdConfig();
  double? _zoom;
  bool _drive3d = true;
  bool _speedSound = true;
  CompassChoice _compass = CompassChoice.auto;
  String? _magnetSensor, _accelSensor;
  PositionArrow _positionArrow = PositionArrow.chevron;
  bool _tilted = false;

  /// Whether the camera tilts and turns along the route during guidance
  /// (on engines that can tilt). Off: the map stays flat and north-up.
  bool get drive3d => _drive3d;

  set drive3d(bool value) {
    if (value == _drive3d) return;
    _drive3d = value;
    _changed();
  }

  /// Whether reaching the fine (limit + 20 km/h) is announced by a signal.
  bool get speedSound => _speedSound;

  set speedSound(bool value) {
    if (value == _speedSound) return;
    _speedSound = value;
    _changed();
  }

  /// Which compass to use (Linux): chosen by hand when the automatic pick
  /// is wrong or finds nothing.
  CompassChoice get compass => _compass;

  /// IIO names of the magnetometer and accelerometer for the raw compass;
  /// null lets the app take the first of each.
  String? get magnetSensor => _magnetSensor;
  String? get accelSensor => _accelSensor;

  void setCompass({
    required CompassChoice choice,
    required String? magnet,
    required String? accel,
  }) {
    if (choice == _compass &&
        magnet == _magnetSensor &&
        accel == _accelSensor) {
      return;
    }
    _compass = choice;
    _magnetSensor = magnet;
    _accelSensor = accel;
    _changed();
  }

  /// How the position is drawn when its direction is known.
  PositionArrow get positionArrow => _positionArrow;

  set positionArrow(PositionArrow value) {
    if (value == _positionArrow) return;
    _positionArrow = value;
    _changed();
  }

  /// Whether the map was left tilted (3D) outside guidance.
  bool get tilted => _tilted;

  /// Saved without notifying listeners: the map itself is the source.
  set tilted(bool value) {
    if (value == _tilted) return;
    _tilted = value;
    _write();
  }

  ThemeMode get themeMode => _themeMode;
  TrafficSource get traffic => _traffic;

  /// Whether unknown Wi-Fi/cell transmitters may be looked up online
  /// (beaconDB, Apple). Each lookup reveals what is nearby, so it is opt-in.
  bool get onlineLocation => _onlineLocation;

  /// Whether transmitter positions are recorded while GNSS is trustworthy.
  bool get wardriving => _wardriving;

  set onlineLocation(bool value) {
    if (value == _onlineLocation) return;
    _onlineLocation = value;
    _changed();
  }

  set wardriving(bool value) {
    if (value == _wardriving) return;
    _wardriving = value;
    _changed();
  }

  /// Where the list of downloadable region packs is fetched from: the
  /// user's own server if one was entered, otherwise [defaultCatalogUrl].
  String get catalogUrl => _catalogUrl ?? defaultCatalogUrl;

  /// True when the address was changed from the default.
  bool get hasCustomCatalog => _catalogUrl != null;

  /// Sets the catalog address; null or the default address resets it.
  set catalogUrl(String? value) {
    final v = value == null || value == defaultCatalogUrl ? null : value;
    if (v == _catalogUrl) return;
    _catalogUrl = v;
    _changed();
  }

  /// ELM327 adapter and what to read from the car.
  ObdConfig get obd => _obd;

  set obd(ObdConfig value) {
    if (value == _obd) return;
    _obd = value;
    _changed();
  }

  /// Last map position, null on first launch.
  LatLng? get center => _center;
  double? get zoom => _zoom;

  /// Saves the map position without notifying listeners: the map itself is
  /// the only source of this value.
  void saveCamera(LatLng center, double zoom) {
    _center = center;
    _zoom = zoom;
    _write();
  }

  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    _changed();
  }

  set traffic(TrafficSource value) {
    if (value == _traffic) return;
    _traffic = value;
    _changed();
  }

  static Future<AppSettings> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final settings = AppSettings._(File('${dir.path}/settings.json'));
      final file = settings._file!;
      if (file.existsSync()) {
        final json = jsonDecode(file.readAsStringSync()) as Map;
        settings._themeMode = _byName(ThemeMode.values, json['themeMode']);
        settings._traffic = _byName(TrafficSource.values, json['traffic']);
        settings._onlineLocation = json['onlineLocation'] == true;
        settings._wardriving = json['wardriving'] == true;
        settings._drive3d = json['drive3d'] != false;
        settings._speedSound = json['speedSound'] != false;
        settings._compass = _byName(CompassChoice.values, json['compass']);
        settings._magnetSensor = json['magnetSensor'] as String?;
        settings._positionArrow = _byName(
          PositionArrow.values,
          json['positionArrow'],
        );
        settings._accelSensor = json['accelSensor'] as String?;
        settings._tilted = json['tilted'] == true;
        final obd = json['obd'];
        if (obd is Map<String, dynamic>) {
          settings._obd = ObdConfig.fromJson(obd);
        }
        final catalog = json['catalogUrl'];
        if (catalog is String && catalog.isNotEmpty) {
          settings._catalogUrl = catalog;
        }
        final lat = json['lat'], lon = json['lon'], zoom = json['zoom'];
        if (lat is num && lon is num && zoom is num) {
          settings._center = LatLng(lat.toDouble(), lon.toDouble());
          settings._zoom = zoom.toDouble();
        }
      }
      return settings;
    } on Exception catch (e) {
      // Unreadable settings must not block startup: run with defaults.
      debugPrint('Settings not loaded: $e');
      return AppSettings._(null);
    }
  }

  static T _byName<T extends Enum>(List<T> values, Object? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => values.first);

  void _changed() {
    notifyListeners();
    _write();
  }

  void _write() {
    try {
      _file
        ?..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'themeMode': _themeMode.name,
            'traffic': _traffic.name,
            'onlineLocation': _onlineLocation,
            'wardriving': _wardriving,
            'drive3d': _drive3d,
            'speedSound': _speedSound,
            'compass': _compass.name,
            'positionArrow': _positionArrow.name,
            if (_magnetSensor != null) 'magnetSensor': _magnetSensor,
            if (_accelSensor != null) 'accelSensor': _accelSensor,
            'tilted': _tilted,
            if (_catalogUrl != null) 'catalogUrl': _catalogUrl,
            'obd': _obd.toJson(),
            if (_center != null) ...{
              'lat': _center!.latitude,
              'lon': _center!.longitude,
              'zoom': _zoom,
            },
          }),
        );
    } on FileSystemException catch (e) {
      debugPrint('Settings not saved: $e');
    }
  }
}
