# MapLibre Native inside a Flutter Linux app: prototype (Titan 2, Alpine/musl, panthor)

Date: 2026-11-27. Follow-up to `docs/maplibre-spike.md`. Scope: a standalone Flutter test
app (`spike/maplibre_flutter/`, not the Mapsoly app) that shows the Moscow pack through
MapLibre Native inside the Flutter widget tree, and the measured cost of doing so.

## Verdict

Two integration routes work on Flutter 3.38.4's GTK embedder on this phone. Both show the
correct map with ordinary Flutter widgets composited on top, and both are driven by the same
Dart API. Neither reaches the standalone figures.

| | Avg FPS (scripted run) | Frames > 33 ms | Frames > 50 ms (of ~2800-3100) |
|---|---|---|---|
| Standalone MapLibre (GLFW), re-measured today | 56.3 | 1.5 % | 1 |
| **Route A**, map as a Flutter texture (`FlTextureGL` + EGLImage) | 48.7-50.3 | 6-9 % | 16-26 |
| **Route B**, map in a Wayland subsurface under a transparent Flutter view | 52.6-54.4 | 3.3-5.6 % | 7-15 |
| Route A, with a Flutter animation running on top at 60 FPS | 43.9-44.5 | 13-16 % | 76-82 |
| Route B, same | 45.3 | 15 % | 34 |

- **Route A costs about 6-7 FPS and 4-5 times more missed vblanks than standalone.** The
  hand-over of the frame is not the expensive part. Every map frame has to be a Flutter
  frame, and every Flutter frame goes through the GTK embedder's presentation path, which
  alone is three full-screen GPU passes plus a 7.9 MB CPU-to-GPU upload (details below).
  With the map on top of that the GPU sits at its maximum frequency 88-91 % of the time
  (standalone: 16 %).
- **Route B costs about 2-3 FPS** while Flutter is not animating, because map frames bypass
  Flutter completely. When Flutter itself animates continuously, route B is no better than
  route A: the same embedder path then runs 60 times a second next to the map.
- Recommendation: route A is the one that behaves like a normal widget and is the safer base
  for a plugin; route B is a Wayland-only fast path worth keeping behind the same API for the
  map screen, where the overlay is mostly static. The prototype's bridge library implements
  both. This is a judgement, not a measurement.

Interaction latency was **not judged by a human** in this prototype (nobody touched the
screen during my runs). Drag, pinch, rotate and the buttons are wired up for that; the
camera API itself was exercised by a scripted demo and checked on screenshots.

## What was built

```
spike/maplibre_flutter/
  native/mlnb.h, mlnb.cpp      C API ("mlnb") around one mln::Map: own thread, own EGL context
  native/bench_script.hpp      the spike's camera script, restartable
  native/build.sh              cross-compiles libmapsoly_mln.so on the PC (aarch64 musl)
  linux/runner/mln_map_plugin.{h,cc}   GObject plugin: FlTextureGL subclass + method channel
  linux/runner/my_application.cc       registers it; transparent window for route B
  lib/mln_map.dart             MlnMapController (Dart API), MlnMapView (widget + gestures)
  lib/main.dart                test page: map, translucent card, 4 buttons, script button
  phone/*.sh, deploy_phone.sh, fetch_run.sh, analyze.py   run + measure + analyse
```

`libmapsoly_mln.so` (10 MB stripped) links the static libraries the spike already built
(`data/maplibre-build/build-gl/*.a`, MapLibre Native `0c62d868`), so **nothing of MapLibre is
compiled on the phone**; the phone build is `flutter build linux` of a small runner
(about 30 s). The vendored freetype/harfbuzz/sqlite are kept private
(`--exclude-libs,ALL -Bsymbolic`) so they cannot clash with the copies GTK loads.

Dart API (`lib/mln_map.dart`): `MlnMapController.create(style, size, pixelRatio,
subsurface)`, `setCamera(lat, lon, zoom, bearing, pitch, duration)`, `moveBy(dx, dy)`,
`zoomBy(delta, focalPoint, duration)`, `rotateBy(degrees, focalPoint)`, `resize(size)`,
`setGestureInProgress`, `startBenchmark(prefix)`, `state()`, `dispose()`. Set-up goes over a
method channel (`mapsoly/mln_map`); camera calls go through `dart:ffi` straight into the
library, which posts them to the map thread, so they do not pass through the platform thread.
`MlnMapView` maps Flutter's scale gesture to pan, pinch zoom and rotation.

