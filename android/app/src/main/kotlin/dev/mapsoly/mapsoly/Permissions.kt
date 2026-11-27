package dev.mapsoly.mapsoly

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.MethodChannel

/**
 * Runtime permissions by a short name ("location", "bluetooth"), so the Dart
 * side does not carry Android permission strings.
 *
 * A request answers with "granted", "denied" (may be asked again) or
 * "blocked" (the system no longer shows the dialog: only the app's page in
 * the system settings can change it).
 */
class Permissions(private val activity: Activity) {
    private val pending = HashMap<Int, Pair<String, MethodChannel.Result>>()
    private var nextCode = 4200

    /** Null: nothing to ask for on this Android version. */
    private fun names(kind: String): Array<String>? = when (kind) {
        // Both are asked for together: since Android 12 the dialog offers
        // "precise" only when the pair is requested.
        "location" -> arrayOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        "bluetooth" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                null // BLUETOOTH is granted at install time before Android 12
            }
        else -> throw IllegalArgumentException("unknown permission: $kind")
    }

    /** What must be held for [kind] to be of use (satellites need "fine"). */
    private fun required(kind: String): String? = names(kind)?.first()

    fun granted(kind: String): Boolean {
        val name = required(kind) ?: return true
        return activity.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
    }

    fun request(kind: String, result: MethodChannel.Result) {
        val names = names(kind)
        if (names == null || granted(kind)) {
            result.success("granted")
            return
        }
        if (pending.values.any { it.first == kind }) {
            // The dialog for it is already on screen.
            result.success("denied")
            return
        }
        val code = nextCode++
        pending[code] = kind to result
        activity.requestPermissions(names, code)
    }

    fun onResult(requestCode: Int) {
        val (kind, result) = pending.remove(requestCode) ?: return
        val name = required(kind)!!
        result.success(
            when {
                granted(kind) -> "granted"
                // After a refusal the system says whether asking again would
                // show anything; when not, the dialog is gone for good.
                activity.shouldShowRequestPermissionRationale(name) -> "denied"
                else -> "blocked"
            },
        )
    }
}
