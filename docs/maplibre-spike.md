# MapLibre Native feasibility spike (Titan 2, Alpine/musl, panthor)

Date: 2026-11-26/27. Scope: is MapLibre Native itself smooth on this GPU/driver with our
offline data? Nothing was integrated into the app.

## Verdict

**Go, with OpenGL ES.** MapLibre Native renders the Moscow pack fully offline (PMTiles read
directly, Cyrillic labels, sprites) at 1440x1372 px, pixel ratio 2, and holds
**56-57 FPS average on a 59.75 Hz panel during continuous scripted pan/zoom/rotate**,
cold and warm alike. It is not perfectly locked: about **2 % of frames miss one vblank
(33 ms)** and roughly 1 frame in 1000 exceeds 50 ms; worst frame seen in valid runs 68 ms.
Raw render cost with vsync off is 7 ms median (118 FPS average), so there is ~2x headroom
on the typical frame; the misses come from occasional 20-45 ms frames.

It is not cheap on CPU: ~1.75 cores for the process while the camera never stops
(render thread ~50 % of a core, four tile workers ~30 % each), and the GPU sits around
770 MHz, at max frequency in about a quarter of the samples.

Vulkan (PanVK) works and performs the same, but the driver refuses this GPU unless an
"I want a broken driver" environment variable is set, and the app segfaults on exit.
Not a shipping option today.

## What ran

| Item | Version |
|---|---|
| MapLibre Native | upstream `main` @ `0c62d868c0346c20bac89c306e8c6972b7dd10c1` (2026-11-26), GLFW example app `mbgl-glfw` + a small scripted-benchmark patch |
| Backends built | OpenGL ES 3.0 via EGL on Wayland; Vulkan |
| Build | cross-compiled on the PC (clang 23.1.4 + lld, cmake 4.4.5, ninja) against an Alpine 3.24 aarch64 sysroot; Release |
| Phone | Alpine 3.24.3, kernel `7.2.0 #1 SMP PREEMPT Thu Nov 26 17:15:38 UTC 2026`, niri 26.04-r1, Mesa 26.3.0-r105 (`Mali-G615 MC2 (Panfrost)`), glfw 3.4-r1 |
| Window | niri tile 720x686 logical, scale 2 -> framebuffer **1440x1372**, map pixel ratio **2.0**; output 1440x1440 @ 59.750 Hz, no VRR |
| Data | `packs/moscow/map.pmtiles` read via `pmtiles://file://...` (no MBTiles conversion needed: upstream has `MLN_WITH_PMTILES=ON` by default) |
| Styles | `assets/styles/bright.json` (129 layers) and `dark.json`, rewritten to local files |

Numbers are from the first kernel (built Nov 26 17:15 UTC) unless a row says "kernel B"
(same 7.2.0 version, rebuilt Nov 26 20:57 UTC, booted mid-spike; see "Kernel change").

### Scripted camera (`spike/maplibre/mapsoly_bench.hpp`)

Time-based, no input, ~70 s per run. The camera is set every frame, so the map never idles.

| Segment | What |
|---|---|
| `load_center_z14` | start at 55.752, 37.616 z14, wait for the first complete frame |
| `pan14_cold` / `pan14_warm` | 8 s pan over 0.20 deg lon at z14 (about 580 logical px/s), then the same path back |
| `zoomout_cold`, `zoomin_cold`, `zoomout_warm`, `zoomin_warm` | z14 -> z11 -> z16 -> z11 -> z14 at the centre |
| `pan12_cold` / `pan12_warm` | 7 s diagonal across the whole city at z12 and back |
| `nav_pitch_rot` | 7 s at z15.5, pitch 50 deg, bearing 0 -> 180 deg while moving |
| `jump_*` | three jumps to never-visited places; time to a complete frame |

"Warm" means tiles were loaded seconds earlier in the same process. MapLibre still
re-parses part of them on the worker threads (its in-memory tile cache is bounded), so
worker CPU does not drop to zero on warm passes.

## Numbers

Frame interval = time between completions of consecutive frames, measured in the app's
render loop around `render()` + buffer swap.

