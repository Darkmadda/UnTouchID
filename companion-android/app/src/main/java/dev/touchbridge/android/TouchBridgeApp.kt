package dev.touchbridge.android

import android.app.Application
import dev.touchbridge.android.core.ConnectionManager
import dev.touchbridge.android.util.NotificationHelper

class TouchBridgeApp : Application() {

    /** Process-scoped BLE connection + challenge owner. Survives Activity teardown. */
    val connectionManager: ConnectionManager by lazy { ConnectionManager(this) }

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannels(this)
    }
}
