# Map engines

The map screen describes what to show (`MapScene`) and talks to a `MapViewController`
(`lib/map/engine/map_engine.dart`). Two engines implement that interface;
`lib/map/engine/engines.dart` picks one per process.

| Engine | File | Used when |
|---|---|---|
| MapLibre Native | `maplibre_engine.dart` + `maplibre/` + `native/maplibre/` | Linux on Wayland, bridge library and map assets present in the bundle |
| Flutter (`flutter_map` + `vector_map_tiles`) | `flutter_map_engine.dart` | everywhere else, and whenever MapLibre cannot start |

One line on stderr says which engine was chosen and why, e.g.
`map engine: Flutter (no /path/lib/libmapsoly_mln.so)`.
`MAPSOLY_MAP_ENGINE=flutter` forces the Flutter engine; `MAPSOLY_MAP_ENGINE=maplibre` is
accepted but still falls back when MapLibre cannot work. A failure after start (the native
map cannot be created, the style does not load, the map thread gives up) also falls back,
inside the same view, with `map engine: MapLibre failed (...), using Flutter`.

The background (why MapLibre, why this way of embedding, measurements) is in
`docs/maplibre-spike.md` and `docs/maplibre-flutter-prototype.md` ("route B").

## How the MapLibre engine works

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
strip maths. The native bridge and the widget itself are only tested on the device.

## Not done

- Android (planned through `maplibre_gl` or `maplibre` behind the same interface), X11,
  the PC: all use the Flutter engine.
- Route A of the prototype (map as a Flutter texture) is not in this bridge; the code is in
  `spike/maplibre_flutter/`.
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