### Frame times (bright style)

| Run | Frames | Avg FPS | Median ms | p99 ms | 1 % low FPS | Worst ms | > 33 ms | > 50 ms |
|---|---|---|---|---|---|---|---|---|
| GLES, vsync, run 1 | 3221 | 56.4 | 16.9 | 35.1 | 24.9 | 56.4 | 65 (2.0 %) | 2 |
| GLES, vsync, run 2 | 3226 | 56.4 | 16.9 | 34.0 | 25.3 | 67.8 | 56 (1.7 %) | 3 |
| Vulkan, vsync (FIFO) | 3268 | 57.2 | 16.9 | 35.4 | 25.1 | 54.9 | 50 (1.5 %) | 2 |
| GLES, vsync off | 6764 | 118.5 | 7.2 | 28.0 | 28.5 | 73.9 | 27 (0.4 %) | 4 |
| GLES, vsync, kernel B, Mapsoly not running | 3237 | 56.6 | 16.9 | 35.2 | 25.3 | 66.6 | 59 (1.8 %) | 3 |
| Vulkan, vsync, kernel B, Mapsoly not running | 3313 | 58.0 | 16.9 | 34.0 | 25.8 | 56.5 | 40 (1.2 %) | 2 |

Per segment, GLES vsync run 2 (run 1 and Vulkan are within noise of it):

| Segment | Frames | Avg FPS | p99 ms | Worst ms | > 33 ms | > 50 ms | Draw calls/frame |
|---|---|---|---|---|---|---|---|
| pan14_cold | 446 | 55.9 | 34.8 | 40.6 | 10 | 0 | 249 |
| pan14_warm | 453 | 56.6 | 31.8 | 59.1 | 3 | 1 | 238 |
| zoomout_cold | 222 | 55.3 | 34.6 | 42.8 | 7 | 0 | 172 |
| zoomin_cold | 341 | 56.8 | 33.8 | 44.2 | 6 | 0 | 206 |
| zoomout_warm | 333 | 55.4 | 34.8 | 41.8 | 10 | 0 | 209 |
| zoomin_warm | 228 | 56.9 | 33.0 | 46.4 | 2 | 0 | 197 |
| pan12_cold | 403 | 57.6 | 31.7 | 51.8 | 3 | 1 | 222 |
| pan12_warm | 413 | 58.8 | 28.4 | 38.8 | 3 | 0 | 250 |
| nav_pitch_rot | 379 | 54.1 | 33.9 | 67.8 | 12 | 1 | 198 |

Observations:

- Cold and warm passes are nearly the same. Tile loading does not block the render loop;
  it shows as worker CPU, not as stutter.
- The slow frames are irregular (no fixed period), and they are present with vsync off
  too (252 of 6764 frames > 20 ms). The cause was not investigated; candidates are
  bucket/texture uploads and symbol placement on the render thread.
- The pitched/rotating segment is the heaviest: with vsync off it averages 62 FPS
  (14.7 ms median) against 100-160 FPS for flat pans.

### Load times

| Event | GLES (3 runs) | Vulkan |
|---|---|---|
| Process start -> first complete frame, centre z14 | 1.7-1.9 s | 1.8 s |
| Jump to unvisited area, z14 (Zelenograd) | 0.67-1.14 s | 0.76 s |
| Jump to unvisited area, z13 (Podolsk) | 0.43-0.74 s | 0.60 s |
| Jump to Kremlin z16 (overzoomed dense z14 tiles) | 2.8-3.8 s | 3.0 s |

"Complete" = MapLibre reports `RenderMode::Full` (all tiles and labels for the view).
The map is drawn progressively before that; time to first visible content was not measured.

### CPU, GPU, memory (during the moving segments, vsync on)

| Metric | GLES | Vulkan |
|---|---|---|
| Process total, % of one core, mean / max sample | 175 / 420 | 175 / 420 |
| Render (main) thread, mean / max | 52 / 85-91 | 49 / 79 |
| Each of 4 tile workers, mean / max | 28-30 / ~89 | 29-31 / ~89 |
| PMTiles file-source thread, mean | 6 | 6 |
| niri compositor (separate process), mean / max | 48-53 / 72 | 50 / 70 |
| GPU frequency, mean (range 265-1047 MHz) | 773 MHz | 767 MHz |
| Share of samples at max GPU frequency | 24 % | 21 % |
| RSS, mean / peak | 185-246 / 215-282 MB | 118-127 / 149-161 MB |

