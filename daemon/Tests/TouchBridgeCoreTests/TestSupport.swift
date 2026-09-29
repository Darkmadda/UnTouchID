import Foundation
@testable import TouchBridgeCore

/// A paired-device store backed by a fresh temp file, so parallel tests never share state.
func makeTempDeviceStore() -> PairedDeviceStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-store-\(UUID().uuidString)", isDirectory: true)
    return PairedDeviceStore(fileURL: dir.appendingPathComponent(PairedDeviceStore.filename))
}

/// A keychain-unlock store backed by a fresh temp file.
func makeTempKeychainStore() -> KeychainSecretStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-kc-\(UUID().uuidString)", isDirectory: true)
    return KeychainSecretStore(fileURL: dir.appendingPathComponent(KeychainSecretStore.filename))
}

/// In-memory `KeychainUnlocking` so coordinator tests never touch a real keychain.
final class MockKeychainUnlocker: KeychainUnlocking, @unchecked Sendable {
    private let mu = NSLock()
    private var _locked: Bool
    /// Passwords passed to `unlock`, in order.
    private(set) var unlockedWith: [String] = []
    /// (old, new) pairs passed to `changePassword`.
    private(set) var changeCalls: [(old: String, new: String)] = []
    /// When true, `unlock` throws instead of succeeding.
    var failUnlock = false
    /// "Unlocked" per securityd, but the cached key can't decrypt the file.
    private var _stale = false
    /// Number of `lock` calls.
    private(set) var lockCalls = 0

    init(locked: Bool = true) { _locked = locked }

    var isLockedNow: Bool { mu.withLock { _locked } }

    func setLocked(_ value: Bool) { mu.withLock { _locked = value } }

    func setStale(_ value: Bool) { mu.withLock { _stale = value } }

    func isLocked(path: String) throws -> Bool { mu.withLock { _locked } }

    func lockState(path: String) throws -> KeychainLockState {
        mu.withLock { _locked ? .locked : (_stale ? .stale : .unlocked) }
    }

    func lock(path: String) throws {
        mu.withLock { _locked = true; _stale = false; lockCalls += 1 }
    }

    func unlock(path: String, password: String) throws {
        if failUnlock { throw KeychainUnlockerError.unlockFailed(-1) }
        mu.withLock { _locked = false; unlockedWith.append(password) }
    }

    func changePassword(path: String, oldPassword: String, newPassword: String) throws {
        mu.withLock { changeCalls.append((oldPassword, newPassword)); _locked = false }
    }
}
