import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the display from turning off, for a phone on the dashboard.
///
/// On Linux the runner holds a Wayland idle inhibitor (see
/// linux/runner/native_view_plugin.cc), on Android the window gets
/// FLAG_KEEP_SCREEN_ON (MainActivity.kt); where there is nothing to ask,
/// the request is quietly dropped.
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
          (held) {
            debugPrint('keep awake: ${on ? 'on' : 'off'} (held: $held)');
            // Not taken (the window was not there yet): the next request
            // tries again.
            if (on && held != true && _on) _on = false;
          },
          onError: (Object e) {
            if (e is! MissingPluginException) {
              debugPrint('Keep awake failed: $e');
            }
          },
        );
  }
}
