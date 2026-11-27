import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:mapsoly/main.dart';
import 'package:mapsoly/map/engine/map_engine.dart';
import 'package:mapsoly/map/point_picker.dart';

/// Shared by the UI tests: renders a widget at the Titan 2's window size
/// (720x686 logical px), fails on layout overflow and, with `UI_SHOTS=dir`,
/// writes a PNG for inspection. `UI_FONT` / `UI_ICON_FONT` name real fonts
/// so that the pictures are readable.
final String? shotsDirectory = Platform.environment['UI_SHOTS'];

Future<void> loadShotFonts() async {
  Future<void> load(String family, String? path) async {
    if (path == null || !File(path).existsSync()) return;
    final loader = FontLoader(family)
      ..addFont(
        Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
      );
    await loader.load();
  }

  await load('Roboto', Platform.environment['UI_FONT']);
  await load('MaterialIcons', Platform.environment['UI_ICON_FONT']);
}

/// The app's own theme with a font that has Cyrillic glyphs.
ThemeData shotTheme(Brightness brightness) {
  final theme = MapsolyApp.theme(brightness);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: 'Roboto'),
  );
}

const _bar = [
  NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
  NavigationDestination(
    icon: Icon(Icons.navigation_outlined),
    label: 'Навигатор',
  ),
  NavigationDestination(icon: Icon(Icons.alt_route), label: 'Маршруты'),
  NavigationDestination(
    icon: Icon(Icons.settings_outlined),
    label: 'Настройки',
  ),
];

final _shotKey = GlobalKey();

/// Pumps [body] above the app's bottom bar ([tab] selected; null: no bar,
/// the body gets the whole window) and takes the picture. [size] defaults
/// to the Titan 2 window.
Future<void> shoot(
  WidgetTester tester,
  String name,
  Widget body, {
  int? tab,
  Brightness brightness = Brightness.light,
  Size size = const Size(720, 686),
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    // Above the app, so that dialogs and sheets are in the picture too.
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: shotTheme(brightness),
        home: tab == null
            ? body
            : Scaffold(
                body: body,
                bottomNavigationBar: NavigationBar(
                  height: 64,
                  selectedIndex: tab,
                  destinations: _bar,
                ),
              ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  expect(tester.takeException(), isNull, reason: '$name overflows');
  await snap(tester, name);
}

/// Writes the picture of what [shoot] (or [snapOf]'s boundary) shows now:
/// use it after tapping through a flow.
Future<void> snap(WidgetTester tester, String name, {GlobalKey? key}) async {
  expect(tester.takeException(), isNull, reason: '$name overflows');
  final shots = shotsDirectory;
  if (shots == null) return;
  await tester.runAsync(() async {
    final boundary =
        (key ?? _shotKey).currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$shots/$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// [MapServices] for tests: a fixed position, canned answers.
class FakeMapServices implements MapServices {
  FakeMapServices({this.myPosition, this.mapAnswer, this.searchAnswer});

  @override
  LatLng? myPosition;

  /// What "pick on the map" returns.
  PickedPlace? mapAnswer;

  /// What a tap on the fake search panel returns.
  PickedPlace? searchAnswer;
  int mapPicks = 0;

  @override
  Future<PickedPlace?> pickOnMap({
    required String title,
    LatLng? around,
  }) async {
    mapPicks++;
    return mapAnswer;
  }

  @override
  Widget searchPanel({
    required ValueChanged<PickedPlace> onSelected,
    required VoidCallback onClose,
  }) => Center(
    child: FilledButton(
      onPressed: () {
        final answer = searchAnswer;
        answer == null ? onClose() : onSelected(answer);
      },
      child: const Text('Результат поиска'),
    ),
  );
}

/// Something map-like to put under the glass cards: blocks, a park, water
/// and a few roads, in the colours of the light or the dark map.
class FakeMap extends StatelessWidget {
  const FakeMap({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _FakeMapPainter(Theme.of(context).brightness == Brightness.dark),
    child: SizedBox.expand(child: child),
  );
}

class _FakeMapPainter extends CustomPainter {
  _FakeMapPainter(this.dark);

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final land = dark ? const Color(0xFF1B2126) : const Color(0xFFF2EFE9);
    final block = dark ? const Color(0xFF242C33) : const Color(0xFFE4DFD6);
    final park = dark ? const Color(0xFF1E3329) : const Color(0xFFCDE6C3);
    final water = dark ? const Color(0xFF14303F) : const Color(0xFFAAD3DF);
    final road = dark ? const Color(0xFF55616B) : const Color(0xFFFFFFFF);
    final major = dark ? const Color(0xFF8A7A4A) : const Color(0xFFF7D488);
    canvas.drawRect(Offset.zero & size, Paint()..color = land);
    for (var x = 20.0; x < size.width; x += 110) {
      for (var y = 30.0; y < size.height; y += 90) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, 86, 64),
            const Radius.circular(4),
          ),
          Paint()..color = block,
        );
      }
    }
    canvas.drawOval(
      Rect.fromLTWH(size.width * 0.52, size.height * 0.1, 230, 170),
      Paint()..color = park,
    );
    final river = Path()
      ..moveTo(0, size.height * 0.62)
      ..quadraticBezierTo(
        size.width * 0.4,
        size.height * 0.45,
        size.width,
        size.height * 0.7,
      );
    canvas.drawPath(
      river,
      Paint()
        ..color = water
        ..style = PaintingStyle.stroke
        ..strokeWidth = 46,
    );
    Paint line(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    for (var x = 8.0; x < size.width; x += 110) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line(road, 6));
    }
    for (var y = 20.0; y < size.height; y += 90) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line(road, 6));
    }
    canvas.drawLine(
      Offset(0, size.height * 0.2),
      Offset(size.width, size.height * 0.85),
      line(major, 12),
    );
  }

  @override
  bool shouldRepaint(_FakeMapPainter old) => old.dark != dark;
}

