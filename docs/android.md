# Android

The app runs on Android with the Flutter map engine (flutter_map + vector
tiles from PMTiles). Everything platform-specific goes through the app's own
small platform channels in `android/app/src/main/kotlin/dev/mapsoly/mapsoly/`;
there are no Google Play services, no API keys and no third-party plugins
beyond `path_provider`.

## Build

```sh
export JAVA_HOME=~/.local/jdk-17 ANDROID_HOME=~/Android/Sdk
flutter build apk --release --no-pub        # all ABIs
# faster, emulator only:
flutter build apk --release --no-pub --target-platform android-x64
# -> build/app/outputs/flutter-apk/app-release.apk
```

Flutter 3.38.4, platform 36, NDK 28.2. The release build is signed with the
debug key. The offline routing engine is built separately, see
`docs/routing.md`.

## What works, and how

| Feature | Android side | Dart side |
| --- | --- | --- |
| Online and offline map, packs, traffic | — (pure Dart) | `lib/map/engine/flutter_map_engine.dart`, `lib/packs/` |
| SQLite (address search, cameras, positioning database) | prebuilt `libsqlite3.so` from the Maven artifact `eu.simonbinder:sqlite3-native-library` (`android/app/build.gradle.kts`) | `package:sqlite3` opens it by name |
| Position | `LocationBridge.kt`: `LocationManager`, GPS provider, 1 Hz, plus `GnssStatus` satellites | `AndroidGnssSource` → `PositioningEngine` (`lib/positioning/platform_engine.dart`) |
| Location permission | `Permissions.kt` | `LocationAccess`, shown in the "Местоположение" sheet |
| Keep screen on | `FLAG_KEEP_SCREEN_ON` on `mapsoly/native_view` → `keepAwake` | `lib/map/keep_awake.dart` (unchanged) |
| Compass | `CompassBridge.kt`: rotation vector → azimuth | `AndroidCompass`, chosen by `platformCompass()` |
| Speeding signal | `AlertPlayer.kt`: `AudioTrack`, navigation-guidance usage | `AlertSound` sends the same samples it writes to a WAV on Linux |
| ELM327 over Bluetooth Classic | `BluetoothBridge.kt`: `BluetoothSocket`, SPP | `AndroidBluetooth`, `AndroidRfcommTransport` (`lib/obd/bluetooth.dart` picks the platform) |
| Export / import of files | `getExternalFilesDir` | `AndroidFileExchange` |

### SQLite and the Linux build

The Linux build must keep using the system SQLite and must not compile or
download anything new on the phone. That is why the library comes in as a
Gradle dependency of the Android app only, not as the `sqlite3_flutter_libs`
plugin (whose Linux part builds SQLite from source): `pubspec.yaml` is
unchanged and nothing under `linux/` knows about it.

### Position

Only satellites are used. The fixes enter the same `PositioningEngine` as on
Linux, as its GNSS source, so the fusion filter, the spoofing checks, speed,
course and the privacy zones behave the same.

Wi-Fi and cell scanning is **not** implemented: Android throttles Wi-Fi scans
to four per two minutes and both need more permissions. Without them the
online lookups and the user's own transmitter database have nothing to work
on, so their lines and switches are hidden in the location sheet on Android.
The "network" location provider is not used either: on most phones it is a
Google service.

The permission is asked for once at the first start (system dialog). After a
refusal the location sheet explains what is missing and offers "Разрешить",
or "Открыть настройки" when the system no longer shows the dialog or
location is switched off for the whole device; the state is read again when
the app returns to the front. Location is read only while the app is on
screen: there is no foreground service and no background permission, so
guidance stops updating when the app is not visible.

The emulator's invented satellites (all with the same signal level, none
used in the fix) look like a spoofing transmitter to `GnssSanityChecker`, so
`LocationBridge` does not pass satellites on when it runs on emulator
hardware (`ranchu`). Real devices are not affected.

### Files

Exports go to `Android/data/dev.mapsoly.mapsoly/files/Mapsoly` on the shared
storage, and the built-in file browser imports from there. It needs no
permission; a computer sees the folder over USB, but the stock file manager
of Android 11+ hides `Android/data`. A share sheet / document picker would be
the proper answer and is not done.

## Not done

- MapLibre native engine (Linux/Wayland only); Android uses the Flutter one.
- Wi-Fi / cell positioning, wardriving, BLE (see above).
- Background location and a foreground service for guidance with the screen
  off or another app on top.
- Sharing files to other apps / picking files from anywhere.
- The "Sensors" settings page stays Linux-only (Android fuses the sensors
  itself).
- Release signing, app icon, per-ABI APKs.

## Testing

Emulator: AVD `mapsoly_test` (Pixel 5 profile, Android 14 / API 34, default
x86_64 image without Google services), headless:

```sh
~/Android/Sdk/emulator/emulator -avd mapsoly_test -no-window -no-audio \
    -gpu swiftshader_indirect -no-boot-anim
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n dev.mapsoly.mapsoly/.MainActivity
adb emu geo fix 34.1024 44.9521 250 12 30   # lon lat alt sats knots
adb emu sensor set magnetic-field 22:0:-40  # turns the compass
```

Feed a fix every second and move it in small steps: a jump of hundreds of
metres is, correctly, taken for spoofing and the satellites are ignored for
a minute.

Checked there (release build, by screenshots and `adb logcat`):

- start, online OSM map, the catalog, download of the "Крым" pack, the
  offline vector map, the Yandex traffic overlay;
- offline search in the pack's `places.sqlite`, online search;
- permission dialog, refusal → explanation and "Разрешить" → grant; the
  position marker, the speedometer and the limit sign following fixes sent
  with `geo fix`; a route from the position and guidance along it;
- the speeding signal being started (`alert sound: android (played: true)`;
  the emulator ran without audio, so it was not heard);
- `keep awake: on (held: true)` and the window's wake lock in
  `dumpsys power`;
- the marker's arrow turning with the emulated magnetic field;
- the Bluetooth permission dialog and the (empty) list of paired devices;
- export to and import from the exchange folder;
- the system back key: closes search, a picked point, asks before ending
  guidance, leaves the app from the bare map.

Not tested on hardware: everything above on a real phone, and in particular
**the Bluetooth link to an ELM327 adapter**, which an emulator cannot do. Its
Dart side is covered by `test/obd/android_rfcomm_test.dart` against a fake
channel; the Kotlin side has never exchanged a byte with a real adapter.

Unit tests for the Dart halves: `test/positioning/android_gnss_test.dart`,
`test/positioning/android_compass_test.dart`,
`test/obd/android_rfcomm_test.dart`,
`test/user/android_file_exchange_test.dart`.
