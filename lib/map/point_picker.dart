/// Choosing a point: the one step shared by the trip planner, saved places
/// and privacy zones.
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../user/user_places.dart';
import 'ui_kit.dart';

/// A point the user chose, with its name when it has one.
@immutable
class PickedPlace {
  const PickedPlace(this.point, {this.label});

  final LatLng point;
  final String? label;
}

/// What the main screen offers to the screens opened from it.
abstract class MapServices {
  /// Current position, null without a fix.
  LatLng? get myPosition;

  /// Shows the map with a crosshair and a "choose this point" button, and
  /// returns to the calling screen afterwards. Null when cancelled.
  Future<PickedPlace?> pickOnMap({required String title, LatLng? around});

  /// The search panel (offline index with the online fallback).
  Widget searchPanel({
    required ValueChanged<PickedPlace> onSelected,
    required VoidCallback onClose,
  });
}

IconData placeKindIcon(SavedPlaceKind kind) => switch (kind) {
  SavedPlaceKind.home => Icons.home_outlined,
  SavedPlaceKind.work => Icons.work_outline,
  SavedPlaceKind.favorite => Icons.star_outline,
};

/// Opens the "choose a point" step and returns what was chosen (null when
/// the user went back).
Future<PickedPlace?> choosePoint(
  BuildContext context, {
  required MapServices services,
  required UserPlaces places,
  required String title,
  bool offerMyPosition = true,
}) => Navigator.of(context).push<PickedPlace>(
  MaterialPageRoute(
    builder: (context) => PointChooserPage(
      services: services,
      places: places,
      title: title,
      offerMyPosition: offerMyPosition,
    ),
  ),
);

/// Opens the search panel as a page and returns the chosen result.
Future<PickedPlace?> searchPoint(BuildContext context, MapServices services) =>
    Navigator.of(context).push<PickedPlace>(
      MaterialPageRoute(
        builder: (context) => Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            child: services.searchPanel(
              onSelected: (p) => Navigator.of(context).pop(p),
              onClose: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      ),
    );

/// One step with clear choices: search, the map, the current position, or
/// a saved place. Pops with a [PickedPlace].
class PointChooserPage extends StatelessWidget {
  const PointChooserPage({
    super.key,
    required this.services,
    required this.places,
    required this.title,
    this.offerMyPosition = true,
  });

  final MapServices services;
  final UserPlaces places;
  final String title;
  final bool offerMyPosition;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final navigator = Navigator.of(context);
    final here = offerMyPosition ? services.myPosition : null;

    Widget choice(
      IconData icon,
      String title,
      String detail,
      VoidCallback go,
    ) => Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, Ui.gap),
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Ui.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: go,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Ui.pad,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Icon(icon, size: 28, color: colors.primary),
                  const SizedBox(width: Ui.pad),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        Text(
                          detail,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return SubPage(
      title: title,
      child: ListenableBuilder(
        listenable: places,
        builder: (context, _) {
          final saved = places.places;
          return ListView(
            padding: const EdgeInsets.only(top: Ui.gap, bottom: Ui.pad),
            children: [
              choice(
                Icons.search,
                'Найти',
                'Адрес, улица, заведение',
                () async {
                  final found = await searchPoint(context, services);
                  if (found != null) navigator.pop(found);
                },
              ),
              choice(
                Icons.map_outlined,
                'На карте',
                'Подвиньте карту под прицел и подтвердите',
                () async {
                  final found = await services.pickOnMap(title: title);
                  if (found != null) navigator.pop(found);
                },
              ),
              if (here != null)
                choice(
                  Icons.my_location,
                  'Моё местоположение',
                  'Там, где вы сейчас',
                  () => navigator.pop(PickedPlace(here)),
                ),
              if (saved.isNotEmpty) ...[
                const SectionHeader('Мои места'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
                  child: Wrap(
                    spacing: Ui.gap,
                    runSpacing: Ui.gap,
                    children: [
                      for (final p in saved)
                        ActionChip(
                          avatar: Icon(placeKindIcon(p.kind), size: 20),
                          label: Text(p.name),
                          labelStyle: theme.textTheme.titleSmall,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 16,
                          ),
                          onPressed: () => navigator.pop(
                            PickedPlace(p.point, label: p.name),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
