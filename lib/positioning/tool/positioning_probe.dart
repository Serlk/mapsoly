// Command-line diagnostics for the positioning subsystem. Pure Dart (no
// Flutter), so it also runs with a bare `dart` on the phone:
//
//   dart run lib/positioning/tool/positioning_probe.dart [options]
//
// Options:
//   --db PATH        location database (default: in-memory)
//   --online         resolve unknown transmitters via Apple WPS / beaconDB
//   --scan           request a Wi-Fi scan first and wait for it
//   --watch N        run the full engine for N seconds and print estimates
//   --gnss PATH      NMEA socket path (default /run/t2-gnss/nmea.sock)
//
// It only reads from the system: the single active call is
// NetworkManager's RequestScan.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../engine.dart';
import '../estimator.dart';
import '../location_db.dart';
import '../models.dart';
import '../online/resolver.dart';
import '../sources/linux_cell.dart';
import '../sources/linux_wifi.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final online = args.contains('--online');
  final dbPath = opt('--db');
  final watch = int.tryParse(opt('--watch') ?? '');
  final db = dbPath == null ? LocationDb.inMemory() : LocationDb.open(dbPath);
  print(
    'user: ${Platform.environment['USER']}  db: ${dbPath ?? '(memory)'} '
    '${db.stats()}',
  );

  if (watch != null) {
    await _watch(db, watch, online, opt('--gnss'));
    return;
  }

  final client = DBusClient.system();
  final nm = NetworkManagerWifiScanner(client: client);
  final wpa = WpaSupplicantWifiScanner(client: client);

  final nmOk = await nm.isAvailable();
  final wpaOk = await wpa.isAvailable();
  print('NetworkManager wifi device: $nmOk');
  print('wpa_supplicant accessible:  $wpaOk');

  if (args.contains('--scan') && nmOk) {
    final sw = Stopwatch()..start();
    print('RequestScan accepted: ${await nm.requestScan()}');
    // Wait until fresh results appear (a full scan takes ~8 s on the phone).
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final fresh = await nm.getObservations(
        maxAge: Duration(milliseconds: sw.elapsedMilliseconds),
      );
      if (fresh.length > 1) break;
    }
    print('scan wait: ${sw.elapsedMilliseconds} ms');
  }

  var scan = <WifiObservation>[];
  if (nmOk) {
    final sw = Stopwatch()..start();
    scan = await nm.getObservations();
    print(
      '\nNetworkManager: ${scan.length} APs (${sw.elapsedMilliseconds} ms)',
    );
    for (final o in scan..sort(_bySignal)) {
      print('  $o');
    }
  }
  if (wpaOk) {
    final sw = Stopwatch()..start();
    final w = await wpa.getObservations();
    print('\nwpa_supplicant: ${w.length} BSSs (${sw.elapsedMilliseconds} ms)');
    for (final o in w..sort(_bySignal)) {
      print('  $o');
    }
    if (w.isNotEmpty) scan = w;
  }

  final mm = ModemManagerCellSource(client: client);
  final sw = Stopwatch()..start();
  final cells = await mm.getCells();
  print('\nModemManager: ${cells.length} cells (${sw.elapsedMilliseconds} ms)');
  for (final c in cells) {
    print('  $c  key=${c.key}');
  }
  mm.lastMode.forEach((path, mode) => print('  $path: ${mode.name}'));
  mm.lastError.forEach((path, e) => print('  $path: $e'));

  if (online) {
    final r = OnlineResolver(db);
    print(
      '\nonline: wifi +${await r.resolveWifi(scan)} records, '
      'cells +${await r.resolveCells(cells)} records '
      '(${r.requests} requests, ${r.failures} failures'
      '${r.lastError == null ? '' : ', ${r.lastError}'})',
    );
    final whole = await r.geolocate(wifi: scan, cells: cells);
    print('beaconDB whole-scan fix: $whole');
    r.close();
  }

  final est = const RadioEstimator().estimate(
    db: db,
    wifi: scan,
    cells: cells,
    now: DateTime.now(),
  );
  print(
    '\nwifi: seen ${est.wifiSeen}, known ${est.wifiKnown}, used '
    '${est.wifiUsed}, rejected ${est.wifiRejected}',
  );
  print('cells: seen ${est.cellsSeen}, known ${est.cellsKnown}');
  print('wifi estimate: ${est.wifi}');
  print('cell estimate: ${est.cell}');
  print('best:          ${est.best}');
  print('db: ${db.stats()}');

  await client.close();
  db.close();
}

int _bySignal(WifiObservation a, WifiObservation b) =>
    (b.effectiveDbm ?? -200).compareTo(a.effectiveDbm ?? -200);

Future<void> _watch(
  LocationDb db,
  int seconds,
  bool online,
  String? gnss,
) async {
  final engine = PositioningEngine(
    db: db,
    wifi: LinuxWifiScanner(),
    cells: ModemManagerCellSource(),
    gnss: null,
    resolver: OnlineResolver(db),
    config: PositioningConfig(onlineLookups: online),
  );
  engine.estimates.listen((e) {
    final s = engine.status;
    print(
      '${DateTime.now().toIso8601String().substring(11, 19)} $e | wifi '
      '${s.wifiVisible}/${s.wifiKnown}/${s.wifiUsed} via ${s.wifiBackend} '
      'cells ${s.cellsVisible}/${s.cellsKnown}'
      '${s.onlineError == null ? '' : ' online: ${s.onlineError}'}',
    );
  });
  await engine.start();
  await Future<void>.delayed(Duration(seconds: seconds));
  print('source error: ${engine.lastSourceError}');
  print('db: ${engine.dbStats()}');
  await engine.dispose();
}
