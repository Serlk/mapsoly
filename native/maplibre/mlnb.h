// mlnb: C API around one MapLibre Native map drawn into its own Wayland subsurface,
// placed below a parent wl_surface (the GTK/Flutter window, which must be transparent
// where the map should show). Used from Dart through dart:ffi; see docs/map-engine.md.
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
#define MLNB_ABI_VERSION 3

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
// NaN leaves a component unchanged. duration_ms 0 = jump.
MLNB_API void mlnb_set_camera(mlnb_map*, double lat, double lon, double zoom, double bearing, double pitch,
                              int32_t duration_ms);

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

// Diagnostics. out3: frames rendered, last frame interval in us, frames slower than 33 ms.
MLNB_API void mlnb_get_stats(mlnb_map*, int64_t* out3);
// One CSV row per rendered frame (boot_ms,t_ms,seg,interval_ms,frame_ms,...) until destroy.
MLNB_API void mlnb_frame_log(mlnb_map*, const char* csv_path);
// Scripted camera run of the spike; writes <prefix>.frames.csv, then MLNB_EVENT_BENCH_DONE.
MLNB_API void mlnb_bench_start(mlnb_map*, const char* out_prefix);

#ifdef __cplusplus
}
#endif
