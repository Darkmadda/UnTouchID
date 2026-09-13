package dev.touchbridge.android.core

import org.json.JSONObject
import java.util.UUID

/**
 * Pairing payload pasted (or QR-scanned) from `touchbridge-test pair` on the Mac.
 *
 * Every Mac advertises under a service UUID generated at its first run — unique
 * per Mac — so the `serviceUUID` in this payload is required to find the Mac at
 * all. The `pairingToken` is a one-time token the daemon uses to authorize the
 * pairing request (valid for 5 minutes).
 */
data class PairingPayload(
    val serviceUUID: UUID,
    val pairingToken: ByteArray,
    val macName: String,
    val version: Int,
) {
    companion object {
        /** Parse a pairing payload from JSON. Returns null if invalid. */
        fun parse(text: String): PairingPayload? {
            return try {
                val json = JSONObject(text.trim())
                val serviceUUID = UUID.fromString(json.getString("serviceUUID"))
                val token = java.util.Base64.getDecoder().decode(json.getString("pairingToken"))
                if (token.isEmpty()) return null
                PairingPayload(
                    serviceUUID = serviceUUID,
                    pairingToken = token,
                    macName = json.optString("macName", "Mac"),
                    version = json.optInt("version", 1),
                )
            } catch (e: Exception) {
                null
            }
        }
    }

    override fun equals(other: Any?): Boolean =
        other is PairingPayload &&
            serviceUUID == other.serviceUUID &&
            pairingToken.contentEquals(other.pairingToken) &&
            macName == other.macName &&
            version == other.version

    override fun hashCode(): Int = serviceUUID.hashCode()
}
