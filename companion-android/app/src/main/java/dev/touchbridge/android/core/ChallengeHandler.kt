package dev.touchbridge.android.core

import android.util.Log
import dev.touchbridge.android.Constants
import org.json.JSONObject

/**
 * Wire-format codec for the challenge/response flow, plus the per-Mac
 * [SecureSession] registry it encrypts with.
 *
 * Flow per Mac:
 * 1. Receive encrypted challenge from that Mac
 * 2. Decrypt with that Mac's ECDH session key
 * 3. Prompt biometric via BiometricPrompt
 * 4. Sign nonce with the (single, shared) Android Keystore key
 * 5. Send the signed response back over that Mac's BLE link
 */
class ChallengeHandler {
    companion object {
        private const val TAG = "ChallengeHandler"
    }

    private val sessions = HashMap<String, SecureSession>()

    private fun session(macId: String): SecureSession = synchronized(sessions) {
        sessions.getOrPut(macId) { SecureSession(macId.takeLast(4)) }
    }

    fun isSessionReady(macId: String): Boolean =
        synchronized(sessions) { sessions[macId]?.isReady == true }

    /** Drop a Mac's session (on disconnect or unpair) so stale keys are never reused. */
    fun clearSession(macId: String) {
        synchronized(sessions) { sessions.remove(macId) }
    }

    fun initiateECDH(macId: String): ByteArray = session(macId).initiateECDH()

    fun completeECDH(macId: String, macPublicKeyBytes: ByteArray) =
        session(macId).completeECDH(macPublicKeyBytes)

    fun encrypt(macId: String, plaintext: ByteArray): ByteArray = session(macId).encrypt(plaintext)

    /**
     * Parse an incoming challenge wire frame from [macId] and decrypt its nonce.
     *
     * Wire format: [version=1][type=3(challengeIssued)] + plain JSON — only the
     * `encryptedNonce` field is AES-GCM encrypted with that Mac's session key.
     *
     * Returns null if the frame is malformed, the session isn't established,
     * or the challenge has already expired.
     */
    fun parseChallengeWire(macId: String, macName: String, data: ByteArray): PendingChallenge? {
        val session = synchronized(sessions) { sessions[macId] }
        if (session == null || !session.isReady) {
            Log.w(TAG, "Challenge from $macName received before ECDH session established")
            return null
        }
        if (data.size <= 2) return null

        return try {
            val json = JSONObject(String(data.copyOfRange(2, data.size)))
            val encryptedNonce = android.util.Base64.decode(
                json.getString("encryptedNonce"), android.util.Base64.DEFAULT
            )
            val expiryUnix = json.getLong("expiryUnix")
            if (System.currentTimeMillis() / 1000 >= expiryUnix) {
                Log.w(TAG, "Challenge expired before handling")
                return null
            }
            PendingChallenge(
                macId = macId,
                macName = macName,
                challengeID = json.getString("challengeID"),
                nonce = session.decrypt(encryptedNonce),
                reason = json.getString("reason"),
                expiryUnix = expiryUnix,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse challenge", e)
            null
        }
    }

    /**
     * Build the signed response wire frame.
     * Wire format: [version=1][type=4(challengeResponse)] + plain JSON.
     */
    fun buildResponseWire(challengeID: String, signature: ByteArray, deviceID: String): ByteArray {
        val json = JSONObject().apply {
            put("challengeID", challengeID)
            put("signature", android.util.Base64.encodeToString(signature, android.util.Base64.NO_WRAP))
            put("deviceID", deviceID)
        }
        return byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_CHALLENGE_RESPONSE) +
            json.toString().toByteArray()
    }

    /**
     * Build a key-invalidated error frame so the Mac fails fast instead of
     * waiting for the response timeout.
     * Wire format: [version=1][type=5(error)] + AES-GCM encrypted JSON.
     */
    fun buildKeyInvalidatedErrorWire(macId: String, challengeID: String): ByteArray {
        val payload = JSONObject().apply {
            put("code", Constants.ERROR_CODE_KEY_INVALIDATED)
            put("description", "key_invalidated")
            put("challengeID", challengeID)
        }.toString().toByteArray()
        return byteArrayOf(Constants.PROTOCOL_VERSION, Constants.MSG_TYPE_ERROR) + encrypt(macId, payload)
    }
}

/** A decrypted challenge from one Mac awaiting biometric approval. */
data class PendingChallenge(
    val macId: String,
    val macName: String,
    val challengeID: String,
    val nonce: ByteArray,
    val reason: String,
    val expiryUnix: Long,
) {
    override fun equals(other: Any?): Boolean =
        other is PendingChallenge && challengeID == other.challengeID
    override fun hashCode(): Int = challengeID.hashCode()
}