With vsync off the render thread is pinned (89 % mean) and the GPU is at max 87 % of
the time; that run is a cost measurement, not a usage mode.

Sampling: `/proc/PID/task/*/stat`, GPU `cur_freq` and `VmRSS` every ~0.5 s
(`spike/maplibre/phone/sampler.sh`), governor `simple_ondemand`, untouched.

### Comparison with the current Flutter map

Only the figures given in the task are available for Flutter (raster thread mean ~54 %,
peaks 100+ % of a core, visible stutter when tiles load); no Flutter frame-time trace was
taken in this spike, so there is no like-for-like FPS comparison.

What can be said from the measurements: MapLibre's render thread uses a similar mean
(~50 %) but never saturated in vsync runs (max sample 91 %), and new tiles cost worker
time instead of frame time: cold passes are as smooth as warm ones. Total CPU is not
lower than a single Flutter raster thread; it is spread over five threads.

## Rendering correctness

Screenshots (PC side, taken with `grim` on the phone):

- `data/maplibre-build/results/gl-vsync-1/shot_start.png`, `shot_end.png` - GLES, bright
- `data/maplibre-build/results/vk-vsync-1/shot_start.png`, `shot_end.png` - Vulkan, bright
- `data/maplibre-build/results/gl-vsync-dark/shot_start.png` - GLES, dark
- `data/maplibre-build/results/smoke-gl-start.png`, `smoke-gl-end.png` - first run

Checked by eye: roads, water, parks, buildings, Cyrillic street and place labels, curved
line labels, POI icons from the sprite sheet, and the dark style's composited font stacks.
GLES and Vulkan output look identical. No missing-glyph boxes, no black or empty frames.

## Problems hit

1. **PanVK refuses the GPU by default.** `vulkaninfo`: `panvk is not well-tested on v11,
   pass PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1 if you know what you're doing`
   (`VK_ERROR_INCOMPATIBLE_DRIVER`). With the variable set it runs and prints
   `panvk is not a conformant Vulkan implementation, testing use only`.
2. **Vulkan build segfaults on exit** (exit code 139, all three runs), after the benchmark
   finished and settings were saved. GLES exits 0. Not debugged.
3. **No uncapped Vulkan measurement.** `Requested PresentModeKHR not available`: the
   Wayland WSI offers no IMMEDIATE mode, so the "vsync off" Vulkan run was FIFO anyway.
4. **Hidden windows render at 1 Hz.** niri throttles frame callbacks of a non-visible
   surface, so the swap blocks for 1 s. Two runs were hit when the Mapsoly window took
   focus mid-run (`gl-vsync-dark` from 30 s on, `vk-novsync-1` for ~8 s);
   `analyze.py` marks those segments INVALID and excludes them. Relevant later: a map
   surface that waits on frame callbacks stalls whenever it is not visible.
5. **Mapsoly bursts during runs.** The running `mapsoly` process used 2-3.6 cores for
   about 2.5 s once per run on the first kernel. It is not the cause of the slow
   frames: the kernel-B runs, taken with Mapsoly not running, show the same miss rate.
6. `Couldn't set thread scheduling policy` warnings from every MapLibre thread
   (it tries to lower worker priority; not permitted for a normal user on this system).
   Harmless.
7. Local glyphs need composited font stacks (see asset recipe).
8. No GPU driver complaints: `dmesg` had no `panthor`/`drm` lines around the runs on the
   first kernel, and on kernel B only the normal probe messages (`Initialized panthor
   1.8.0`, CSF FW interface v2.8.0, plus the informational `Firmware protected mode
   entry is not supported, ignoring`). No Mesa errors in the logs.

Not tested: touch gestures, long sessions / thermal throttling, battery draw, memory
growth over time, the dark style over the full script (valid for the first 4 segments
only: 55.7-58.7 FPS), other regions.

