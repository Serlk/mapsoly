import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'catalog.dart';
import 'pack_store.dart';

/// Where the list of downloadable regions comes from unless overridden by
/// the MAPSOLY_CATALOG environment variable.
const defaultCatalogUrl =
    'https://github.com/Serlk/mapsoly/releases/download/packs/catalog.json';

String formatBytes(int bytes) {
  if (bytes >= 1 << 30) {
    return '${(bytes / (1 << 30)).toStringAsFixed(1).replaceAll('.', ',')} ГБ';
  }
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).round()} МБ';
  return '${(bytes / 1024).ceil()} КБ';
}

/// "Maps" screen: regions available for download and those on the device.
class PacksScreen extends StatefulWidget {
  const PacksScreen({super.key, required this.store, required this.onChanged});

  final PackStore store;

  /// Called after a pack was installed or deleted, so the map can reload.
  final VoidCallback onChanged;

  @override
  State<PacksScreen> createState() => _PacksScreenState();
}

class _PacksScreenState extends State<PacksScreen> {
  List<InstalledPack> _installed = const [];
  PackCatalog? _catalog;
  String? _catalogError;
  bool _loading = false;

  // Downloads running right now, by pack id.
  final _downloads = <String, PackDownload>{};
  final _progress = <String, PackProgress>{};
  final _errors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _installed = widget.store.installed();
    _refresh();
  }

  @override
  void dispose() {
    // Leaving the screen pauses downloads; what was received is kept.
    for (final d in _downloads.values) {
      d.cancel();
    }
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _catalogError = null;
    });
    try {
      final url = Uri.parse(
        Platform.environment['MAPSOLY_CATALOG'] ?? defaultCatalogUrl,
      );
      final catalog = await widget.store.fetchCatalog(url);
      if (mounted) setState(() => _catalog = catalog);
    } on Exception catch (e) {
      debugPrint('Catalog not loaded: $e');
      if (mounted) {
        setState(
          () => _catalogError =
              'Список карт не загрузился. Проверьте подключение к сети.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _start(PackInfo pack) {
    final download = widget.store.download(pack);
    setState(() {
      _downloads[pack.id] = download;
      _errors.remove(pack.id);
      _progress[pack.id] = PackProgress(
        widget.store.partialBytes(pack),
        pack.size,
      );
    });
    download.progress.listen((p) {
      if (mounted) setState(() => _progress[pack.id] = p);
    });
    download.done.then(
      (_) {
        if (!mounted) return;
        setState(() {
          _downloads.remove(pack.id);
          _progress.remove(pack.id);
          _installed = widget.store.installed();
        });
        widget.onChanged();
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _downloads.remove(pack.id);
          if (e is! PackDownloadCancelled) _errors[pack.id] = '$e';
        });
      },
    );
  }

  Future<void> _delete(InstalledPack pack) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить «${pack.name}»?'),
        content: Text(
          'Освободится ${formatBytes(pack.sizeOnDisk)}. Карта, маршруты и '
          'поиск по этому региону перестанут работать без сети.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    widget.store.delete(pack.id);
    setState(() => _installed = widget.store.installed());
    widget.onChanged();
  }

  Widget _catalogTile(PackInfo pack) {
    final theme = Theme.of(context);
    final local = _installed.where((p) => p.id == pack.id).firstOrNull;
    final download = _downloads[pack.id];
    final progress = _progress[pack.id];
    final error = _errors[pack.id];
    final partial = download == null ? widget.store.partialBytes(pack) : 0;
    final upToDate = local?.info?.version == pack.version;

    final String status;
    if (download != null && progress != null) {
      status =
          'Загружено ${formatBytes(progress.received)} из '
          '${formatBytes(progress.total)}';
    } else if (error != null) {
      status = error;
    } else if (local != null && upToDate) {
      status = 'Установлено · ${formatBytes(local.sizeOnDisk)}';
    } else if (local != null) {
      status = 'Есть обновление от ${pack.version} · ${formatBytes(pack.size)}';
    } else if (partial > 0) {
      status =
          'Загрузка приостановлена: ${formatBytes(partial)} из '
          '${formatBytes(pack.size)}';
    } else {
      status = '${formatBytes(pack.size)} · данные от ${pack.version}';
    }

    final Widget action;
    if (download != null) {
      action = IconButton(
        tooltip: 'Приостановить',
        icon: const Icon(Icons.pause),
        onPressed: download.cancel,
      );
    } else if (local != null && upToDate) {
      action = IconButton(
        tooltip: 'Удалить',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(local),
      );
    } else {
      action = IconButton(
        tooltip: local != null
            ? 'Обновить'
            : partial > 0
            ? 'Продолжить загрузку'
            : 'Скачать',
        icon: Icon(local != null ? Icons.update : Icons.download),
        onPressed: () => _start(pack),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text(pack.name),
          subtitle: Text(
            status,
            style: error != null && download == null
                ? TextStyle(color: theme.colorScheme.error)
                : null,
          ),
          trailing: action,
        ),
        if (download != null && progress != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: LinearProgressIndicator(value: progress.fraction),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = _catalog;
    final listed = {...?catalog?.packs.map((p) => p.id)};
    // Packs copied to the device by hand, or no longer in the catalog.
    final localOnly = _installed.where((p) => !listed.contains(p.id)).toList();

    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Карты'),
        actions: [
          IconButton(
            tooltip: 'Обновить список',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_loading) const LinearProgressIndicator(),
          if (_catalogError != null)
            ListTile(
              leading: Icon(
                Icons.cloud_off,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              title: Text(_catalogError!),
              trailing: TextButton(
                onPressed: _refresh,
                child: const Text('Повторить'),
              ),
            ),
          if (catalog != null) ...[
            header('Доступно для загрузки'),
            if (catalog.packs.isEmpty)
              const ListTile(title: Text('В списке пока нет регионов')),
            for (final pack in catalog.packs) _catalogTile(pack),
          ],
          if (localOnly.isNotEmpty) ...[
            header('На устройстве'),
            for (final pack in localOnly)
              ListTile(
                title: Text(pack.name),
                subtitle: Text(formatBytes(pack.sizeOnDisk)),
                trailing: IconButton(
                  tooltip: 'Удалить',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(pack),
                ),
              ),
          ],
          if (catalog == null && localOnly.isEmpty && !_loading)
            const ListTile(
              title: Text('На устройстве нет карт'),
              subtitle: Text(
                'Без них карта работает только с интернетом, а маршруты и '
                'поиск по адресам недоступны.',
              ),
            ),
        ],
      ),
    );
  }
}
