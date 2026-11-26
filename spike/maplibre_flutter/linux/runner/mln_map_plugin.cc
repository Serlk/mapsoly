// Flutter Linux (GTK) side of the MapLibre prototype.
//
// The map itself lives in libmapsoly_mln.so (native/mlnb.cpp): its own thread, its own
// EGL context on the EGLDisplay the Flutter embedder also uses. This file only
//  * registers an FlTextureGL whose populate() asks the bridge for the texture of the
//    newest finished map frame (an EGLImage sibling created in Flutter's context),
//  * tells Flutter when a new frame is ready (called from the map thread),
//  * serves a small method channel (create / dispose / benchStart / getState).
// Camera calls go from Dart straight to the bridge through dart:ffi.
#include "mln_map_plugin.h"

#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

#include "prebuilt/mlnb.h"

// ---------------------------------------------------------------- texture

G_DECLARE_FINAL_TYPE(MlnTexture, mln_texture, MLN, TEXTURE, FlTextureGL)

struct _MlnTexture {
  FlTextureGL parent_instance;
  mlnb_map* map;
};

G_DEFINE_TYPE(MlnTexture, mln_texture, fl_texture_gl_get_type())

// Raster thread, Flutter's GL context current.
static gboolean mln_texture_populate(FlTextureGL* texture,
                                     uint32_t* target,
                                     uint32_t* name,
                                     uint32_t* width,
                                     uint32_t* height,
                                     GError** error) {
  MlnTexture* self = MLN_TEXTURE(texture);
  if (self->map == nullptr ||
      !mlnb_populate(self->map, target, name, width, height)) {
    g_set_error(error, g_quark_from_static_string("mln"), 1, "no map frame yet");
    return FALSE;
  }
  return TRUE;
}

static void mln_texture_class_init(MlnTextureClass* klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = mln_texture_populate;
}

static void mln_texture_init(MlnTexture* self) {}

// ---------------------------------------------------------------- plugin

G_DECLARE_FINAL_TYPE(MlnMapPlugin, mln_map_plugin, MLN, MAP_PLUGIN, GObject)

struct _MlnMapPlugin {
  GObject parent_instance;
  FlView* view;  // not owned
  FlTextureRegistrar* registrar;
  FlMethodChannel* channel;
  MlnTexture* texture;
  mlnb_map* map;
  gulong paint_handler;
};

G_DEFINE_TYPE(MlnMapPlugin, mln_map_plugin, G_TYPE_OBJECT)

// Map thread: a finished frame is waiting. Thread-safe in the 3.38 embedder
// (weak-ref lookup + FlutterEngineMarkExternalTextureFrameAvailable).
static void frame_ready_cb(void* user) {
  MlnMapPlugin* self = static_cast<MlnMapPlugin*>(user);
  fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                    FL_TEXTURE(self->texture));
}

// GTK main thread: the toplevel was painted (= one wl_surface commit).
static void after_paint_cb(GdkFrameClock* clock, gpointer user) {
  MlnMapPlugin* self = static_cast<MlnMapPlugin*>(user);
  mlnb_note_paint(self->map);
}

static void destroy_map(MlnMapPlugin* self) {
  if (self->paint_handler != 0) {
    GdkFrameClock* clock = gtk_widget_get_frame_clock(GTK_WIDGET(self->view));
    if (clock != nullptr) {
      g_signal_handler_disconnect(clock, self->paint_handler);
    }
    self->paint_handler = 0;
  }
  if (self->texture != nullptr) {
    fl_texture_registrar_unregister_texture(self->registrar,
                                            FL_TEXTURE(self->texture));
  }
  if (self->map != nullptr) {
    mlnb_map* map = self->map;
    self->map = nullptr;
    if (self->texture != nullptr) {
      self->texture->map = nullptr;
    }
    mlnb_destroy(map);
  }
  g_clear_object(&self->texture);
}

static FlMethodResponse* handle_create(MlnMapPlugin* self, FlValue* args) {
  if (self->map != nullptr) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("exists", "map already created", nullptr));
  }
  const gchar* style =
      fl_value_get_string(fl_value_lookup_string(args, "style"));
  int width = fl_value_get_int(fl_value_lookup_string(args, "width"));
  int height = fl_value_get_int(fl_value_lookup_string(args, "height"));
  double ratio = fl_value_get_float(fl_value_lookup_string(args, "ratio"));
  gboolean subsurface =
      fl_value_get_bool(fl_value_lookup_string(args, "subsurface"));

  void* wl_display = nullptr;
  void* parent_surface = nullptr;
