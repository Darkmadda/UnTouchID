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
    private let lock = NSLock()
    private var _locked: Bool
    /// Passwords passed to `unlock`, in order.
    private(set) var unlockedWith: [String] = []
    /// (old, new) pairs passed to `changePassword`.
    private(set) var changeCalls: [(old: String, new: String)] = []
    /// When true, `unlock` throws instead of succeeding.
    var failUnlock = false

    init(locked: Bool = true) { _locked = locked }

    var isLockedNow: Bool { lock.withLock { _locked } }

    func setLocked(_ value: Bool) { lock.withLock { _locked = value } }

    func isLocked(path: String) throws -> Bool { lock.withLock { _locked } }

    func unlock(path: String, password: String) throws {
        if failUnlock { throw KeychainUnlockerError.unlockFailed(-1) }
        lock.withLock { _locked = false; unlockedWith.append(password) }
    }

    func changePassword(path: String, oldPassword: String, newPassword: String) throws {
        lock.withLock { changeCalls.append((oldPassword, newPassword)); _locked = false }
    }
}
