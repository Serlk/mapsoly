package dev.mapsoly.mapsoly

import android.annotation.SuppressLint
import android.content.Context
import android.location.GnssStatus
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Satellite fixes from the platform's own LocationManager (GPS provider
 * only: the "network" provider is a Google service on most phones).
 *
 * Events on `mapsoly/android/location` are maps:
 *  - a fix: `lat`, `lon`, and when the receiver gives them `alt`, `acc`,
 *    `speed` (m/s), `course` (degrees), `time` (ms since the epoch, UTC);
 *  - `sats`: with every event, the satellites of the latest status report
 *    as flat lists `[constellation, svid, cn0, elevation, azimuth, used]`;
 *  - no `lat`: the receiver is on but has no position (sent with a status
 *    report when the last fix is older than a few seconds).
 *
 * Listening starts with the Dart subscription and stops with it. Without
 * the permission the stream reports the error `permission`.
 */
class LocationBridge(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler, LocationListener {
    private val manager =
        context.applicationContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var satellites: List<List<Any?>> = emptyList()
    private var lastFixAt = 0L

    /**
     * The Android emulator ("ranchu") invents a sky: a handful of satellites,
     * all with the same signal level and none used in the fix. That is
     * exactly what the app's spoofing check looks for, so its satellites are
     * not passed on and only the position is.
     */
    private val syntheticSky = Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish"

    private val statusCallback = object : GnssStatus.Callback() {
        override fun onSatelliteStatusChanged(status: GnssStatus) {
            if (syntheticSky) return
            val list = ArrayList<List<Any?>>(status.satelliteCount)
            for (i in 0 until status.satelliteCount) {
                list.add(
                    listOf(
                        status.getConstellationType(i),
                        status.getSvid(i),
                        status.getCn0DbHz(i).toDouble(),
                        status.getElevationDegrees(i).toDouble(),
                        status.getAzimuthDegrees(i).toDouble(),
                        status.usedInFix(i),
                    ),
                )
            }
            satellites = list
            // No position for a while: say so, with what is in view.
            if (android.os.SystemClock.elapsedRealtime() - lastFixAt > 3000) {
                sink?.success(mapOf("sats" to list))
            }
        }
    }

    init {
        EventChannel(messenger, "mapsoly/android/location").setStreamHandler(this)
    }

    fun providerEnabled(): Boolean = try {
        manager.isProviderEnabled(LocationManager.GPS_PROVIDER)
    } catch (e: Exception) {
        false
    }

    @SuppressLint("MissingPermission")
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        sink = events
        try {
            if (!manager.allProviders.contains(LocationManager.GPS_PROVIDER)) {
                events.error("unavailable", "no GPS provider on this device", null)
                sink = null
                return
            }
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, 1000L, 0f, this, Looper.getMainLooper(),
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                manager.registerGnssStatusCallback({ main.post(it) }, statusCallback)
            } else {
                @Suppress("DEPRECATION")
                manager.registerGnssStatusCallback(statusCallback, main)
            }
        } catch (e: SecurityException) {
            sink = null
            stop()
            events.error("permission", "location permission not granted", null)
        } catch (e: Exception) {
            sink = null
            stop()
            events.error("unavailable", e.toString(), null)
        }
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        sink = null
        try {
            manager.removeUpdates(this)
            manager.unregisterGnssStatusCallback(statusCallback)
        } catch (e: Exception) {
            // Never registered: nothing to undo.
        }
        satellites = emptyList()
    }

    override fun onLocationChanged(location: Location) {
        lastFixAt = android.os.SystemClock.elapsedRealtime()
        val event = HashMap<String, Any?>()
        event["lat"] = location.latitude
        event["lon"] = location.longitude
        if (location.hasAltitude()) event["alt"] = location.altitude
        if (location.hasAccuracy()) event["acc"] = location.accuracy.toDouble()
        if (location.hasSpeed()) event["speed"] = location.speed.toDouble()
        if (location.hasBearing()) event["course"] = location.bearing.toDouble()
        event["time"] = location.time
        event["sats"] = satellites
        sink?.success(event)
    }

    override fun onProviderEnabled(provider: String) {}

    override fun onProviderDisabled(provider: String) {
        // Location switched off in the system: the position is gone.
        sink?.success(mapOf("sats" to emptyList<Any>(), "off" to true))
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {
    }
}
