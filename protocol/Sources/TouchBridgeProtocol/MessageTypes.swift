import Foundation

/// Wire message type identifier — first byte of every message.
public enum MessageType: UInt8, Codable, Sendable {
    case pairRequest = 1
    case pairResponse = 2
    case challengeIssued = 3
    case challengeResponse = 4
    case error = 5
    /// Sent by companion after ECDH to identify itself on reconnect (no pairing required).
    case identify = 6
    /// Companion → Mac: registers this device's biometric-gated keychain-unlock
    /// public key so the Mac can wrap the keychain secret to it. Session-encrypted.
    case keychainEnroll = 7
    /// Mac → companion: asks the phone to perform the blind ECDH that unwraps the
    /// stored keychain secret. Carries the Mac's ephemeral public key. Session-encrypted.
    case keychainUnlockRequest = 8
    /// Companion → Mac: the raw ECDH shared secret the Mac needs to unwrap the
    /// keychain secret. The phone never sees the password itself. Session-encrypted.
    case keychainUnlockResponse = 9
}

// MARK: - Message Payloads

public struct PairRequestMessage: Codable, Sendable {
    public let deviceName: String
    public let publicKey: Data
    /// Companion's stable device identifier — the daemon keys the stored public key
    /// by this ID, and the companion presents it in identify and challenge responses.
    public let deviceID: String?
    /// One-time pairing token from the QR/pairing payload. The daemon rejects
    /// pairing requests whose token doesn't match the active pairing session.
    public let pairingToken: Data?

    public init(deviceName: String, publicKey: Data, deviceID: String? = nil, pairingToken: Data? = nil) {
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.deviceID = deviceID
        self.pairingToken = pairingToken
    }
}

public struct PairResponseMessage: Codable, Sendable {
    public let deviceID: String
    public let publicKey: Data
    public let accepted: Bool

    public init(deviceID: String, publicKey: Data, accepted: Bool) {
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.accepted = accepted
    }
}

public struct ChallengeIssuedMessage: Codable, Sendable {
    public let challengeID: String
    public let encryptedNonce: Data
    public let reason: String
    public let expiryUnix: UInt64

    public init(challengeID: String, encryptedNonce: Data, reason: String, expiryUnix: UInt64) {
        self.challengeID = challengeID
        self.encryptedNonce = encryptedNonce
        self.reason = reason
        self.expiryUnix = expiryUnix
    }
}

public struct ChallengeResponseMessage: Codable, Sendable {
    public let challengeID: String
    public let signature: Data
    public let deviceID: String

    public init(challengeID: String, signature: Data, deviceID: String) {
        self.challengeID = challengeID
        self.signature = signature
        self.deviceID = deviceID
    }
}

public struct ErrorMessage: Codable, Sendable {
    public let code: UInt16
    public let description: String
    /// Challenge this error relates to — allows daemon to resolve a pending auth immediately.
    public let challengeID: String?

    public init(code: UInt16, description: String, challengeID: String? = nil) {
        self.code = code
        self.description = description
        self.challengeID = challengeID
    }
}

/// Sent by companion after ECDH to identify itself without going through full pairing.
/// Allows the daemon to recognise a previously-paired device that reconnected.
public struct IdentifyMessage: Codable, Sendable {
    public let deviceID: String
    public let deviceName: String

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

/// Companion → Mac: registers the biometric-gated keychain-unlock public key.
/// Sent session-encrypted (like `identify`) once the user turns on keychain
/// unlock in the app. The Mac stores `unlockPublicKey` against `deviceID` and
/// later wraps the random keychain password to it.
public struct KeychainEnrollMessage: Codable, Sendable {
    public let deviceID: String
    /// X9.63 (uncompressed, 65-byte) representation of the phone's P-256
    /// key-agreement public key held in its Secure Enclave.
    public let unlockPublicKey: Data

    public init(deviceID: String, unlockPublicKey: Data) {
        self.deviceID = deviceID
        self.unlockPublicKey = unlockPublicKey
    }
}

/// Mac → companion: asks the phone to unwrap the keychain secret. Carries the
/// Mac's ephemeral public key from enrollment; the phone completes the ECDH.
/// Sent session-encrypted.
public struct KeychainUnlockRequestMessage: Codable, Sendable {
    public let requestID: String
    /// X9.63 representation of the Mac's ephemeral public key stored at setup.
    public let ephemeralPublicKey: Data
    /// Human-readable text shown on the phone (e.g. "unlock your Mac keychain").
    public let reason: String

    public init(requestID: String, ephemeralPublicKey: Data, reason: String) {
        self.requestID = requestID
        self.ephemeralPublicKey = ephemeralPublicKey
        self.reason = reason
    }
}

/// Companion → Mac: the raw ECDH shared secret (P-256 X-coordinate) that lets
/// the Mac derive the AES key and unwrap the keychain secret. The phone computes
/// this with its Secure-Enclave key after a biometric check; it never learns the
/// password. Sent session-encrypted.
public struct KeychainUnlockResponseMessage: Codable, Sendable {
    public let requestID: String
    public let sharedSecret: Data

    public init(requestID: String, sharedSecret: Data) {
        self.requestID = requestID
        self.sharedSecret = sharedSecret
    }
}

/// Well-known error codes sent from companion to daemon.
public enum ErrorCode: UInt16, Sendable {
    /// Secure Enclave key was invalidated — biometric enrollment changed since pairing.
    case keyInvalidated = 1001
    /// Companion has no keychain-unlock key (enrollment was removed on the phone).
    case keychainKeyMissing = 1002
}
