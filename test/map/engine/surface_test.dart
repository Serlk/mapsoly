import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/engine/maplibre/surface.dart';
import 'package:mapsoly/map/engine/maplibre/surface_android.dart';
import 'package:mapsoly/platform/android_properties.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bufferPixels', () {
    test('covers the logical size exactly at a fractional density', () {
      // A 1080x2208 px view at 2.75: the logical size is not a whole number.
      final px = bufferPixels(const Size(1080 / 2.75, 2208 / 2.75), 2.75);
      expect(px, (width: 1080, height: 2208));
    });

    test('is never empty and never absurd', () {
      expect(bufferPixels(Size.zero, 3), (width: 1, height: 1));
      expect(bufferPixels(const Size(1e6, 10), 3).width, 16384);
    });
  });

  group('placeSurface', () {
    test('at the screen ratio the buffers are the view, pixel for pixel', () {
      // A 1080x2208 px view that starts 66 px down, at 2.75.
      final p = placeSurface(
        const Rect.fromLTWH(0, 66 / 2.75, 1080 / 2.75, 2208 / 2.75),
        2.75,
        2.75,
      );
      expect(p, (
        x: 0,
        y: 66,
        width: 1080,
        height: 2208,
        bufferWidth: 1080,
        bufferHeight: 2208,
      ));
    });

    test('edges are rounded, not sizes: no gap to the neighbour', () {
      // Top at 10.4 logical = 13.2 px, bottom at 500.6 logical = 635.8 px.
      final p = placeSurface(
        const Rect.fromLTRB(0, 10.4, 300, 500.6),
        1.27,
        1.27,
      );
      expect(p.y, 13);
      expect(p.y + p.height, 636);
      expect(p.width, 381);
      expect((p.bufferWidth, p.bufferHeight), (p.width, p.height));
    });

    test('at a lower map ratio the buffers are smaller than the view', () {
      // The tablet: 1600x2560 px at 1.27, the map drawn at 1.
      const logical = Size(1600 / 1.27, 2560 / 1.27);
      final p = placeSurface(Offset.zero & logical, 1.27, 1.0);
      expect((p.width, p.height), (1600, 2560));
      expect((p.bufferWidth, p.bufferHeight), (1260, 2016));
      // What MapLibre lays out is the logical size again.
      expect((p.bufferWidth / 1.0).round(), logical.width.round());
    });

    test('never empty, and the buffers never larger than the view', () {
      final empty = placeSurface(Rect.zero, 2, 2);
      expect((empty.width, empty.height), (1, 1));
      expect((empty.bufferWidth, empty.bufferHeight), (1, 1));
      // A map ratio above the screen's (not asked for by the engine).
      final over = placeSurface(const Rect.fromLTWH(0, 0, 100, 50), 1.5, 2);
      expect((over.bufferWidth, over.bufferHeight), (150, 75));
    });
  });

  test('a Wayland buffer scale is a whole number between 1 and 4', () {
    final surface = WaylandMapSurface();
    expect(surface.ratioFor(1.0), 1);
    expect(surface.ratioFor(1.5), 2);
    expect(surface.ratioFor(2.4), 2);
    expect(surface.ratioFor(0.3), 1);
    expect(surface.ratioFor(7), 4);
    expect(surface.wholeLogicalPixels, isTrue);
    expect(surface.present, isNull);
  });

  test('no Android system property off Android', () {
    expect(androidSystemProperty('debug.mapsoly.map_engine'), isNull);
  });

  group('SurfaceViewController', () {
    const channel = MethodChannel('test/map_surface');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    late List<(int, int, int)> windows;
    late List<String> errors;

    SurfaceViewController make() => SurfaceViewController(
      channel: channel,
      onWindow: (window, w, h) => windows.add((window, w, h)),
      onError: errors.add,
    );

    SurfacePlacement at(int width, int height, {int y = 0, int? buffer}) => (
      x: 0,
      y: y,
      width: width,
      height: height,
      bufferWidth: buffer ?? width,
      bufferHeight: buffer == null ? height : buffer * height ~/ width,
    );

    /// What MapSurface.kt sends when Android makes, changes or takes the
    /// window.
    Future<void> platformSends(
      int surface,
      int window, [
      int width = 0,
      int height = 0,
    ]) => messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('surface', {
          'surface': surface,
          'window': window,
          'width': width,
          'height': height,
        }),
      ),
      (_) {},
    );

    setUp(() {
      calls = [];
      windows = [];
      errors = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'create':
            calls.add('create');
            return 7;
          case 'place':
            final a = (call.arguments as Map).cast<String, Object?>();
            calls.add(
              'place ${a['surface']} ${a['x']},${a['y']} '
              '${a['width']}x${a['height']} '
              'buffers ${a['bufferWidth']}x${a['bufferHeight']}',
            );
            // The platform takes a moment: placements asked for meanwhile
            // pile up.
            await Future<void>.delayed(const Duration(milliseconds: 1));
            return null;
          case 'dispose':
            calls.add('dispose ${call.arguments}');
            return null;
        }
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('creates the view once and places it', () async {
      final c = make();
      c.place(at(1600, 2400, y: 60, buffer: 1260));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, ['create', 'place 7 0,60 1600x2400 buffers 1260x1890']);
      // The window is not an answer: Android announces it.
      expect(windows, isEmpty);
      await platformSends(7, 4242, 1260, 1890);
      expect(windows, [(4242, 1260, 1890)]);

      // The same placement again asks for nothing.
      c.place(at(1600, 2400, y: 60, buffer: 1260));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.length, 2);
      c.dispose();
    });

    test('placements overtaken while a request runs are skipped', () async {
      final c = make();
      c.place(at(100, 200));
      c.place(at(300, 400));
      c.place(at(500, 600));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, ['create', 'place 7 0,0 500x600 buffers 500x600']);

      // A placement during a running one: both happen, in order.
      c.place(at(700, 800));
      await Future<void>.delayed(Duration.zero);
      c.place(at(900, 1000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.sublist(2), [
        'place 7 0,0 700x800 buffers 700x800',
        'place 7 0,0 900x1000 buffers 900x1000',
      ]);
      c.dispose();
    });

    test('a move without a new size is sent too', () async {
      final c = make();
      c.place(at(500, 600));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.place(at(500, 600, y: 40));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.last, 'place 7 0,40 500x600 buffers 500x600');
      c.dispose();
    });

    test('a window taken away keeps the size of its buffers', () async {
      final c = make();
      c.place(at(1080, 2208));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await platformSends(7, 4242, 1080, 2208);
      windows.clear();

      await platformSends(7, 0); // app in the background
      await platformSends(7, 4343, 1080, 2208); // and back
      await platformSends(7, 4343, 2208, 1080); // rotated: other buffers
      await platformSends(99, 1, 5, 5); // someone else's surface
      expect(windows, [
        (0, 1080, 2208),
        (4343, 1080, 2208),
        (4343, 2208, 1080),
      ]);
      c.dispose();
    });

    test('"no window" before there ever was one says nothing', () async {
      final c = make();
      c.place(at(10, 10));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await platformSends(7, 0);
      expect(windows, isEmpty);
      expect(errors, isEmpty);
      c.dispose();
    });

    test('dispose removes the view and silences the rest', () async {
      final c = make();
      c.place(at(1080, 2208));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.dispose();
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls.last, 'dispose 7');
      expect(calls.where((c) => c.startsWith('dispose')).length, 1);
      await platformSends(7, 4242, 1080, 2208);
      expect(windows, isEmpty);
    });

    test('disposed while the view is being created: it is removed', () async {
      final c = make();
      c.place(at(1080, 2208));
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, ['create', 'dispose 7']);
      expect(windows, isEmpty);
    });

    test('a platform error is reported once', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable', message: 'no library');
      });
      final c = make();
      c.place(at(1080, 2208));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(errors, ['no library']);
      expect(windows, isEmpty);
      c.dispose();
    });
  });

  group('AndroidMapSurface', () {
    test('is outside Flutter\'s scene, on exact pixels', () {
      final surface = AndroidMapSurface();
      expect(surface.wholeLogicalPixels, isFalse);
      // Nothing to show before a map has a window.
      expect(surface.present.value, isFalse);
      surface.dispose();
      surface.dispose();
    });

    test('the map ratio follows the budget unless full resolution is on', () {
      final surface = AndroidMapSurface();
      const view = Size(1600 / 1.27, 2560 / 1.27);
      expect(surface.ratioFor(1.27, view), 1.0);
      AndroidMapSurface.fullResolution = true;
      addTearDown(() => AndroidMapSurface.fullResolution = false);
      expect(surface.ratioFor(1.27, view), 1.27);
      surface.dispose();
    });
  });
}
