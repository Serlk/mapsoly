package dev.mapsoly.mapsoly

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlin.math.sqrt

/**
 * Whether the device is lying still, on `mapsoly/android/still` (a Boolean
 * whenever it changes, and once at the start).
 *
 * Wi-Fi scans come half a minute apart; between them the positioning filter
 * has to assume the device may be driving away, and its accuracy circle
 * grows to kilometres. A device that does not shake at all is not driving,
 * and saying so keeps the position where the last scan put it.
 *
 * "Still" is strict on purpose: the spread of the accelerometer over the
 * last few seconds must be down at the sensor's own noise. A table gives
 * that; a hand or a pocket does not, and neither does a car, whose engine
 * and road show up as several times more. Being wrong the other way only
 * loses the benefit.
 */
class StillnessBridge(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler, SensorEventListener {
    private val manager =
        context.applicationContext.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor: Sensor? = manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private var sink: EventChannel.EventSink? = null
    private val window = FloatArray(WINDOW)
    private var filled = 0
    private var next = 0
    private var still: Boolean? = null

    init {
        EventChannel(messenger, "mapsoly/android/still").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val s = sensor
        if (s == null) {
            events.success(false) // nothing to tell stillness by
            return
        }
        sink = events
        // About five readings a second: plenty, and nearly free.
        manager.registerListener(this, s, SensorManager.SENSOR_DELAY_NORMAL)
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        sink = null
        manager.unregisterListener(this)
        filled = 0
        next = 0
        still = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        val (x, y, z) = event.values
        window[next] = sqrt(x * x + y * y + z * z)
        next = (next + 1) % WINDOW
        if (filled < WINDOW) {
            filled++
            if (filled < WINDOW) return
        }
        var mean = 0f
        for (v in window) mean += v
        mean /= WINDOW
        var variance = 0f
        for (v in window) variance += (v - mean) * (v - mean)
        val deviation = sqrt(variance / WINDOW)
        // Two thresholds, so a reading on the edge does not flicker.
        val now = when (still) {
            true -> deviation < MOVING
            else -> deviation < STILL
        }
        if (now != still) {
            still = now
            sink?.success(now)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private companion object {
        /** Readings looked at: about three seconds. */
        const val WINDOW = 16

        /**
         * Standard deviation of |acceleration|, m/s². Phone accelerometers at
         * rest measure 0.01–0.03; a hand-held device 0.1 and up.
         */
        const val STILL = 0.04f
        const val MOVING = 0.07f
    }
}
