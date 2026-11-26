// Test app of the MapLibre-in-Flutter prototype (not the Mapsoly app).
//
// Environment:
//   MLN_STYLE=/abs/path/style.json   style to load (default: the spike's bright style)
//   MLN_BENCH=1                      start the scripted camera run after start-up and
//                                    exit when it is done
//   MLN_BENCH_OUT=/abs/prefix        output prefix (default /tmp/mlnb)
//   MLN_SUBSURFACE=1                 route B: map in a Wayland subsurface below a
//                                    transparent Flutter window (also read by the runner)
//   MLN_DEMO=1                       exercise the Dart API without touch input: moveBy,
//                                    zoomBy, setCamera, rotateBy, then shrink the map
//                                    widget (resize). One step per second, logged to stderr.
//   MLN_STATIC=1                     do not refresh the info card while the script runs, so
//                                    Flutter draws no frames of its own (route B then shows
//                                    the map alone; route A still needs one Flutter frame
//                                    per map frame)
//   MLN_TICKER=1                     keep a Flutter animation running on top of the map,
//                                    so every frame is a full Flutter frame (build +
//                                    raster) and shows up in FrameTiming. Without it the
//                                    map-only frames are raster-only and Flutter reports
//                                    no timings for them.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'mln_map.dart';

const _defaultStyle =
    '/home/serlk/mapsoly-maplibre/assets/styles/bright.json';

