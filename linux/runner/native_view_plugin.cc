// Gives Dart what it needs to put a native surface below the Flutter view.
//
// The MapLibre engine (lib/map/engine/maplibre_engine.dart) draws the map in a
// wl_subsurface below this window's surface; libmapsoly_mln.so does that, driven from
// Dart through dart:ffi. The only things Dart cannot get by itself are the wl_display
// and the window's wl_surface, and somebody has to make GTK commit the parent surface
// after the subsurface was moved or restacked. Nothing here depends on MapLibre.
#include "native_view_plugin.h"

#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#endif

gboolean native_view_wanted(GtkWindow* window) {
#ifdef GDK_WINDOWING_WAYLAND
  if (g_strcmp0(g_getenv("MAPSOLY_MAP_ENGINE"), "flutter") == 0) {
    return FALSE;
  }
  return GDK_IS_WAYLAND_DISPLAY(gtk_widget_get_display(GTK_WIDGET(window)));
#else
  return FALSE;
#endif
}

void native_view_prepare_window(GtkWindow* window) {
  GdkVisual* visual = gdk_screen_get_rgba_visual(gtk_window_get_screen(window));
  if (visual != nullptr) {
    gtk_widget_set_visual(GTK_WIDGET(window), visual);
  }
  gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
}

static FlMethodResponse* handles(FlView* view) {
  g_autoptr(FlValue) result = fl_value_new_map();
  gboolean wayland = FALSE;
#ifdef GDK_WINDOWING_WAYLAND
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  GdkWindow* window = gtk_widget_get_window(toplevel);
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(view));
  if (window != nullptr && GDK_IS_WAYLAND_DISPLAY(display) &&
      native_view_wanted(GTK_WINDOW(toplevel))) {
    wayland = TRUE;
    // Where the Flutter view starts inside the window's surface (client-side
    // decorations and shadows, if any, come first).
    gint x = 0, y = 0;
    gtk_widget_translate_coordinates(GTK_WIDGET(view), toplevel, 0, 0, &x, &y);
    fl_value_set_string_take(
        result, "display",
        fl_value_new_int(reinterpret_cast<int64_t>(
            gdk_wayland_display_get_wl_display(display))));
    fl_value_set_string_take(
        result, "surface",
        fl_value_new_int(reinterpret_cast<int64_t>(
            gdk_wayland_window_get_wl_surface(window))));
    fl_value_set_string_take(result, "x", fl_value_new_int(x));
    fl_value_set_string_take(result, "y", fl_value_new_int(y));
  }
#endif
  fl_value_set_string_take(result, "wayland", fl_value_new_bool(wayland));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Keeps the screen on while the driver follows the map: an idle inhibitor on
// the window's surface (idle-inhibit-unstable-v1). The protocol is two tiny
// interfaces, described here by hand so that the build needs no scanner. GTK's own
// gtk_application_inhibit() was tried first and returned nothing on the phone.
#ifdef GDK_WINDOWING_WAYLAND
static const wl_interface* kNoTypes[] = {nullptr};
static const wl_message kInhibitorRequests[] = {{"destroy", "", kNoTypes}};
static const wl_interface kInhibitorInterface = {
    "zwp_idle_inhibitor_v1", 1, 1, kInhibitorRequests, 0, nullptr};
static const wl_interface* kCreateTypes[] = {&kInhibitorInterface,
                                                   &wl_surface_interface};
static const wl_message kManagerRequests[] = {
    {"destroy", "", kNoTypes}, {"create_inhibitor", "no", kCreateTypes}};
static const wl_interface kManagerInterface = {
    "zwp_idle_inhibit_manager_v1", 1, 2, kManagerRequests, 0, nullptr};

static wl_proxy* idle_manager = nullptr;
static wl_proxy* idle_inhibitor = nullptr;
static gboolean idle_manager_looked_up = FALSE;

static void registry_global(void* data, wl_registry* registry, uint32_t name,
                            const char* interface, uint32_t version) {
  if (g_strcmp0(interface, kManagerInterface.name) == 0 &&
      idle_manager == nullptr) {
    idle_manager = static_cast<wl_proxy*>(
        wl_registry_bind(registry, name, &kManagerInterface, 1));
  }
}

static void registry_global_remove(void*, wl_registry*, uint32_t) {}

static const wl_registry_listener kRegistryListener = {registry_global,
                                                       registry_global_remove};

// Finds the compositor's inhibit manager on a queue of its own, so that GTK's
// event handling is not disturbed.
static void find_idle_manager(wl_display* display) {
  if (idle_manager_looked_up) {
    return;
  }
  idle_manager_looked_up = TRUE;
  wl_event_queue* queue = wl_display_create_queue(display);
  wl_display* wrapper =
      static_cast<wl_display*>(wl_proxy_create_wrapper(display));
  wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(wrapper), queue);
  wl_registry* registry = wl_display_get_registry(wrapper);
  wl_proxy_wrapper_destroy(wrapper);
  wl_registry_add_listener(registry, &kRegistryListener, nullptr);
  wl_display_roundtrip_queue(display, queue);
  if (idle_manager != nullptr) {
    // The manager sends no events; move it off the queue about to go away.
    wl_proxy_set_queue(idle_manager, nullptr);
  }
  wl_registry_destroy(registry);
  wl_event_queue_destroy(queue);
}
#endif

static gboolean keep_awake(FlView* view, gboolean on) {
#ifdef GDK_WINDOWING_WAYLAND
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  GdkWindow* window = gtk_widget_get_window(toplevel);
  GdkDisplay* gdk_display = gtk_widget_get_display(GTK_WIDGET(view));
  if (window == nullptr || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
    return FALSE;
  }
  wl_display* display = gdk_wayland_display_get_wl_display(gdk_display);
  if (on && idle_inhibitor == nullptr) {
    find_idle_manager(display);
    wl_surface* surface = gdk_wayland_window_get_wl_surface(window);
    if (idle_manager != nullptr && surface != nullptr) {
      idle_inhibitor = wl_proxy_marshal_flags(
          idle_manager, 1 /* create_inhibitor */, &kInhibitorInterface,
          wl_proxy_get_version(idle_manager), 0, nullptr, surface);
    }
  } else if (!on && idle_inhibitor != nullptr) {
    wl_proxy_marshal_flags(idle_inhibitor, 0 /* destroy */, nullptr,
                           wl_proxy_get_version(idle_inhibitor),
                           WL_MARSHAL_FLAG_DESTROY);
    idle_inhibitor = nullptr;
  }
  wl_display_flush(display);
  return idle_inhibitor != nullptr;
#else
  return FALSE;
#endif
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* call,
                           gpointer user_data) {
  FlView* view = FL_VIEW(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "handles") == 0) {
    response = handles(view);
  } else if (g_strcmp0(method, "commit") == 0) {
    // Subsurface position and stacking take effect when the parent commits.
    gtk_widget_queue_draw(gtk_widget_get_toplevel(GTK_WIDGET(view)));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "keepAwake") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    gboolean held = keep_awake(
        view, args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                  fl_value_get_bool(args));
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(held)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

void native_view_plugin_register(FlView* view) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "NativeViewPlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // The channel lives as long as the engine; the view outlives every call.
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "mapsoly/native_view",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, view,
                                            nullptr);
  g_object_set_data_full(G_OBJECT(view), "mapsoly-native-view-channel", channel,
                         g_object_unref);
}