## Offline asset recipe

`spike/maplibre/make_assets.py` does all of it (no accounts or keys):

```sh
spike/maplibre/make_assets.py \
  --root /home/serlk/mapsoly-maplibre/assets \
  --pmtiles /home/serlk/.local/share/dev.mapsoly.mapsoly/packs/moscow/map.pmtiles
```

| Asset | Source | Result under `data/maplibre-assets/` |
|---|---|---|
| Glyph PBFs | `https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip` (74 MB) | `fonts/<fontstack>/<range>.pbf` |
| Sprites | `https://openmaptiles.github.io/osm-bright-gl-style/sprite[@2x].{json,png}` and `.../dark-matter-gl-style/...` | `sprites/{bright,dark}/` |
| Styles | `assets/styles/{bright,dark}.json` | `styles/{bright,dark}.json` with `sources.openmaptiles.url = pmtiles://file://<abs path>`, `glyphs = file://<root>/fonts/{fontstack}/{range}.pbf`, `sprite = file://<root>/sprites/<style>/sprite` |

Details that matter:

- MapLibre Native requests a multi-font stack as **one** resource named by the
  comma-joined stack (`Metropolis Light,Noto Sans Regular/1024-1279.pbf`). The dark
  style uses four such stacks and Metropolis has no Cyrillic, so the script composites
  the PBFs (first font wins per glyph), as a font server would. Bright needs only
  `Noto Sans Regular`, `Noto Sans Bold`, `Noto Sans Italic`.
- All 256 ranges are kept: 235 MB for 7 stacks, mostly CJK. Latin + Cyrillic +
  punctuation (ranges 0-1535 and 8192-8703) is about 0.65 MB per stack; trimming is a
  one-line change, not done here.
- URLs are absolute, so styles must be generated (or patched at runtime) for the
  device's paths. The pack moved from `maps/moscow.pmtiles` to `packs/moscow/map.pmtiles`
  during the spike; the script default follows the new path.
- The style's `{key}` placeholders disappear with the rewritten URLs.

## Build and run recipe

```sh
spike/maplibre/build.sh          # sysroot (docker alpine:3.24) + clone + patch + both builds
                                 # -> data/maplibre-build/mbgl-glfw-{gl,vk}  (~10 MB stripped each)
spike/maplibre/make_assets.py    # -> data/maplibre-assets
```

Full build of one backend took about 6 minutes on the PC. Nothing was compiled on the phone.

On the phone (files under `/home/serlk/mapsoly-maplibre/`: `bin/`, `assets/`,
`run_bench.sh`, `sampler.sh`, `out/<label>/`):

```sh
su serlk -c 'sh /home/serlk/mapsoly-maplibre/run_bench.sh gl gl-vsync-1 1'   # backend label vsync [style]
spike/maplibre/analyze.py data/maplibre-build/results/gl-vsync-1            # on the PC, after copying out/<label>
```

Benchmark switches: `MLN_BENCH=1`, `MLN_BENCH_VSYNC=0|1`, `MLN_BENCH_OUT=file.csv`.
Runtime libraries are all stock Alpine 3.24 packages (glfw, libuv, libcurl, icu, libpng,
libjpeg-turbo, libwebp, zlib, mesa-egl/gles; sqlite is vendored).

### System changes on the phone

- `apk add --no-cache glfw` -> **glfw 3.4-r1** (v3.24/community; simulate showed one new
  package, no upgrades or removals). This is the only package installed.
- Files only under `/home/serlk/mapsoly-maplibre/` (about 260 MB, mostly fonts).
- The GLFW app writes its settings to `/tmp/mbgl-native.cfg`.
- No edits to `/etc`, no services, no sysfs changes.

### Path not taken: Alpine `maplibre-native-qt`

`maplibre-native-qt` 3.0.0-r3 is in v3.24/community and installs without upgrades, but it
is the Qt 5 build: it pulls in `qt5-qtbase`, `qt5-qtbase-x11`, `qt5-qtdeclarative`,
`qt5-qtwayland`, `qt5-qtlocation` (5 new packages, ~56 MB). It was not installed: the
upstream cross-build worked first and gives both backends plus PMTiles. Whether 3.0.0
reads `pmtiles://` was not checked.