void main() {
  runApp(const SpikeApp());
}

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MlnFlutterSpike',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: const MapPage(),
  );
}

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _env = Platform.environment;
  MlnMapController? _map;
  MlnMapState? _state;
  Timer? _poll;
  int _lastConsumed = 0;
  DateTime _lastPoll = DateTime.now();
  double _mapFps = 0;
  bool _benchRunning = false;
  double _bottomInset = 0;
  final List<FrameTiming> _timings = [];
  late final String _outPrefix = _env['MLN_BENCH_OUT'] ?? '/tmp/mlnb';

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> t) {
    if (_benchRunning) _timings.addAll(t);
  }

  void _onCreated(MlnMapController c) {
    _map = c;
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    if (_env['MLN_BENCH'] == '1') {
      Timer(const Duration(milliseconds: 1500), _startBench);
    }
    if (_env['MLN_DEMO'] == '1') _demo(c);
  }

  /// Calls every camera method once, a second apart, so a screenshot after each
  /// step shows whether the Dart -> FFI -> map thread path works.
  Future<void> _demo(MlnMapController c) async {
    final steps = <(String, void Function())>[
      ('moveBy(120, 60)', () => c.moveBy(120, 60)),
      (
        'zoomBy(+1, focal 180,170, 300 ms)',
        () => c.zoomBy(
          1,
          focalPoint: const Offset(180, 170),
          duration: const Duration(milliseconds: 300),
        ),
      ),
      (
        'setCamera(bearing 30, pitch 45, 400 ms)',
        () => c.setCamera(
          bearing: 30,
          pitch: 45,
          duration: const Duration(milliseconds: 400),
        ),
      ),
      ('rotateBy(60)', () => c.rotateBy(60)),
      (
        'setCamera(55.76, 37.64, z13, bearing 0, pitch 0)',
        () => c.setCamera(lat: 55.76, lon: 37.64, zoom: 13, bearing: 0, pitch: 0),
      ),
      ('resize: bottom inset 200', () => setState(() => _bottomInset = 200)),
      ('resize: bottom inset 0', () => setState(() => _bottomInset = 0)),
    ];
    await Future<void>.delayed(const Duration(seconds: 3));
    for (final (name, fn) in steps) {
      stderr.writeln('DEMO $name');
      fn();
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    stderr.writeln('DEMO done');
  }

  Future<void> _tick() async {
    final c = _map;
    if (c == null) return;
    final s = await c.state();
    final now = DateTime.now();
    final dt = now.difference(_lastPoll).inMicroseconds / 1e6;
    if (!mounted) return;
    if (!(_benchRunning && _env['MLN_STATIC'] == '1')) {
      setState(() {
        _state = s;
        if (dt > 0) _mapFps = (s.consumed - _lastConsumed) / dt;
        _lastConsumed = s.consumed;
        _lastPoll = now;
      });
    }
    if (_benchRunning && s.bench == 2) {
      _benchRunning = false;
      await _writeTimings();
      if (_env['MLN_BENCH'] == '1') {
        stderr.writeln('BENCH flutter timings written, exiting');
        exit(0);
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _startBench() async {
    final c = _map;
    if (c == null || _benchRunning) return;
    _timings.clear();
    await c.startBenchmark(_outPrefix);
    setState(() => _benchRunning = true);
  }

  /// One row per frame Flutter rasterised while the script ran. Timestamps are
  /// CLOCK_MONOTONIC microseconds, the clock the native logs use too.
  Future<void> _writeTimings() async {
    final b = StringBuffer(
      'vsync_us,build_start_us,build_us,raster_start_us,raster_us,raster_finish_us,total_us,frame_number\n',
    );
    for (final t in _timings) {
      b.writeln(
        '${t.timestampInMicroseconds(FramePhase.vsyncStart)},'
        '${t.timestampInMicroseconds(FramePhase.buildStart)},'
        '${t.buildDuration.inMicroseconds},'
        '${t.timestampInMicroseconds(FramePhase.rasterStart)},'
        '${t.rasterDuration.inMicroseconds},'
        '${t.timestampInMicroseconds(FramePhase.rasterFinish)},'
        '${t.totalSpan.inMicroseconds},'
        '${t.frameNumber}',
      );
    }
    await File('$_outPrefix.flutter.csv').writeAsString(b.toString());
    _timings.clear();
  }

  @override
  void dispose() {
    _poll?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final c = _map;
    final subsurface = _env['MLN_SUBSURFACE'] == '1';
    return Scaffold(
      backgroundColor: subsurface ? Colors.transparent : null,
      body: Stack(
        children: [
          Positioned.fill(
            bottom: _bottomInset,
            child: MlnMapView(
              style: _env['MLN_STYLE'] ?? _defaultStyle,
              subsurface: subsurface,
              onCreated: _onCreated,
            ),
          ),
          // Ordinary Flutter widgets composited over the map.
          Positioned(
            left: 12,
            top: 12,
            child: Card(
              color: Colors.white.withValues(alpha: 0.6),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  s == null
                      ? 'MapLibre Native in Flutter\nstarting…'
                      : 'MapLibre Native in Flutter\n'
                            '${s.lat.toStringAsFixed(4)}, ${s.lon.toStringAsFixed(4)}  '
                            'z${s.zoom.toStringAsFixed(2)}\n'
                            'bearing ${s.bearing.toStringAsFixed(0)}°  '
                            'pitch ${s.pitch.toStringAsFixed(0)}°\n'
                            'map frames shown: ${_mapFps.toStringAsFixed(1)}/s'
                            '${_benchRunning ? '  (script running)' : ''}',
                  style: const TextStyle(fontSize: 13, height: 1.3),
                ),
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                FloatingActionButton.small(
                  heroTag: 'in',
                  onPressed: c == null
                      ? null
                      : () => c.zoomBy(
                          1,
                          duration: const Duration(milliseconds: 300),
                        ),
                  child: const Icon(Icons.add),
                ),
                FloatingActionButton.small(
                  heroTag: 'out',
                  onPressed: c == null
                      ? null
                      : () => c.zoomBy(
                          -1,
                          duration: const Duration(milliseconds: 300),
                        ),
                  child: const Icon(Icons.remove),
                ),
                FloatingActionButton.small(
                  heroTag: 'north',
                  onPressed: c == null
                      ? null
                      : () => c.setCamera(
                          bearing: 0,
                          pitch: 0,
                          duration: const Duration(milliseconds: 400),
                        ),
                  child: const Icon(Icons.navigation),
                ),
                FloatingActionButton.small(
                  heroTag: 'tilt',
                  onPressed: c == null
                      ? null
                      : () => c.setCamera(
                          pitch: 50,
                          bearing: 40,
                          duration: const Duration(milliseconds: 400),
                        ),
                  child: const Icon(Icons.threed_rotation),
                ),
              ],
            ),
          ),
          if (_env['MLN_TICKER'] == '1')
            const Positioned(
              right: 16,
              top: 16,
              child: SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 5),
              ),
            ),
          Positioned(
            left: 12,
            bottom: 12,
            child: FilledButton.tonal(
              onPressed: c == null || _benchRunning ? null : _startBench,
              child: Text(_benchRunning ? 'Script running…' : 'Run script'),
            ),
          ),
        ],
      ),
    );
  }
}
