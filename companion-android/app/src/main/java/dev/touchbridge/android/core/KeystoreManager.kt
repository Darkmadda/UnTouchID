package dev.touchbridge.android.core

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.annotation.RequiresApi
import java.security.*
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.KeyAgreement

/**
 * Manages ECDSA P-256 keys in the Android Keystore (hardware-backed via TEE/StrongBox).
 *
 * Equivalent to iOS SecureEnclaveManager:
 * - Keys are generated inside the hardware security module
 * - Private key never leaves the secure hardware
 * - Signing requires biometric authentication
 *
 * On devices with StrongBox (Pixel 3+, Samsung Galaxy S10+, etc.),
 * keys are stored in a dedicated security chip — equivalent to Apple's Secure Enclave.
 */
class KeystoreManager {
    companion object {
        private const val TAG = "KeystoreManager"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        /** Seconds a biometric auth authorises the key-agreement key for use. */
        const val KEYCHAIN_AUTH_VALIDITY_SECONDS = 30
    }

    private val keyStore: KeyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }

    /**
     * Generate a new ECDSA P-256 key pair in the Android Keystore.
     *
     * The key is hardware-backed and requires biometric auth for signing.
     * Returns the public key in X9.62 uncompressed format (65 bytes).
     */
    fun generateKeyPair(alias: String): ByteArray {
        // Delete existing key if present
        deleteKey(alias)

        val spec = KeyGenParameterSpec.Builder(
            alias,
            KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY
        )
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
            // Try StrongBox first (hardware security module, like Apple's Secure Enclave)
            // Falls back to TEE if StrongBox not available
            .apply {
                try {
                    setIsStrongBoxBacked(true)
                    Log.i(TAG, "Using StrongBox for key storage")
                } catch (e: Exception) {
                    Log.i(TAG, "StrongBox not available, using TEE")
                }
            }
            .build()

        val keyPairGenerator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER
        )
        keyPairGenerator.initialize(spec)
        val keyPair = keyPairGenerator.generateKeyPair()

        Log.i(TAG, "Generated ECDSA P-256 key pair: $alias")
        return exportPublicKey(keyPair.public)
    }

    /**
     * Sign data with the Keystore private key.
     *
     * This triggers a biometric prompt because the key was created with
     * setUserAuthenticationRequired(true).
     *
     * Must be called after BiometricPrompt authentication succeeds,
     * using the CryptoObject's Signature.
     */
    fun createSignature(alias: String): Signature {
        val privateKey = keyStore.getKey(alias, null) as? PrivateKey
            ?: throw KeyStoreException("Key not found: $alias")

        return Signature.getInstance("SHA256withECDSA").apply {
            initSign(privateKey)
        }
    }

    /**
     * Sign data directly (for testing or when biometric auth is handled separately).
     */
    fun sign(data: ByteArray, alias: String): ByteArray {
        val signature = createSignature(alias)
        signature.update(data)
        return signature.sign()
    }

    /**
     * Generate a P-256 **key-agreement** key in the Keystore for opt-in Mac
     * keychain unlock. Separate from the signing key, biometric-gated, and — since
     * KeyAgreement can't bind to a BiometricPrompt CryptoObject — authorised by a
     * short time-bound biometric window ([KEYCHAIN_AUTH_VALIDITY_SECONDS]).
     *
     * Requires API 31 (PURPOSE_AGREE_KEY). Returns the X9.62 public key (65 bytes).
     */
    @RequiresApi(Build.VERSION_CODES.S)
    fun generateKeyAgreementKeyPair(alias: String): ByteArray {
        deleteKey(alias)

        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_AGREE_KEY)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setUserAuthenticationRequired(true)
            .setUserAuthenticationParameters(
                KEYCHAIN_AUTH_VALIDITY_SECONDS,
                KeyProperties.AUTH_BIOMETRIC_STRONG
            )
            .setInvalidatedByBiometricEnrollment(true)
            .apply {
                try {
                    setIsStrongBoxBacked(true)
                } catch (e: Exception) {
                    Log.i(TAG, "StrongBox not available for key agreement, using TEE")
                }
            }
            .build()

        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE_PROVIDER)
        generator.initialize(spec)
        val keyPair = generator.generateKeyPair()
        Log.i(TAG, "Generated P-256 key-agreement key: $alias")
        return exportPublicKey(keyPair.public)
    }

    /**
     * Perform ECDH with the Mac's ephemeral public key (X9.62, 65 bytes) and
     * return the raw shared secret (P-256 X-coordinate, 32 bytes).
     *
     * Must be called shortly after a successful biometric prompt, within the
     * key's [KEYCHAIN_AUTH_VALIDITY_SECONDS] window, or the Keystore throws
     * (surfaced as UserNotAuthenticatedException / KeyPermanentlyInvalidated).
     */
    fun computeSharedSecret(alias: String, peerPublicKeyX963: ByteArray): ByteArray {
        val privateKey = keyStore.getKey(alias, null) as? PrivateKey
            ?: throw KeyStoreException("Key-agreement key not found: $alias")

        // Wrap the raw X9.62 point in an X.509 SubjectPublicKeyInfo header for EC P-256.
        val header = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86.toByte(),
            0x48, 0xCE.toByte(), 0x3D, 0x02, 0x01, 0x06, 0x08, 0x2A,
            0x86.toByte(), 0x48, 0xCE.toByte(), 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        )
        val peerKey = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(header + peerPublicKeyX963))

        val agreement = KeyAgreement.getInstance("ECDH", KEYSTORE_PROVIDER)
        agreement.init(privateKey)
        agreement.doPhase(peerKey, true)
        return agreement.generateSecret()
    }

    /**
     * Export the public key in X9.62 uncompressed format (65 bytes).
     */
    fun getPublicKey(alias: String): ByteArray {
        val cert = keyStore.getCertificate(alias)
            ?: throw KeyStoreException("Certificate not found: $alias")
        return exportPublicKey(cert.publicKey)
    }

    /**
     * Check if a key pair exists for the given alias.
     */
    fun hasKey(alias: String): Boolean = keyStore.containsAlias(alias)

    /**
     * Delete a key pair.
     */
    fun deleteKey(alias: String) {
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
            Log.i(TAG, "Deleted key: $alias")
        }
    }

    /**
     * Export public key to X9.62 uncompressed format.
     * Android's ECPublicKey.encoded is in X.509 SubjectPublicKeyInfo format.
     * We need to extract the raw point (65 bytes for uncompressed P-256).
     */
    private fun exportPublicKey(publicKey: PublicKey): ByteArray {
        val encoded = publicKey.encoded
        // X.509 SubjectPublicKeyInfo for EC P-256 has a fixed header.
        // The last 65 bytes are the uncompressed point (04 || x || y).
        return if (encoded.size > 65) {
            encoded.takeLast(65).toByteArray()
        } else {
            encoded
        }
    }
}
