# Android

The app runs on Android with the same MapLibre Native map engine as on Linux
(GPU vector rendering, tilt and 3D buildings, rotation), drawn into a
`SurfaceView` of its own below the transparent Flutter view; without its library in the APK it falls back to the Flutter map
engine (flutter_map + vector tiles from PMTiles). Everything platform-specific goes through the app's own
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
debug key. Two native parts are built separately, before the APK, and are
optional (the app builds and runs without them, with less):

```sh
tool/build_valhalla_android.sh     # offline routing, see docs/routing.md
tool/build_maplibre.sh assets      # glyphs and sprites (shared with Linux)
tool/build_maplibre_android.sh     # MapLibre map engine, see docs/map-engine.md
```

The map engine adds 11.3 MB to the universal APK (33.1 MB -> 44.5 MB with
arm64-v8a, armeabi-v7a and x86_64 inside): 4.1 MB per ABI for
`libmapsoly_mln.so` (arm64-v8a and x86_64; 9.7-10 MB each once installed) and
2.8 MB of glyphs and sprites, which take another 4.7 MB unpacked in the app's
files directory.

## What works, and how

| Feature | Android side | Dart side |
| --- | --- | --- |
| Online and offline map, traffic, route, 3D | `MapSurface.kt`: the `SurfaceView` MapLibre draws into (below the Flutter view, which `MainActivity` makes transparent), unpacking of glyphs/sprites; `libmapsoly_mln.so` (`native/maplibre/`) | `lib/map/engine/maplibre_engine.dart`, `maplibre/surface_android.dart`; `docs/map-engine.md`, "Android" |
| Map without that library, packs | — (pure Dart) | `lib/map/engine/flutter_map_engine.dart`, `lib/packs/` |
| SQLite (address search, cameras, positioning database) | prebuilt `libsqlite3.so` from the Maven artifact `eu.simonbinder:sqlite3-native-library` (`android/app/build.gradle.kts`) | `package:sqlite3` opens it by name |
| Position from satellites | `LocationBridge.kt`: `LocationManager`, GPS provider, 1 Hz, plus `GnssStatus` satellites | `AndroidGnssSource` → `PositioningEngine` (`lib/positioning/platform_engine.dart`) |
| Position without satellites | `RadioBridge.kt`: `WifiManager` scan results, `TelephonyManager` cells; `StillnessBridge.kt`: accelerometer | `AndroidWifiScanner`, `AndroidCellSource`, `StationaryFeeder` → the same engine |
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

Three sources feed the same `PositioningEngine` as on Linux, so the
estimator, the fusion filter, the spoofing checks, the user's own
transmitter database ("Собирать свою базу"), the online lookups ("Уточнять
онлайн", off by default) and the privacy zones behave the same. Details of
the sources are in `docs/positioning.md`, "Android".

- **Satellites**: `LocationManager`, GPS provider. The "network" provider
  is not used: on most phones it is a Google service.
- **Wi-Fi**: the system's scan results (BSSID, level in dBm, frequency, the
  age of each entry; the SSID only for the `_nomap` opt-out). Reading them
  is free; a fresh scan is asked for at most every 31 s, because Android 9+
  allows an app on screen four `startScan()` calls in two minutes. A
  refusal (allowance used up, Wi-Fi scanning off) is not repeated for a
  minute.
- **Cells**: `TelephonyManager.requestCellInfoUpdate` (Android 10+, the
  cached `getAllCellInfo` before that): GSM, UMTS, LTE and NR, serving and
  neighbours. A device without a modem reports none.

Permissions: `ACCESS_FINE_LOCATION` (already needed for satellites) guards
all three; `ACCESS_WIFI_STATE` and `CHANGE_WIFI_STATE` are install-time.
`NEARBY_WIFI_DEVICES` is deliberately not declared: it exists for apps that
do not derive location from Wi-Fi, and scan results need the location
permission regardless. Verified on Android 14 (emulator and a tablet): scan
results and cells arrive with these permissions alone. Location must also
be switched on in the system, or Android returns empty lists; the location
sheet says so and offers the settings.

Because scans are half a minute apart, two things differ from Linux
(`androidPositioningConfig`): a scan entry counts for 45 s instead of 30,
and while the accelerometer shows the device lying perfectly still the
engine is told so once a second (`StationaryFeeder`), which keeps the
accuracy circle from growing to kilometres between two scans. Stillness is
ignored while satellites give a usable fix.

Everything stops when the app leaves the screen (`AppLifecycleListener`,
hidden → `engine.stop()`, shown → `engine.start()`): no location listener,
no scan requests, no cell polls, no sensor. There is no foreground service
and no background permission, so guidance does not update while another app
is on top.

The permission is asked for once per run of the app (system dialog). After
a refusal the location sheet explains what is missing and offers
"Разрешить", or "Открыть настройки" when the system no longer shows the
dialog or location is switched off for the whole device; the state is read
again when the app returns to the front.

Fixes are dated by the platform's own record of when they were taken
(`Location.elapsedRealtimeNanos`, turned into system-clock time), not by
when the message reached Dart. While the app is busy several fixes can
arrive together; dated by arrival they looked like one jump and tripped the
spoofing check on a real device.

The emulator's invented satellites (all with the same signal level, none
used in the fix) look like a spoofing transmitter to `GnssSanityChecker`, so
`LocationBridge` does not pass satellites on when it runs on emulator
hardware (`ranchu`). Real devices are not affected.

Bluetooth LE beacons are not used; what exists and what is missing is in
`docs/positioning.md`, "BLE".

