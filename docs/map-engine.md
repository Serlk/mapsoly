# Map engines

The map screen describes what to show (`MapScene`) and talks to a `MapViewController`
(`lib/map/engine/map_engine.dart`). Two engines implement that interface;
`lib/map/engine/engines.dart` picks one per process.

| Engine | File | Used when |
|---|---|---|
| MapLibre Native | `maplibre_engine.dart` + `maplibre/` + `native/maplibre/` | Linux on Wayland, bridge library and map assets present in the bundle; Android, bridge library in the APK (see [Android](#android)) |
| Flutter (`flutter_map` + `vector_map_tiles`) | `flutter_map_engine.dart` | everywhere else, and whenever MapLibre cannot start |

One line on stderr says which engine was chosen and why, e.g.
`map engine: Flutter (no /path/lib/libmapsoly_mln.so)`.
`MAPSOLY_MAP_ENGINE=flutter` forces the Flutter engine (on Android, which has no
environment to set: `adb shell setprop debug.mapsoly.map_engine flutter`, read when the
app starts); `MAPSOLY_MAP_ENGINE=maplibre` is accepted but still falls back when MapLibre
cannot work. A failure after start (the native
map cannot be created, the style does not load, the map thread gives up) also falls back,
inside the same view, with `map engine: MapLibre failed (...), using Flutter`.

The background (why MapLibre, why this way of embedding, measurements) is in
`docs/maplibre-spike.md` and `docs/maplibre-flutter-prototype.md` ("route B").

## How the MapLibre engine works

This section describes Linux. Scene, style, camera, gestures and the tile server are the
same code on Android; where the map is drawn and how it gets on screen differs, see
[Android](#android). That difference sits behind `MapSurface`
(`maplibre/surface.dart`: `WaylandMapSurface`, `AndroidMapSurface`).

```
 Flutter window (GTK, transparent)        <- cards, buttons, sheets: ordinary widgets
   MapLibreView: paints a hole (BlendMode.clear) where the map is; takes pointer events
 ------------------------------------------------------------------------------
 wl_subsurface placed BELOW the window    <- libmapsoly_mln.so: MapLibre Native, GLES 3,
                                             own thread, own EGL context
```

- **Not part of Flutter's scene.** The bridge library draws the map into a Wayland
  subsurface below the application window. The runner makes the window and the Flutter
  view transparent (`linux/runner/native_view_plugin.cc`, only on Wayland and not with
  `MAPSOLY_MAP_ENGINE=flutter`). `MapLibreView` clears its rectangle, including the
  scaffold background painted under it, so the map shows through; everything painted
  later stays on top. Until the first style is loaded it paints the colour of the
  style's `background` layer instead of a hole.
- **Input stays in Flutter.** The subsurface has an empty input region. `MapLibreView` is
  a `Listener`; widgets above it in the stack get their own taps as usual.
  `maplibre/gestures.dart` turns pointer events into camera changes: one-finger pan with
  fling, pinch zoom, two-finger rotation (after a 12 degree threshold), double tap,
  double-tap-drag zoom, mouse wheel, long press.
- **The camera lives in Dart** (`maplibre/camera.dart`): centre, zoom, bearing, pitch
  (0-60 degrees). Gestures and controller calls compute the new camera and push it to the
  native map (`mlnb_set_camera`), so the getters and screen <-> coordinate conversion
  (including the perspective of a tilted view) are synchronous and pure. `zoom` keeps the
  app's convention (256 px tiles); MapLibre's is one less. While the native map eases to a
  new camera the same interpolation is evaluated in Dart (`CameraTween`), so the getters and
  `cameraChanges` (about 30 notifications a second) follow what is on screen.
  `onCameraChanged` is throttled to one call per 250 ms, the last after the camera stopped.
- **`moveCamera`** (`planCameraMove`): an explicit duration is used as given. Without one,
  calls that arrive 0.15-1.6 s apart (driving: a position about once a second) run at
  constant speed for 1.15 times their interval, so they blend into one motion; a single
  call eases for 350 ms, or jumps when the target is more than two view sides or 2.5 zoom
  levels away. Bearing always turns the short way round.
- **Camera padding**: per side the larger of `setPadding()` and the `MediaQuery.padding`
  of the place the view is built in (the bottom bar the body extends under). It is passed
  to MapLibre as camera padding: the target is drawn at the centre of what is left, the
  vanishing point of a tilted view moves with it. `fit()` keeps its own padding free in
  addition. The attribution text sits inside the same insets.
- **Two-finger tilt**: both fingers moving up or down together change the pitch; any other
  two-finger movement pans, zooms and rotates. Nothing moves until it is clear which.
- **3D buildings** (`MapScene.buildings3d`): a `fill-extrusion` layer over the
  OpenMapTiles `building` layer (`render_height`, `render_min_height`) from zoom 15, below
  the route; soft grey on the light map, a little lighter than the flat buildings on the
  dark one. It is part of the style, so toggling it reloads the style.
- **Blur regions** (`MapScene.blurRects`, logical px in the view's coordinates): after
  MapLibre has drawn a frame the bridge blurs these rectangles of it in place (halving
  blits down to about 1/8 resolution for sigma 18, separable Gaussian, drawn back; a
  margin of 3 sigma around the rectangle is sampled so its edges do not darken). Flutter's
  own `BackdropFilter` cannot reach the map, which is not in Flutter's scene.
  `MAPSOLY_MAP_BLUR=0` turns it off.
- **Several packs** (`MapScene.offlineMaps`): with one pack MapLibre reads the archive
  itself (`pmtiles://`). With more, the style's vector source points at the tile server
  (`/packs/<set>/z/x/y.pbf`), which answers each tile from the first archive that has it,
  bytes as stored (gzip passed through with `Content-Encoding`). Packs cut from one tileset
  hold identical tiles along their borders, so the map has no seam.
- **`MapScene.offlineLoading`**: while true no style is loaded and the placeholder colour
  is shown, so the start does not flash the online raster map.
- **Scene diffing** (`maplibre/scene.dart`). A scene becomes five strings: a style key,
  three GeoJSON documents (routes, points, accuracy circle) and a traffic key. Only what
  changed is sent. The base style is loaded only when its key changes (theme, pack,
  colours); after a style load the rest is sent again.
- **Style** (`maplibre/style.dart`). `assets/styles/{bright,dark}.json` are rewritten at
  run time: `pmtiles://file://<pack>/map.pmtiles`, local glyphs and sprites, plus the
  app's sources and layers. Route and alternatives sit right above the last road/rail
  layer, i.e. below road and place labels; position, accuracy circle (a polygon in true
  metres), the "from" ring and the two pins are on top. Colours come from the Material
  colour scheme of the app theme. Pin images are drawn in Dart from the Material icons.
- **No pack installed** (`scene.offline == null`): a raster style with OpenStreetMap tiles,
  dimmed and inverted for the dark theme, with the same overlays.
- **Traffic and online tiles go through a loopback tile server**
  (`maplibre/tile_server.dart`, `127.0.0.1`, random port). MapLibre Native sends a fixed
  User-Agent the traffic services reject, and Yandex tiles are EPSG:3395:
  `/google/<version>/z/x/y.png` proxies with the browser headers,
  `/yandex/<version>/z/x/y.png` recomposes the tile from one or two Yandex tiles
  (`composeYandexTrafficTile` in `lib/traffic/yandex_tile_provider.dart`, shared with the
  Flutter engine), `/osm/z/x/y.png` proxies the OSM tiles. The traffic layer is added at
  run time right below the route; on a new version the new layer is added and the old one
  removed 10 s later. For these overlay sources the bridge turns off MapLibre's low-zoom
  prefetch and allows a parent tile as a stand-in only one level up: otherwise a loading
  view shows tiles from four levels up stretched over the screen, which on the dark map is
  a bright flash (`MLNB_OVERLAY_PLACEHOLDERS=1` restores that for comparison).
- **`visible: false`** unmaps the subsurface and stops rendering; the map and its state stay.
- **Geometry.** After every layout the widget's rectangle is sent to the bridge
  (subsurface position and size). The device pixel ratio is read from the view; MapLibre
  fixes it per renderer, so a change recreates the native map with the same camera and
  scene.
- **Frame pacing** (in `native/maplibre/mlnb.cpp`): one frame per compositor frame
  callback, drawn first and committed when the previous frame's callback arrives; the wait
  is bounded (50 ms), so a hidden or locked screen stalls nothing - the map then draws
  one frame per callback that does arrive.
- **Lifecycle.** `mlnb_destroy` joins the map thread before returning, so no native
  callback can arrive afterwards; events come through a `NativeCallable.listener`. A frame
  that throws inside MapLibre is logged (`mlnb: frame failed: ...`) and the next one is
  drawn; after 20 in a row the engine falls back. A fatal signal in the process prints
  `mlnb: fatal signal ..., last bridge call: ...` and a backtrace (module + offset) to
  stderr before the default action.

### Native side

`native/maplibre/mlnb.h` is the whole interface (plain C, called through `dart:ffi` from
`maplibre/bridge.dart`): create/destroy, geometry, visibility, style JSON, camera, runtime
sources/layers/images, GeoJSON data, diagnostics. `linux/runner/native_view_plugin.cc`
only hands Dart the `wl_display` and the window's `wl_surface` (method channel
`mapsoly/native_view`) and makes GTK commit the window after the subsurface moved.

## Build and deploy

```sh
# once per machine (PC, x86_64): MapLibre Native static libraries + Alpine sysroot (docker, ~10 min)
spike/maplibre/build.sh
spike/maplibre/make_assets.py                 # downloads fonts and sprites into data/maplibre-assets/

# bridge libraries (phone: cross-built, PC: native) + trimmed assets -> linux/prebuilt/ (git-ignored)
tool/build_maplibre.sh            # or: tool/build_maplibre.sh phone | pc | assets | pc-core

# everything: runs tool/build_maplibre.sh, copies the tree, builds on the phone
./tool/deploy_titan2.sh
```

`linux/CMakeLists.txt` installs `linux/prebuilt/<arch>/libmapsoly_mln.so` into `bundle/lib/`
and `linux/prebuilt/maplibre/` into `bundle/data/maplibre/`, both optional.

**PC build** (x86_64): `tool/build_maplibre.sh pc-core` builds MapLibre Native natively once
(system libuv, curl, ICU, png, jpeg, webp, Wayland, Mesa), `tool/build_maplibre.sh pc` the
bridge; `flutter build linux` then bundles it and the app uses MapLibre on a Wayland
desktop too. Without the library it falls back to the Flutter engine.

**Harness**: `flutter build linux --release -t lib/map/engine/dev/harness_main.dart` builds
the map view alone under a translucent bar, with scripted camera moves
(`HARNESS_SCRIPT=fit|drive|spin|north`, `HARNESS_DARK=1`, `HARNESS_3D=1`,
`HARNESS_BLUR=0`), for work on the engine without the rest of the app.

### Assets

`tool/build_maplibre_assets.py` copies into `linux/prebuilt/maplibre/`:

- glyphs for the 7 font stacks the two styles use, Unicode blocks 0-1535 (Latin, Latin
  Extended, IPA, Greek, Cyrillic, Cyrillic Supplement) and 8192-8703 (punctuation,
  currency, letter-like, arrows): 630-680 kB per stack;
- sprites of both styles.

4.8 MB in total (the untrimmed fonts are 235 MB). They are generated, not committed. Labels
in other scripts (CJK, Arabic, ...) are not drawn.

## Android

```
 Flutter scene (Impeller)
   ... cards, buttons, sheets; Glass = BackdropFilter, blurs whatever is below
   Listener (gestures)  >  Stack [ placeholder colour | Texture(id) | attribution ]
                                                         ^ SurfaceProducer (ImageReader)
 libmapsoly_mln.so: MapLibre Native, GLES 3, own thread, own EGL context
   EGL window surface on the producer's ANativeWindow  -- eglSwapBuffers -->
```

### Design

- **The map is a Flutter texture.** `MapSurface.kt` creates a
  `TextureRegistry.SurfaceProducer`; its `Surface` goes to the bridge as an
  `ANativeWindow`, the bridge makes an EGL window surface on it with its own GLES 3
  context and MapLibre renders there (`native/maplibre/android/backend.hpp`). Flutter
  shows it with a `Texture` widget at the bottom of the view. So, unlike on Linux, the map
  *is* part of Flutter's scene: no transparent window, no hole, it may be clipped or
  covered by anything, and the glass surfaces blur it with their own `BackdropFilter`.
  `mlnb_set_blur` does nothing on Android and `MapScene.blurRects` is not sent.
- **One bridge, two backends.** `mlnb.cpp` is shared; the Wayland backend and the Android
  one are selected with `#ifdef __ANDROID__`. The C API is the same except for how a map
  gets its surface: `mlnb_android_create(window, width_px, height_px, pixel_ratio, ...)`
  and `mlnb_android_set_surface(map, window, width_px, height_px)` replace `mlnb_create`
  and `mlnb_set_geometry` (which exist on Android but do nothing useful). These symbols
  are not in the Linux library; its ABI is still version 6 and `bridge.dart` looks the
  Android ones up only on Android.
- **Pixel ratio is the real one** (2.75 on a 440 dpi phone, not rounded): the texture has
  exactly the widget's device pixels, the map's logical size is that divided by the ratio.
  Pin and arrow images are drawn at the next whole number.
- **The window comes and goes.** A resize (rotation) gives the producer a new surface, and
  Android takes the surface away while the app is in the background
  (`SurfaceLifecycle.resetInBackground`) and makes a new one afterwards. Kotlin tells the
  native library first, synchronously (`mlnb_android_unregister_window` returns when the
  map thread no longer touches the window), then Dart, which later passes the new window
  to `mlnb_android_set_surface`. The EGL context, and with it every texture and buffer of
  MapLibre, survives: without a window it is current on a 1x1 pbuffer and nothing is
  drawn. Window pointers that Dart holds are only ever compared against the list of
  windows Kotlin has registered, never dereferenced blindly. `TextureSurfaceController`
  (`maplibre/surface_android.dart`) keeps the texture at the size wanted last.
- **Pacing.** `eglSwapBuffers` does not wait here (the consumer is Flutter's raster
  thread; swap interval 0), so frames are paced by the display: a small thread with an
  `ALooper` asks `AChoreographer` for one callback per frame drawn; the next frame is
  drawn right after that vsync. Every frame the map queues makes Flutter composite a
  frame of its own.
- **Logging** goes to logcat: tag `mlnb` for the bridge and MapLibre, `flutter` for the
  `map engine: ...` lines. No signal handler is installed (Android writes a tombstone with
  a backtrace itself) and the map thread is not pinned to cores.

### MapLibre Native for Android: what it is built from

MapLibre's own Android platform (`platform/android`) is the native half of its Java SDK:
run loop, HTTP, image decoding and text helpers there call into Java classes. This app
has no such SDK, so the core is built alone (`MLN_WITH_CORE_ONLY`, GLES renderer) by
`native/maplibre/android/CMakeLists.txt` with these pieces:

| Piece | Linux build | Android build |
|---|---|---|
| run loop, timers, async tasks | libuv (system) | libuv 1.51.0, static |
| file sources, PMTiles, MBTiles, offline database | `platform/default` | the same files |
| SQLite, HarfBuzz, FreeType | vendored in MapLibre | the same |
| bidi, case mapping, collation | system ICU | MapLibre's vendored ICU subset + nunicode; number formatting is the plain fallback |
| image decoding | libpng, libjpeg, libwebp | libpng 1.6.50 only (`android/image.cpp`): sprites and every tile the app serves are PNG |
| HTTP | curl | `android/http_file_source.cpp`: plain HTTP/1.0 to `127.0.0.1` only, a non-blocking socket per request on the file-source thread, gzip bodies inflated; any other host is refused |
| logging, thread names | stderr, pthread | `android/logging.cpp` (logcat), `android/thread.cpp` |
| JNI | - | two functions (`android/jni.cpp`): `Surface` <-> `ANativeWindow` |

The HTTP client can be that small because MapLibre never talks to the network in this
app: packs are files, glyphs and sprites are files, and traffic and the online raster map
come from the Dart tile server on the loopback interface. The library needs only `libEGL`,
`libGLESv3`, `libandroid`, `liblog`, `libz`, `libm`, `libdl`, `libc`; libc++ is linked
statically; API level 24, 16 KiB pages.

### Build

```sh
tool/build_maplibre.sh assets            # glyphs and sprites (as for Linux), once
tool/build_maplibre_android.sh           # arm64-v8a and x86_64, then the assets archive
tool/build_maplibre_android.sh x86_64    # one ABI (x86_64 = emulator)
tool/build_maplibre_android.sh assets    # only android/app/src/main/assets/maplibre.zip
flutter build apk --release --no-pub
```

It needs the NDK (28.2), the system's CMake (3.25 or newer; the SDK's 3.22 is too old for
MapLibre) and ninja, git, curl, python3; no root, no Docker. The MapLibre source is the
tree of the Linux build (`data/maplibre-build/maplibre-native`, the commit pinned in
`spike/maplibre/build.sh`; fetched if missing); libuv and libpng are downloaded and checked
against SHA-256 sums in the script. Build trees are in `data/maplibre-android/`. A first
build takes a few minutes per ABI on a 16-thread PC; after an edit of the bridge,
seconds.

Results, both git-ignored: `android/app/src/main/jniLibs/<abi>/libmapsoly_mln.so`
(stripped: 9.7 MB arm64-v8a, 10.0 MB x86_64) and `android/app/src/main/assets/maplibre.zip`
(2.8 MB: the 4.7 MB of `linux/prebuilt/maplibre/`, deflated). Without the library the app
builds and uses the Flutter engine (`map engine: Flutter (cannot load ...)`).

**Assets.** MapLibre reads glyphs and sprites as plain files, so `MapSurface.kt` unpacks
the archive into `<files>/maplibre/` at the first start of each installed version (a
marker file holds the package's update time) and gives Dart the path. A missing archive
makes the view fall back to the Flutter engine.

### Differences from Linux, limits

- No blur pass, no subsurface, no frame-callback pacing, no core pinning, no crash
  handler (see above); `MLNB_FREERUN`, `MLNB_NO_PIN`, `MLNB_NO_CRASH_HANDLER` and
  `MAPSOLY_MAP_BLUR` mean nothing there. Of the debug hooks only the engine override and
  the frame log exist: `adb shell setprop debug.mapsoly.map_framelog
  /sdcard/Android/data/dev.mapsoly.mapsoly/files/frames.csv`.
- JPEG and WebP images are not decoded and MapLibre cannot fetch from the network itself.
  A style that needs either would have to go through the tile server (as PNG).
- The map is one frame behind the widgets drawn over it in the worst case (it is drawn
  after a vsync and composited by Flutter at the next one), and every map frame costs a
  Flutter frame with its blurs on top. Whether that matters on a slow phone is not known.
- The texture is the full resolution of the screen. Rendering at a lower pixel ratio and
  letting Flutter scale it would be the first thing to try on a weak GPU; not done.
- armeabi-v7a is not built by default (the script accepts it; never tried).
- **Tested on the emulator only** (x86_64, API 34). The arm64 library is built and
  packaged but has never run; frame rates on a phone are unmeasured. See
  `docs/android.md`.
- The emulator's default software renderer (`-gpu swiftshader_indirect`) draws the map
  without any text or icons: its GLES translator mishandles the alpha-only glyph textures.
  With `-gpu swangle_indirect` (ANGLE on SwiftShader) and with `-gpu host` everything is
  drawn. No GL error is reported in either case.

## Signal map (heat map of the collected transmitters)

A layer of its own, switched in Settings ("Карта сигналов", `AppSettings.signalHeat`, off by
default) independently of the traffic choice: where the app itself has collected Wi-Fi
access points, cells and Bluetooth devices. Purely local: read from the positioning
database, drawn, sent nowhere. Privacy zones need no handling here, the collector stores
nothing inside them.

- **Data** (`lib/map/signal_heat.dart`). `SignalHeatController` keeps the points for the
  view. It reads a square twice the longer side of the view around the camera
  (`SignalHeatArea`), again when the camera is more than 30% of that half-size away from
  where it last read or the zoom changed the grid, at most once a second (longer after a
  slow read: 20 times what the read took), and every 10 s while the layer is on, so what
  was collected a moment ago appears during a drive. An unchanged result keeps the same
  list, so nothing is sent to the engine again.
- **Query** (`LocationDb.wardrivingGrid`, read-only). Only `source = wardriving`, all
  kinds, gathered with `GROUP BY` on a grid anchored at 0, 0: the step along the longitude
  is 360 / 2^n degrees with n chosen so that a cell is 20-40 px wide on the screen, the
  step along the latitude is that divided by about 1/cos(latitude) (in steps of a half).
  One point per non-empty cell, at the mean position of its transmitters. More than 4000
  cells: the grid is made coarser (up to 3 times), never cut. The database handle is a
  synchronous sqlite3 object of the UI isolate, so the read happens there; it costs a few
  microseconds per record of any source in the square. With more than 30 000 records in
  the square (`LocationDb.countInBounds`, index only) it is not read at all and the layer
  shows nothing until the map is zoomed in.
- **Weight** of a cell, 0..1 (`signalHeatWeight`): for each kind
  `factor * sqrt(min(count, 10) / 10) * strength`, where `strength = clamp((dBm + 100) / 60,
  0.15, 1)` of the strongest signal seen (-90 dBm and weaker: the floor, -40 dBm: 1,
  unknown: 0.4) and `factor` is 1 for Wi-Fi, 0.6 for Bluetooth, 0.35 for cells (their
  position is a rough guess); the sum over the kinds, capped at 1.
- **MapLibre engine.** `MapScene.signalHeat` (null = off). While it is on, the style has a
  GeoJSON source and a `heatmap` layer `mapsoly-heat` (`heatLayer()` in
  `maplibre/style.dart`; the style key includes it, so switching reloads the style once);
  the points go through the ordinary `SetGeoJson` op, feature property `w` is the weight.
  Layer order: roads, [3D buildings], **heat**, [traffic raster], route, labels, markers.
  The traffic overlay is inserted at run time right below the first route layer, that is
  above the heat. Opacity 0.65, colour ramp from transparent through blue, cyan, green,
  yellow to red. No native change: the layer arrives inside the style JSON, and the
  prebuilt bridge libraries contain MapLibre's heatmap layer.
- **Flutter engine.** A blurred translucent spot per point, coloured by its weight, below
  the traffic and the route. Spots do not add up into a density.

## Debug hooks (environment)

| Variable | Effect |
|---|---|
| `MAPSOLY_MAP_ENGINE=flutter\|maplibre` | engine override |
| `MAPSOLY_MAP_FRAMELOG=/path.csv` | one CSV row per rendered map frame; `data/maplibre-build/engine/frames.py` summarises it |
| `MAPSOLY_MAP_BENCH=/prefix` | 3 s after start, runs the scripted camera of the spike; writes `<prefix>.frames.csv` |
| `MAPSOLY_MAP_FLIP=<ms>` | switches bright/dark by itself, after `<ms>` and again 80 ms later, repeatedly |
| `MAPSOLY_MAP_BLUR=0\|strip` | no blur / an extra 64 px strip along the bottom edge |
| `MAPSOLY_MAP_PACKS=/a.pmtiles:/b.pmtiles` | draw these archives instead of the scene's packs |
| `MAPSOLY_MAP_PACK_SERVER=1` | send even a single pack through the tile server |
| `MAPSOLY_MAP_3D=<pitch>` | extruded buildings on, camera tilted from the start |
| `MAPSOLY_MAP_SNAPSHOTS=<prefix>,<ms>,<n>` | write n frames of the map itself (no Flutter layer) as `<prefix>-NN.ppm` |
| `MLNB_FREERUN=1` | draw even when the compositor takes no frames (hidden window; for snapshots) |
| `MLNB_OVERLAY_PLACEHOLDERS=1` | MapLibre's default stand-in tiles for the traffic overlay |
| `MLNB_NO_PIN=1` | do not pin the map thread to the big cores |
| `MLNB_NO_CRASH_HANDLER=1` | do not install the signal handler |

## Tests

`test/map/engine/`: camera arithmetic and fitting, the gesture machine, style rewriting for
both bundled styles, scene diffing and GeoJSON, tile-server URL handling and the Yandex
strip maths, and (`surface_test.dart`) the Android texture's size/window bookkeeping
against a fake platform channel. The native bridge and the widget itself are only tested
on the device.

The signal map: `test/map/signal_heat_test.dart` (weights, area and grid, the controller's
throttling), `test/positioning/location_db_grid_test.dart` (the query), the style and scene
tests above (source and layer only when on, the order), `test/map/map_screen_test.dart`
(the scene of the screen). How the heat map looks on the device is not covered by tests.

## Not done

- X11 uses the Flutter engine.
- On Linux the map is not a Flutter texture (route A of the prototype, code in
  `spike/maplibre_flutter/`); on Android it is, see above.
- The subsurface is not synchronised with Flutter frames: during a window resize, or if the
  map widget were moved or animated, map and widgets can be a frame apart. The widget must
  not be clipped, faded or transformed; anything meant to cover it must be opaque.
- Hot restart of the Dart code leaks the native map (release builds are not affected).
- A pack replaced under the same path while the app runs: the style is reloaded, but
  whether MapLibre's PMTiles reader drops what it cached for that file was not checked.
- The Flutter engine draws one pack only, cannot tilt, ignores camera padding and blur
  rectangles.
- With several packs every vector tile goes through the Dart tile server on the UI
  isolate; with one pack MapLibre reads the file directly.
- Glyphs outside the kept ranges.
