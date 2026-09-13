package dev.touchbridge.android.core

import android.content.SharedPreferences
import dev.touchbridge.android.Constants
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * A Mac this phone has completed pairing with.
 *
 * [id] is the Mac's BLE service UUID in canonical string form. Every Mac
 * generates its own service UUID at first run, so it doubles as a stable,
 * unique identity for the Mac across the app (scan filters, GATT links,
 * crypto sessions, UI rows).
 */
data class PairedMac(
    val id: String,
    /** The name the Mac reported when pairing (its computer name). */
    val name: String,
    val pairedAt: Long,
    /**
     * User-chosen name for this Mac, or null to show [name]. Two Macs often
     * share a computer name, so this is how the user tells rows apart.
     */
    val nickname: String? = null,
) {
    val serviceUUID: UUID get() = UUID.fromString(id)

    /** What the UI shows for this Mac: the nickname if set, else the Mac's own name. */
    val displayName: String get() = nickname ?: name

    /** Copy with a new nickname; blank input clears it so [displayName] falls back to [name]. */
    fun withNickname(raw: String?): PairedMac = copy(nickname = normalizeNickname(raw))

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("pairedAt", pairedAt)
        .apply { nickname?.let { put("nickname", it) } }

    companion object {
        /** Longest nickname we store; keeps rows and notification titles readable. */
        const val MAX_NICKNAME_LENGTH = 40

        /** Canonical id for a service UUID (lowercase, as produced by [UUID.toString]). */
        fun idFor(serviceUUID: UUID): String = serviceUUID.toString()

        /** Trim and cap a nickname; returns null for blank input (meaning "use the Mac's name"). */
        fun normalizeNickname(raw: String?): String? =
            raw?.trim()?.take(MAX_NICKNAME_LENGTH)?.takeIf { it.isNotEmpty() }

        fun fromJson(json: JSONObject): PairedMac? {
            val id = json.optString("id", "")
            val uuid = runCatching { UUID.fromString(id) }.getOrNull() ?: return null
            return PairedMac(
                id = idFor(uuid),
                name = json.optString("name", "Mac"),
                pairedAt = json.optLong("pairedAt", 0L),
                nickname = normalizeNickname(json.optString("nickname", "")),
            )
        }

        fun listToJson(macs: Collection<PairedMac>): String =
            JSONArray().apply { macs.forEach { put(it.toJson()) } }.toString()

        /** Parse a stored list; malformed entries are skipped rather than failing the whole list. */
        fun listFromJson(text: String?): List<PairedMac> {
            if (text.isNullOrBlank()) return emptyList()
            val array = runCatching { JSONArray(text) }.getOrNull() ?: return emptyList()
            return (0 until array.length()).mapNotNull { i ->
                array.optJSONObject(i)?.let { fromJson(it) }
            }.distinctBy { it.id }
        }
    }
}

/** Persists the paired-Mac list in SharedPreferences, migrating the old single-Mac keys. */
class PairedMacStore(private val prefs: SharedPreferences) {

    fun load(): List<PairedMac> {
        if (prefs.contains(Constants.PREF_PAIRED_MACS)) {
            return PairedMac.listFromJson(prefs.getString(Constants.PREF_PAIRED_MACS, null))
        }
        // First run after upgrading from the single-Mac build: convert the old keys.
        val legacyUUID = prefs.getString(Constants.LEGACY_PREF_PAIRED_SERVICE_UUID, null)
            ?: prefs.getString(Constants.LEGACY_PREF_PAIRED_MAC_ID, null)
        val legacy = legacyUUID
            ?.let { runCatching { UUID.fromString(it) }.getOrNull() }
            ?.let {
                PairedMac(
                    id = PairedMac.idFor(it),
                    name = prefs.getString(Constants.LEGACY_PREF_PAIRED_MAC_NAME, null) ?: "Mac",
                    pairedAt = 0L,
                )
            }
        val macs = listOfNotNull(legacy)
        prefs.edit()
            .putString(Constants.PREF_PAIRED_MACS, PairedMac.listToJson(macs))
            .remove(Constants.LEGACY_PREF_PAIRED_MAC_ID)
            .remove(Constants.LEGACY_PREF_PAIRED_MAC_NAME)
            .remove(Constants.LEGACY_PREF_PAIRED_SERVICE_UUID)
            .apply()
        return macs
    }

    fun save(macs: Collection<PairedMac>) {
        prefs.edit().putString(Constants.PREF_PAIRED_MACS, PairedMac.listToJson(macs)).apply()
    }
}
