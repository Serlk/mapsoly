/// Whether the platform lets the app read the position, for platforms
/// where that takes the user's consent.
library;

import 'package:flutter/foundation.dart';

enum LocationAccessState {
  /// Not asked or not answered yet.
  unknown,
  granted,

  /// Refused; asking again shows the system dialog.
  denied,

  /// Refused for good: only the system settings can change it.
  blocked,

  /// Allowed, but location is switched off for the whole device.
  switchedOff,
}

/// What the UI needs to explain a missing position and to fix it.
abstract class LocationAccess {
  ValueListenable<LocationAccessState> get state;

  /// Asks the user (system dialog), or opens the system settings when the
  /// dialog can no longer be shown or location is switched off.
  Future<void> request();
}