### Files

Exports go to `Android/data/dev.mapsoly.mapsoly/files/Mapsoly` on the shared
storage, and the built-in file browser imports from there. It needs no
permission; a computer sees the folder over USB, but the stock file manager
of Android 11+ hides `Android/data`. A share sheet / document picker would be
the proper answer and is not done.

## Not done

- The MapLibre engine on real hardware: it has only run on the emulator
  (x86_64); the arm64 library is built but untested, and performance on a
  phone is unmeasured.
- Bluetooth LE beacons for positioning (design note in
  `docs/positioning.md`).
- CDMA and TD-SCDMA cells (no model for them in the engine).
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
    -gpu swangle_indirect -no-boot-anim
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell am start -n dev.mapsoly.mapsoly/.MainActivity
adb emu geo fix 34.1024 44.9521 250 12 30   # lon lat alt sats knots
adb emu sensor set magnetic-field 22:0:-40  # turns the compass
```

`-gpu swangle_indirect` is software rendering through ANGLE. With the older
`-gpu swiftshader_indirect` the MapLibre map has no labels and no icons (a
fault of that renderer's handling of alpha-only textures, not of the app);
`-gpu host` uses the PC's GPU, also without a window, and is the only one
fast enough to judge animations.

`adb shell setprop debug.mapsoly.map_engine flutter` (until the emulator
restarts; `""` clears it) starts the app with the Flutter map engine.

The emulator has one invented access point and one invented LTE cell. To
take the satellites away without switching location off (which would also
empty the Wi-Fi and cell lists):

```sh
adb shell appops set com.android.shell android:mock_location allow
adb shell cmd location providers add-test-provider gps
adb shell cmd location providers set-test-provider-enabled gps false
adb shell cmd location providers remove-test-provider gps   # back to normal
```

`adb logcat -s flutter` shows, in counts only, what the radios hear and
what the satellites are thought of (`radio: wifi 9 seen 0 known ...`,
`gnss health: suspect [radioMismatch]`, `online wifi lookup: ...`).

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

Radio positioning, checked there (2026-11-27):

- the location sheet shows "Wi-Fi: видно 1" and "Соты: видно 1" (the
  emulator's access point and cell), with no permission beyond location;
- with "Собирать свою базу" on and fixes from `geo fix`, both become
  "известно 1" within a scan or two and the source reads "спутники и
  радио";
- with the GPS provider replaced by a disabled test provider the position
  stays: "Источник: Wi-Fi", 19–33 m while the accelerometer is still.
  Without the stillness input the same setup swung between about 250 m and
  2.7 km with every scan cycle;
- a new scan list arrives every 33–35 s; right after a restart of the app
  one request was refused (the allowance of the previous run) and the list
  was 66 s old before the next one;
- HOME removes the app's GPS registration (`dumpsys location`:
  `-registration`), returning adds it again.

On a real tablet (Android 14, arm64, with a modem), 2026-11-27, counts
only: 9–11 access points and 3 cells seen. With "Уточнять онлайн" switched
on, 2 of the 3 cells were resolved by beaconDB and the position came from
them ("Источник: сотовые вышки", 170–185 m); none of the access points
were known to Apple or beaconDB, which matches what `docs/positioning.md`
records for the Linux phone at the same place, so a position from Wi-Fi was
not observed on real hardware. The tablet's satellite receiver reported a
steady 33 m/s while the device, by its accelerometer, lay still; once the
cells were known the spoofing check called it (`radioMismatch`) and the
satellites were ignored.
Not exercised on hardware: learning the own database (it needs satellites
the engine trusts) and phones on Android versions other than 14.

The MapLibre engine, checked the same way (release build, `swangle_indirect`
and `host`): the offline vector map of the pack with labels and icons, pan,
fling, the zoom buttons, pinch (a `monkey` script with `PinchZoom`), "3D" with
extruded buildings, the Yandex traffic overlay, a route with its
traffic-coloured core and the grey alternative, the destination pin, the
position arrow, the long-press pin at the pressed place, light and dark
theme, the glass panels blurring the map, Search / Routes / Settings and back,
rotation to landscape and back, HOME and return, screen off and on (the map
gets a new surface each time: `mlnb: surface detached` / `attached` in
logcat), and the fallback to the Flutter engine both by the property and with
the library left out of the APK.

Frame times of the map itself (`debug.mapsoly.map_framelog`, 1080x2208
texture, city centre with traffic; measured when the map still was a Flutter
texture, not repeated since): with `-gpu host` (a desktop integrated
GPU behind the emulator's GL translation, 60 Hz) a median of 17-20 ms between
frames while panning and zooming, 10-14 ms of that in MapLibre's render call;
with `swangle_indirect` about 0.3 s per frame, which only measures the
software renderer. Neither says anything about a phone.

Not tested on hardware: everything above on a real phone, and in particular
**the Bluetooth link to an ELM327 adapter**, which an emulator cannot do. Its
Dart side is covered by `test/obd/android_rfcomm_test.dart` against a fake
channel; the Kotlin side has never exchanged a byte with a real adapter.

Unit tests for the Dart halves: `test/positioning/android_gnss_test.dart`,
`test/positioning/android_radio_test.dart`,
`test/positioning/android_stillness_test.dart`,
`test/positioning/platform_engine_test.dart`,
`test/user/privacy_android_sources_test.dart`,
`test/positioning/android_compass_test.dart`,
`test/obd/android_rfcomm_test.dart`,
`test/user/android_file_exchange_test.dart`.
