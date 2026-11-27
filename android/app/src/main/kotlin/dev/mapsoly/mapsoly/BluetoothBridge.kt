package dev.mapsoly.mapsoly

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Bluetooth Classic serial links (SPP over RFCOMM) to paired devices: the
 * way ELM327 adapters talk.
 *
 * `btConnect` answers with a link id; bytes from the adapter arrive on
 * `mapsoly/android/bluetooth` as `{id, data}` and the end of a link as
 * `{id, closed: true}`. Pairing is left to the system settings.
 *
 * NOT TESTED ON HARDWARE: the emulator has no Bluetooth radio.
 */
class BluetoothBridge(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler {
    private class Link(val socket: BluetoothSocket) {
        // One thread per link keeps the writes in order and off the UI.
        val writer: ExecutorService = Executors.newSingleThreadExecutor()
    }

    private val adapter: BluetoothAdapter? =
        (context.applicationContext.getSystemService(Context.BLUETOOTH_SERVICE)
            as? BluetoothManager)?.adapter
    private val main = Handler(Looper.getMainLooper())
    private val links = HashMap<Int, Link>() // touched on the main thread only
    private var nextId = 1
    private var sink: EventChannel.EventSink? = null

    init {
        EventChannel(messenger, "mapsoly/android/bluetooth").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /** Paired devices as `{address, name}`. */
    @SuppressLint("MissingPermission")
    fun bonded(result: MethodChannel.Result) {
        val a = adapter
        if (a == null) {
            result.error("unavailable", "no Bluetooth adapter", null)
            return
        }
        try {
            if (!a.isEnabled) {
                result.error("off", "Bluetooth is switched off", null)
                return
            }
            result.success(
                a.bondedDevices.map {
                    mapOf("address" to it.address, "name" to (it.name ?: it.address))
                },
            )
        } catch (e: SecurityException) {
            result.error("permission", "Bluetooth permission not granted", null)
        }
    }

    @SuppressLint("MissingPermission")
    fun connect(address: String, result: MethodChannel.Result) {
        val a = adapter
        if (a == null) {
            result.error("unavailable", "no Bluetooth adapter", null)
            return
        }
        if (!BluetoothAdapter.checkBluetoothAddress(address.uppercase())) {
            result.error("address", "not a Bluetooth address: $address", null)
            return
        }
        // connect() blocks for seconds while the radio pages the adapter.
        Thread {
            var socket: BluetoothSocket? = null
            try {
                val device = a.getRemoteDevice(address.uppercase())
                // A running discovery makes connections slow or fail; this
                // needs BLUETOOTH_SCAN on Android 12+, which the app does
                // not hold, so a refusal is expected there.
                try {
                    a.cancelDiscovery()
                } catch (e: SecurityException) {
                }
                socket = try {
                    device.createRfcommSocketToServiceRecord(SPP).also { it.connect() }
                } catch (e: IOException) {
                    // Cheap ELM327 clones often refuse the authenticated
                    // channel and accept the plain one.
                    device.createInsecureRfcommSocketToServiceRecord(SPP).also { it.connect() }
                }
                val connected = socket!!
                main.post {
                    val id = nextId++
                    links[id] = Link(connected)
                    result.success(id)
                    Thread { readLoop(id, connected) }.start()
                }
            } catch (e: SecurityException) {
                closeQuietly(socket)
                main.post { result.error("permission", "Bluetooth permission not granted", null) }
            } catch (e: Exception) {
                closeQuietly(socket)
                main.post { result.error("connect", e.message ?: e.toString(), null) }
            }
        }.start()
    }

    private fun readLoop(id: Int, socket: BluetoothSocket) {
        val buffer = ByteArray(512)
        try {
            val input = socket.inputStream
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                if (n == 0) continue
                val chunk = buffer.copyOf(n)
                main.post { sink?.success(mapOf("id" to id, "data" to chunk)) }
            }
        } catch (e: IOException) {
            // Closed by either side.
        }
        main.post {
            links.remove(id)?.let { release(it) }
            sink?.success(mapOf("id" to id, "closed" to true))
        }
    }

    fun write(id: Int, data: ByteArray?) {
        val link = links[id] ?: return
        if (data == null || data.isEmpty()) return
        try {
            link.writer.execute {
                try {
                    link.socket.outputStream.write(data)
                    link.socket.outputStream.flush()
                } catch (e: IOException) {
                    // The reader notices the dead link and reports it.
                    closeQuietly(link.socket)
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            // Closing.
        }
    }

    fun close(id: Int) {
        // Closing the socket wakes the reader, which reports the end.
        links[id]?.let { release(it) }
    }

    fun closeAll() {
        links.values.toList().forEach { release(it) }
    }

    private fun release(link: Link) {
        link.writer.shutdown()
        closeQuietly(link.socket)
    }

    private fun closeQuietly(socket: BluetoothSocket?) {
        try {
            socket?.close()
        } catch (e: IOException) {
        }
    }

    private companion object {
        /** The well-known Serial Port Profile service. */
        val SPP: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