#ifdef GDK_WINDOWING_WAYLAND
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(self->view));
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    wl_display = gdk_wayland_display_get_wl_display(display);
    GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(self->view));
    parent_surface =
        gdk_wayland_window_get_wl_surface(gtk_widget_get_window(toplevel));
  }
#endif
  if (wl_display == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unsupported", "only the Wayland GDK backend is supported", nullptr));
  }

  if (subsurface) {
    // Route B: the map draws to its own wl_subsurface below the GTK surface;
    // nothing is registered with Flutter. The Flutter view must be transparent
    // (see my_application.cc, MLN_SUBSURFACE).
    self->map = mlnb_create(wl_display, parent_surface, MLNB_MODE_SUBSURFACE,
                            style, nullptr, width, height, ratio, nullptr,
                            nullptr);
    if (self->map == nullptr) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "failed", "mlnb_create failed (see stderr)", nullptr));
    }
    // The subsurface's stacking and position apply on the parent's next commit.
    gtk_widget_queue_draw(gtk_widget_get_toplevel(GTK_WIDGET(self->view)));
  } else {
    self->texture = MLN_TEXTURE(g_object_new(mln_texture_get_type(), nullptr));
    self->map = mlnb_create(wl_display, nullptr, MLNB_MODE_TEXTURE, style,
                            nullptr, width, height, ratio, frame_ready_cb, self);
    if (self->map == nullptr) {
      g_clear_object(&self->texture);
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "failed", "mlnb_create failed (see stderr)", nullptr));
    }
    self->texture->map = self->map;
    fl_texture_registrar_register_texture(self->registrar,
                                          FL_TEXTURE(self->texture));
  }

  GdkFrameClock* clock = gtk_widget_get_frame_clock(GTK_WIDGET(self->view));
  if (clock != nullptr) {
    self->paint_handler = g_signal_connect(clock, "after-paint",
                                           G_CALLBACK(after_paint_cb), self);
  }

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(
      result, "textureId",
      fl_value_new_int(self->texture != nullptr
                           ? fl_texture_get_id(FL_TEXTURE(self->texture))
                           : -1));
  fl_value_set_string_take(
      result, "handle",
      fl_value_new_int(reinterpret_cast<int64_t>(self->map)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* handle_get_state(MlnMapPlugin* self) {
  if (self->map == nullptr) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("nomap", "no map", nullptr));
  }
  double cam[5];
  int64_t stats[2];
  mlnb_get_camera(self->map, cam);
  mlnb_get_stats(self->map, stats);
  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "lat", fl_value_new_float(cam[0]));
  fl_value_set_string_take(result, "lon", fl_value_new_float(cam[1]));
  fl_value_set_string_take(result, "zoom", fl_value_new_float(cam[2]));
  fl_value_set_string_take(result, "bearing", fl_value_new_float(cam[3]));
  fl_value_set_string_take(result, "pitch", fl_value_new_float(cam[4]));
  fl_value_set_string_take(result, "rendered", fl_value_new_int(stats[0]));
  fl_value_set_string_take(result, "consumed", fl_value_new_int(stats[1]));
  fl_value_set_string_take(result, "bench",
                           fl_value_new_int(mlnb_bench_state(self->map)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* call,
                           gpointer user_data) {
  MlnMapPlugin* self = MLN_MAP_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "create") == 0) {
    response = handle_create(self, args);
  } else if (g_strcmp0(method, "dispose") == 0) {
    destroy_map(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "benchStart") == 0) {
    if (self->map != nullptr) {
      mlnb_bench_start(self->map, fl_value_get_string(args));
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "getState") == 0) {
    response = handle_get_state(self);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

static void mln_map_plugin_dispose(GObject* object) {
  MlnMapPlugin* self = MLN_MAP_PLUGIN(object);
  destroy_map(self);
  g_clear_object(&self->channel);
  g_clear_object(&self->registrar);
  G_OBJECT_CLASS(mln_map_plugin_parent_class)->dispose(object);
}

static void mln_map_plugin_class_init(MlnMapPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = mln_map_plugin_dispose;
}

static void mln_map_plugin_init(MlnMapPlugin* self) {}

void mln_map_plugin_register(FlView* view) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "MlnMapPlugin");
  MlnMapPlugin* self =
      MLN_MAP_PLUGIN(g_object_new(mln_map_plugin_get_type(), nullptr));
  self->view = view;
  self->registrar = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "mapsoly/mln_map",
      FL_METHOD_CODEC(codec));
  // The channel keeps the plugin alive for the lifetime of the engine.
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            self, g_object_unref);
}
