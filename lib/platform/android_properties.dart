import 'dart:convert';
import 'dart:ffi';

/// Value of an Android system property, or null when it is not set (or this
/// is not Android).
///
/// Read synchronously through libc, so it can decide things before the first
/// frame. Properties named `debug.*` can be set from a computer without root
/// (`adb shell setprop debug.mapsoly.x value`) and last until the device
/// restarts: the Android counterpart of an environment variable for testing.
String? androidSystemProperty(String name) {
  try {
    final get = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>),
          int Function(Pointer<Uint8>, Pointer<Uint8>)
        >('__system_property_get');
    final malloc = DynamicLibrary.process()
        .lookupFunction<
          Pointer<Uint8> Function(IntPtr),
          Pointer<Uint8> Function(int)
        >('malloc');
    final free = DynamicLibrary.process()
        .lookupFunction<
          Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)
        >('free');
    final key = utf8.encode(name);
    // PROP_VALUE_MAX is 92 bytes including the terminator.
    final buffer = malloc(key.length + 1 + 92);
    try {
      buffer.asTypedList(key.length).setAll(0, key);
      buffer[key.length] = 0;
      final value = buffer + key.length + 1;
      final length = get(buffer, value);
      if (length <= 0) return null;
      return utf8.decode(value.asTypedList(length), allowMalformed: true);
    } finally {
      free(buffer);
    }
  } on ArgumentError {
    return null; // no such symbol: not Android
  }
}
