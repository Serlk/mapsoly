/// The app's own Android platform channels (see MainActivity.kt): names and
/// the few calls shared by more than one feature.
library;

import 'package:flutter/services.dart';

/// Methods: permissions, folders, the alert sound, Bluetooth.
const androidChannel = MethodChannel('mapsoly/android');

/// Answer to a permission request.
enum PermissionAnswer {
  granted,

  /// Refused; may be asked again.
  denied,

  /// Refused for good: the system no longer shows the dialog, only the
  /// app's page in the system settings can change it.
  blocked,
}

/// Runtime permissions by the short names Permissions.kt knows.
class AndroidPermissions {
  const AndroidPermissions([this._channel = androidChannel]);

  final MethodChannel _channel;

  static const location = 'location';
  static const bluetooth = 'bluetooth';

  Future<bool> has(String kind) async =>
      await _channel.invokeMethod<bool>('hasPermission', kind) ?? false;

  /// Shows the system dialog when the system still allows it.
  Future<PermissionAnswer> request(String kind) async {
    final answer = await _channel.invokeMethod<String>(
      'requestPermission',
      kind,
    );
    return PermissionAnswer.values.firstWhere(
      (a) => a.name == answer,
      orElse: () => PermissionAnswer.denied,
    );
  }

  /// Opens this app's page in the system settings.
  Future<void> openAppSettings() => _channel.invokeMethod('openAppSettings');
}
