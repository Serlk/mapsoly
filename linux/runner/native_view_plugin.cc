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
// the window, which on Wayland GTK turns into zwp_idle_inhibitor_v1.
static guint keep_awake_cookie = 0;

static void keep_awake(FlView* view, gboolean on) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (!GTK_IS_WINDOW(toplevel)) {
    return;
  }
  GtkApplication* app = gtk_window_get_application(GTK_WINDOW(toplevel));
  if (app == nullptr) {
    return;
  }
  if (on && keep_awake_cookie == 0) {
    keep_awake_cookie = gtk_application_inhibit(
        app, GTK_WINDOW(toplevel), GTK_APPLICATION_INHIBIT_IDLE, "Navigation");
  } else if (!on && keep_awake_cookie != 0) {
    gtk_application_uninhibit(app, keep_awake_cookie);
    keep_awake_cookie = 0;
  }
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
    keep_awake(view, args != nullptr &&
                         fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
                         fl_value_get_bool(args));
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(keep_awake_cookie != 0)));
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
