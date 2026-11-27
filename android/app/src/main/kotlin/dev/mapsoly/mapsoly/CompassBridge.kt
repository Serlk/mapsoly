package dev.mapsoly.mapsoly

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Surface
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import kotlin.math.abs

/**
 * Where the top of the screen points, in degrees clockwise from magnetic
 * north, on `mapsoly/android/compass`.
 *
 * Uses the system's fused rotation vector (magnetometer + accelerometer +
 * gyroscope), or the geomagnetic one on devices without a gyroscope.
 */
class CompassBridge(private val activity: Activity, messenger: BinaryMessenger) :
    EventChannel.StreamHandler, SensorEventListener {
    private val manager = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val sensor: Sensor? =
        manager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: manager.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR)
    private var sink: EventChannel.EventSink? = null
    private val rotation = FloatArray(9)
    private val remapped = FloatArray(9)
    private val orientation = FloatArray(3)
    private var last = Double.NaN

    init {
        EventChannel(messenger, "mapsoly/android/compass").setStreamHandler(this)
    }

    /**
     * A rotation vector needs a magnetometer to know where north is; the
     * sensor itself may be listed without one.
     */
    fun available(): Boolean =
        sensor != null && manager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD) != null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val s = sensor
        if (s == null) {
            events.endOfStream()
            return
        }
        sink = events
        last = Double.NaN
        manager.registerListener(this, s, SensorManager.SENSOR_DELAY_UI)
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        sink = null
        manager.unregisterListener(this)
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: Surface.ROTATION_0
        } else {
            (activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .defaultDisplay.rotation
        }

    override fun onSensorChanged(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        // The azimuth is that of the device's own Y axis; with the screen
        // turned, "up" on screen is another axis.
        val (x, y) = when (displayRotation()) {
            Surface.ROTATION_90 -> SensorManager.AXIS_Y to SensorManager.AXIS_MINUS_X
            Surface.ROTATION_180 -> SensorManager.AXIS_MINUS_X to SensorManager.AXIS_MINUS_Y
            Surface.ROTATION_270 -> SensorManager.AXIS_MINUS_Y to SensorManager.AXIS_X
            else -> SensorManager.AXIS_X to SensorManager.AXIS_Y
        }
        SensorManager.remapCoordinateSystem(rotation, x, y, remapped)
        SensorManager.getOrientation(remapped, orientation)
        var degrees = Math.toDegrees(orientation[0].toDouble())
        if (degrees.isNaN()) return
        degrees = (degrees % 360 + 360) % 360
        // The sensor reports many times a second; a change too small to see
        // is not worth a message.
        val delta = abs(((degrees - last + 540) % 360) - 180)
        if (!last.isNaN() && delta < 0.5) return
        last = degrees
        sink?.success(degrees)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