/// A [MapViewController] that only remembers what it was told.
class FakeMapController extends ChangeNotifier implements MapViewController {
  FakeMapController({this.maxPitch = 60});

  @override
  bool ready = true;
  @override
  LatLng center = const LatLng(55.7522, 37.6156);
  @override
  double zoom = 12;
  @override
  double bearing = 0;
  @override
  double pitch = 0;
  @override
  final double maxPitch;
  EdgeInsets padding = EdgeInsets.zero;
  int moves = 0;
  List<LatLng>? fitted;
  bool disposed = false;

  @override
  Listenable get cameraChanges => this;

  @override
  void move(LatLng center, double zoom) =>
      moveCamera(center: center, zoom: zoom);

  @override
  void moveCamera({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    Duration? duration,
  }) {
    moves++;
    this.center = center ?? this.center;
    this.zoom = zoom ?? this.zoom;
    this.bearing = bearing ?? this.bearing;
    this.pitch = pitch ?? this.pitch;
    notifyListeners();
  }

  /// What a finger on the map does (the camera changes, nobody asked).
  void gesture({LatLng? center, double? bearing, double? pitch}) {
    this.center = center ?? this.center;
    this.bearing = bearing ?? this.bearing;
    this.pitch = pitch ?? this.pitch;
    notifyListeners();
  }

  @override
  void setPadding(EdgeInsets padding) => this.padding = padding;

  int? frameRateLimit;

  @override
  void setFrameRateLimit(int? fps) => frameRateLimit = fps;

  @override
  void fit(List<LatLng> points, EdgeInsets padding) => fitted = points;

  @override
  void panBy(Offset fraction) => notifyListeners();

  @override
  void resetNorth() => moveCamera(bearing: 0);
}

/// Lets real file IO started by a tap finish: it only advances while the
/// test is inside `runAsync`, and its results show after a pump.
Future<void> settleIo(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}
