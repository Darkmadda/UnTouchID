import Foundation
import OSLog
import TouchBridgeProtocol

/// One paired phone's keychain-unlock enrollment.
///
/// `unlockPublicKey` is pushed by the phone when the user turns on keychain
/// unlock. `wrapped` is filled in later by `keychain-setup` on the Mac, once the
/// user has captured the random keychain password: it is the random password
/// sealed to *this* phone's key. Every enrolled phone gets its own `wrapped`
/// copy of the same password, so losing one phone never strands the keychain as
/// long as another enrolled phone remains.
public struct KeychainEnrollment: Codable, Sendable, Equatable {
    public let deviceID: String
    public var displayName: String
    /// X9.63 P-256 key-agreement public key from the phone's Secure Enclave.
    public var unlockPublicKey: Data
    /// The random keychain password sealed to `unlockPublicKey`, or nil until
    /// `keychain-setup` has run.
    public var wrapped: KeychainSecretCrypto.WrappedSecret?
    public var enrolledAt: Date

    public init(
        deviceID: String,
        displayName: String,
        unlockPublicKey: Data,
        wrapped: KeychainSecretCrypto.WrappedSecret? = nil,
        enrolledAt: Date = Date()
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.unlockPublicKey = unlockPublicKey
        self.wrapped = wrapped
        self.enrolledAt = enrolledAt
    }
}

/// Persists keychain-unlock state in
/// `~/Library/Application Support/TouchBridge/keychain-unlock.json` (mode 0600).
///
/// What is and isn't secret here: `unlockPublicKey` is a public key, and
/// `wrapped` is the random keychain password sealed so that *only a paired
/// phone's Secure Enclave* can turn it back into plaintext. Reading this file
/// alone reveals nothing usable — the same trust boundary as `PairedDeviceStore`.
/// The actual account password is never stored; the keychain is re-keyed to a
/// random value at setup (`keychain-setup`) which the user also saves in their
/// password manager as the ultimate recovery path.
///
/// Like `PairedDeviceStore`, the file is re-read on every call so the daemon and
/// the `touchbridge-test` CLI see each other's writes without a restart, and
/// writes are atomic (temp file + rename).
public struct KeychainSecretStore: Sendable {
    private static let logger = Logger(subsystem: "dev.touchbridge", category: "KeychainSecretStore")
    public static let filename = "keychain-unlock.json"

    public let fileURL: URL

    struct Stored: Codable {
        var version: Int = 1
        /// Master opt-in. False until `keychain-setup` completes; the daemon does
        /// nothing keychain-related while this is false.
        var enabled: Bool = false
        /// Absolute path of the login keychain this applies to.
        var keychainPath: String?
        /// Enrollments keyed by deviceID.
        var enrollments: [String: KeychainEnrollment] = [:]
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The store every TouchBridge binary on this Mac shares.
    public static func standard() -> KeychainSecretStore {
        KeychainSecretStore(fileURL: TouchBridgePaths.supportDirectory.appendingPathComponent(filename))
    }

    // MARK: - Reads

    /// Whether keychain unlock is switched on *and* at least one phone has a
    /// wrapped copy of the password ready to unlock with.
    public func isActive() -> Bool {
        guard let stored = try? load() else { return false }
        return stored.enabled && stored.enrollments.values.contains { $0.wrapped != nil }
    }

    /// The login keychain path recorded at setup, if any.
    public func keychainPath() -> String? {
        (try? load())?.keychainPath
    }

    /// The wrapped secret for a specific device, if it is enrolled and set up.
    public func wrappedSecret(forDeviceID deviceID: String) -> KeychainSecretCrypto.WrappedSecret? {
        guard let stored = try? load() else { return nil }
        return stored.enrollments[deviceID]?.wrapped
    }

    /// All enrollments (for CLI status / setup).
    public func enrollments() throws -> [KeychainEnrollment] {
        Array(try load().enrollments.values).sorted { $0.enrolledAt < $1.enrolledAt }
    }

    public func isEnabled() -> Bool {
        (try? load())?.enabled ?? false
    }

    // MARK: - Writes

    /// Record (or refresh) a phone's unlock public key. Called by the daemon when
    /// a phone sends a `keychainEnroll` message. Preserves any existing `wrapped`
    /// copy *if* the public key is unchanged; a changed key (phone re-enrolled)
    /// clears the stale wrap so setup must re-run for that device.
    public func upsertEnrollment(deviceID: String, displayName: String, unlockPublicKey: Data) throws {
        var stored = try load()
        if var existing = stored.enrollments[deviceID] {
            if existing.unlockPublicKey != unlockPublicKey {
                existing.unlockPublicKey = unlockPublicKey
                existing.wrapped = nil // stale — must be re-wrapped
            }
            existing.displayName = displayName
            stored.enrollments[deviceID] = existing
        } else {
            stored.enrollments[deviceID] = KeychainEnrollment(
                deviceID: deviceID,
                displayName: displayName,
                unlockPublicKey: unlockPublicKey
            )
        }
        try save(stored)
    }

    /// Store the wrapped password for a device and mark the feature enabled.
    /// Called by `keychain-setup` after it re-keys the keychain.
    public func setWrappedSecret(
        forDeviceID deviceID: String,
        wrapped: KeychainSecretCrypto.WrappedSecret,
        keychainPath: String
    ) throws {
        var stored = try load()
        guard var enrollment = stored.enrollments[deviceID] else {
            throw KeychainSecretStoreError.deviceNotEnrolled(deviceID)
        }
        enrollment.wrapped = wrapped
        stored.enrollments[deviceID] = enrollment
        stored.keychainPath = keychainPath
        stored.enabled = true
        try save(stored)
    }

    /// Remove a single device's enrollment (e.g. phone lost / unpaired).
    public func removeEnrollment(deviceID: String) throws {
        var stored = try load()
        stored.enrollments.removeValue(forKey: deviceID)
        if !stored.enrollments.values.contains(where: { $0.wrapped != nil }) {
            stored.enabled = false
        }
        try save(stored)
    }

    /// Turn the feature off and forget every wrapped secret. Does *not* re-key
    /// the keychain — the caller (`keychain-recover`) handles that first.
    public func disableAndClear() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File I/O

    func load() throws -> Stored {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return Stored()
        }
        do {
            return try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            throw KeychainSecretStoreError.corruptStore(fileURL.path, error.localizedDescription)
        }
    }

    private func save(_ stored: Stored) throws {
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(stored)
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            guard rename(tmp.path, fileURL.path) == 0 else {
                throw KeychainSecretStoreError.writeFailed(String(cString: strerror(errno)))
            }
        } catch let error as KeychainSecretStoreError {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw KeychainSecretStoreError.writeFailed(error.localizedDescription)
        }
    }
}

public enum KeychainSecretStoreError: Error, Sendable, Equatable {
    case deviceNotEnrolled(String)
    case corruptStore(String, String)
    case writeFailed(String)
}
