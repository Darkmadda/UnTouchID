package dev.touchbridge.android.ui

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.lifecycle.lifecycleScope
import dev.touchbridge.android.Constants
import dev.touchbridge.android.TouchBridgeApp
import dev.touchbridge.android.core.ConnectionManager
import dev.touchbridge.android.core.PendingChallenge
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        manager = (application as TouchBridgeApp).connectionManager

        showWhenLockedAndTurnScreenOn()

        // Finish automatically once the challenge is resolved (approved, denied,
        // or expired-and-cleared by a newer one).
        lifecycleScope.launch {
            manager.uiState.collect { state ->
                val challenge = state.pendingChallenge
                if (challenge == null) {
                    finishAndRemoveTask()
                } else if (challenge.challengeID != promptShownFor) {
                    promptShownFor = challenge.challengeID
                    promptFor(challenge)
                }
            }
        }
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

    private fun showWhenLockedAndTurnScreenOn() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            (getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
                ?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    override fun onDestroy() {
        cancellationSignal?.cancel()
        super.onDestroy()
    }
}