## How the 3.38.4 GTK embedder renders (read from the engine source, tag 3.38.4)

Verified in `engine/src/flutter/shell/platform/linux/` and `shell/platform/embedder/`:

- `fl_opengl_manager.cc`: the embedder creates **its own** EGL contexts (render + resource)
  on `eglGetPlatformDisplayEXT(EGL_PLATFORM_WAYLAND_EXT, gdk_wayland_display_get_wl_display())`.
  They are not GDK contexts and are not exposed by any public API. A plugin that asks EGL
  for the same `wl_display` gets the same `EGLDisplay`.
- `fl_texture_gl.cc`, `fl_engine.cc`: `FlTextureGL::populate()` runs on the raster thread
  with Flutter's render context current, and is called once per
  `mark_texture_frame_available` (`embedder_external_texture_gl.cc` caches the image until
  the next mark). The texture is treated as top-left origin, so a GL framebuffer arrives
  upside down.
- `fl_compositor_opengl.cc`, `fl_framebuffer.cc`: each Flutter frame is rendered into an
  FBO, **blitted** into a second framebuffer, exported as an EGLImage, and drawn from GTK's
  own GL context with `gdk_cairo_draw_from_gl`. So EGLImage sharing between unrelated
  contexts on one display is exactly what the embedder itself relies on.
- No `vsync_callback` is set, so the engine uses `VsyncWaiterFallback`: a **60.0 Hz timer**
  that is not tied to the compositor (panel: 59.75 Hz).
- `rasterizer.cc`: `FrameTiming` is reported only from `DoDraw`. Frames caused by a texture
  update alone (`DrawLastLayerTrees`) are rasterised but produce **no FrameTiming**.

Verified in GTK 3.24.52 `gdk/gdkgl.c` and with `perf` on the phone: for a GL texture source
on GLES, `gdk_cairo_draw_from_gl` assumes alpha, uploads the window's cairo paint surface
(1440x1372x4 = 7.9 MB) as a texture and draws it, then draws Flutter's frame blended over
it. In the profile the GTK main thread spends its time in `memcpy`, `pixman_fill` and page
clearing; it uses 56-61 % of a core at 49 FPS. This is the embedder's baseline for any
Flutter app on this stack, map or not.

## Route A: texture (`FlTextureGL` + EGLImage) - works

- The map thread creates a surfaceless GLES 3 context on the shared `EGLDisplay`
  (`EGL_KHR_surfaceless_context`, `EGL_KHR_no_config_context` are present; log line
  `consumer context: display=... (same as map: yes)`).
