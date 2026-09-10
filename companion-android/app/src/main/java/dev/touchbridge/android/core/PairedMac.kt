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
    val name: String,
    val pairedAt: Long,
) {
    val serviceUUID: UUID get() = UUID.fromString(id)

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("name", name)
        .put("pairedAt", pairedAt)

    companion object {
        /** Canonical id for a service UUID (lowercase, as produced by [UUID.toString]). */
        fun idFor(serviceUUID: UUID): String = serviceUUID.toString()

        fun fromJson(json: JSONObject): PairedMac? {
            val id = json.optString("id", "")
            val uuid = runCatching { UUID.fromString(id) }.getOrNull() ?: return null
            return PairedMac(
                id = idFor(uuid),
                name = json.optString("name", "Mac"),
                pairedAt = json.optLong("pairedAt", 0L),
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
