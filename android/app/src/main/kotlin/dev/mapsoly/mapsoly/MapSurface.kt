package dev.mapsoly.mapsoly

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread

/**
 * The Android half of the MapLibre map engine (docs/map-engine.md, "Android"): the
 * Flutter textures the native map draws into, and the map's offline glyphs and sprites.
 *
 * The map itself is created and driven from Dart through dart:ffi
 * (libmapsoly_mln.so, native/maplibre/mlnb.h). This class only owns what needs the
 * Android framework: a `SurfaceProducer` per map view, whose `Surface` is handed to Dart
 * as an `ANativeWindow` pointer. Android takes that surface away while the app is in the
 * background and after a resize; the native library is told first (it stops drawing
 * into the window before the call returns), Dart afterwards.
 *
 * Channel `mapsoly/map_surface`:
 *  - `assets` -> directory with `fonts/` and `sprites/` (unpacked from the APK once per
 *    installed version), or an error when the APK has none;
 *  - `create` -> texture id;
 *  - `resize` {texture, width, height} -> window handle for that size (0: none now);
 *  - `dispose` texture id;
 *  - to Dart: `surface` {texture, window}: the texture has a new window (0: none).
 */
class MapSurface(
    private val context: Context,
    private val textures: TextureRegistry,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "mapsoly/map_surface")
    private val main = Handler(Looper.getMainLooper())
    private val entries = HashMap<Long, Entry>()

    init {
        channel.setMethodCallHandler(this)
    }

    private inner class Entry(val producer: TextureRegistry.SurfaceProducer) :
        TextureRegistry.SurfaceProducer.Callback {
        var surface: Surface? = null
        var window = 0L

        /** The producer's current surface as a native window; the same one while it lasts. */
        fun acquire(): Long {
            val current = producer.surface
            if (current === surface && window != 0L) return window
            drop()
            surface = current
            window = if (current.isValid) nativeAcquire(current) else 0L
            return window
        }

        /** Takes the map off the window before Android destroys it. */
        fun drop() {
            if (window != 0L) nativeRelease(window)
            window = 0L
            surface = null
        }

        override fun onSurfaceAvailable() {
            // Back on screen: a new surface of the size set last.
            if (producer.width > 0 && producer.height > 0) announce(acquire())
        }

        override fun onSurfaceCleanup() {
            drop()
            announce(0L)
        }

        private fun announce(window: Long) {
            channel.invokeMethod("surface", mapOf("texture" to producer.id(), "window" to window))
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
                // Reset in the background: after a pause the map gets a fresh surface
                // and repaints, instead of trusting buffers that outlived it.
                val producer = textures.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
                val entry = Entry(producer)
                producer.setCallback(entry)
                entries[producer.id()] = entry
                result.success(producer.id())
            }
            "resize" -> {
                val entry = entries[(call.argument<Number>("texture") ?: -1).toLong()]
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (entry == null || width < 1 || height < 1) {
                    result.success(0L)
                    return
                }
                if (entry.producer.width != width || entry.producer.height != height) {
                    // A producer of another size has another surface: let go of the old one.
                    entry.drop()
                    entry.producer.setSize(width, height)
                }
                result.success(entry.acquire())
            }
            "dispose" -> {
                entries.remove((call.arguments as Number).toLong())?.let {
                    it.drop()
                    it.producer.release()
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Flutter is going away: no surface may outlive it. */
    fun release() {
        channel.setMethodCallHandler(null)
        for (entry in entries.values) {
            entry.drop()
            entry.producer.release()
        }
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
