#ifndef RUNNER_NATIVE_VIEW_PLUGIN_H_
#define RUNNER_NATIVE_VIEW_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

// TRUE when the map may be drawn by MapLibre in a Wayland subsurface below the
// window: Wayland session and not disabled with MAPSOLY_MAP_ENGINE=flutter. The
// window and the Flutter view must then be created transparent.
gboolean native_view_wanted(GtkWindow* window);

// Makes the window able to show a surface placed below it (RGBA visual, no opaque
// background). Call before the window is realized.
void native_view_prepare_window(GtkWindow* window);

// Registers the "mapsoly/native_view" method channel, which hands the Wayland
// handles of the window to Dart (lib/map/engine/maplibre/).
void native_view_plugin_register(FlView* view);

G_END_DECLS

#endif  // RUNNER_NATIVE_VIEW_PLUGIN_H_
