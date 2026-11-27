package dev.mapsoly.mapsoly

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Android side of the app's own platform channels. Everything here uses
 * plain framework APIs (LocationManager, WifiManager, TelephonyManager,
 * SensorManager, BluetoothSocket, AudioTrack): no Google Play services and nothing that needs a key.
 *
 * Channels:
 *  - `mapsoly/native_view`: the name the Linux runner already answers on;
 *    only `keepAwake` exists here.
 *  - `mapsoly/android`: permissions, folders, the alert sound, Bluetooth,
 *    Wi-Fi scans and cell measurements (RadioBridge.kt).
 *  - `mapsoly/android/location`, `/compass`, `/still`, `/bluetooth`: event
 *    streams.
 *  - `mapsoly/map_surface`: the texture the MapLibre map engine draws into
 *    (MapSurface.kt).
 */
class MainActivity : FlutterActivity() {
    private lateinit var permissions: Permissions
    private var location: LocationBridge? = null
    private var compass: CompassBridge? = null
    private var stillness: StillnessBridge? = null
    private var bluetooth: BluetoothBridge? = null
    private var mapSurface: MapSurface? = null
    private val sound = AlertPlayer()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // With a hardware keyboard Android frames the focused view, which
        // here is always the whole screen.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            findViewById<View>(FLUTTER_VIEW_ID)?.defaultFocusHighlightEnabled = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        permissions = Permissions(this)
        location = LocationBridge(this, messenger)
        compass = CompassBridge(this, messenger)
        stillness = StillnessBridge(this, messenger)
        val bt = BluetoothBridge(this, messenger).also { bluetooth = it }
        val radio = RadioBridge(this)
        mapSurface = MapSurface(applicationContext, flutterEngine.renderer, messenger)

        MethodChannel(messenger, "mapsoly/native_view").setMethodCallHandler { call, result ->
            when (call.method) {
                "keepAwake" -> {
                    val on = call.arguments as? Boolean ?: false
                    if (on) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    // The flag is on the window itself: once set it holds.
                    result.success(on)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "mapsoly/android").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" ->
                    result.success(permissions.granted(call.arguments as String))
                "requestPermission" ->
                    permissions.request(call.arguments as String, result)
                "openAppSettings" -> {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null),
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "locationEnabled" -> result.success(location?.locationEnabled() ?: false)
                "wifiScan" -> result.success(radio.wifiScan())
                "wifiRequestScan" -> result.success(radio.wifiRequestScan())
                "cells" -> radio.cells(result)
                "hasCompass" -> result.success(compass?.available() ?: false)
                "playPcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    val rate = call.argument<Int>("rate") ?: 22050
                    result.success(pcm != null && sound.play(pcm, rate))
                }
                "exportDir" -> result.success(getExternalFilesDir(null)?.absolutePath)
                "btBonded" -> bt.bonded(result)
                "btConnect" -> bt.connect(call.arguments as String, result)
                "btWrite" -> {
                    bt.write(call.argument<Int>("id") ?: -1, call.argument<ByteArray>("data"))
                    result.success(null)
                }
                "btClose" -> {
                    bt.close(call.arguments as Int)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        this.permissions.onResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        location?.stop()
        compass?.stop()
        stillness?.stop()
        bluetooth?.closeAll()
        mapSurface?.release()
        mapSurface = null
        sound.release()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
