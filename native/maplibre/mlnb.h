// mlnb: C API around one MapLibre Native map drawn into its own Wayland subsurface,
// placed below a parent wl_surface (the GTK/Flutter window, which must be transparent
// where the map should show). Used from Dart through dart:ffi; see docs/map-engine.md.
//
// On Android the map is drawn into an ANativeWindow instead (the producer side of a
// Flutter texture): the mlnb_android_* functions at the end replace mlnb_create and
// mlnb_set_geometry there; everything else is the same on both platforms.
//
// Threading: every function may be called from any thread. Calls are posted to the map's
// own thread and return immediately, except mlnb_create (waits until the map thread is
// up) and mlnb_destroy (waits until it is gone; no callback is delivered afterwards).
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MLNB_API __attribute__((visibility("default")))
#define MLNB_ABI_VERSION 7

typedef struct mlnb_map mlnb_map;

// Events, delivered on the map thread.
#define MLNB_EVENT_STYLE_LOADED 1 // arg: generation passed to mlnb_set_style_json
#define MLNB_EVENT_STYLE_FAILED 2 // arg: generation
#define MLNB_EVENT_BENCH_DONE 3
#define MLNB_EVENT_MAP_FAILED 4 // the map stopped working; destroy it and fall back
typedef void (*mlnb_event_cb)(int32_t event, int64_t arg);

MLNB_API int32_t mlnb_abi_version(void);

// x, y, width, height: logical pixels relative to the parent surface. scale: integer
// buffer scale (device pixel ratio); fixed for the lifetime of the map.
// Returns NULL on failure (reason on stderr).
MLNB_API mlnb_map* mlnb_create(void* wl_display, void* parent_wl_surface, int32_t x, int32_t y, int32_t width,
                               int32_t height, int32_t scale, const char* cache_path, mlnb_event_cb cb);
MLNB_API void mlnb_destroy(mlnb_map*);

MLNB_API void mlnb_set_geometry(mlnb_map*, int32_t x, int32_t y, int32_t width, int32_t height);
// Hidden: the subsurface is unmapped and nothing is rendered; state is kept.
MLNB_API void mlnb_set_visible(mlnb_map*, int32_t visible);

// Replaces the whole style. Runtime sources, layers and images are gone afterwards;
// MLNB_EVENT_STYLE_LOADED(generation) says when they can be added again.
MLNB_API void mlnb_set_style_json(mlnb_map*, const char* json, int64_t generation);
// NaN leaves a component unchanged. padding_ltrb: NULL (unchanged) or left, top, right,
// bottom insets in logical pixels; the camera target is shown at the centre of what
// remains. duration_ms 0 = jump; linear != 0 = constant speed instead of ease-out.
MLNB_API void mlnb_set_camera(mlnb_map*, double lat, double lon, double zoom, double bearing, double pitch,
                              const double* padding_ltrb, int32_t duration_ms, int32_t linear);

// Runtime style. JSON as in the style specification. Errors are logged, not returned.
MLNB_API void mlnb_add_source(mlnb_map*, const char* id, const char* json);
MLNB_API void mlnb_remove_source(mlnb_map*, const char* id);
// before_id NULL or "": on top.
MLNB_API void mlnb_add_layer(mlnb_map*, const char* json, const char* before_id);
MLNB_API void mlnb_remove_layer(mlnb_map*, const char* id);
// Sets the data of a GeoJSON source that exists in the style.
MLNB_API void mlnb_set_geojson(mlnb_map*, const char* source_id, const char* geojson);
// Straight (not premultiplied) RGBA, width*height*4 bytes; copied before returning.
MLNB_API void mlnb_add_image(mlnb_map*, const char* id, const uint8_t* rgba, int32_t width, int32_t height,
                             double pixel_ratio);

// The position marker: the point feature of the GeoJSON source "mapsoly-puck" (properties
// kind = "position" or "position-heading", heading) and its accuracy circle, a polygon in
// the source "mapsoly-accuracy". Moves them to lat/lon, turned to bearing (degrees; NaN =
// no direction), with a circle of accuracy_m metres, in duration_ms at a constant speed,
// starting from where they are shown now (0 = at once). lat NaN removes the marker.
// Kept across style changes: once the new style has the sources the marker is back.
MLNB_API void mlnb_set_puck(mlnb_map*, double lat, double lon, double bearing, double accuracy_m,
                            int32_t duration_ms);

// At most this many frames a second while the map animates; 0 = every frame the display
// takes. Each frame costs processor time in the GPU driver whatever it shows, so a camera
// that follows a car for hours is better off at 30 than at 60.
MLNB_API void mlnb_set_max_fps(mlnb_map*, int32_t fps);

// Rectangles of the map presented blurred (frosted glass under translucent UI): count
// times x, y, width, height in logical pixels from the map's top-left corner; sigma in
// logical pixels. Copied before returning. count 0 turns it off.
MLNB_API void mlnb_set_blur(mlnb_map*, const float* xywh, int32_t count, float sigma);

// Diagnostics. out3: frames rendered, last frame interval in us, frames slower than 33 ms.
MLNB_API void mlnb_get_stats(mlnb_map*, int64_t* out3);
// One CSV row per rendered frame (boot_ms,t_ms,seg,interval_ms,frame_ms,...) until destroy.
MLNB_API void mlnb_frame_log(mlnb_map*, const char* csv_path);
// Debug: writes the next rendered frame, as handed to the compositor (blur included), to a
// binary PPM file.
MLNB_API void mlnb_snapshot(mlnb_map*, const char* ppm_path);
// Scripted camera run of the spike; writes <prefix>.frames.csv, then MLNB_EVENT_BENCH_DONE.
MLNB_API void mlnb_bench_start(mlnb_map*, const char* out_prefix);

#ifdef __ANDROID__
// ---- Android only (not part of the library on Linux) --------------------------------
// Windows are ANativeWindow pointers. Only pointers announced with
// mlnb_android_register_window and not yet taken back are ever used; any other value is
// treated as "no window", so a stale pointer is harmless. The library takes references
// of its own; the caller keeps and releases its own.
MLNB_API void mlnb_android_register_window(void* native_window);
// The window is about to go away: maps drawing into it are taken off it. Returns when
// none of them touches it any more.
MLNB_API void mlnb_android_unregister_window(void* native_window);

// width_px, height_px: size of the window's buffers in device pixels. pixel_ratio:
// device pixels per logical pixel (any positive number), fixed for the lifetime of the
// map; camera padding and the map's own size are in logical pixels as elsewhere.
// native_window may be NULL: the map exists but draws nothing until it gets one.
MLNB_API mlnb_map* mlnb_android_create(void* native_window, int32_t width_px, int32_t height_px, double pixel_ratio,
                                       const char* cache_path, mlnb_event_cb cb);
// Another window (after a resize, or when the app is back on screen), or NULL.
MLNB_API void mlnb_android_set_surface(mlnb_map*, void* native_window, int32_t width_px, int32_t height_px);
#endif

#ifdef __cplusplus
}
#endif
