import 'package:flutter/material.dart';

import 'map/map_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MapsolyApp(settings: await AppSettings.load()));
}

class MapsolyApp extends StatelessWidget {
  const MapsolyApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D6B);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MaterialApp(
        title: 'Mapsoly',
        debugShowCheckedModeBanner: false,
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
