import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

import '../user/fakes.dart';

/// Counts what the engine asks of it.
class _CountingWifi extends FakeWifi {
  int reads = 0, requests = 0;

  @override
  Future<bool> requestScan() async {
    requests++;
    return true;
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    reads++;
    return scan;
  }
}

void main() {
  test('off the screen nothing is scanned; back on it, again', () async {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    void lifecycle(AppLifecycleState state) =>
        binding.handleAppLifecycleStateChanged(state);
    Future<void> wait(int ms) =>
        Future<void>.delayed(Duration(milliseconds: ms));
    lifecycle(AppLifecycleState.resumed);
    addTearDown(() => lifecycle(AppLifecycleState.resumed));

    final wifi = _CountingWifi();
    final gnss = FakeGnss();
    final engine = PositioningEngine(
      db: LocationDb.inMemory(),
      wifi: wifi,
      cells: FakeCells(),
      gnss: gnss,
      // Fast polls, so that a few fit into the test.
      config: const PositioningConfig(
        wifiScanInterval: Duration(milliseconds: 10),
        cellPollInterval: Duration(milliseconds: 10),
      ),
    );
    final platform = PlatformPositioning(engine, pauseWhenHidden: true);
    // Also when an expectation fails: its timers would keep the test alive.
    addTearDown(() async {
      platform.release();
      await engine.dispose();
      await gnss.controller.close();
    });
    await engine.start();
    await wait(50);
    expect(engine.isRunning, isTrue);
    expect(gnss.started, isTrue);
    expect(wifi.reads, greaterThanOrEqualTo(2));

    // A system dialog over the app (the permission question): still there.
    lifecycle(AppLifecycleState.inactive);
    await wait(10);
    expect(engine.isRunning, isTrue);

    // Home button, another app, screen off.
    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.paused);
    await wait(20);
    expect(engine.isRunning, isFalse);
    expect(gnss.started, isFalse);
    final reads = wifi.reads, requests = wifi.requests;
    await wait(100);
    expect(wifi.reads, reads);
    expect(wifi.requests, requests);

    lifecycle(AppLifecycleState.hidden);
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.resumed);
    await wait(50);
    expect(engine.isRunning, isTrue);
    expect(gnss.started, isTrue);
    expect(wifi.reads, greaterThan(reads));

    // Released: the engine is the caller's again and stays as it is.
    platform.release();
    lifecycle(AppLifecycleState.inactive);
    lifecycle(AppLifecycleState.hidden);
    await wait(20);
    expect(engine.isRunning, isTrue);
  });

  test('other platforms keep running whatever the window does', () {
    final engine = PositioningEngine(db: LocationDb.inMemory());
    // No listener at all: nothing to release, nothing to react.
    PlatformPositioning(engine).release();
    engine.dispose();
  });
}
