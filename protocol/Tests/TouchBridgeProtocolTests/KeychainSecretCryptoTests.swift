import XCTest
import CryptoKit
@testable import TouchBridgeProtocol

final class KeychainSecretCryptoTests: XCTestCase {

    /// The core guarantee: a secret wrapped to a phone's public key round-trips
    /// when unwrapped with the raw ECDH shared secret the phone's private key
    /// produces. This also proves the HKDF derivations on both paths agree.
    func testWrapUnwrapRoundTrip() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let secret = Data("correct horse battery staple".utf8)

        let wrapped = try KeychainSecretCrypto.wrap(
            secret: secret,
            recipientPublicKey: phoneKey.publicKey.x963Representation
        )

        let raw = try KeychainSecretCrypto.rawSharedSecret(
            recipientPrivateKey: phoneKey,
            ephemeralPublicKey: wrapped.ephemeralPublicKey
        )
        let recovered = try KeychainSecretCrypto.unwrap(wrapped, rawSharedSecret: raw)

        XCTAssertEqual(recovered, secret)
    }

    /// A different phone key must not be able to unwrap.
    func testWrongKeyFailsToUnwrap() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let attackerKey = P256.KeyAgreement.PrivateKey()
        let secret = Data("s3cr3t".utf8)

        let wrapped = try KeychainSecretCrypto.wrap(
            secret: secret,
            recipientPublicKey: phoneKey.publicKey.x963Representation
        )

        let wrongRaw = try KeychainSecretCrypto.rawSharedSecret(
            recipientPrivateKey: attackerKey,
            ephemeralPublicKey: wrapped.ephemeralPublicKey
        )

        XCTAssertThrowsError(try KeychainSecretCrypto.unwrap(wrapped, rawSharedSecret: wrongRaw))
    }

    /// Each wrap uses a fresh ephemeral key, so wrapping the same secret twice
    /// yields different ciphertext and different ephemeral public keys.
    func testWrapIsNonDeterministic() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let secret = Data("same".utf8)

        let a = try KeychainSecretCrypto.wrap(secret: secret, recipientPublicKey: phoneKey.publicKey.x963Representation)
        let b = try KeychainSecretCrypto.wrap(secret: secret, recipientPublicKey: phoneKey.publicKey.x963Representation)

        XCTAssertNotEqual(a.ephemeralPublicKey, b.ephemeralPublicKey)
        XCTAssertNotEqual(a.ciphertext, b.ciphertext)

        // Both still recover the same secret.
        let ra = try KeychainSecretCrypto.rawSharedSecret(recipientPrivateKey: phoneKey, ephemeralPublicKey: a.ephemeralPublicKey)
        let rb = try KeychainSecretCrypto.rawSharedSecret(recipientPrivateKey: phoneKey, ephemeralPublicKey: b.ephemeralPublicKey)
        XCTAssertEqual(try KeychainSecretCrypto.unwrap(a, rawSharedSecret: ra), secret)
        XCTAssertEqual(try KeychainSecretCrypto.unwrap(b, rawSharedSecret: rb), secret)
    }

    /// A tampered ciphertext must fail the GCM tag check.
    func testTamperedCiphertextFails() throws {
        let phoneKey = P256.KeyAgreement.PrivateKey()
        let wrapped = try KeychainSecretCrypto.wrap(
            secret: Data("hello".utf8),
            recipientPublicKey: phoneKey.publicKey.x963Representation
        )

        var bad = wrapped.ciphertext
        bad[bad.index(bad.endIndex, offsetBy: -1)] ^= 0xFF
        let tampered = KeychainSecretCrypto.WrappedSecret(
            ephemeralPublicKey: wrapped.ephemeralPublicKey,
            ciphertext: bad
        )

        let raw = try KeychainSecretCrypto.rawSharedSecret(
            recipientPrivateKey: phoneKey,
            ephemeralPublicKey: wrapped.ephemeralPublicKey
        )
        XCTAssertThrowsError(try KeychainSecretCrypto.unwrap(tampered, rawSharedSecret: raw))
    }

    /// A public key that predates enrollment (garbage bytes) is rejected cleanly.
    func testInvalidRecipientKeyThrows() {
        XCTAssertThrowsError(
            try KeychainSecretCrypto.wrap(secret: Data("x".utf8), recipientPublicKey: Data([0x00, 0x01, 0x02]))
        ) { error in
            XCTAssertEqual(error as? KeychainSecretCryptoError, .invalidRecipientKey)
        }
    }
}
