import Foundation
import CryptoKit

/// Errors during keychain-secret wrapping / unwrapping.
public enum KeychainSecretCryptoError: Error, Sendable {
    case invalidRecipientKey
    case wrapFailed
    case unwrapFailed
}

/// Wraps and unwraps the decoupled random *keychain password* so it can live on
/// the Mac at rest while only a paired phone can turn it back into plaintext.
///
/// Design (an ECIES-style scheme built on the same primitives as `SessionCrypto`):
///
/// - The phone holds a P-256 **key-agreement** key in its Secure Enclave,
///   gated by `.biometryCurrentSet`. Only its public half ever leaves the phone.
/// - At setup the Mac generates an *ephemeral* P-256 key pair, does ECDH against
///   the phone's public key, derives an AES-256 key via HKDF-SHA256, and seals
///   the password with AES-GCM. It stores `{ephemeralPublicKey, ciphertext}` and
///   throws away the ephemeral private key and the plaintext. (`wrap`)
/// - To unlock, the Mac hands the phone the stored ephemeral public key. The
///   phone's Secure Enclave computes the same ECDH shared secret (after a
///   biometric check) and returns it. The Mac re-derives the AES key and opens
///   the box. (`unwrap`)
///
/// The phone performs a *blind* key agreement: it never sees the password and
/// cannot tell what it is helping to decrypt. The plaintext password exists only
/// transiently in the daemon, never on the phone and never on the BLE link in
/// the clear (the shared secret itself travels inside the session-encrypted
/// channel).
///
/// Cross-platform note: `wrap`/`unwrap` here use CryptoKit. The phone produces
/// the raw shared secret with Security.framework
/// `SecKeyCopyKeyExchangeResult(_, .ecdhKeyExchangeStandard, _, _)`, which
/// returns the same P-256 X-coordinate that CryptoKit's
/// `sharedSecretFromKeyAgreement` exposes, so the two interoperate.
public enum KeychainSecretCrypto {
    /// HKDF salt — empty, matching `SessionCrypto`.
    private static let hkdfSalt = Data()
    /// HKDF info — distinct from the session-key derivation so a session key and
    /// a keychain-wrap key can never collide even given the same shared secret.
    private static let hkdfInfo = Data("TouchBridge-keychain-v1".utf8)
    private static let keyByteCount = 32

    /// A password wrapped to a phone's keychain-unlock public key.
    public struct WrappedSecret: Codable, Sendable, Equatable {
        /// X9.63 representation of the Mac's ephemeral public key.
        public let ephemeralPublicKey: Data
        /// AES-256-GCM sealed box (nonce + ciphertext + tag), combined form.
        public let ciphertext: Data

        public init(ephemeralPublicKey: Data, ciphertext: Data) {
            self.ephemeralPublicKey = ephemeralPublicKey
            self.ciphertext = ciphertext
        }
    }

    /// Wrap `secret` so only the holder of the private key matching
    /// `recipientPublicKey` (an X9.63 P-256 public key) can recover it.
    public static func wrap(secret: Data, recipientPublicKey: Data) throws -> WrappedSecret {
        let recipient: P256.KeyAgreement.PublicKey
        do {
            recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey)
        } catch {
            throw KeychainSecretCryptoError.invalidRecipientKey
        }

        let ephemeral = P256.KeyAgreement.PrivateKey()
        do {
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
            let key = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: hkdfSalt,
                sharedInfo: hkdfInfo,
                outputByteCount: keyByteCount
            )
            let box = try AES.GCM.seal(secret, using: key)
            guard let combined = box.combined else {
                throw KeychainSecretCryptoError.wrapFailed
            }
            return WrappedSecret(
                ephemeralPublicKey: ephemeral.publicKey.x963Representation,
                ciphertext: combined
            )
        } catch let error as KeychainSecretCryptoError {
            throw error
        } catch {
            throw KeychainSecretCryptoError.wrapFailed
        }
    }

    /// Unwrap a sealed secret given the raw ECDH shared secret the phone
    /// returned (the P-256 X-coordinate, 32 bytes).
    public static func unwrap(_ wrapped: WrappedSecret, rawSharedSecret: Data) throws -> Data {
        do {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: rawSharedSecret),
                salt: hkdfSalt,
                info: hkdfInfo,
                outputByteCount: keyByteCount
            )
            let box = try AES.GCM.SealedBox(combined: wrapped.ciphertext)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw KeychainSecretCryptoError.unwrapFailed
        }
    }

    /// Compute the raw ECDH shared secret the way the phone's Secure Enclave
    /// does — for the daemon's own tests and for any software-key simulation.
    ///
    /// On a real phone this is `SecKeyCopyKeyExchangeResult`; here it is the
    /// CryptoKit equivalent, so a test can prove `wrap` → `unwrap` round-trips.
    public static func rawSharedSecret(
        recipientPrivateKey: P256.KeyAgreement.PrivateKey,
        ephemeralPublicKey: Data
    ) throws -> Data {
        let ephemeralPublic = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublicKey)
        let shared = try recipientPrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        return shared.withUnsafeBytes { Data($0) }
    }
}
