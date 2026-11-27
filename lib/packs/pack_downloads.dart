import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'pack_store.dart';

/// Pack downloads that outlive the "Maps" screen: started there, they keep
/// running while the user is back on the map, and the screen shows their
/// state again when reopened.
class PackDownloads extends ChangeNotifier {
  PackDownloads(this.store, {this.onInstalled});

  final PackStore store;

  /// Called after a pack was installed, so the map can load it.
  final VoidCallback? onInstalled;

  final _running = <String, PackDownload>{};
  final _progress = <String, PackProgress>{};
  final _errors = <String, String>{};
  bool _disposed = false;

  bool get active => _running.isNotEmpty;
  bool isRunning(String id) => _running.containsKey(id);
  PackProgress? progressOf(String id) => _progress[id];
  String? errorOf(String id) => _errors[id];

  /// Packs being downloaded right now.
  Iterable<PackInfo> get running => _running.values.map((d) => d.pack);

  /// Share of all running downloads that has arrived, 0..1.
  double get fraction {
    var received = 0, total = 0;
    for (final id in _running.keys) {
      final p = _progress[id];
      if (p == null) continue;
      received += p.received;
      total += p.total;
    }
    return total == 0 ? 0 : received / total;
  }

  /// True when everything has arrived and the packs are being verified and
  /// unpacked.
  bool get installing =>
      active &&
      _running.keys.every((id) {
        final p = _progress[id];
        return p != null && p.total > 0 && p.received >= p.total;
      });

  void start(PackInfo pack) {
    if (_running.containsKey(pack.id)) return;
    final download = store.download(pack);
    _running[pack.id] = download;
    _errors.remove(pack.id);
    _progress[pack.id] = PackProgress(store.partialBytes(pack), pack.size);
    _notify();
    download.progress.listen((p) {
      _progress[pack.id] = p;
      _notify();
    });
    download.done.then(
      (_) {
        _running.remove(pack.id);
        _progress.remove(pack.id);
        _notify();
        if (!_disposed) onInstalled?.call();
      },
      onError: (Object e) {
        _running.remove(pack.id);
        if (e is! PackDownloadCancelled) _errors[pack.id] = '$e';
        _notify();
      },
    );
  }

  /// Stops a download, keeping what was received for a later resume.
  void pause(String id) => _running[id]?.cancel();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final d in _running.values) {
      d.cancel();
    }
    store.close();
    super.dispose();
  }
}
