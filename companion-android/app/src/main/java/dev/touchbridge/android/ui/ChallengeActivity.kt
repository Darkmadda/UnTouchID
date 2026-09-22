package dev.touchbridge.android.ui

import android.app.Activity
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import dev.touchbridge.android.Constants
import dev.touchbridge.android.TouchBridgeApp
import dev.touchbridge.android.core.ConnectionManager
import dev.touchbridge.android.core.PendingChallenge
import dev.touchbridge.android.core.PendingUnlock
import kotlinx.coroutines.launch

/**
 * Transparent, no-UI activity whose only job is to show the system biometric
 * prompt for a pending challenge — including from the background / lock screen,
 * where it's launched by [dev.touchbridge.android.service.TouchBridgeService]'s
 * full-screen-intent notification.
 *
 * It reads the pending challenge from the process-scoped [ConnectionManager]
 * (not from the launching Intent) so a duplicate launch just re-shows the same
 * single prompt, and it finishes as soon as the challenge is resolved.
 */
class ChallengeActivity : ComponentActivity() {

    companion object {
        private const val TAG = "ChallengeActivity"
    }

    private lateinit var manager: ConnectionManager
    private var cancellationSignal: CancellationSignal? = null
    private var promptShownFor: String? = null

    /** A prompt held back because the device is locked; run once it's unlocked. */
    private var pendingPresentation: (() -> Unit)? = null
    private var unlockReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        manager = (application as TouchBridgeApp).connectionManager

        // Deliberately do NOT show over / dismiss the keyguard. When the device is
        // locked we let this (transparent) activity sit *behind* the lock screen and
        // defer the biometric prompt until the user unlocks normally — see present().
        // Showing over the keyguard caused the prompt to be cancelled mid-unlock and
        // left a blank wallpaper the user was stuck on.

