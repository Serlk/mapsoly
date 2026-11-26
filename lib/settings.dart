import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import 'traffic/traffic.dart';

/// User choices that survive restarts, kept in a small JSON file.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._file);

  final File? _file;
  ThemeMode _themeMode = ThemeMode.system;
  TrafficSource _traffic = TrafficSource.off;
  LatLng? _center;
  bool _onlineLocation = false;
  bool _wardriving = false;
  double? _zoom;

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
