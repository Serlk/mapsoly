/// Self-contained search UI: a compact Material 3 search field with a
/// results list, sized for a 480×480 dp square screen and usable from a
/// hardware keyboard (↑/↓ move the highlight, Enter selects, Esc closes).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'photon_geocoder.dart';
import 'places_database.dart';

/// Russian UI strings of the search panel.
class SearchPanelTexts {
  const SearchPanelTexts._();
  static const String hint = 'Адрес, место, АЗС…';
  static const String close = 'Закрыть';
  static const String clear = 'Очистить';
  static const String nothingFound = 'Ничего не найдено';
  static const String searchingOnline = 'Поиск в интернете…';
  static const String onlineResults = 'Найдено в интернете';
  static const String onlineFailed = 'Онлайн-поиск недоступен';
  static const String noPack =
      'Пакет региона не установлен — поиск только онлайн';
  static const String noPackNoOnline = 'Пакет региона не установлен';
  static const String typeToSearch = 'Введите адрес или название';

  static String distance(double m) {
    if (m < 950) return '${(m / 10).round() * 10} м';
    final km = m / 1000;
    if (km < 10) return '${km.toStringAsFixed(1).replaceAll('.', ',')} км';
    return '${km.round()} км';
  }
}

/// Icon for a result category code.
IconData placeIcon(PlaceResult r) {
  switch (r.kind) {
    case PlaceKind.house:
      return Icons.home_outlined;
    case PlaceKind.street:
      return Icons.signpost_outlined;
    case PlaceKind.locality:
      return Icons.location_city_outlined;
    case PlaceKind.poi:
      break;
  }
  return switch (r.category) {
    'fuel' => Icons.local_gas_station_outlined,
    'charging' => Icons.ev_station_outlined,
    'parking' => Icons.local_parking_outlined,
    'car_wash' => Icons.local_car_wash_outlined,
    'car_repair' || 'car_shop' => Icons.car_repair_outlined,
    'pharmacy' => Icons.local_pharmacy_outlined,
    'hospital' || 'clinic' || 'dentist' => Icons.local_hospital_outlined,
    'police' => Icons.local_police_outlined,
    'post' => Icons.local_post_office_outlined,
    'bank' || 'atm' => Icons.account_balance_outlined,
    'cafe' => Icons.local_cafe_outlined,
    'restaurant' || 'fast_food' => Icons.restaurant_outlined,
    'bar' => Icons.local_bar_outlined,
    'supermarket' ||
    'convenience' ||
    'shop' ||
    'marketplace' => Icons.shopping_cart_outlined,
    'mall' => Icons.local_mall_outlined,
    'hotel' || 'camp' => Icons.hotel_outlined,
    'station' || 'metro' => Icons.train_outlined,
    'bus_station' => Icons.directions_bus_outlined,
    'airport' => Icons.flight_outlined,
    'ferry' => Icons.directions_boat_outlined,
    'park' || 'beach' => Icons.park_outlined,
    'museum' ||
    'attraction' ||
    'monument' ||
    'historic' => Icons.museum_outlined,
    'school' ||
    'university' ||
    'kindergarten' ||
    'library' => Icons.school_outlined,
    'worship' => Icons.church_outlined,
    'toilets' => Icons.wc_outlined,
    _ => Icons.place_outlined,
  };
}

