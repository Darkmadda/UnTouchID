import Foundation
import OSLog
import Security

// `SecKeychainChangePassword` still ships in the Security dylib but Apple pulled
// its declaration from the public headers, so it isn't visible to Swift. Bind
// the symbol directly — it is the only supported way to re-key a *file*
// keychain such as the login keychain without exposing the password on argv.
@_silgen_name("SecKeychainChangePassword")
private func _SecKeychainChangePassword(
    _ keychain: SecKeychain?,
    _ oldPasswordLength: UInt32,
    _ oldPassword: UnsafeRawPointer?,
    _ newPasswordLength: UInt32,
    _ newPassword: UnsafeRawPointer?
) -> OSStatus

/// Abstraction over the login-keychain operations, so the coordinator and the
/// setup CLI can be unit-tested with a mock instead of touching a real keychain.
public protocol KeychainUnlocking: Sendable {
    /// Whether the keychain at `path` is currently locked.
    func isLocked(path: String) throws -> Bool
    /// The *usable* lock state of the keychain at `path`. Unlike `isLocked`,
    /// this detects a keychain that securityd reports as unlocked but whose
    /// cached key no longer decrypts the file (`.stale`).
    func lockState(path: String) throws -> KeychainLockState
    /// Lock the keychain at `path`, discarding securityd's cached key.
    func lock(path: String) throws
    /// Unlock the keychain at `path` with `password`.
    func unlock(path: String, password: String) throws
    /// Change the keychain password at `path` from `oldPassword` to `newPassword`.
    func changePassword(path: String, oldPassword: String, newPassword: String) throws
}

/// Lock state of a file keychain as seen by callers that need to *use* it.
public enum KeychainLockState: Sendable, Equatable {
    /// Locked — needs a password to unlock.
    case locked
    /// Unlocked and actually usable (items can be read and written).
    case unlocked
    /// securityd says "unlocked", but its cached master key no longer decrypts
    /// the keychain file, so every read/write fails with errSecAuthFailed
    /// ("The user name or passphrase you entered is not correct"). Typically
    /// the file was re-keyed or replaced while the old unlock stayed cached.
    /// Recovery: lock (drop the stale key), then unlock with the password.
    case stale
}

public enum KeychainUnlockerError: Error, Sendable, Equatable {
    case openFailed(OSStatus)
    case unlockFailed(OSStatus)
    case lockFailed(OSStatus)
    case statusFailed(OSStatus)
    case changePasswordFailed(OSStatus)
}

/// The default login-keychain path for the current user.
public func defaultLoginKeychainPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Keychains/login.keychain-db")
        .path
}

/// Real implementation using the `SecKeychain*` C API.
///
/// These APIs are deprecated in favour of the data-protection keychain, but they
/// remain the only way to programmatically unlock or re-key a *file* keychain
/// such as the login keychain — which is exactly what this feature needs. The
/// deprecation is suppressed deliberately.
public struct SystemKeychainUnlocker: KeychainUnlocking {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "KeychainUnlocker")

    public init() {}

    @available(macOS, deprecated: 10.10)
    private func open(_ path: String) throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess, let keychain else {
            throw KeychainUnlockerError.openFailed(status)
        }
        return keychain
    }

    @available(macOS, deprecated: 10.10)
    public func isLocked(path: String) throws -> Bool {
        let keychain = try open(path)
        var status: SecKeychainStatus = 0
        let result = SecKeychainGetStatus(keychain, &status)
        guard result == errSecSuccess else {
            throw KeychainUnlockerError.statusFailed(result)
        }
        // kSecUnlockStateStatus is set when the keychain is unlocked.
        return (status & UInt32(kSecUnlockStateStatus)) == 0
    }

    /// `SecKeychainGetStatus` only reports securityd's cached flag, which stays
    /// "unlocked" even when the cached key can't decrypt the file any more. So
    /// when it says unlocked, confirm with `SecKeychainCopySettings`, which
    /// needs the real key and fails with errSecAuthFailed in the stale case —
    /// without reading or writing any item. User interaction is disabled for
    /// the probe so it can never pop a password dialog.
    @available(macOS, deprecated: 10.10)
    public func lockState(path: String) throws -> KeychainLockState {
        if try isLocked(path: path) { return .locked }
        let keychain = try open(path)

        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }

        var settings = SecKeychainSettings()
        settings.version = 1 // SEC_KEYCHAIN_SETTINGS_VERS1
        let status = SecKeychainCopySettings(keychain, &settings)
        switch status {
        case errSecSuccess:
            return .unlocked
        case errSecAuthFailed:
            logger.warning("Keychain reports unlocked but its cached key is stale (errSecAuthFailed)")
            return .stale
        case errSecInteractionNotAllowed:
            // Locked between the two calls.
            return .locked
        default:
            // Unknown probe failure: don't disrupt a keychain that may be fine.
            logger.warning("Keychain settings probe failed (\(status)); assuming unlocked")
            return .unlocked
        }
    }

    @available(macOS, deprecated: 10.10)
    public func lock(path: String) throws {
        let keychain = try open(path)
        let status = SecKeychainLock(keychain)
        guard status == errSecSuccess else {
            throw KeychainUnlockerError.lockFailed(status)
        }
    }

    @available(macOS, deprecated: 10.10)
    public func unlock(path: String, password: String) throws {
        let keychain = try open(path)
        var pw = Array(password.utf8)
        defer { for i in pw.indices { pw[i] = 0 } }
        let status = pw.withUnsafeBytes { buf in
            SecKeychainUnlock(keychain, UInt32(buf.count), buf.baseAddress, true)
        }
        guard status == errSecSuccess else {
            throw KeychainUnlockerError.unlockFailed(status)
        }
    }

    @available(macOS, deprecated: 10.10)
    public func changePassword(path: String, oldPassword: String, newPassword: String) throws {
        let keychain = try open(path)
        var oldPW = Array(oldPassword.utf8)
        var newPW = Array(newPassword.utf8)
        defer {
            for i in oldPW.indices { oldPW[i] = 0 }
            for i in newPW.indices { newPW[i] = 0 }
        }
        let status = oldPW.withUnsafeBytes { oldBuf in
            newPW.withUnsafeBytes { newBuf in
                _SecKeychainChangePassword(
                    keychain,
                    UInt32(oldBuf.count), oldBuf.baseAddress,
                    UInt32(newBuf.count), newBuf.baseAddress
                )
            }
        }
        guard status == errSecSuccess else {
            throw KeychainUnlockerError.changePasswordFailed(status)
        }
    }
}
