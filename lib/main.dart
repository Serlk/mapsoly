import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';

import 'map/map_screen.dart';
import 'settings.dart';
import 'user/user_data.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  // Saved places, routes and the privacy zones: read before anything that
  // collects or sends positions starts.
  UserData user;
  try {
    user = UserData.load(await getApplicationSupportDirectory());
  } on Exception catch (e) {
    debugPrint('User data not loaded: $e');
    user = UserData.inMemory();
  }
  runApp(MapsolyApp(settings: settings, user: user));
}

class MapsolyApp extends StatelessWidget {
  const MapsolyApp({super.key, required this.settings, required this.user});

  final AppSettings settings;
  final UserData user;

  /// One look for both themes: the accent seed, full-size touch targets
  /// (desktop platforms default to a compact density) and quick page
  /// transitions.
  static ThemeData theme(Brightness brightness) => ThemeData(
    colorSchemeSeed: const Color(0xFF2E7D6B),
    brightness: brightness,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );

  static SystemUiOverlayStyle _systemBars(Brightness theme) {
    final icons = theme == Brightness.dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static final _navigator = GlobalKey<NavigatorState>();

  /// The hardware or system "back" key: close whatever is on top. Screens
  /// decide what that means through [PopScope]; at the very root the
  /// platform takes over (leaving the app).
  static void _back() => _navigator.currentState?.maybePop();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Mapsoly',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          // Android: the app draws under the system bars, so they carry no
          // colour of their own, only icons that contrast with the theme.
          // Other platforms ignore this.
          value: _systemBars(Theme.of(context).brightness),
          child: CallbackShortcuts(
            bindings: const {
              SingleActivator(LogicalKeyboardKey.goBack): _back,
              SingleActivator(LogicalKeyboardKey.browserBack): _back,
            },
            child: child!,
          ),
        ),
        themeMode: settings.themeMode,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: MapScreen(settings: settings, user: user),
      ),
    );
  }
}
