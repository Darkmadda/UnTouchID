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
    /// Unlock the keychain at `path` with `password`.
    func unlock(path: String, password: String) throws
    /// Change the keychain password at `path` from `oldPassword` to `newPassword`.
    func changePassword(path: String, oldPassword: String, newPassword: String) throws
}

public enum KeychainUnlockerError: Error, Sendable, Equatable {
    case openFailed(OSStatus)
    case unlockFailed(OSStatus)
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
