
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/engine/maplibre/surface.dart';
import 'package:mapsoly/map/engine/maplibre/surface_android.dart';
import 'package:mapsoly/platform/android_properties.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('texturePixels', () {
    test('covers the logical size exactly at a fractional density', () {
      // A 1080x2208 px view at 2.75: the logical size is not a whole number.
      final px = texturePixels(const Size(1080 / 2.75, 2208 / 2.75), 2.75);
      expect(px, (width: 1080, height: 2208));
    });

    test('is never empty and never absurd', () {
      expect(texturePixels(Size.zero, 3), (width: 1, height: 1));
      expect(texturePixels(const Size(1e6, 10), 3).width, 16384);
    });
  });

  test('a Wayland buffer scale is a whole number between 1 and 4', () {
    final surface = WaylandMapSurface();
    expect(surface.ratioFor(1.0), 1);
    expect(surface.ratioFor(1.5), 2);
    expect(surface.ratioFor(2.4), 2);
    expect(surface.ratioFor(0.3), 1);
    expect(surface.ratioFor(7), 4);
    expect(surface.buildView(), isNull);
  });

  test('no Android system property off Android', () {
    expect(androidSystemProperty('debug.mapsoly.map_engine'), isNull);
  });

  group('TextureSurfaceController', () {
    const channel = MethodChannel('test/map_surface');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<String> calls;
    late List<(int, int, int)> windows;
    late List<String> errors;
    // Window handle the fake platform answers a resize with.
    late int Function(int width, int height) windowFor;

    TextureSurfaceController make() => TextureSurfaceController(
      channel: channel,
      onWindow: (window, w, h) => windows.add((window, w, h)),
      onError: errors.add,
    );

    /// What MapSurface.kt sends when Android replaces or takes the window.
    Future<void> platformSends(int texture, int window) =>
        messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('surface', {'texture': texture, 'window': window}),
          ),
          (_) {},
        );

    setUp(() {
      calls = [];
      windows = [];
      errors = [];
      windowFor = (w, h) => w * 10000 + h;
      messenger.setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'create':
            calls.add('create');
            return 7;
          case 'resize':
            final a = (call.arguments as Map).cast<String, Object?>();
            calls.add('resize ${a['texture']} ${a['width']}x${a['height']}');
            // The platform takes a moment: sizes asked for meanwhile pile up.
            await Future<void>.delayed(const Duration(milliseconds: 1));
            return windowFor(a['width']! as int, a['height']! as int);
          case 'dispose':
            calls.add('dispose ${call.arguments}');
            return null;
        }
        return null;
      });
    });

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('creates the texture once and reports the window of a size', () async {
      final c = make();
      expect(c.textureId.value, isNull);
      c.setSize(1080, 2208);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.textureId.value, 7);
      expect(calls, ['create', 'resize 7 1080x2208']);
      expect(windows, [(10802208, 1080, 2208)]);

      // The same size again asks for nothing.
      c.setSize(1080, 2208);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls.length, 2);
      c.dispose();
    });

    test('sizes overtaken while a request runs are skipped', () async {
      final c = make();
      c.setSize(100, 200);
      c.setSize(300, 400);
      c.setSize(500, 600);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, ['create', 'resize 7 500x600']);
      expect(windows, [(5000600, 500, 600)]);

      // A resize during a running one: both happen, in order, last one wins.
      c.setSize(700, 800);
      await Future<void>.delayed(Duration.zero);
      c.setSize(900, 1000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.sublist(2), ['resize 7 700x800', 'resize 7 900x1000']);
      expect(windows.last, (9001000, 900, 1000));
      c.dispose();
    });

    test(
      'a window taken away and given back is passed on with the size',
      () async {
        final c = make();
        c.setSize(1080, 2208);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        windows.clear();

        await platformSends(7, 0); // app in the background
        await platformSends(7, 4242); // and back
        await platformSends(99, 1); // someone else's texture
        expect(windows, [(0, 1080, 2208), (4242, 1080, 2208)]);
        c.dispose();
      },
    );

    test('no window (0) from the platform is "none", not an error', () async {
      windowFor = (_, _) => 0;
      final c = make();
      c.setSize(10, 10);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(windows, [(0, 10, 10)]);
      expect(errors, isEmpty);
      c.dispose();
    });

    test('dispose releases the texture and silences the rest', () async {
      final c = make();
      c.setSize(1080, 2208);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(calls.last, 'dispose 7');
      windows.clear();
      await platformSends(7, 4242);
      expect(windows, isEmpty);
    });

    test(
      'disposed while the texture is being created: it is released',
      () async {
        final c = make();
        c.setSize(1080, 2208);
        c.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(calls, ['create', 'dispose 7']);
        expect(windows, isEmpty);
      },
    );

    test('a platform error is reported once', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable', message: 'no library');
      });
      final c = make();
      c.setSize(1080, 2208);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(errors, ['no library']);
      expect(windows, isEmpty);
      c.dispose();
    });
  });
}