## Integration into Flutter's Linux (GTK) embedder

None of these was prototyped; this is analysis, ordered by preference.

1. **MapLibre renders into an FBO, shared with Flutter as a GL texture (`FlTextureGL`).**
   MapLibre gets its own EGL context on the same `EGLDisplay` as Flutter and its own
   render thread; the FBO colour attachment is exported as an `EGLImage` and bound to a
   texture in Flutter's context inside `populate()`. Flutter widgets (route banner,
   buttons) compose on top for free, and the map keeps its own frame pacing.
   Risks: the embedder does not hand out its EGL context/display through a public API,
   so the plugin has to obtain it from GDK or from the current context in `populate()`;
   MapLibre's GL backend assumes it owns GL state (`updateAssumedState`), so sharing
   Flutter's context directly instead of using a second one is fragile; one extra
   full-screen composite per frame in Flutter's raster thread at 1440x1372; frame
   delivery has to be driven by `fl_texture_registrar_mark_texture_frame_available`,
   so pacing depends on Flutter's vsync, and Flutter-side jank still delays map frames.
2. **dmabuf / pixel-buffer texture.** A CPU pixel buffer (`FlPixelBufferTexture`) means
   a ~7.9 MB readback and upload per frame at this resolution; not viable for 60 FPS.
   A dmabuf-backed variant is the same mechanism as option 1 with more plumbing; only
   worth it if the two renderers must live in different processes.
3. **Separate Wayland subsurface under a transparent Flutter view.** Best possible map
   performance (direct scan-out path through the compositor, exactly what was measured
   here) and complete isolation of GL state. Risks: needs the Flutter view to be
   transparent and GTK to cooperate with a foreign subsurface below its own surface;
   Wayland-only; input stays with Flutter and must be forwarded; resize and
   synchronisation between the two surfaces can tear; item 4 above (1 Hz throttle
   semantics) applies to the map surface separately.

Common work regardless of route: a C API around `mln::Map` (camera, style, sources and
layers for route line / position marker / traffic overlays, gestures, feature queries),
Dart FFI or method-channel bindings, lifecycle and resize handling, and porting the
existing overlays from `flutter_map` layers to MapLibre layers or to Flutter widgets
positioned from camera callbacks. Rough size, assumption not measured: 2-3 weeks for
route 1 with a minimal API (camera, style switch, one GeoJSON line, one marker,
gestures), more for parity with today's map screen.

Open questions to settle first in a 1-2 day prototype: can a second EGL context on
Flutter's display be created from a plugin on this embedder version (3.38.4), and what
does the extra composite cost on this GPU.

## Android later

The same engine is what `maplibre_gl` wraps on Android (and iOS), so styles, the
PMTiles pack, the glyph/sprite assets and the style-rewrite step carry over unchanged.
The Linux plugin would be our own code, though: `maplibre_gl` has no Linux desktop
implementation (assumption from its platform list, not re-verified in this spike), so
either we mirror its Dart API on Linux or keep a thin common interface over both.
Android was not tested here.

## Kernel change

The phone was rebooted mid-spike from `7.2.0 #1 SMP PREEMPT Thu Nov 26 17:15:38 UTC 2026`
to `7.2.0 #1 SMP PREEMPT Thu Nov 26 20:57:06 UTC 2026` (kernel B, touchscreen fix).
After the reboot one GLES and one Vulkan vsync run were repeated
(`results/k2-gl-vsync`, `results/k2-vk-vsync`): the GPU stack works, rendering is
unchanged and the numbers match the earlier ones (rows marked "kernel B" above).
Everything else in this document (vsync-off run, dark style, per-segment table, CPU
table) was measured on the first kernel only. Mapsoly was not running after the reboot
and was not started by this spike.

Vulkan shows slightly fewer missed frames than GLES in all three paired runs
(40-51 vs 56-65 frames > 33 ms); the difference is small and was not tested for
significance.
