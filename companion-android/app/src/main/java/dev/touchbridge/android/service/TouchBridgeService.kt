package dev.touchbridge.android.service

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import dev.touchbridge.android.R
import dev.touchbridge.android.TouchBridgeApp
import dev.touchbridge.android.core.ConnectionManager
import dev.touchbridge.android.core.PendingChallenge
import dev.touchbridge.android.ui.ChallengeActivity
import dev.touchbridge.android.util.NotificationHelper
import dev.touchbridge.android.util.PermissionUtils
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch

/**
 * Foreground service that keeps the TouchBridge process — and its BLE link to
 * the Mac — alive while the app is backgrounded or swiped away, and presents
 * incoming auth challenges even when no Activity is in the foreground.
 *
 * On a challenge it launches [ChallengeActivity] via a full-screen-intent
 * notification, which shows the biometric prompt over the lock screen / current
 * app (the "incoming call" pattern). Android forbids showing a BiometricPrompt
 * straight from a Service, hence the tiny transparent Activity.
 */
class TouchBridgeService : Service() {

    companion object {
        private const val TAG = "TouchBridgeService"

        fun start(context: Context) {
            val intent = Intent(context, TouchBridgeService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TouchBridgeService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var manager: ConnectionManager
    private var lastChallengeShown: String? = null

    override fun onCreate() {
        super.onCreate()
        manager = (application as TouchBridgeApp).connectionManager
        startForegroundInternal()
        observeChallenges()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Reconnect to the paired Mac if we came up cold (boot, process restart).
        if (PermissionUtils.hasBluetoothPermissions(this)) {
            manager.ensureConnected()
        }
        // START_STICKY: if the OS kills us under memory pressure, restart when able.
        return START_STICKY
    }

    private fun startForegroundInternal() {
        val open = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, NotificationHelper.CHANNEL_SERVICE)
            .setContentTitle("TouchBridge active")
            .setContentText("Ready to approve sign-in on your Macs")
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setOngoing(true)
            .setContentIntent(open)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NotificationHelper.NOTIF_ID_SERVICE,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NotificationHelper.NOTIF_ID_SERVICE, notification)
        }
    }

    private fun observeChallenges() {
        scope.launch {
            manager.uiState
                .distinctUntilChangedBy { it.pendingChallenge?.challengeID }
                .collect { state ->
                    val challenge = state.pendingChallenge
                    if (challenge != null && challenge.challengeID != lastChallengeShown) {
                        lastChallengeShown = challenge.challengeID
                        presentChallenge(challenge)
                    } else if (challenge == null) {
                        lastChallengeShown = null
                    }
                }
        }
    }

    /**
     * Launch the biometric prompt. A direct startActivity works when we're
     * already foreground; the full-screen-intent notification is what lets it
     * appear from the background / over the lock screen.
     */
    private fun presentChallenge(challenge: PendingChallenge) {
        Log.i(TAG, "Presenting challenge from ${challenge.macName}: ${challenge.reason}")
        val activityIntent = Intent(this, ChallengeActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_HISTORY)
        }
        val fsIntent = PendingIntent.getActivity(
            this, 1, activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, NotificationHelper.CHANNEL_CHALLENGE)
            .setContentTitle("Approve sign-in on ${challenge.macName}")
            .setContentText(challenge.reason)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setAutoCancel(true)
            .setFullScreenIntent(fsIntent, true)
            .setContentIntent(fsIntent)
            .build()

        androidx.core.app.NotificationManagerCompat.from(this)
            .notify(NotificationHelper.NOTIF_ID_CHALLENGE, notification)

        // Also try a direct launch — instant when we're already in the foreground.
        try {
            startActivity(activityIntent)
        } catch (e: Exception) {
            Log.i(TAG, "Direct activity launch blocked (background) — relying on full-screen intent")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
