import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'map/map_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MapsolyApp(settings: await AppSettings.load()));
}

class MapsolyApp extends StatelessWidget {
  const MapsolyApp({super.key, required this.settings});

  final AppSettings settings;

  static final _navigator = GlobalKey<NavigatorState>();

  /// The hardware or system "back" key: close whatever is on top. Screens
  /// decide what that means through [PopScope]; at the very root the
  /// platform takes over (leaving the app).
  static void _back() => _navigator.currentState?.maybePop();

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D6B);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Mapsoly',
        debugShowCheckedModeBanner: false,
        navigatorKey: _navigator,
        builder: (context, child) => CallbackShortcuts(
          bindings: const {
            SingleActivator(LogicalKeyboardKey.goBack): _back,
            SingleActivator(LogicalKeyboardKey.browserBack): _back,
          },
          child: child!,
        ),
        themeMode: settings.themeMode,
        theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
        darkTheme: ThemeData(
          colorSchemeSeed: seed,
          brightness: Brightness.dark,
        ),
        home: MapScreen(settings: settings),
      ),
    );
  }
}
