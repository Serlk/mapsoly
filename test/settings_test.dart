import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/settings.dart';
import 'package:mapsoly/traffic/traffic.dart';

void main() {
  group('signal map switch', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('mapsoly_settings_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => dir.path);
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      dir.deleteSync(recursive: true);
    });

    test('off by default, also for settings saved before it existed', () async {
      expect((await AppSettings.load()).signalHeat, isFalse);
      File(
        '${dir.path}/settings.json',
      ).writeAsStringSync(jsonEncode({'traffic': 'yandex', 'drive3d': false}));
      final settings = await AppSettings.load();
      expect(settings.traffic.name, 'yandex');
      expect(settings.signalHeat, isFalse);
    });

    test('the spoofing check is on unless switched off', () async {
      final settings = await AppSettings.load();
      expect(settings.spoofingCheck, isTrue);
      var told = 0;
      settings.addListener(() => told++);
      settings.spoofingCheck = false;
      settings.spoofingCheck = false;
      expect(told, 1);
      expect((await AppSettings.load()).spoofingCheck, isFalse);
    });

    test('is saved and read back, whatever the traffic choice', () async {
      final settings = await AppSettings.load();
      var told = 0;
      settings.addListener(() => told++);
      settings.signalHeat = true;
      settings.signalHeat = true;
      expect(told, 1);
      final file = File('${dir.path}/settings.json');
      expect((jsonDecode(file.readAsStringSync()) as Map)['signalHeat'], true);
      var again = await AppSettings.load();
      expect(again.signalHeat, isTrue);
      expect(again.traffic.name, 'off');
      // Changing the traffic leaves it alone, and the other way round.
      again.traffic = TrafficSource.yandex;
      again = await AppSettings.load();
      expect(again.signalHeat, isTrue);
      expect(again.traffic.name, isNot('off'));
      again.signalHeat = false;
      again = await AppSettings.load();
      expect(again.signalHeat, isFalse);
      expect(again.traffic.name, isNot('off'));
    });
  });

  test('what a user types becomes a catalog address', () {
    expect(
      normalizeCatalogUrl('maps.example.org'),
      'https://maps.example.org/catalog.json',
    );
    expect(
      normalizeCatalogUrl(' https://maps.example.org/ '),
      'https://maps.example.org/catalog.json',
    );
    expect(
      normalizeCatalogUrl('http://192.168.1.5:8080'),
      'http://192.168.1.5:8080/catalog.json',
    );
    expect(
      normalizeCatalogUrl('https://example.org/packs/list.json'),
      'https://example.org/packs/list.json',
    );
  });

  test('things that are not server addresses are rejected', () {
    expect(normalizeCatalogUrl(''), isNull);
    expect(normalizeCatalogUrl('   '), isNull);
    expect(normalizeCatalogUrl('ftp://example.org'), isNull);
    expect(normalizeCatalogUrl('file:///etc/passwd'), isNull);
    expect(normalizeCatalogUrl('https://'), isNull);
  });
}
