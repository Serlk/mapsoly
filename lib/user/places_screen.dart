/// "Мои места": home, work and favourites, and the dialog that saves one.
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../map/point_picker.dart';
import '../map/ui_kit.dart';
import 'user_data.dart';
import 'user_places.dart';

const _kindNames = {
  SavedPlaceKind.home: 'Дом',
  SavedPlaceKind.work: 'Работа',
  SavedPlaceKind.favorite: 'Место',
};

String _coordinates(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';

/// Asks for the name and the kind of a place at [point] and saves it.
/// With [existing] the dialog edits that place (same id). Returns the place
/// as stored, or null when cancelled.
Future<SavedPlace?> savePlaceDialog(
  BuildContext context,
  UserPlaces places, {
  required LatLng point,
  String? name,
  String? address,
  SavedPlace? existing,
}) => showDialog<SavedPlace>(
  context: context,
  builder: (context) => _SavePlaceDialog(
    places: places,
    point: point,
    name: name,
    address: address,
    existing: existing,
  ),
);

class _SavePlaceDialog extends StatefulWidget {
  const _SavePlaceDialog({
    required this.places,
    required this.point,
    this.name,
    this.address,
    this.existing,
  });

  final UserPlaces places;
  final LatLng point;
  final String? name, address;
  final SavedPlace? existing;

  @override
  State<_SavePlaceDialog> createState() => _SavePlaceDialogState();
}

class _SavePlaceDialogState extends State<_SavePlaceDialog> {
  late SavedPlaceKind _kind = widget.existing?.kind ?? SavedPlaceKind.favorite;
  late final _name = TextEditingController(
    text: widget.existing?.name ?? widget.name ?? '',
  );

  @override
  void initState() {
    super.initState();
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// The home (work) this save would replace, if any.
  SavedPlace? get _replaced {
    final other = switch (_kind) {
      SavedPlaceKind.home => widget.places.home,
      SavedPlaceKind.work => widget.places.work,
      SavedPlaceKind.favorite => null,
    };
    return other == null || other.id == widget.existing?.id ? null : other;
  }

  void _setKind(SavedPlaceKind kind) {
    // A name that is only the default of the previous kind follows the kind.
    final text = _name.text.trim();
    final wasDefault = text.isEmpty || _kindNames.containsValue(text);
    setState(() => _kind = kind);
    if (wasDefault && kind != SavedPlaceKind.favorite) {
      _name.text = _kindNames[kind]!;
    } else if (wasDefault) {
      _name.text = widget.name ?? '';
    }
  }

  void _save() {
    final existing = widget.existing;
    final stored = widget.places.save(
      SavedPlace(
        id: existing?.id,
        name: _name.text,
        kind: _kind,
        point: widget.point,
        address: widget.address ?? existing?.address,
      ),
    );
    Navigator.pop(context, stored);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final replaced = _replaced;
    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Сохранить место' : 'Изменить место',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Название',
                  hintText: _kindNames[_kind],
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: Ui.pad),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<SavedPlaceKind>(
                  showSelectedIcon: false,
                  style: Ui.segmented(),
                  segments: [
                    for (final k in SavedPlaceKind.values)
                      ButtonSegment(
                        value: k,
                        icon: Icon(placeKindIcon(k)),
                        label: Text(_kindNames[k]!),
                      ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => _setKind(s.first),
                ),
              ),
              // Always takes its line, so the dialog does not jump.
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  replaced == null
                      ? (widget.address ??
                            widget.existing?.address ??
                            _coordinates(widget.point))
                      : 'Заменит прежний «${replaced.name}»',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: Ui.text,
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: Ui.filled,
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

/// Home, work and favourites: add, rename, delete, and (with [onGo]) start
/// a route to one of them.
class PlacesScreen extends StatelessWidget {
  const PlacesScreen({
    super.key,
    required this.user,
    required this.services,
    this.onGo,
  });

  final UserData user;
  final MapServices services;

  /// Called when a saved place is tapped: build a route to it.
  final void Function(SavedPlace place)? onGo;

  UserPlaces get _places => user.places;

  /// Home or work that is not set yet: choose the point, save at once.
  Future<void> _setSingle(BuildContext context, SavedPlaceKind kind) async {
    final name = _kindNames[kind]!;
    final picked = await choosePoint(
      context,
      services: services,
      places: _places,
      title: kind == SavedPlaceKind.home ? 'Где дом' : 'Где работа',
    );
    if (picked == null || !context.mounted) return;
    _places.save(
      SavedPlace(
        name: name,
        kind: kind,
        point: picked.point,
        address: picked.label,
      ),
    );
    showNote(context, '$name: место сохранено');
  }

  Future<void> _add(BuildContext context) async {
    final picked = await choosePoint(
      context,
      services: services,
      places: _places,
      title: 'Новое место',
    );
    if (picked == null || !context.mounted) return;
    await savePlaceDialog(
      context,
      _places,
      point: picked.point,
      name: picked.label,
    );
  }

  void _delete(BuildContext context, SavedPlace place) {
    _places.remove(place.id);
    showNote(
      context,
      '«${place.name}» удалено',
      action: 'Вернуть',
      onAction: () => _places.save(place),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SubPage(
      title: 'Мои места',
      bottom: FilledButton.icon(
        style: Ui.filled,
        onPressed: () => _add(context),
        icon: const Icon(Icons.add),
        label: const Text('Добавить место'),
      ),
      child: ListenableBuilder(
        listenable: _places,
        builder: (context, _) {
          final favorites = _places.favorites;
          final problem = _places.saveError ?? _places.loadError;

          Widget single(SavedPlaceKind kind, SavedPlace? place) => place != null
              ? _PlaceRow(
                  place: place,
                  onTap: onGo == null ? null : () => onGo!(place),
                  onEdit: () => savePlaceDialog(
                    context,
                    _places,
                    point: place.point,
                    existing: place,
                  ),
                  onDelete: () => _delete(context, place),
                )
              : ListTile(
                  minTileHeight: Ui.row,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Ui.pad,
                  ),
                  leading: Icon(placeKindIcon(kind), color: colors.outline),
                  title: Text(_kindNames[kind]!),
                  subtitle: const Text('Нажмите, чтобы указать место'),
                  trailing: Icon(Icons.add, color: colors.primary),
                  onTap: () => _setSingle(context, kind),
                );

          return ListView(
            padding: const EdgeInsets.only(bottom: Ui.pad),
            children: [
              if (problem != null) InfoPanel(text: problem, error: true),
              if (onGo != null && _places.places.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, 4),
                  child: Text(
                    'Нажмите на место, чтобы построить к нему маршрут.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              single(SavedPlaceKind.home, _places.home),
              single(SavedPlaceKind.work, _places.work),
              const SectionHeader('Избранное'),
              if (favorites.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, Ui.pad),
                  child: Text(
                    'Здесь будут места, в которые вы ездите часто: дача, '
                    'заправка, родители.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final place in favorites)
                _PlaceRow(
                  place: place,
                  onTap: onGo == null ? null : () => onGo!(place),
                  onEdit: () => savePlaceDialog(
                    context,
                    _places,
                    point: place.point,
                    existing: place,
                  ),
                  onDelete: () => _delete(context, place),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.place,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final SavedPlace place;
  final VoidCallback? onTap;
  final VoidCallback onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Ui.row),
        child: Padding(
          padding: const EdgeInsets.only(left: Ui.pad, right: 4),
          child: Row(
            children: [
              Icon(placeKindIcon(place.kind), color: colors.primary),
              const SizedBox(width: Ui.pad),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        place.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                      Text(
                        place.address ?? _coordinates(place.point),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Ui.iconButton(
                icon: Icons.edit_outlined,
                label: 'Изменить «${place.name}»',
                color: colors.onSurfaceVariant,
                onPressed: onEdit,
                size: 52,
              ),
              Ui.iconButton(
                icon: Icons.delete_outline,
                label: 'Удалить «${place.name}»',
                color: colors.onSurfaceVariant,
                onPressed: onDelete,
                size: 52,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
