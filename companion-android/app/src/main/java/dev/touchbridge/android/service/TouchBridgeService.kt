package dev.touchbridge.android.service

import android.app.KeyguardManager
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
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
    private var lastUnlockShown: String? = null

    /** Set while a prompt is held back until the device is unlocked. */
    private var pendingActivityIntent: Intent? = null
    private var unlockReceiver: BroadcastReceiver? = null

    /** Bumped per challenge so each notification/PendingIntent is unique. */
    private var promptSeq = 0
    private var lastChallengeNotifId: Int? = null

    override fun onCreate() {
        super.onCreate()
        manager = (application as TouchBridgeApp).connectionManager
        startForegroundInternal()
        observeChallenges()
        observeUnlocks()
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

    private fun observeUnlocks() {
        scope.launch {
            manager.uiState
                .distinctUntilChangedBy { it.pendingUnlock?.requestID }
                .collect { state ->
                    val unlock = state.pendingUnlock
                    if (unlock != null && unlock.requestID != lastUnlockShown) {
                        lastUnlockShown = unlock.requestID
                        presentPrompt(
                            "Unlock keychain on ${unlock.macName}",
                            unlock.reason
                        )
                    } else if (unlock == null) {
                        lastUnlockShown = null
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
        presentPrompt("Approve sign-in on ${challenge.macName}", challenge.reason)
    }

    /** Post the challenge notification and bring up the biometric prompt. */
    private fun presentPrompt(title: String, text: String) {
        val activityIntent = Intent(this, ChallengeActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        // Each challenge must be a genuinely NEW full-screen-intent notification, or
        // the OS treats a repost with the same id/PendingIntent as an update and does
        // NOT re-fire the full-screen intent — so the 2nd+ prompt never launches.
        // Use a fresh notification id and PendingIntent request code each time, and
        // cancel the previous one so only one challenge notification is ever shown.
        promptSeq += 1
        val notifId = NotificationHelper.NOTIF_ID_CHALLENGE + 1 + promptSeq
        val tapIntent = PendingIntent.getActivity(
            this, promptSeq, activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // The full-screen intent is what reliably launches ChallengeActivity while
        // the device is locked (broadcasts like ACTION_USER_PRESENT are not
        // delivered to us on some OEMs). The activity itself does NOT show the
        // biometric prompt while locked — it waits until it's focused and unlocked
        // (see ChallengeActivity.present) — so launching it early is safe.
        val notification = NotificationCompat.Builder(this, NotificationHelper.CHANNEL_CHALLENGE)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setAutoCancel(true)
            .setFullScreenIntent(tapIntent, true)
            .setContentIntent(tapIntent)
            .build()

        val nm = androidx.core.app.NotificationManagerCompat.from(this)
        lastChallengeNotifId?.let { nm.cancel(it) }
        lastChallengeNotifId = notifId
        nm.notify(notifId, notification)

        if (isDeviceLocked()) {
            // Locked: rely on the full-screen intent to bring up the activity, which
            // holds the prompt until unlock. Also arm an unlock listener as a
            // secondary path for OEMs where it is delivered.
            awaitUnlockThenLaunch(activityIntent)
        } else {
            launchPrompt(activityIntent)
        }
    }

    /**
     * Launch the prompt activity now. Instant when we're already foreground; from
     * the background it succeeds only when the user has granted "Display over other
     * apps" (which grants a background-activity-launch exemption). Otherwise Android
     * blocks it and the posted notification remains as the way in.
     */
    private fun launchPrompt(activityIntent: Intent) {
        try {
            startActivity(activityIntent)
        } catch (e: Exception) {
            if (PermissionUtils.canDrawOverlays(this)) {
                Log.w(TAG, "Activity launch failed despite overlay permission", e)
            } else {
                Log.i(TAG, "Activity launch blocked (background, no overlay permission) — relying on notification")
            }
        }
    }

    private fun isDeviceLocked(): Boolean {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager ?: return false
        return km.isKeyguardLocked
    }

    /** Launch [activityIntent] once the device is unlocked (user present). */
    private fun awaitUnlockThenLaunch(activityIntent: Intent) {
        pendingActivityIntent = activityIntent
        if (unlockReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (isDeviceLocked()) return
                val toLaunch = pendingActivityIntent ?: return
                pendingActivityIntent = null
                unregisterUnlockReceiver()
                launchPrompt(toLaunch)
            }
        }
        unlockReceiver = receiver
        // ACTION_USER_PRESENT is a protected system broadcast; NOT_EXPORTED is
        // correct and satisfies the Android 14 registration requirement.
        ContextCompat.registerReceiver(
            this, receiver, IntentFilter(Intent.ACTION_USER_PRESENT),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    private fun unregisterUnlockReceiver() {
        unlockReceiver?.let { runCatching { unregisterReceiver(it) } }
        unlockReceiver = null
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        unregisterUnlockReceiver()
        super.onDestroy()
    }
}
