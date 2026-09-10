package dev.touchbridge.android.util

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

object NotificationHelper {

    /** Low-importance channel for the always-on foreground-service notification. */
    const val CHANNEL_SERVICE = "touchbridge_service"

    /** High-importance channel for incoming auth challenges (full-screen intent). */
    const val CHANNEL_CHALLENGE = "touchbridge_challenge"

    const val NOTIF_ID_SERVICE = 1
    const val NOTIF_ID_CHALLENGE = 2

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(NotificationManager::class.java) ?: return

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_SERVICE,
                "TouchBridge status",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps TouchBridge connected to your Mac"
                setShowBadge(false)
            }
        )

        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_CHALLENGE,
                "Authentication requests",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Prompts to approve sign-in on your Mac"
                setShowBadge(true)
                enableVibration(true)
            }
        )
    }
}
