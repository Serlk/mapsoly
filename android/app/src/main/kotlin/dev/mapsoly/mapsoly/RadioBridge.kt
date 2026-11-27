package dev.mapsoly.mapsoly

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.ScanResult
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.telephony.CellIdentityNr
import android.telephony.CellInfo
import android.telephony.CellInfoGsm
import android.telephony.CellInfoLte
import android.telephony.CellInfoNr
import android.telephony.CellInfoWcdma
import android.telephony.CellSignalStrengthNr
import android.telephony.TelephonyManager
import io.flutter.plugin.common.MethodChannel

/**
 * What the radios hear, for positioning without satellites: Wi-Fi access
 * points and cell towers. Raw platform values go to the Dart side as they
 * are; cleaning them up (placeholders, "unavailable" markers) happens there,
 * where it is unit-tested.
 *
 * Both need ACCESS_FINE_LOCATION and location switched on in the system;
 * without either the platform returns nothing and so does this class.
 * Nothing here runs by itself: the Dart side asks, and it only asks while
 * the app is on screen.
 */
class RadioBridge(context: Context) {
    private val app = context.applicationContext
    private val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val telephony: TelephonyManager? =
        if (app.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)) {
            app.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        } else {
            null // a tablet without a modem: no cells, and no errors either
        }
    private val main = Handler(Looper.getMainLooper())

    /**
     * The system's latest scan results, whoever asked for the scan, as
     * `[bssid, rssi dBm, frequency MHz, age ms, ssid]`. The age comes from
     * each result's own timestamp: the list is a cache and may be minutes
     * old.
     */
    @SuppressLint("MissingPermission")
    fun wifiScan(): List<List<Any?>> {
        val manager = wifi ?: return emptyList()
        val results: List<ScanResult> = try {
            manager.scanResults ?: emptyList()
        } catch (e: SecurityException) {
            emptyList()
        }
        val now = SystemClock.elapsedRealtime()
        return results.map {
            listOf(it.BSSID, it.level, it.frequency, now - it.timestamp / 1000, ssid(it))
        }
    }

    @Suppress("DEPRECATION")
    private fun ssid(result: ScanResult): String? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Quoted when it is text, bare hex otherwise.
            result.wifiSsid?.toString()?.let {
                if (it.length >= 2 && it.startsWith("\"") && it.endsWith("\"")) {
                    it.substring(1, it.length - 1)
                } else {
                    null
                }
            }
        } else {
            result.SSID
        }

    /**
     * Asks for a fresh scan. False when the system refuses: Wi-Fi scanning
     * is off, or the app used up its allowance (four scans in two minutes
     * while on screen, since Android 9).
     */
    @Suppress("DEPRECATION")
    fun wifiRequestScan(): Boolean = try {
        wifi?.startScan() ?: false
    } catch (e: SecurityException) {
        false
    }

    /**
     * Serving and neighbour cells as maps (see [describe]). Asks the modem
     * for fresh measurements where the platform allows (Android 10+);
     * otherwise, and when the modem does not answer in time, the cached
     * list.
     */
    @SuppressLint("MissingPermission")
    fun cells(result: MethodChannel.Result) {
        val manager = telephony
        if (manager == null) {
            result.success(emptyList<Any>())
            return
        }
        var answered = false
        fun answer(cells: List<CellInfo>?) {
            if (answered) return
            answered = true
            result.success((cells ?: emptyList()).mapNotNull { describe(it) })
        }
        fun cached(): List<CellInfo>? = try {
            manager.allCellInfo
        } catch (e: Exception) {
            null
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                manager.requestCellInfoUpdate(
                    { main.post(it) },
                    object : TelephonyManager.CellInfoCallback() {
                        override fun onCellInfo(cells: MutableList<CellInfo>) = answer(cells)

                        override fun onError(errorCode: Int, detail: Throwable?) =
                            answer(cached())
                    },
                )
                main.postDelayed({ answer(cached()) }, 3000)
            } else {
                answer(cached())
            }
        } catch (e: Exception) {
            // No permission, no modem behind the feature flag, a broken RIL.
            answer(null)
        }
    }

    /**
     * One cell with the platform's numbers untouched: an absent value is
     * `Int.MAX_VALUE` (`Long.MAX_VALUE` for the NR cell id), as Android
     * reports it. Kinds the engine has no model for (CDMA, TD-SCDMA) are
     * left out.
     */
    @Suppress("DEPRECATION")
    private fun describe(info: CellInfo): Map<String, Any?>? {
        val cell = HashMap<String, Any?>()
        cell["serving"] = info.isRegistered
        when {
            info is CellInfoLte -> {
                val id = info.cellIdentity
                val signal = info.cellSignalStrength
                cell["radio"] = "lte"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    mccMnc(cell, id.mccString, id.mncString)
                } else {
                    cell["mcc"] = id.mcc
                    cell["mnc"] = id.mnc
                }
                cell["area"] = id.tac
                cell["cid"] = id.ci
                cell["pci"] = id.pci
                cell["arfcn"] = id.earfcn
                cell["dbm"] =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) signal.rsrp else signal.dbm
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) cell["rsrq"] = signal.rsrq
                cell["ta"] = signal.timingAdvance
            }
            info is CellInfoGsm -> {
                val id = info.cellIdentity
                val signal = info.cellSignalStrength
                cell["radio"] = "gsm"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    mccMnc(cell, id.mccString, id.mncString)
                } else {
                    cell["mcc"] = id.mcc
                    cell["mnc"] = id.mnc
                }
                cell["area"] = id.lac
                cell["cid"] = id.cid
                cell["pci"] = id.bsic
                cell["arfcn"] = id.arfcn
                cell["dbm"] = signal.dbm
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    cell["ta"] = signal.timingAdvance
                }
            }
            info is CellInfoWcdma -> {
                val id = info.cellIdentity
                cell["radio"] = "umts"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    mccMnc(cell, id.mccString, id.mncString)
                } else {
                    cell["mcc"] = id.mcc
                    cell["mnc"] = id.mnc
                }
                cell["area"] = id.lac
                cell["cid"] = id.cid
                cell["pci"] = id.psc
                cell["arfcn"] = id.uarfcn
                cell["dbm"] = info.cellSignalStrength.dbm
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info is CellInfoNr -> {
                val id = info.cellIdentity as CellIdentityNr
                val signal = info.cellSignalStrength as CellSignalStrengthNr
                cell["radio"] = "nr"
                mccMnc(cell, id.mccString, id.mncString)
                cell["area"] = id.tac
                cell["cid"] = id.nci
                cell["pci"] = id.pci
                cell["arfcn"] = id.nrarfcn
                cell["dbm"] = signal.ssRsrp
                cell["rsrq"] = signal.ssRsrq
            }
            else -> return null
        }
        return cell
    }

    private fun mccMnc(cell: HashMap<String, Any?>, mcc: String?, mnc: String?) {
        cell["mcc"] = mcc?.toIntOrNull()
        cell["mnc"] = mnc?.toIntOrNull()
    }
}
