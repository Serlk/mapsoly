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
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Satellite fixes from the platform's own LocationManager (GPS provider
 * only: the "network" provider is a Google service on most phones).
 *
 * Events on `mapsoly/android/location` are maps:
 *  - a fix: `lat`, `lon`, and when the receiver gives them `alt`, `acc`,
 *    `speed` (m/s), `course` (degrees), `time` (the receiver's UTC, ms since
 *    the epoch), `at` (when it was taken, by the system clock, same unit);
 *  - `sats`: with every event, the satellites of the latest status report
 *    as flat lists `[constellation, svid, cn0, elevation, azimuth, used]`;
 *  - no `lat`: the receiver is on but has no position (sent with a status
 *    report when the last fix is older than a few seconds);
 *  - `off`: the satellite provider was disabled.
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
            if (SystemClock.elapsedRealtime() - lastFixAt > 3000) {
                sink?.success(mapOf("sats" to list))
            }
        }
    }

    init {
        EventChannel(messenger, "mapsoly/android/location").setStreamHandler(this)
    }

    /**
     * The system-wide location switch. With it off there are no fixes, and
     * no Wi-Fi scan results or cells either. (Before Android 9 there is no
     * such question to ask; the satellite provider's own switch is the
     * closest.)
     */
    fun locationEnabled(): Boolean = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            manager.isLocationEnabled
        } else {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER)
        }
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
        lastFixAt = SystemClock.elapsedRealtime()
        val event = HashMap<String, Any?>()
        event["lat"] = location.latitude
        event["lon"] = location.longitude
        if (location.hasAltitude()) event["alt"] = location.altitude
        if (location.hasAccuracy()) event["acc"] = location.accuracy.toDouble()
        if (location.hasSpeed()) event["speed"] = location.speed.toDouble()
        if (location.hasBearing()) event["course"] = location.bearing.toDouble()
        event["time"] = location.time
        // When the fix was taken, by this device's own clock: the receiver
        // stamps it on the monotonic clock, and messages to the Dart side
        // can queue up for seconds while the app is busy. Two fixes that
        // arrive together must not look like one jump.
        event["at"] = System.currentTimeMillis() -
            (SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos) / 1_000_000
        event["sats"] = satellites
        sink?.success(event)
    }

    override fun onProviderEnabled(provider: String) {}

    override fun onProviderDisabled(provider: String) {
        // The receiver is gone, usually because location was switched off
        // in the system; the Dart side asks which.
        sink?.success(mapOf("sats" to emptyList<Any>(), "off" to true))
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {
    }
}
