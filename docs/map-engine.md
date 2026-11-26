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
  later stays on top. Until the first style is loaded it paints the style's land colour
  instead of a hole.
- **Input stays in Flutter.** The subsurface has an empty input region. `MapLibreView` is
  a `Listener`; widgets above it in the stack get their own taps as usual.
  `maplibre/gestures.dart` turns pointer events into camera changes: one-finger pan with
  fling, pinch zoom, two-finger rotation (after a 12 degree threshold), double tap,
  double-tap-drag zoom, mouse wheel, long press.
- **The camera lives in Dart** (`maplibre/camera.dart`). Gestures and controller calls
  compute the new camera and push it to the native map (`mlnb_set_camera`), so `center`,
  `zoom` and screen <-> coordinate conversion are synchronous and pure. `zoom` keeps the
  app's convention (256 px tiles); MapLibre's is one less. Controller moves over a short
  distance are eased (350 ms), far ones jump. `onCameraChanged` is throttled to one call
  per 250 ms, the last one after the camera stopped.
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
  removed 3 s later.
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

# bridge library for the phone + trimmed assets -> linux/prebuilt/ (git-ignored)
tool/build_maplibre.sh            # or: tool/build_maplibre.sh lib | assets

# everything: runs tool/build_maplibre.sh, copies the tree, builds on the phone
./tool/deploy_titan2.sh
```

`linux/CMakeLists.txt` installs `linux/prebuilt/libmapsoly_mln.so` into `bundle/lib/` (ARM
targets only) and `linux/prebuilt/maplibre/` into `bundle/data/maplibre/`, both optional.

**PC build** (`flutter build linux` on x86_64): works as before and uses the Flutter engine;
the bridge is not built for the PC (it would need a native MapLibre build). The window is
created transparent on Wayland there as well; with the Flutter engine everything is
painted opaque, so nothing changes visibly.

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
- No pitch gesture, no compass button (the controller has `bearing` and `resetNorth()`).
- Glyphs outside the kept ranges.
