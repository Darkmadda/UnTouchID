package dev.touchbridge.android

import java.util.UUID

/**
 * Shared constants matching the TouchBridge protocol.
 * Must stay in sync with protocol/Sources/TouchBridgeProtocol/Constants.swift
 */
object Constants {
    const val PROTOCOL_VERSION: Byte = 0x01
    const val MAX_MESSAGE_SIZE = 256

    // Wire message types — must match protocol MessageTypes.swift
    const val MSG_TYPE_PAIR_REQUEST: Byte = 1
    const val MSG_TYPE_PAIR_RESPONSE: Byte = 2
    const val MSG_TYPE_CHALLENGE_ISSUED: Byte = 3
    const val MSG_TYPE_CHALLENGE_RESPONSE: Byte = 4
    const val MSG_TYPE_ERROR: Byte = 5
    const val MSG_TYPE_IDENTIFY: Byte = 6

    // Well-known error code: signing key invalidated (biometric enrollment changed)
    const val ERROR_CODE_KEY_INVALIDATED = 1001

    // Default BLE service UUID. Each Mac generates its own service UUID at first
    // run (see daemon DaemonConfig.swift) and delivers it in the pairing payload;
    // this constant is only the fallback before any pairing payload has been seen.
    val SERVICE_UUID: UUID = UUID.fromString("B5E6D1A4-8C3F-4E2A-9D7B-1F5A0C6E3B28")
    val SESSION_KEY_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0001-4E2A-9D7B-1F5A0C6E3B28")
    val CHALLENGE_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0002-4E2A-9D7B-1F5A0C6E3B28")
    val RESPONSE_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0003-4E2A-9D7B-1F5A0C6E3B28")
    val PAIRING_CHAR_UUID: UUID = UUID.fromString("B5E6D1A4-0004-4E2A-9D7B-1F5A0C6E3B28")

    // BLE descriptor for enabling notifications
    val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    // Timing
    const val CHALLENGE_EXPIRY_SECONDS = 10L
    const val RESPONSE_TIMEOUT_SECONDS = 15L

    // Keystore
    const val SIGNING_KEY_ALIAS = "dev.touchbridge.signing"

    // Preferences
    const val PREFS_NAME = "touchbridge_prefs"
    // JSON array of every paired Mac (see PairedMac). Each entry carries the
    // Mac's BLE service UUID, which is what scanning is locked to.
    const val PREF_PAIRED_MACS = "paired_macs"
    // Legacy single-Mac keys — migrated into PREF_PAIRED_MACS on first load.
    const val LEGACY_PREF_PAIRED_MAC_ID = "paired_mac_id"
    const val LEGACY_PREF_PAIRED_MAC_NAME = "paired_mac_name"
    const val LEGACY_PREF_PAIRED_SERVICE_UUID = "paired_service_uuid"
    // Stable identifier this device presents to the daemon (generated once).
    const val PREF_DEVICE_ID = "device_id"
}
