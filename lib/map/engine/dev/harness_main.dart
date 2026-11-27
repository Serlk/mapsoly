// Development harness for the map engines: the map view alone, without the
// rest of the app, under a translucent bottom bar like the app's.
//
//   flutter build linux --release -t lib/map/engine/dev/harness_main.dart
//
// Environment (besides the engine's own MAPSOLY_MAP_* hooks):
//   MAPSOLY_MAP=/path/map.pmtiles   pack to draw (as in the app)
//   HARNESS_DARK=1                  dark theme
//   HARNESS_SCRIPT=name             scripted camera, see [_scripts]
//   HARNESS_BLUR=0                  do not pass the bar's rectangle as a blur rect
//   HARNESS_3D=1                    MapScene.buildings3d
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../offline/offline_map.dart';
import '../engines.dart';
import '../map_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _Harness());
}

class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  static final _env = Platform.environment;
  final MapViewController _map = createMapController();
  OfflineMap? _offline;
  bool _loading = true;
  String _status = '';
  LatLng? _position;
  List<LatLng>? _route;

  static const _kremlin = LatLng(55.752, 37.6175);

  @override
  void initState() {
    super.initState();
    _map.cameraChanges.addListener(_onCamera);
    OfflineMap.load().then((map) {
      if (!mounted) return;
      setState(() {
        _offline = map;
        _loading = false;
      });
      Timer(const Duration(seconds: 3), _runScript);
    });
  }

  void _onCamera() {
    final text =
        'bearing ${_map.bearing.toStringAsFixed(0)}°  pitch ${_map.pitch.toStringAsFixed(0)}°  '
        'z${_map.ready ? _map.zoom.toStringAsFixed(1) : '-'}';
    if (text != _status) setState(() => _status = text);
  }

  /// Scripted camera moves, to exercise the controller without input.
  Future<void> _runScript() async {
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    switch (_env['HARNESS_SCRIPT']) {
      case 'fit':
        // A route across the city centre: must end up centred in the part of
        // the view that is not under the bar.
        final route = [
          const LatLng(55.70, 37.52),
          const LatLng(55.74, 37.60),
          const LatLng(55.80, 37.70),
        ];
        setState(() => _route = route);
        _map.fit(route, const EdgeInsets.all(40));
      case 'drive':
        // Driving mode: about once a second a new position and course; camera
        // behind the car, tilted, position in the lower third.
        final size = context.size ?? const Size(720, 686);
        _map.setPadding(EdgeInsets.only(top: size.height * 0.45));
        var p = _kremlin;
        const distance = Distance();
        for (var i = 0; i < 40 && mounted; i++) {
          final course = 30.0 + i * 9; // a wide right-hand curve
          p = distance.offset(p, 25, course);
          setState(() => _position = p);
          _map.moveCamera(center: p, zoom: 17, bearing: course, pitch: 55);
          await wait(1000);
        }
      case 'spin':
        _map.moveCamera(
          center: _kremlin,
          zoom: 16,
          pitch: 55,
          duration: Duration.zero,
        );
        for (var i = 1; i <= 12 && mounted; i++) {
          _map.moveCamera(
            bearing: i * 30.0,
            duration: const Duration(seconds: 2),
          );
          await wait(2000);
        }
      case 'north':
        // 350° -> 10° must turn 20° through north, not 340° the other way.
        _map.moveCamera(
          center: _kremlin,
          zoom: 15,
          bearing: 350,
          duration: Duration.zero,
        );
        await wait(1500);
        _map.moveCamera(bearing: 10, duration: const Duration(seconds: 2));
      default:
    }
  }

  @override
  void dispose() {
    _map.cameraChanges.removeListener(_onCamera);
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D6B);
    final dark = _env['HARNESS_DARK'] == '1';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: seed,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      home: Builder(
        builder: (context) {
          final colors = Theme.of(context).colorScheme;
          const barHeight = 64.0;
          return Scaffold(
            extendBody: true,
            body: LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  buildMapView(
                    controller: _map,
                    scene: MapScene(
                      dark: dark,
                      offline: _offline,
                      offlineLoading: _loading,
                      buildings3d: _env['HARNESS_3D'] == '1',
                      route: _route,
                      from: _route?.first,
                      to: _route?.last,
                      position: _position,
                      positionAccuracyM: 15,
                      blurRects: _env['HARNESS_BLUR'] == '0'
                          ? const []
                          : [
                              Rect.fromLTWH(
                                0,
                                box.maxHeight - barHeight,
                                box.maxWidth,
                                barHeight,
                              ),
                            ],
                    ),
                    initialCenter: _kremlin,
                    initialZoom: 15,
                    onLongPress: (_) {},
                    onCameraChanged: (_, _) {},
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_status.isEmpty ? 'harness' : _status),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // The app's frosted bar: translucent surface over the map.
            bottomNavigationBar: Container(
              height: barHeight,
              decoration: BoxDecoration(
                color: colors.surfaceContainer.withValues(alpha: 0.72),
                border: Border(
                  top: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
              ),
              alignment: Alignment.center,
              child: Text('bar', style: TextStyle(color: colors.onSurface)),
            ),
          );
        },
      ),
    );
  }
}
