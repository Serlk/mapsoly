// mlnb: a small C API around one MapLibre Native map that renders into GL textures
// which another GL context on the same EGLDisplay (Flutter's) can sample (EGLImage).
// Prototype quality. See docs/maplibre-flutter-prototype.md.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MLNB_API __attribute__((visibility("default")))

typedef struct mlnb_map mlnb_map;

// Called on the map thread each time a finished frame is ready to be picked up.
typedef void (*mlnb_frame_cb)(void* user);

// wl_display: the process's wl_display (GDK's); the EGLDisplay is derived from it and is
// therefore the same one Flutter's GTK embedder uses. Sizes are logical pixels.
//
// mode MLNB_MODE_TEXTURE: frames are handed over through mlnb_populate() (route A).
// mode MLNB_MODE_SUBSURFACE: the map draws to its own wl_subsurface placed below
// parent_wl_surface at (0,0); cb and mlnb_populate() are not used (route B).
#define MLNB_MODE_TEXTURE 0
#define MLNB_MODE_SUBSURFACE 1
MLNB_API mlnb_map* mlnb_create(void* wl_display, void* parent_wl_surface, int mode,
                               const char* style_url, const char* cache_path,
                               int width, int height, double pixel_ratio,
                               mlnb_frame_cb cb, void* user);
MLNB_API void mlnb_destroy(mlnb_map*);

// To be called with the consumer's GL context current (FlTextureGL::populate).
// Returns 1 and a GL_TEXTURE_2D name valid in the current context, 0 if no frame yet.
// The image is bottom-up (GL convention).
MLNB_API int mlnb_populate(mlnb_map*, uint32_t* target, uint32_t* name, uint32_t* width, uint32_t* height);

// Everything below is thread-safe and asynchronous (posted to the map thread).
MLNB_API void mlnb_resize(mlnb_map*, int width, int height);
// NaN leaves a component unchanged. duration_ms 0 = jump.
MLNB_API void mlnb_set_camera(mlnb_map*, double lat, double lon, double zoom, double bearing, double pitch,
                              int duration_ms);
MLNB_API void mlnb_move_by(mlnb_map*, double dx, double dy);
MLNB_API void mlnb_zoom_by(mlnb_map*, double delta, double focal_x, double focal_y, int duration_ms);
MLNB_API void mlnb_rotate_by(mlnb_map*, double degrees, double focal_x, double focal_y);
MLNB_API void mlnb_set_gesture(mlnb_map*, int in_progress);
// out: lat, lon, zoom, bearing, pitch (last values seen by the map thread).
MLNB_API void mlnb_get_camera(mlnb_map*, double* out5);

// Scripted camera run (same script as spike/maplibre/mapsoly_bench.hpp).
// Writes <out_prefix>.frames.csv (map frames), .consume.csv (frames picked up by the
// consumer) and .paint.csv (mlnb_note_paint timestamps) when the script ends.
MLNB_API void mlnb_bench_start(mlnb_map*, const char* out_prefix);
MLNB_API int mlnb_bench_state(mlnb_map*); // 0 idle, 1 running, 2 finished
MLNB_API void mlnb_note_paint(mlnb_map*);  // any thread; records a timestamp
// frames rendered, frames consumed
MLNB_API void mlnb_get_stats(mlnb_map*, int64_t* out2);

#ifdef __cplusplus
}
#endif
