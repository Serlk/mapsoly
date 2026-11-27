/// Everything the user keeps, loaded once at startup.
library;

import 'dart:io';

import 'privacy_guard.dart';
import 'privacy_zones.dart';
import 'saved_routes.dart';
import 'search_history.dart';
import 'user_places.dart';

/// The user's stores and the guard that enforces the privacy zones.
class UserData {
  UserData({
    required this.places,
    required this.routes,
    required this.zones,
    required this.guard,
    SearchHistory? searches,
    this.supportDirectory,
  }) : searches = searches ?? SearchHistory.inMemory();

  /// Loads the stores from `<support>/user`. Never throws: unreadable
  /// files give empty stores with their `loadError` set.
  factory UserData.load(Directory support) {
    final dir = Directory('${support.path}/user');
    final zones = PrivacyZones.load(dir);
    return UserData(
      places: UserPlaces.load(dir),
      routes: SavedRoutes.load(dir),
      zones: zones,
      guard: PrivacyGuard.load(dir, zones),
      searches: SearchHistory.load(dir),
      supportDirectory: support,
    );
  }

  /// Stores that are not persisted (tests, or no data directory).
  factory UserData.inMemory() {
    final zones = PrivacyZones.inMemory();
    return UserData(
      places: UserPlaces.inMemory(),
      routes: SavedRoutes.inMemory(),
      zones: zones,
      guard: PrivacyGuard(zones),
    );
  }

  final UserPlaces places;
  final SavedRoutes routes;
  final PrivacyZones zones;
  final PrivacyGuard guard;

  /// Places picked from the search results.
  final SearchHistory searches;

  /// The app's data directory; null when it could not be determined.
  final Directory? supportDirectory;

  /// Where the OBD trip logs are written.
  Directory? get tripLogDirectory => supportDirectory == null
      ? null
      : Directory('${supportDirectory!.path}/obd-logs');
}
