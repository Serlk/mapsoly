/// The few building blocks every screen is made of, so that they look like
/// one app: spacing, row and button sizes, the translucent "glass" surface
/// of everything that lies on the map, page frames and small dialogs.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Sizes shared by all screens. Rows and buttons are tall enough to hit
/// from a car mount without aiming.
abstract final class Ui {
  /// Outer margin of a page and the gap between unrelated blocks.
  static const double pad = 16;

  /// Gap between related things.
  static const double gap = 8;

  /// Corner radius of cards; controls inside them use [radiusSmall].
  static const double radius = 16;
  static const double radiusSmall = 12;

  /// Smallest height of a tappable row and of a button.
  static const double row = 64;
  static const double button = 56;

  static ButtonStyle filled = FilledButton.styleFrom(
    minimumSize: const Size(0, button),
    padding: const EdgeInsets.symmetric(horizontal: 20),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusSmall),
    ),
  );

  static ButtonStyle outlined = OutlinedButton.styleFrom(
    minimumSize: const Size(0, button),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusSmall),
    ),
  );

  static ButtonStyle text = TextButton.styleFrom(
    minimumSize: const Size(0, button),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusSmall),
    ),
  );

  /// Style of a segmented control [height] px tall. (Its segments ignore
  /// `minimumSize`; the height has to come from the padding.)
  static ButtonStyle segmented({double height = button, double side = 12}) =>
      ButtonStyle(
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: (height - 20) / 2, horizontal: side),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
      );

  /// A square icon button of full touch size.
  static Widget iconButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    Color? color,
    double size = button,
  }) => IconButton(
    tooltip: label,
    iconSize: 26,
    color: color,
    constraints: BoxConstraints.tightFor(width: size, height: size),
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

/// Where the glass surfaces currently are on the screen. A map engine that
/// draws outside Flutter's scene blurs these rectangles itself.
class GlassRegistry extends ChangeNotifier {
  final _rects = <Object, Rect>{};

  List<Rect> get rects => List.unmodifiable(_rects.values);

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void report(Object owner, Rect? rect) {
    if (_disposed) return;
    if (rect == null) {
      if (_rects.remove(owner) == null) return;
    } else {
      if (_rects[owner] == rect) return;
      _rects[owner] = rect;
    }
    notifyListeners();
  }
}

/// Makes a [GlassRegistry] known to the [Glass] surfaces below it.
class GlassScope extends InheritedWidget {
  const GlassScope({super.key, required this.registry, required super.child});

  final GlassRegistry registry;

  static GlassRegistry? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>()?.registry;

  @override
  bool updateShouldNotify(GlassScope old) => old.registry != registry;
}

/// A translucent, blurred surface for everything that lies on the map: the
/// same look as the bottom bar, so cards, chips and buttons read as one
/// family and the map stays visible around and through them.
class Glass extends StatefulWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = Ui.radius,
    this.color,
    this.opacity = 0.86,
    this.border = true,
    this.blur = true,
  });

  final Widget child;
  final double radius;

  /// Tint of the surface; the theme's container colour by default.
  final Color? color;

  /// How solid the surface is. Text on it has to stay readable over any
  /// map, so this is high; the bottom bar, which carries only icons with
  /// labels, uses less.
  final double opacity;
  final bool border;

  /// Whether the map behind is blurred. The map engine blurs whole
  /// rectangles, which shows as square corners around a small round
  /// surface; those go without blur and are a little more solid instead.
  final bool blur;

  @override
  State<Glass> createState() => _GlassState();
}

class _GlassState extends State<Glass> {
  GlassRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final registry = GlassScope.of(context);
    if (registry != _registry) {
      final old = _registry;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => old.report(this, null),
        );
      }
      _registry = registry;
    }
  }

  void _report() {
    final registry = _registry;
    if (registry == null || !mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    // The engine blurs a rectangle; pulled in far enough to stay inside
    // the rounded corners, so no square blur shows around the surface.
    final inset = math.min(
      widget.radius * 0.3,
      math.min(box.size.width, box.size.height) / 4,
    );
    registry.report(
      this,
      (box.localToGlobal(Offset.zero) & box.size).deflate(inset),
    );
  }

  @override
  void dispose() {
    final registry = _registry;
    if (registry != null) {
      // Listeners rebuild; that must not happen while the tree is locked.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry.report(this, null),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_registry != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.blur ? _report() : _registry?.report(this, null),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(widget.radius);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: (widget.color ?? colors.surfaceContainer).withValues(
          alpha: widget.blur
              ? widget.opacity
              : math.min(1, widget.opacity + 0.08),
        ),
        borderRadius: radius,
        border: widget.border
            ? Border.all(color: colors.outlineVariant.withValues(alpha: 0.6))
            : null,
      ),
      child: Material(type: MaterialType.transparency, child: widget.child),
    );
    return ClipRRect(
      borderRadius: radius,
      child: !widget.blur
          ? surface
          : BackdropFilter(
              // Blurs what Flutter itself draws behind. A map drawn by the
              // native engine lies outside Flutter's scene; it blurs the
              // rectangles the registry reports.
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              // All panels of a screen share one blurred copy of what is
              // behind them (see BackdropGroup in the map screen) instead
              // of each making its own: on Android the map is a texture
              // that changes every frame, and every copy is a pass over
              // the whole screen.
              backdropGroupKey: BackdropGroup.of(context)?.backdropKey,
              child: surface,
            ),
    );
  }
}