/// Search field + results list.
///
/// Offline results come from [database] synchronously on every keystroke.
/// When there is no database, or it finds nothing, [online] (if given) is
/// asked after a short pause. Not wired to any map: the owner reacts to
/// [onSelected] and [onClose].
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.database,
    required this.onSelected,
    this.onClose,
    this.online,
    this.near,
    this.initialQuery = '',
    this.autofocus = true,
    this.limit = 20,
    this.onlineDelay = const Duration(milliseconds: 700),
  });

  /// Installed region pack, or null when none is installed.
  final PlacesDatabase? database;

  /// Online fallback; null disables it.
  final PhotonGeocoder? online;

  /// Position to rank nearby results higher (current fix or map centre).
  final LatLng? near;

  final ValueChanged<PlaceResult> onSelected;

  /// Called on Esc and on the close button.
  final VoidCallback? onClose;

  final String initialQuery;
  final bool autofocus;
  final int limit;

  /// Pause after the last keystroke before the online geocoder is asked.
  final Duration onlineDelay;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  static const double _rowHeight = 52;

  late final TextEditingController _text;
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  List<PlaceResult> _results = const [];
  int _highlight = 0;
  bool _onlineBusy = false;
  bool _onlineShown = false;
  bool _onlineFailed = false;
  Timer? _onlineTimer;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialQuery);
    if (widget.initialQuery.isNotEmpty) _runSearch(widget.initialQuery);
  }

  @override
  void didUpdateWidget(SearchPanel old) {
    super.didUpdateWidget(old);
    if (old.database != widget.database) _runSearch(_text.text);
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _runSearch(String query) {
    _onlineTimer?.cancel();
    final gen = ++_generation;
    final q = query.trim();
    var results = const <PlaceResult>[];
    final db = widget.database;
    if (q.isNotEmpty && db != null) {
      try {
        results = db.search(query, near: widget.near, limit: widget.limit);
      } catch (_) {
        results = const []; // damaged pack: behave as "nothing found"
      }
    }
    _results = results;
    _highlight = 0;
    _onlineShown = false;
    _onlineFailed = false;
    _onlineBusy = false;
    final online = widget.online;
    if (results.isEmpty && online != null && q.length >= 3) {
      _onlineBusy = true;
      _onlineTimer = Timer(widget.onlineDelay, () async {
        final found = await online.search(
          q,
          near: widget.near,
          limit: widget.limit,
        );
        if (!mounted || gen != _generation) return;
        setState(() {
          _onlineBusy = false;
          _onlineShown = found.isNotEmpty;
          _onlineFailed = online.lastError != null;
          _results = found;
          _highlight = 0;
        });
      });
    }
    if (mounted) setState(() {});
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _highlight = (_highlight + delta).clamp(0, _results.length - 1);
    });
    if (!_scroll.hasClients) return;
    final top = _highlight * _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - pos.viewportDimension);
    }
  }

  void _select([int? index]) {
    final i = index ?? _highlight;
    if (i < 0 || i >= _results.length) return;
    widget.onSelected(_results[i]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _move(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _move(-5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _select();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      widget.onClose?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _statusText() {
    final q = _text.text.trim();
    if (_onlineBusy) return SearchPanelTexts.searchingOnline;
    if (_onlineShown) return SearchPanelTexts.onlineResults;
    if (widget.database == null && _results.isEmpty) {
      if (widget.online == null) return SearchPanelTexts.noPackNoOnline;
      if (q.length < 3) return SearchPanelTexts.noPack;
    }
    if (q.isEmpty) return SearchPanelTexts.typeToSearch;
    if (_results.isEmpty) {
      return _onlineFailed
          ? '${SearchPanelTexts.nothingFound}. ${SearchPanelTexts.onlineFailed}'
          : SearchPanelTexts.nothingFound;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = _statusText();
    return Material(
      color: scheme.surface,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                IconButton(
                  tooltip: SearchPanelTexts.close,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onClose,
                ),
                Expanded(
                  child: Focus(
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      autofocus: widget.autofocus,
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: theme.textTheme.titleMedium,
                      decoration: const InputDecoration(
                        hintText: SearchPanelTexts.hint,
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: _runSearch,
                      onSubmitted: (_) => _select(),
                    ),
                  ),
                ),
                if (_text.text.isNotEmpty)
                  IconButton(
                    tooltip: SearchPanelTexts.clear,
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _text.clear();
                      _runSearch('');
                      _focus.requestFocus();
                    },
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          if (status != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (_onlineBusy)
                    const Padding(
                      padding: EdgeInsets.only(right: 12),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _rowHeight,
              itemCount: _results.length,
              itemBuilder: (context, i) => _ResultRow(
                result: _results[i],
                highlighted: i == _highlight,
                onTap: () => _select(i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.result,
    required this.highlighted,
    required this.onTap,
  });

  final PlaceResult result;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = highlighted ? scheme.onSecondaryContainer : scheme.onSurface;
    final sub = highlighted
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant;
    final details = [
      if (result.kind == PlaceKind.poi &&
          result.categoryLabel.isNotEmpty &&
          result.categoryLabel != result.name)
        result.categoryLabel,
      if (result.context != null && result.context!.isNotEmpty) result.context!,
    ].join(' · ');
    return Material(
      color: highlighted ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(placeIcon(result), size: 22, color: sub),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(color: fg),
                    ),
                    if (details.isNotEmpty)
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: sub),
                      ),
                  ],
                ),
              ),
              if (result.distanceM != null) ...[
                const SizedBox(width: 8),
                Text(
                  SearchPanelTexts.distance(result.distanceM!),
                  style: theme.textTheme.labelMedium?.copyWith(color: sub),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
