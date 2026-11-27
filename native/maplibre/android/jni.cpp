// The two JNI entry points of the bridge (class dev.mapsoly.mapsoly.MapSurface): turning
// a android.view.Surface into an ANativeWindow needs a JNIEnv, which dart:ffi has not.
// Everything else goes from Dart straight to the C API in mlnb.h.
#include "mlnb.h"

#include <android/native_window_jni.h>
#include <jni.h>

extern "C" {

// Returns the window with one reference held for the Java side, 0 on failure.
JNIEXPORT jlong JNICALL Java_dev_mapsoly_mapsoly_MapSurface_nativeAcquire(JNIEnv* env, jclass, jobject surface) {
    if (!surface) return 0;
    ANativeWindow* window = ANativeWindow_fromSurface(env, surface);
    if (window) mlnb_android_register_window(window);
    return reinterpret_cast<jlong>(window);
}

// Takes every map off the window, then drops the Java side's reference.
JNIEXPORT void JNICALL Java_dev_mapsoly_mapsoly_MapSurface_nativeRelease(JNIEnv*, jclass, jlong handle) {
    auto* window = reinterpret_cast<ANativeWindow*>(handle);
    if (!window) return;
    mlnb_android_unregister_window(window);
    ANativeWindow_release(window);
}

} // extern "C"