- Three RGBA8 textures with FBOs; each is exported with
  `eglCreateImage(EGL_GL_TEXTURE_2D)`. In `populate()` the image of the newest finished
  frame is bound to a texture in Flutter's context with `glEGLImageTargetTexture2DOES`
  (resolved through `eglGetProcAddress`; Mesa's `libGLESv2` does not export it).
  **No copy and no readback**; works on panthor/Mesa 26.3.
- The map thread waits on an EGL fence before handing a frame over, so Flutter never
  samples a half-drawn frame. No tearing or garbage was seen in any screenshot.
- The vertical flip is done by Flutter (`Transform.flip`), not by a copy.
- Sharing Flutter's context directly (share group) was not needed and not tried.

Costs:

- One extra full-screen textured quad in Flutter's raster thread, **plus the whole embedder
  path above for every map frame**. Flutter's raster thread: 21-23 % of a core; GTK main
  thread: 56-61 %; process total about 270 % against 174 % standalone.
- **Pacing is tied to Flutter's 60 Hz timer**, not to the display. The map renders at most
  one frame ahead and holds a finished frame until the previous one was picked up
  (hand-over wait: 16 ms median). Input therefore reaches the screen about one frame later
  than in the standalone app, plus the embedder's own latency. This is derived from the
  design and the hand-over timing; end-to-end latency was not measured.
- First attempt, kept as `MLNB_SERIAL=1`: render only after Flutter picked the previous
  frame up. That gave **32 FPS** (median 33 ms), because render + hand-over does not fit
  into one period. Rendering one frame ahead fixed it.
- Pinning the map thread to the four big cores (`MLNB_BIG=1`; the scheduler otherwise puts
  it on the little cores, capacity 213 vs 1024, in about 40 % of the samples) gives about
  +1 FPS, within run-to-run noise. The GPU, not the CPU, is the limit.

## Route B: Wayland subsurface under a transparent Flutter view - works

- The bridge creates its own `wl_surface` on a private event queue, makes it a desync
  `wl_subsurface` of the GTK toplevel surface, `place_below`, empty input region, buffer
  scale 2, and renders to it with a normal EGL window surface (swap interval 1).
- The runner gives the GTK window an RGBA visual, `app-paintable`, and
  `fl_view_set_background_color(#00000000)`; the Flutter page uses a transparent
  `Scaffold`. niri composites it correctly: the translucent card shows the map through it.
- Input: nothing to forward. All touch input stays on the GTK surface and reaches Flutter's
  gesture recognisers exactly as in route A.

Costs:

- Wayland only. The map is not part of Flutter's scene: no clipping, opacity, transforms
  or page transitions over it; anything meant to hide it must be opaque. The prototype
  places it at the window origin (position is not synchronised with the widget).
- Resize is not synchronised between the two surfaces (in the demo the shrunk map leaves
  the transparent window showing the compositor's backdrop, as expected).
- A hidden window blocks the map thread in `eglSwapBuffers` at 1 Hz (same as the spike).
- Still 2-3 FPS and 2-3 times the missed frames of standalone, **even with no Flutter
  frames at all** (`MLN_STATIC=1`: 53.5 FPS, 4.8 %). Assumption, not isolated: the
  compositor now blends a full-screen transparent surface over the map.

## Route C: the published `maplibre` plugin - not usable here

`maplibre` 0.4.0 / `maplibre_native` 0.4.0 on pub.dev (2026-11-18) has a Linux
implementation. Read from the package, not built or run: it also uses `FlTextureGL`, but
renders with **Vulkan** and imports the memory into Flutter's GL
(`GL_EXT_memory_object_fd`), falling back to CPU readback into a pixel-buffer texture; its
native library is downloaded prebuilt for `linux-gnu-{x64,arm64}` (glibc); it requires
Flutter >= 3.47. On this phone: Vulkan is out, glibc binaries do not run, Flutter is 3.38.4.
`maplibre_gl` 0.28.1 lists only Android, iOS and web.

## Numbers

Scripted camera of the spike, bright style, 1440x1372 px, pixel ratio 2, 57 s of continuous
motion per run (9 segments), window focused. "Shown" = a new map frame picked up by
Flutter's raster thread (route A) or swapped to the compositor (route B, standalone).
Segments during which the window lost focus are excluded; "valid" says how much is left.

| Run | Valid | Map FPS | Median ms | p99 ms | 1 % low FPS | > 33 ms | > 50 ms | Process CPU % | Map thread % | GTK main % | Flutter raster % | niri % | GPU MHz (at max) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Standalone `ref-gl-1` | 57 s | 56.3 | 17.0 | 34.6 | 25.5 | 1.5 % | 1 | 174 | 51 | - | - | 50 | 755 (16 %) |
| Spike `gl-vsync-2` (for reference) | 57 s | 56.4 | 16.9 | 34.0 | 25.3 | 1.7 % | 3 | 173 | 52 | - | - | 48 | 775 (24 %) |
| A `a1` | 57 s | 49.4 | 16.8 | 49.8 | 18.9 | 7.0 % | 16 | 266 | 56 | 56 | 21 | 41 | 1026 (88 %) |
| A `a2` | 57 s | 49.4 | 17.1 | 49.6 | 16.9 | 7.5 % | 20 | 274 | 56 | 57 | 21 | 41 | 1031 (91 %) |
| A `v3-a1` | 57 s | 48.8 | 17.1 | 49.9 | 17.6 | 8.7 % | 26 | 274 | 55 | 59 | 23 | 42 | 1021 (88 %) |
| A, big cores `a-big1` | 57 s | 50.3 | 16.8 | 49.6 | 18.7 | 5.9 % | 16 | 243 | 51 | 59 | 23 | 49 | 1025 (88 %) |
| A, big cores `v3-a-big1` | 57 s | 49.8 | 17.0 | 49.9 | 18.0 | 7.5 % | 25 | 251 | 53 | 61 | 23 | 46 | 1021 (88 %) |
| A, serial pacing `smoke1` | 57 s | 32.4 | 33.2 | 66.9 | 12.2 | 34.4 % | 148 | 237 | 48 | 44 | 14 | 32 | 750 (17 %) |
| B `b1` | 57 s | 54.4 | 17.0 | 38.3 | 20.3 | 3.3 % | 8 | 186 | 51 | 4 | 1 | 48 | 860 (42 %) |
| B `b2` | 57 s | 53.2 | 17.1 | 39.4 | 20.6 | 4.8 % | 7 | 183 | 50 | 4 | 1 | 50 | 849 (35 %) |
| B `v3-b1` | 45 s | 52.6 | 17.2 | 39.6 | 19.4 | 5.6 % | 15 | 176 | 50 | 4 | 1 | 51 | 821 (27 %) |
| B, no Flutter frames `v4-b-static` | 57 s | 53.5 | 17.0 | 38.7 | 20.3 | 4.8 % | 9 | 178 | 50 | 1 | 0 | 48 | 866 (41 %) |
| A + Flutter animation `a-tick1` | 57 s | 44.6 | 17.3 | 67.5 | 12.7 | 13.1 % | 76 | 331 | 57 | 69 | 39 | 38 | 1043 (98 %) |
| A + Flutter animation `v4-a-tick` | 57 s | 43.9 | 17.8 | 62.6 | 13.6 | 15.7 % | 82 | 333 | 56 | 71 | 39 | 37 | 1044 (97 %) |
| B + Flutter animation `v4-b-tick` | 47 s | 45.3 | 17.5 | 53.3 | 15.7 | 15.1 % | 34 | 267 | 51 | 45 | 35 | 40 | 1043 (98 %) |

Run names: `a*`/`b*` used a build in which the render-ahead of route A was triggered by a
16 ms timer; `v3-*`/`v4-*` trigger it directly. The numbers do not differ beyond noise.
RSS: 307-315 MB mean (standalone spike: 185-246 MB).

MapLibre side versus Flutter side (route A, `v3-a1`): the streams agree, so no frames are
lost between the map and the screen.

| Stream | Frames | Avg FPS | Median ms | p99 ms | > 33 ms | > 50 ms |
|---|---|---|---|---|---|---|
| Map frames finished by MapLibre (its frame observer + GPU fence) | 2778 | 48.7 | 18.4 | 48.2 | 6.7 % | 21 |
| Map frames picked up by Flutter's raster thread | 2768 | 48.8 | 16.9 | 49.8 | 7.5 % | 21 |
| GTK paints of the window (`GdkFrameClock::after-paint`) | 2772 | 48.9 | 17.7 | 47.2 | 7.0 % | 16 |

Per frame (route A, `v3-a1`): MapLibre `render()` 16.4 ms median wall, of which 6.4 ms is
waiting for the GPU (p99 46.9 / 18.2 ms). In the standalone spike a whole frame took 7.2 ms
with vsync off.

Flutter `FrameTiming` (`SchedulerBinding.addTimingsCallback`). Without an animation Flutter
reports only the 2 frames per second in which the info card is rebuilt; with the animation
(`MLN_TICKER=1`) every frame is reported:

| Run | Flutter frames | Flutter FPS | Build ms median / p99 | Raster ms median / p99 | Raster > 16.7 ms |
|---|---|---|---|---|---|
| A `v3-a1` (card updates only) | 115 | - | 7.7 / 16.1 | 5.8 / 11.4 | 0 |
| A + animation `v4-a-tick` | 3410 | 59.7 | 2.3 / 12.0 | 9.4 / 20.4 | 143 (4.2 %) |
| B + animation `v4-b-tick` | 1866 | 60.0 | 2.0 / 7.9 | 5.9 / 13.9 | 7 (0.4 %) |

So Flutter's own UI stays at 60 FPS in both routes; it is the map that loses frames when the
two compete for the GPU.

Per segment, route A (`v3-a1`): flat pans at z12 54 FPS (2 % > 33 ms), pans at z14 49-50
FPS, zoom sweeps 43-51 FPS, pitched and rotating 39.7 FPS (20 % > 33 ms). Load times are
unchanged from the spike (jumps 0.8-1.0 s, Kremlin z16 3.0-3.3 s).

### Validity of the runs

- About 30 runs were started; the table lists the ones that count.
- Another process compiled software on the phone during part of the session (root
  `cc1plus` for `/opt/field-signal/src/titan2-de`, load average 6-10). Runs that overlapped
  it were discarded: one standalone reference (51.9 FPS), one route A run (31.5 FPS), one
  route A + animation run. From then on the sampler records whole-system CPU and the batch
  runner waits for compilers to finish.
- The `a*`/`b*` rows (00:49-01:01) were taken before that sampling existed. No compiler was
  seen then, and the standalone-like figures of `b1`/`b2` argue against a disturbance, but
  it is not proven. The `v3-*`/`v4-*` rows are checked.
- Several runs lost 1-3 segments because no window had focus for a few seconds (a shell
  overlay); those segments are excluded, see "Valid".
- The Mapsoly app was running in the background throughout; it was not touched.

## Screenshots (PC paths, taken with `grim`, all looked at)

Under `data/maplibre-build/flutter/results/`:

- `smoke1/shot_start.png`, `smoke1/shot_nav.png` - route A: centre z14 and the pitched
  segment. Geometry, scale and colours identical to the spike's
  `data/maplibre-build/results/gl-vsync-1/shot_start.png`; Cyrillic labels, icons; card
  (60 % white) and buttons on top; not flipped or mirrored.
- `sub1/shot_start.png`, `sub1/shot_nav.png` - route B, same content, card translucent over
  the subsurface.
- `demo-a/step1..7.png`, `demo-b/step1..7.png` - API demo: after `moveBy`, `zoomBy(+1)`
  (card shows z15), `setCamera(bearing 30, pitch 45)`, `rotateBy(60)` (bearing 90),
  `setCamera(55.76, 37.64, z13)`, widget shrunk by 200 px (`step6`), restored (`step7`).

## Problems hit

1. Serial pacing halves the frame rate (above).
2. `glEGLImageTargetTexture2DOES` is not exported by Mesa's `libGLESv2.so`.
3. No `FrameTiming` for texture-only frames; an always-running Flutter animation is needed
   to get Flutter-side timings, which changes the load. Both cases were measured.
4. big.LITTLE placement of a render thread that sleeps half the time (little cores).
5. The spike's `analyze.py` ran on import; its main part is now under `__main__`.
6. `Theme parsing error: gtk.css:35:1` from GTK at start (the phone's theme); harmless.

Not done / not tested: human judgement of touch latency; long sessions, thermals, battery;
dark style; hot restart; several maps; X11; destroying the map while Flutter is rasterising
(the prototype's teardown is not race-free and leaks the consumer-side textures); device
pixel ratio changes (fixed at creation).

`spike/maplibre/build.sh` was run end to end in a scratch directory on the PC (sysroot from
docker, clone, patch, both backends): it works as written. Only change: the output
directory can be overridden with `MLN_BUILD_OUT`.

## What a production plugin still needs

Estimates, not measurements; one developer, route A as the base.

| Item | Work | Estimate |
|---|---|---|
| Gestures: pan with fling, pinch, rotate, two-finger tilt, double-tap, limits | Flutter recognisers calling the C API; MapLibre has the animations | 3-4 days |
| Camera API and events: camera-changed / idle callbacks, screen <-> lat/lon, fit bounds, padding | C API + event channel | 2-3 days |
| Annotations: route polyline (GeoJSON source + line layers), markers (symbol layer + images from Flutter), accuracy circle | generic add/remove source, layer (JSON), image, `setGeoJSON` | 4-6 days |
| Raster overlay for traffic tiles | raster source; decide who fetches (MapLibre's HTTP source or the app through a custom scheme), caching | 2-4 days |
| Style switching (bright/dark) with re-adding runtime layers; styles rewritten for device paths at run time | | 2 days |
| Lifecycle: race-free create/destroy, texture clean-up, pause when hidden, resize and DPR change, hot restart, several instances, errors to Dart | | 4-5 days |
| Packaging: reproducible build of the library for aarch64-musl (and x86_64 for development), trimmed glyphs, a real plugin package | | 3-4 days |
| Android through `maplibre_gl` (or `maplibre`) behind a common Dart interface | adapter + testing on a device | 4-6 days |
| Porting the Mapsoly map screen (overlays, follow mode, navigation camera) | depends on the screen; not sized here | open |

Total without the last row: about 5-7 weeks; a minimal version (camera, gestures, style
switch, one line, one marker, Linux only) about 2-3 weeks. Route B adds roughly 3-5 days
(position and resize synchronisation, explicit frame callbacks instead of a blocking swap,
fallback to route A elsewhere). An alternative worth a look before starting: contributing
a GLES/EGLImage path and musl builds to the upstream `maplibre` plugin instead of owning a
plugin; not evaluated.

What would move the numbers more than anything in the plugin: the embedder's presentation
path (blit + GDK upload + two quads per frame) and its 60 Hz timer. That is outside a
plugin and applies to the current Flutter map as well.

## Build and run

On the PC:

```sh
spike/maplibre/build.sh                      # once: sysroot + MapLibre static libs (data/maplibre-build/build-gl)
spike/maplibre_flutter/native/build.sh       # libmapsoly_mln.so -> data/maplibre-build/flutter/ and linux/prebuilt/
spike/maplibre_flutter/deploy_phone.sh       # copy sources + library, `flutter build linux --release` on the phone
                                             # (SKIP_BUILD=1: copy scripts only)
```

On the phone (root shell; everything runs as `serlk` inside the niri session):

```sh
cd /home/serlk/mapsoly-maplibre-flutter
su serlk -c 'sh run_bench.sh a1'                                  # route A, scripted run
su serlk -c 'MLN_SUBSURFACE=1 sh run_bench.sh b1'                 # route B
su serlk -c 'MLN_TICKER=1 sh run_bench.sh a-tick1'                # with a Flutter animation on top
su serlk -c 'sh run_standalone.sh ref-gl-1'                       # the spike's GLFW benchmark as reference
su serlk -c 'sh run_demo.sh demo-a'                               # API demo with screenshots
su serlk -c 'sh batch.sh "a1 run_bench.sh" "b1 run_bench.sh MLN_SUBSURFACE=1"'   # several, waits for foreign builds
# by hand, for touch testing (window title "MlnFlutterSpike"):
su serlk -c 'env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  /home/serlk/mapsoly-maplibre-flutter/app/build/linux/arm64/release/bundle/mln_flutter_spike'
```

Switches (environment): `MLN_SUBSURFACE=1` route B; `MLN_BENCH=1`, `MLN_BENCH_OUT=prefix`
scripted run then exit; `MLN_TICKER=1` Flutter animation on top; `MLN_STATIC=1` no card
updates during the run; `MLN_DEMO=1` API demo; `MLN_STYLE=/path/style.json`; `MLNB_BIG=1`
map thread on big cores; `MLNB_SERIAL=1` first pacing scheme; `MLNB_NOVSYNC=1` route B
without vsync.

Back on the PC:

```sh
spike/maplibre_flutter/fetch_run.sh a1 b1 ref-gl-1          # -> data/maplibre-build/flutter/results/
spike/maplibre_flutter/analyze.py data/maplibre-build/flutter/results/a1            # full report
spike/maplibre_flutter/analyze.py --table data/maplibre-build/flutter/results/*     # one row per run
```

The app reads the spike's assets in place
(`/home/serlk/mapsoly-maplibre/assets/styles/bright.json`, glyphs, sprites) and the pack at
`/home/serlk/.local/share/dev.mapsoly.mapsoly/packs/moscow/map.pmtiles`.

## System changes on the phone

- **No packages installed, removed or upgraded.** Everything needed was already there.
- Files under `/home/serlk/mapsoly-maplibre-flutter/` (owned by `serlk`, about 245 MB,
  mostly run outputs): `app/` (sources, `build/`, `.dart_tool/`), `out/`, the run scripts.
- `flutter build` as `serlk` may have added entries to that user's pub cache and Flutter
  tool state in its home directory (not inspected).
- `perf record` was run once as root; its data file in `/tmp` was removed. A
  `/tmp/perf-vdso.so-*` file may be from that run; the many other `perf-*.map` files in
  `/tmp` are not from this work and were left alone.
- Nothing was written to `/home/serlk/mapsoly-maplibre/` (read only: binary, assets).
- No edits to `/etc`, no services, no sysfs writes, no reboots. All test windows are
  closed; the Mapsoly app was never killed or restarted by this work.

## Facts and assumptions

Verified (source read, logged, or measured here): how the embedder creates contexts and
presents frames; same `EGLDisplay` for plugin and Flutter; EGLImage sharing between the two
contexts on panthor; GDK's upload-and-blend path; all figures in the tables; both routes'
screenshots; the camera API through FFI; resize in both routes; the spike's `build.sh`.

Assumptions: that route B's remaining gap to standalone is the compositor blending a second
full-screen surface; that the early (`a*`, `b*`) runs were undisturbed; the added input
latency of route A (one frame, from the design); all estimates of remaining work; that the
upstream plugin cannot be made to work here without the changes named (read, not tried).