        // Finish automatically once the challenge is resolved (approved, denied,
        // or expired-and-cleared by a newer one).
        lifecycleScope.launch {
            manager.uiState.collect { state ->
                val challenge = state.pendingChallenge
                val unlock = state.pendingUnlock
                when {
                    challenge != null -> present(challenge.challengeID) { promptFor(challenge) }
                    unlock != null -> present(unlock.requestID) { promptForUnlock(unlock) }
                    else -> {
                        // Nothing pending (resolved or expired) — drop any deferred
                        // prompt and close.
                        pendingPresentation = null
                        finishAndRemoveTask()
                    }
                }
            }
        }
    }

    /**
     * Show the biometric prompt for [id] — but only while the device is unlocked.
     *
     * If the phone is locked, the OS cancels a biometric prompt the instant the
     * user starts unlocking (firing onAuthenticationError, which declines and
     * clears the request), so it flashes up and then there's nothing left to
     * approve. Instead we defer the prompt until the device is unlocked
     * (ACTION_USER_PRESENT, or the next resume as a fallback).
     */
    private fun present(id: String, show: () -> Unit) {
        if (id == promptShownFor) return
        promptShownFor = id
        if (isDeviceLocked()) {
            pendingPresentation = show
            registerUnlockReceiver()
        } else {
            show()
        }
    }

    private fun isDeviceLocked(): Boolean {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager ?: return false
        return km.isKeyguardLocked
    }

    /**
     * Show a held-back prompt if we're ready.
     *
     * [focused] is the authoritative signal: this activity is not shown over the
     * keyguard, so once it has window focus the keyguard is gone — even if
     * `isKeyguardLocked()` still momentarily reports locked mid-dismiss (that race
     * is exactly what previously left the prompt stuck). For callers without
     * guaranteed focus (onResume / USER_PRESENT) we fall back to the keyguard check.
     */
    private fun presentDeferred(focused: Boolean) {
        val show = pendingPresentation ?: return
        if (!focused && isDeviceLocked()) return
        pendingPresentation = null
        unregisterUnlockReceiver()
        show()
    }

    private fun registerUnlockReceiver() {
        if (unlockReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                presentDeferred(focused = hasWindowFocus())
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

    override fun onResume() {
        super.onResume()
        // If we're already focused (unlocked), show now; otherwise fall back to the
        // keyguard check in case focus hasn't been reported yet.
        presentDeferred(focused = hasWindowFocus())
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // The reliable signal on OEMs that don't broadcast ACTION_USER_PRESENT:
        // gaining window focus means the keyguard is gone (this activity is not
        // shown over it), so it's safe to show the prompt.
        if (hasFocus) presentDeferred(focused = true)
    }

    private fun promptForUnlock(unlock: PendingUnlock) {
        val builder = BiometricPrompt.Builder(this)
            .setTitle("Unlock keychain on ${unlock.macName}")
            .setSubtitle(unlock.reason)
            .setDescription("${unlock.macName} is asking to unlock its login keychain.")
            .setNegativeButton("Deny", mainExecutor) { _, _ -> manager.declineKeychainUnlock() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setAllowedAuthenticators(
                android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG
            )
        }
        val prompt = builder.build()

        cancellationSignal = CancellationSignal()
        // Key agreement can't bind to a CryptoObject, so a successful strong
        // biometric authorises the time-bound key; do the ECDH right after.
        prompt.authenticate(
            cancellationSignal!!,
            mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    try {
                        val shared = manager.keystoreManager.computeSharedSecret(
                            Constants.KEYCHAIN_UNLOCK_KEY_ALIAS, unlock.ephemeralPublicKey
                        )
                        manager.completeKeychainUnlock(unlock.requestID, shared)
                    } catch (e: KeyPermanentlyInvalidatedException) {
                        Log.e(TAG, "Keychain-unlock key invalidated", e)
                        manager.declineKeychainUnlock()
                    } catch (e: Exception) {
                        Log.e(TAG, "Key agreement failed after biometric auth", e)
                        manager.declineKeychainUnlock()
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    Log.w(TAG, "Keychain unlock biometric error $errorCode: $errString")
                    manager.declineKeychainUnlock()
                }
            }
        )
    }

    private fun promptFor(challenge: PendingChallenge) {
        val signature = try {
            manager.keystoreManager.createSignature(Constants.SIGNING_KEY_ALIAS)
        } catch (e: KeyPermanentlyInvalidatedException) {
            manager.challengeKeyInvalidated(challenge.challengeID)
            return
        } catch (e: Exception) {
            Log.e(TAG, "Cannot init signature for challenge", e)
            manager.declineChallenge()
            return
        }

        val prompt = BiometricPrompt.Builder(this)
            .setTitle("Approve sign-in on ${challenge.macName}")
            .setSubtitle(challenge.reason)
            .setDescription("${challenge.macName} is requesting authentication: ${challenge.reason}")
            .setNegativeButton("Deny", mainExecutor) { _, _ -> manager.declineChallenge() }
            .build()

        cancellationSignal = CancellationSignal()
        prompt.authenticate(
            BiometricPrompt.CryptoObject(signature),
            cancellationSignal!!,
            mainExecutor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    val sig = result.cryptoObject?.signature
                    if (sig == null) {
                        manager.declineChallenge()
                        return
                    }
                    try {
                        sig.update(challenge.nonce)
                        manager.completeChallenge(challenge.challengeID, sig.sign())
                    } catch (e: Exception) {
                        Log.e(TAG, "Signing failed after biometric auth", e)
                        manager.declineChallenge()
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                    Log.w(TAG, "Biometric error $errorCode: $errString")
                    manager.declineChallenge()
                }
                // onAuthenticationFailed (wrong finger) is non-terminal — the
                // prompt stays up for a retry, so don't resolve the challenge.
            }
        )
    }

    override fun onDestroy() {
        cancellationSignal?.cancel()
        unregisterUnlockReceiver()
        super.onDestroy()
    }
}
