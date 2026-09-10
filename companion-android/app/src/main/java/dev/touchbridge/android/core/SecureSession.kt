package dev.touchbridge.android.core

import android.util.Log
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The encrypted session with one Mac: an ephemeral ECDH (P-256) key exchange
 * followed by AES-256-GCM. One instance exists per connected Mac, since each
 * Mac derives its own session key with us.
 *
 * Uses standard JCA/JCE so the output is compatible with Apple's CryptoKit
 * (same curve, HKDF-SHA256 derivation, combined nonce+ciphertext+tag format).
 */
class SecureSession(private val label: String) {
    companion object {
        private const val TAG = "SecureSession"
    }

    private var sessionKey: SecretKeySpec? = null
    private var localECDHPrivateKey: PrivateKey? = null

    val isReady: Boolean get() = sessionKey != null

    /** Generate an ephemeral key pair; returns our public key in X9.62 uncompressed form. */
    fun initiateECDH(): ByteArray {
        val keyPairGen = KeyPairGenerator.getInstance("EC")
        keyPairGen.initialize(ECGenParameterSpec("secp256r1"))
        val keyPair = keyPairGen.generateKeyPair()
        localECDHPrivateKey = keyPair.private
        sessionKey = null

        val encoded = keyPair.public.encoded
        val publicKeyBytes = if (encoded.size > 65) encoded.takeLast(65).toByteArray() else encoded
        Log.i(TAG, "[$label] Generated ECDH ephemeral key pair (${publicKeyBytes.size} bytes)")
        return publicKeyBytes
    }

    /** Derive the shared AES key from the Mac's public key. */
    fun completeECDH(macPublicKeyBytes: ByteArray) {
        val privKey = localECDHPrivateKey ?: throw IllegalStateException("ECDH not initiated")

        // Wrap the raw X9.62 point in an X.509 SubjectPublicKeyInfo header for EC P-256.
        val header = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86.toByte(),
            0x48, 0xCE.toByte(), 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        )
        val macPublicKey = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(header + macPublicKeyBytes))

        val keyAgreement = KeyAgreement.getInstance("ECDH")
        keyAgreement.init(privKey)
        keyAgreement.doPhase(macPublicKey, true)
        val sharedSecret = keyAgreement.generateSecret()

        val derivedKey = hkdfSHA256(
            ikm = sharedSecret,
            salt = byteArrayOf(),
            info = "TouchBridge-v1".toByteArray(),
            length = 32
        )
        sessionKey = SecretKeySpec(derivedKey, "AES")
        Log.i(TAG, "[$label] ECDH session established")
    }

    /** AES-256-GCM decrypt of nonce(12) + ciphertext + tag(16). */
    fun decrypt(ciphertext: ByteArray): ByteArray {
        val key = sessionKey ?: throw IllegalStateException("No session key")
        val nonce = ciphertext.copyOfRange(0, 12)
        val encrypted = ciphertext.copyOfRange(12, ciphertext.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, nonce))
        return cipher.doFinal(encrypted)
    }

    /** AES-256-GCM encrypt, returning nonce(12) + ciphertext + tag(16). */
    fun encrypt(plaintext: ByteArray): ByteArray {
        val key = sessionKey ?: throw IllegalStateException("No session key")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val nonce = cipher.iv
        return nonce + cipher.doFinal(plaintext)
    }

    /** HKDF-SHA256 (RFC 5869), matching CryptoKit's derivation. */
    private fun hkdfSHA256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        val actualSalt = if (salt.isEmpty()) ByteArray(32) else salt
        mac.init(SecretKeySpec(actualSalt, "HmacSHA256"))
        val prk = mac.doFinal(ikm)

        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val result = ByteArray(length)
        var t = byteArrayOf()
        var offset = 0
        var counter: Byte = 1
        while (offset < length) {
            mac.update(t)
            mac.update(info)
            mac.update(counter)
            t = mac.doFinal()
            val toCopy = minOf(t.size, length - offset)
            System.arraycopy(t, 0, result, offset, toCopy)
            offset += toCopy
            counter++
        }
        return result
    }
}
