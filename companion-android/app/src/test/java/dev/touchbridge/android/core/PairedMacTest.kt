package dev.touchbridge.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/**
 * The paired-Mac list is what lets the phone find and trust several Macs, so
 * its on-disk shape must round-trip exactly and tolerate junk entries.
 */
class PairedMacTest {

    private val a = PairedMac(
        id = PairedMac.idFor(UUID.fromString("EE2DD318-B9DD-4898-A5BE-E5D32319A606")),
        name = "Dylan's MacBook Pro",
        pairedAt = 1_757_000_000_000L,
    )
    private val b = PairedMac(
        id = PairedMac.idFor(UUID.fromString("0041DDE9-1111-2222-3333-444455556666")),
        name = "Mac Studio",
        pairedAt = 1_757_000_100_000L,
    )

    @Test
    fun `id is the canonical lowercase service UUID`() {
        assertEquals("ee2dd318-b9dd-4898-a5be-e5d32319a606", a.id)
        assertEquals(UUID.fromString("EE2DD318-B9DD-4898-A5BE-E5D32319A606"), a.serviceUUID)
    }

    @Test
    fun `list round-trips through JSON preserving order`() {
        val json = PairedMac.listToJson(listOf(a, b))
        assertEquals(listOf(a, b), PairedMac.listFromJson(json))
    }

    @Test
    fun `malformed entries are skipped and duplicates collapsed`() {
        val json = """[
            {"id":"not-a-uuid","name":"Broken","pairedAt":1},
            ${a.toJson()},
            "garbage",
            ${a.toJson()},
            ${b.toJson()}
        ]"""
        assertEquals(listOf(a, b), PairedMac.listFromJson(json))
    }

    @Test
    fun `empty or invalid text yields an empty list`() {
        assertTrue(PairedMac.listFromJson(null).isEmpty())
        assertTrue(PairedMac.listFromJson("").isEmpty())
        assertTrue(PairedMac.listFromJson("{not json").isEmpty())
    }

    @Test
    fun `nickname round-trips and drives displayName`() {
        val renamed = a.withNickname("  Work laptop  ")
        assertEquals("Work laptop", renamed.nickname)
        assertEquals("Work laptop", renamed.displayName)
        assertEquals("Dylan's MacBook Pro", renamed.name)
        assertEquals(listOf(renamed, b), PairedMac.listFromJson(PairedMac.listToJson(listOf(renamed, b))))
    }

    @Test
    fun `blank nickname clears it and displayName falls back to the Mac's name`() {
        val renamed = a.withNickname("Work laptop")
        assertNull(renamed.withNickname("   ").nickname)
        assertNull(renamed.withNickname(null).nickname)
        assertEquals(a, renamed.withNickname(""))
        assertEquals("Dylan's MacBook Pro", a.displayName)
    }

    @Test
    fun `nickname is capped at the maximum length`() {
        val long = "x".repeat(PairedMac.MAX_NICKNAME_LENGTH + 10)
        assertEquals(PairedMac.MAX_NICKNAME_LENGTH, a.withNickname(long).nickname!!.length)
    }

    @Test
    fun `entries stored before nicknames existed load with no nickname`() {
        val json = """[{"id":"${a.id}","name":"Dylan's MacBook Pro","pairedAt":1}]"""
        val loaded = PairedMac.listFromJson(json).single()
        assertNull(loaded.nickname)
        assertEquals("Dylan's MacBook Pro", loaded.displayName)
    }

    @Test
    fun `entry without a valid id is rejected`() {
        assertNull(PairedMac.fromJson(org.json.JSONObject("""{"name":"Nameless"}""")))
    }
}
