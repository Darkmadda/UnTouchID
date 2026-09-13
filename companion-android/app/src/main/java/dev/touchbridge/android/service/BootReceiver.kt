package dev.touchbridge.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import dev.touchbridge.android.TouchBridgeApp
import dev.touchbridge.android.util.PermissionUtils

/**
 * Restarts the foreground service after a reboot so a paired device reconnects
 * without the user having to open the app. Only fires if a Mac is paired and
 * Bluetooth permissions are still granted.
 *
 * Note: a true Force-Stop clears this receiver until the user next opens the
 * app — Android intentionally allows nothing to run for a force-stopped app.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TouchBridgeBoot"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val paired = (context.applicationContext as? TouchBridgeApp)
            ?.connectionManager?.isPaired ?: false

        if (paired && PermissionUtils.hasBluetoothPermissions(context)) {
            Log.i(TAG, "Boot completed — starting TouchBridge service")
            TouchBridgeService.start(context)
        }
    }
}