/// Title of a block of rows.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 20, Ui.pad, Ui.gap),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// A tall row: icon, title, up to two lines of quiet detail, and either a
/// chevron (when it opens something) or [trailing].
class BigRow extends StatelessWidget {
  const BigRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.warning = false,
  });

  final IconData? icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Draws the detail line in the error colour: something needs attention.
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: Ui.row,
      // Two-line tiles ignore the minimum height; the padding restores it.
      minVerticalPadding: 12,
      contentPadding: const EdgeInsets.symmetric(horizontal: Ui.pad),
      leading: icon == null ? null : Icon(icon),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: warning ? TextStyle(color: colors.error) : null,
            ),
      trailing:
          trailing ?? (onTap == null ? null : const Icon(Icons.chevron_right)),
      onTap: onTap,
    );
  }
}

/// What a screen shows when it has nothing yet: one sentence saying what to
/// do, and the one button that does it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.actionIcon,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: colors.outline),
              const SizedBox(height: Ui.pad),
              Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  style: Ui.filled,
                  onPressed: onAction,
                  icon: Icon(actionIcon ?? Icons.add),
                  label: Text(action!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Frame of a screen opened from a section: a header with a large back
/// button and the title, the content, and optionally the actions pinned at
/// the bottom, within reach of the thumb.
class SubPage extends StatelessWidget {
  const SubPage({
    super.key,
    required this.title,
    required this.child,
    this.bottom,
    this.actions = const [],
    this.onBack,
  });

  final String title;
  final Widget child;

  /// Pinned under the content (the primary action goes here).
  final Widget? bottom;

  /// Small actions at the right end of the header.
  final List<Widget> actions;

  /// Defaults to closing this page.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: Ui.button,
              child: Row(
                children: [
                  Ui.iconButton(
                    icon: Icons.arrow_back,
                    label: 'Назад',
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  ...actions,
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Expanded(child: child),
            if (bottom != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 12, Ui.pad, 12),
                  child: bottom,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A calm note: an icon and a paragraph on a tinted panel. With [error] it
/// is a warning that needs the user's attention.
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.error = false,
    this.action,
    this.onAction,
  });

  final String text;
  final IconData icon;
  final bool error;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = error ? colors.onErrorContainer : colors.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Ui.pad, vertical: Ui.gap),
      padding: const EdgeInsets.all(Ui.pad),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Ui.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
            ],
          ),
          if (action != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: Ui.filled,
                onPressed: onAction,
                child: Text(action!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// How far above the bottom edge of the screen's body a note floats.
const double noteLift = 152;

/// A short message near the bottom, optionally with one action ("Вернуть",
/// "Открыть папку"). Replaces the message shown before it.
void showNote(
  BuildContext context,
  String text, {
  String? action,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 5),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        // Lifted clear of the actions pinned at the bottom of a screen: a
        // note must never cover the button the thumb is going for.
        margin: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, noteLift),
        duration: duration,
        // With an action a note would otherwise stay until dismissed.
        persist: false,
        content: Text(text),
        action: action == null
            ? null
            : SnackBarAction(label: action, onPressed: onAction ?? () {}),
      ),
    );
}

/// Asks for one line of text. Returns null when cancelled.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String confirm = 'Сохранить',
}) async {
  final controller = TextEditingController(text: initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          style: Ui.text,
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: Ui.filled,
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(confirm),
        ),
      ],
    ),
  );
  // The dialog's exit animation still shows the field for a moment.
  WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  return result;
}

/// Asks before something that cannot be undone. Returns true on consent.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? text,
  required String confirm,
  bool destructive = true,
}) async {
  final colors = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: text == null ? null : Text(text),
      actions: [
        TextButton(
          style: Ui.text,
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: destructive
              ? Ui.filled.copyWith(
                  backgroundColor: WidgetStatePropertyAll(colors.error),
                  foregroundColor: WidgetStatePropertyAll(colors.onError),
                )
              : Ui.filled,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// "1 точка", "2 точки", "5 точек".
String plural(int n, String one, String few, String many) {
  final d = n % 10, h = n % 100;
  final word = d == 1 && h != 11
      ? one
      : d >= 2 && d <= 4 && (h < 12 || h > 14)
      ? few
      : many;
  return '$n $word';
}

/// "12 КБ", "3,4 МБ".
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} КБ';
  final mb = bytes / 1024 / 1024;
  return '${mb < 10 ? mb.toStringAsFixed(1).replaceAll('.', ',') : mb.round()} МБ';
}

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

/// "27 ноября, 14:05" (with the year when it is not [now]'s).
String formatDateTime(DateTime t, {DateTime? now}) {
  final year = t.year == (now ?? DateTime.now()).year ? '' : ' ${t.year}';
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]}$year, $hh:$mm';
}
