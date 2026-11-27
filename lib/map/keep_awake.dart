import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the display from turning off, for a phone on the dashboard.
///
/// On Linux the runner holds a Wayland idle inhibitor (see
/// linux/runner/native_view_plugin.cc); where there is nothing to ask, the
/// request is quietly dropped.
class KeepAwake {
  static const _channel = MethodChannel('mapsoly/native_view');

  bool _on = false;
  bool get on => _on;

  void set(bool on) {
    if (on == _on) return;
    _on = on;
    _channel
        .invokeMethod<bool>('keepAwake', on)
        .then(
          (held) =>
              debugPrint('keep awake: ${on ? 'on' : 'off'} (held: $held)'),
          onError: (Object e) {
            if (e is! MissingPluginException) {
              debugPrint('Keep awake failed: $e');
            }
          },
        );
  }
}
