import Testing
import Foundation
import Security
@testable import TouchBridgeCore

/// Each test gets its own Keychain service to avoid parallel test interference.
private func makeStore() -> PairedDeviceStore {
    makeTempDeviceStore()
}

private func makeDevice(id: String = "test-device-1", name: String = "Test iPhone") -> PairedDevice {
    let attributes: [String: Any] = [
        kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeySizeInBits as String: 256,
    ]
    var error: Unmanaged<CFError>?
    let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error)!
    let publicKey = SecKeyCopyPublicKey(privateKey)!
    let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error)! as Data

    return PairedDevice(
        deviceID: id,
        publicKey: publicKeyData,
        displayName: name,
        pairedAt: Date()
    )
}

// MARK: - Tests

@Test func storeAndRetrieve() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)

    let retrieved = try store.retrievePairedDevice(deviceID: device.deviceID)
    #expect(retrieved.deviceID == device.deviceID)
    #expect(retrieved.publicKey == device.publicKey)
    #expect(retrieved.displayName == device.displayName)
}

@Test func storeOverwritesExisting() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device1 = makeDevice(id: "same-id", name: "First")
    try store.storePairedDevice(device1)

    let device2 = makeDevice(id: "same-id", name: "Second")
    try store.storePairedDevice(device2)

    let retrieved = try store.retrievePairedDevice(deviceID: "same-id")
    #expect(retrieved.displayName == "Second")
}

@Test func retrieveNonexistentThrows() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    #expect(throws: PairedDeviceStoreError.self) {
        try store.retrievePairedDevice(deviceID: "nonexistent")
    }
}

@Test func listDevices() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device1 = makeDevice(id: "device-a", name: "iPhone A")
    let device2 = makeDevice(id: "device-b", name: "iPhone B")
    try store.storePairedDevice(device1)
    try store.storePairedDevice(device2)

    let devices = try store.listPairedDevices()
    #expect(devices.count == 2)

    let ids = Set(devices.map(\.deviceID))
    #expect(ids.contains("device-a"))
    #expect(ids.contains("device-b"))
}

@Test func listDevicesEmptyReturnsEmptyArray() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let devices = try store.listPairedDevices()
    #expect(devices.isEmpty)
}

@Test func removeDevice() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)
    try store.removePairedDevice(deviceID: device.deviceID)

    #expect(throws: PairedDeviceStoreError.self) {
        try store.retrievePairedDevice(deviceID: device.deviceID)
    }
}

@Test func removeNonexistentDoesNotThrow() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    try store.removePairedDevice(deviceID: "does-not-exist")
}

@Test func retrievePublicKeyReconstructsSecKey() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    let device = makeDevice()
    try store.storePairedDevice(device)

    let key = try store.retrievePublicKey(for: device.deviceID)

    let attributes = SecKeyCopyAttributes(key) as? [String: Any]
    let keyType = attributes?[kSecAttrKeyType as String] as? String
    #expect(keyType == kSecAttrKeyTypeECSECPrimeRandom as String)
}

// MARK: - File-store specifics

@Test func fileIsCreatedWithOwnerOnlyPermissions() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    try store.storePairedDevice(makeDevice())

    let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    #expect((attrs[.posixPermissions] as? Int) == 0o600)
}

@Test func secondInstanceOnSameFileSeesWrites() throws {
    // The pairing tool writes; the daemon reads — different processes, same file.
    let writer = makeStore()
    defer { try? writer.removeAll() }
    let reader = PairedDeviceStore(fileURL: writer.fileURL)

    #expect(try reader.listPairedDevices().isEmpty)
    try writer.storePairedDevice(makeDevice(id: "late-pairing"))
    #expect(try reader.retrievePairedDevice(deviceID: "late-pairing").deviceID == "late-pairing")
}

@Test func corruptFileIsReportedNotSilentlyEmpty() throws {
    let store = makeStore()
    defer { try? store.removeAll() }

    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("not json".utf8).write(to: store.fileURL)

    #expect(throws: PairedDeviceStoreError.self) {
        try store.listPairedDevices()
    }
}

@Test func removeAllOnMissingFileDoesNotThrow() throws {
    let store = makeStore()
    try store.removeAll()
}

// MARK: - Legacy Keychain import

/// Writes an item the way pre-file-store versions did. Same binary creates and
/// reads it, so no ACL prompt is involved in the test.
private func addLegacyItem(service: String, device: PairedDevice) throws {
    let data = try JSONEncoder().encode(device)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: device.deviceID,
        kSecValueData as String: data,
    ]
    #expect(SecItemAdd(query as CFDictionary, nil) == errSecSuccess)
}

private func removeLegacyItems(service: String) {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ] as CFDictionary)
}

@Test func legacyKeychainRecordsAreImportedOnce() throws {
    let service = "dev.touchbridge.test.legacy.\(UUID().uuidString)"
    defer { removeLegacyItems(service: service) }
    let store = makeStore()
    defer { try? store.removeAll() }

    try addLegacyItem(service: service, device: makeDevice(id: "legacy-a", name: "Old iPhone"))
    try addLegacyItem(service: service, device: makeDevice(id: "legacy-b", name: "Old Android"))

    store.importLegacyKeychainIfNeeded(legacy: LegacyKeychainStore(service: service))

    let ids = Set(try store.listPairedDevices().map(\.deviceID))
    #expect(ids == ["legacy-a", "legacy-b"])

    // A second import must not clobber what the file now holds.
    try store.storePairedDevice(makeDevice(id: "new-c"))
    removeLegacyItems(service: service)
    store.importLegacyKeychainIfNeeded(legacy: LegacyKeychainStore(service: service))
    #expect(try store.listPairedDevices().count == 3)
}

@Test func legacyImportWithNothingToImportCreatesEmptyStore() throws {
    let service = "dev.touchbridge.test.legacy.\(UUID().uuidString)"
    let store = makeStore()
    defer { try? store.removeAll() }

    store.importLegacyKeychainIfNeeded(legacy: LegacyKeychainStore(service: service))

    #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(try store.listPairedDevices().isEmpty)
}
