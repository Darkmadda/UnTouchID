package dev.touchbridge.android.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.UUID

/**
 * Regression tests for parsing the pairing payload from `touchbridge-test pair`.
 *
 * The original pairing bug: the app parsed the payload but ignored its
 * serviceUUID and scanned for a hardcoded default UUID no configured daemon
 * advertises. These tests lock down that the per-Mac serviceUUID and the
 * one-time pairingToken are actually extracted.
 */
class PairingPayloadTest {

    // Shape produced by PairingManager.generatePairingQRData (sortedKeys JSON,
    // Data fields base64-encoded by Swift's JSONEncoder).
    private val validJson = """
        {"macName":"Dylan's MacBook Pro","pairingToken":"q83vASNFZ4mrze8BI0VniQ==","serviceUUID":"0041DDE9-1111-2222-3333-444455556666","version":1}
    """.trimIndent()

    @Test
    fun `parses serviceUUID token and macName from daemon payload`() {
        val payload = PairingPayload.parse(validJson)
        assertNotNull(payload)
        assertEquals(UUID.fromString("0041DDE9-1111-2222-3333-444455556666"), payload!!.serviceUUID)
        assertEquals("Dylan's MacBook Pro", payload.macName)
        assertEquals(1, payload.version)
        assertArrayEquals(
            java.util.Base64.getDecoder().decode("q83vASNFZ4mrze8BI0VniQ=="),
            payload.pairingToken
        )
    }

    @Test
    fun `tolerates surrounding whitespace from copy-paste`() {
        val payload = PairingPayload.parse("\n  $validJson  \n")
        assertNotNull(payload)
        assertEquals(UUID.fromString("0041DDE9-1111-2222-3333-444455556666"), payload!!.serviceUUID)
    }

    @Test
    fun `rejects payload without serviceUUID`() {
        assertNull(PairingPayload.parse("""{"macName":"Mac","pairingToken":"q83v","version":1}"""))
    }

    @Test
    fun `rejects payload without pairingToken`() {
        assertNull(
            PairingPayload.parse(
                """{"macName":"Mac","serviceUUID":"0041DDE9-1111-2222-3333-444455556666","version":1}"""
            )
        )
    }

    @Test
    fun `rejects malformed serviceUUID`() {
        assertNull(
            PairingPayload.parse(
                """{"macName":"Mac","pairingToken":"q83vASNFZ4mrze8BI0VniQ==","serviceUUID":"not-a-uuid","version":1}"""
            )
        )
    }

    @Test
    fun `rejects empty token`() {
        assertNull(
            PairingPayload.parse(
                """{"macName":"Mac","pairingToken":"","serviceUUID":"0041DDE9-1111-2222-3333-444455556666","version":1}"""
            )
        )
    }

    @Test
    fun `rejects non-JSON garbage`() {
        assertNull(PairingPayload.parse("hello"))
        assertNull(PairingPayload.parse(""))
    }
}
