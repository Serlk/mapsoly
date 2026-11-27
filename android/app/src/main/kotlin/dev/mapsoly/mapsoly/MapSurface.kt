package dev.mapsoly.mapsoly

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread

/**
 * The Android half of the MapLibre map engine (docs/map-engine.md, "Android"): the
 * surfaces the native map draws into, and the map's offline glyphs and sprites.
 *
 * The map itself is created and driven from Dart through dart:ffi
 * (libmapsoly_mln.so, native/maplibre/mlnb.h). This class only owns what needs the
 * Android framework: a `SurfaceView` per map view, placed in the activity's content
 * view *below* the Flutter view, which is transparent (MainActivity) and leaves a hole
 * where the map is. SurfaceFlinger puts the two together; Flutter never sees the map's
 * pixels. The view takes no input: it lies under the Flutter view, which gets every
 * touch.
 *
 * The view's `Surface` is handed to Dart as an `ANativeWindow` pointer. Its buffers
 * have a fixed size of their own (`SurfaceHolder.setFixedSize`), which may be smaller
 * than the view: the display then scales the picture up. Android takes the surface
 * away while the app is in the background; the native library is told first (it stops
 * drawing into the window before the call returns), Dart afterwards.
 *
 * Channel `mapsoly/map_surface`:
 *  - `assets` -> directory with `fonts/` and `sprites/` (unpacked from the APK once per
 *    installed version), or an error when the APK has none;
 *  - `create` -> surface id;
 *  - `place` {surface, x, y, width, height, bufferWidth, bufferHeight}: where the view
 *    lies (pixels of the screen, relative to the Flutter view) and the size of its
 *    buffers;
 *  - `dispose` surface id;
 *  - to Dart: `surface` {surface, window, width, height}: the surface has a window with
 *    buffers of that size (window 0: none at the moment).
 */
class MapSurface(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "mapsoly/map_surface")
    private val main = Handler(Looper.getMainLooper())
    private val entries = HashMap<Long, Entry>()
    private var nextId = 1L

    init {
        channel.setMethodCallHandler(this)
    }

    private inner class Entry(val id: Long) : SurfaceHolder.Callback {
        // Default Z order: below the window, which gets a hole where the view is; the
        // Flutter view's own surface is above the window.
        val view = SurfaceView(activity).apply {
            isFocusable = false
            isClickable = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        var window = 0L

        init {
            view.holder.addCallback(this)
        }

        fun place(x: Int, y: Int, width: Int, height: Int, bufferWidth: Int, bufferHeight: Int) {
            val flutter = activity.findViewById<View>(FlutterActivity.FLUTTER_VIEW_ID)
            val container = flutter?.parent as? ViewGroup ?: return
            val params = FrameLayout.LayoutParams(width, height, Gravity.TOP or Gravity.LEFT).apply {
                leftMargin = flutter.left + x
                topMargin = flutter.top + y
            }
            // Before the layout: the surface is then made with these buffers at once.
            view.holder.setFixedSize(bufferWidth, bufferHeight)
            if (view.parent == null) {
                container.addView(view, 0, params) // first child: behind the Flutter view
            } else {
                view.layoutParams = params
            }
        }

        /** Takes the map off the window before Android destroys or changes it. */
        fun drop() {
            if (window != 0L) nativeRelease(window)
            window = 0L
        }

        fun remove() {
            view.holder.removeCallback(this)
            drop()
            (view.parent as? ViewGroup)?.removeView(view)
        }

        override fun surfaceCreated(holder: SurfaceHolder) {
            // surfaceChanged always follows, with the size.
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            // Also after a change of the buffers' size: the map starts on the window
            // anew, so it never draws with a size the window no longer has.
            drop()
            val surface: Surface? = holder.surface
            window = if (surface != null && surface.isValid) nativeAcquire(surface) else 0L
            announce(window, width, height)
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {
            // The app left the screen (or the view is going away).
            drop()
            announce(0L, 0, 0)
        }

        private fun announce(window: Long, width: Int, height: Int) {
            channel.invokeMethod(
                "surface",
                mapOf("surface" to id, "window" to window, "width" to width, "height" to height),
            )
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "assets" -> unpackAssets(result)
            "create" -> {
                if (!loadLibrary()) {
                    result.error("unavailable", "libmapsoly_mln.so cannot be loaded", null)
                    return
                }
                val entry = Entry(nextId++)
                entries[entry.id] = entry
                result.success(entry.id)
            }
            "place" -> {
                val entry = entries[(call.argument<Number>("surface") ?: -1).toLong()]
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val bufferWidth = call.argument<Int>("bufferWidth") ?: 0
                val bufferHeight = call.argument<Int>("bufferHeight") ?: 0
                if (entry != null && width > 0 && height > 0 && bufferWidth > 0 && bufferHeight > 0) {
                    entry.place(
                        call.argument<Int>("x") ?: 0,
                        call.argument<Int>("y") ?: 0,
                        width,
                        height,
                        bufferWidth,
                        bufferHeight,
                    )
                }
                result.success(null)
            }
            "dispose" -> {
                entries.remove((call.arguments as Number).toLong())?.remove()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Flutter is going away: no surface may outlive it. */
    fun release() {
        channel.setMethodCallHandler(null)
        for (entry in entries.values) entry.remove()
        entries.clear()
    }

    /**
     * MapLibre reads glyphs and sprites as plain files, so `assets/maplibre.zip`
     * (tool/build_maplibre_android.sh) is unpacked into the app's files directory,
     * once per installed version of the app.
     */
    private fun unpackAssets(result: MethodChannel.Result) {
        thread(name = "map-assets") {
            val outcome = runCatching {
                val context = activity.applicationContext
                val info = context.packageManager.getPackageInfo(context.packageName, 0)
                val stamp = "${info.lastUpdateTime}"
                val dir = File(context.filesDir, "maplibre")
                val marker = File(dir, ".unpacked")
                if (!marker.isFile || marker.readText() != stamp) {
                    dir.deleteRecursively()
                    val root = dir.canonicalPath + File.separator
                    ZipInputStream(context.assets.open("maplibre.zip")).use { zip ->
                        while (true) {
                            val item = zip.nextEntry ?: break
                            val file = File(dir, item.name)
                            // Never write outside the directory, whatever the archive says.
                            if (!file.canonicalPath.startsWith(root)) continue
                            if (item.isDirectory) {
                                file.mkdirs()
                            } else {
                                file.parentFile?.mkdirs()
                                file.outputStream().use { zip.copyTo(it) }
                            }
                        }
                    }
                    marker.writeText(stamp)
                }
                dir.absolutePath
            }
            main.post {
                outcome.fold(
                    { result.success(it) },
                    { result.error("assets", "no map assets in the APK: $it", null) },
                )
            }
        }
    }

    private companion object {
        private var loaded: Boolean? = null

        /** The library holds the two JNI functions below; Dart opens the same one. */
        fun loadLibrary(): Boolean =
            loaded ?: runCatching { System.loadLibrary("mapsoly_mln") }.isSuccess.also { loaded = it }

        @JvmStatic
        external fun nativeAcquire(surface: Surface): Long

        @JvmStatic
        external fun nativeRelease(window: Long)
    }
}
