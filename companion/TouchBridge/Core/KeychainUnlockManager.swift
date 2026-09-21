import Foundation
import Security
import LocalAuthentication

/// Errors from keychain-unlock key-agreement operations.
public enum KeyAgreementError: Error, Sendable {
    case keyGenerationFailed(String)
    case keyNotFound
    case publicKeyExportFailed(String)
    case keyExchangeFailed(String)
    /// Key was invalidated because biometric enrollment changed since enrollment.
    case keyInvalidated
    case accessControlCreationFailed
    case peerKeyInvalid
}

/// Provides the phone side of "unlock the Mac's keychain": a dedicated,
/// biometric-gated P-256 **key-agreement** key in the Secure Enclave, kept
/// separate from the signing key. It never signs and never decrypts a password
/// — it only performs a blind ECDH whose result the Mac uses to unwrap the
/// keychain secret. The private key never leaves the Secure Enclave.
public protocol KeyAgreementProvider: Sendable {
    /// Create (or replace) the key-agreement key and return its X9.63 public key.
    func generateKeyPair(tag: String) throws -> Data
    /// Return the X9.63 public key for an existing key, or throw if none.
    func publicKey(for tag: String) throws -> Data
    /// Whether a key with this tag exists.
    func hasKey(tag: String) -> Bool
    /// Delete the key.
    func deleteKey(tag: String) throws
    /// Perform ECDH with the Mac's ephemeral public key (X9.63) and return the
    /// raw shared secret (P-256 X-coordinate). Triggers a biometric prompt.
    /// `reason` is shown on that prompt.
    func sharedSecret(tag: String, peerPublicKeyX963: Data, reason: String) throws -> Data
}

/// Real Secure Enclave implementation.
public final class SecureEnclaveKeyAgreement: KeyAgreementProvider, @unchecked Sendable {
    public init() {}

    public func generateKeyPair(tag: String) throws -> Data {
        try? deleteKey(tag: tag)

        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            nil
        ) else {
            throw KeyAgreementError.accessControlCreationFailed
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessControl as String: accessControl,
            ] as [String: Any],
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw KeyAgreementError.keyGenerationFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return try exportPublicKey(privateKey)
    }

    public func publicKey(for tag: String) throws -> Data {
        let privateKey = try retrievePrivateKey(tag: tag, reason: nil)
        return try exportPublicKey(privateKey)
    }

    public func hasKey(tag: String) -> Bool {
        (try? retrievePrivateKey(tag: tag, reason: nil)) != nil
    }

    public func deleteKey(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyAgreementError.keyExchangeFailed("delete failed: \(status)")
        }
    }

    public func sharedSecret(tag: String, peerPublicKeyX963: Data, reason: String) throws -> Data {
        let privateKey = try retrievePrivateKey(tag: tag, reason: reason)

        let peerAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let peerKey = SecKeyCreateWithData(peerPublicKeyX963 as CFData, peerAttrs as CFDictionary, &error) else {
            throw KeyAgreementError.peerKeyInvalid
        }

        guard let shared = SecKeyCopyKeyExchangeResult(
            privateKey,
            .ecdhKeyExchangeStandard,
            peerKey,
            [:] as CFDictionary,
            &error
        ) as Data? else {
            let cfError = error?.takeRetainedValue()
            let desc = cfError?.localizedDescription ?? "unknown"
            let code = cfError.map { CFErrorGetCode($0) } ?? 0
            let lower = desc.lowercased()
            if code == -25293 || lower.contains("biometry") || lower.contains("invalidat") || lower.contains("acl") {
                throw KeyAgreementError.keyInvalidated
            }
            throw KeyAgreementError.keyExchangeFailed(desc)
        }
        return shared
    }

    // MARK: - Private

    private func exportPublicKey(_ privateKey: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(privateKey) else {
            throw KeyAgreementError.publicKeyExportFailed("no public key")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw KeyAgreementError.publicKeyExportFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return data
    }

    private func retrievePrivateKey(tag: String, reason: String?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        // Shown on the biometric sheet when the key is actually used.
        if let reason { query[kSecUseOperationPrompt as String] = reason }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result else {
            throw KeyAgreementError.keyNotFound
        }
        // swiftlint:disable:next force_cast
        return result as! SecKey
    }
}

/// Software fallback for the simulator (no Secure Enclave). No biometric gate.
public final class MockKeyAgreementProvider: KeyAgreementProvider, @unchecked Sendable {
    private var keys: [String: SecKey] = [:]
    public init() {}

    public func generateKeyPair(tag: String) throws -> Data {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw KeyAgreementError.keyGenerationFailed("mock")
        }
        keys[tag] = priv
        return try export(priv)
    }

    public func publicKey(for tag: String) throws -> Data {
        guard let priv = keys[tag] else { throw KeyAgreementError.keyNotFound }
        return try export(priv)
    }

    public func hasKey(tag: String) -> Bool { keys[tag] != nil }

    public func deleteKey(tag: String) throws { keys.removeValue(forKey: tag) }

    public func sharedSecret(tag: String, peerPublicKeyX963: Data, reason: String) throws -> Data {
        guard let priv = keys[tag] else { throw KeyAgreementError.keyNotFound }
        let peerAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let peer = SecKeyCreateWithData(peerPublicKeyX963 as CFData, peerAttrs as CFDictionary, &error) else {
            throw KeyAgreementError.peerKeyInvalid
        }
        guard let shared = SecKeyCopyKeyExchangeResult(priv, .ecdhKeyExchangeStandard, peer, [:] as CFDictionary, &error) as Data? else {
            throw KeyAgreementError.keyExchangeFailed("mock")
        }
        return shared
    }

    private func export(_ priv: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(priv) else { throw KeyAgreementError.publicKeyExportFailed("mock") }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw KeyAgreementError.publicKeyExportFailed("mock")
        }
        return data
    }
}
