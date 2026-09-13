import Foundation
import OSLog
import Security
import TouchBridgeProtocol

/// A paired companion device record.
public struct PairedDevice: Codable, Sendable, Equatable {
    public let deviceID: String
    public let publicKey: Data
    public let displayName: String
    public let pairedAt: Date

    public init(deviceID: String, publicKey: Data, displayName: String, pairedAt: Date) {
        self.deviceID = deviceID
        self.publicKey = publicKey
        self.displayName = displayName
        self.pairedAt = pairedAt
    }
}

/// Persists paired companion devices (their *public* keys and metadata) in
/// `~/Library/Application Support/TouchBridge/paired-devices.json`.
///
/// Why a file and not the Keychain: paired-device records are written by the
/// pairing tool and read by the daemon, and both are ad-hoc signed, so their
/// code hashes change on every build. Legacy Keychain items are gated by a
/// per-application ACL plus a partition-ID check keyed on that hash, so every
/// reinstall made securityd prompt the user — and when nobody could answer
/// (screen locked, daemon in the background) it denied access outright and the
/// daemon treated its own paired phone as unknown. The data-protection Keychain
/// needs entitlements an ad-hoc CLI cannot carry.
///
/// Nothing stored here is secret: it is the phones' public keys. The file is
/// mode 0600 in the user's own Application Support directory, which is the
/// same trust boundary the Keychain gave a public key readable by any
/// user-level process. Private keys never leave the phone's Secure Enclave.
///
/// The file is re-read on every call so the daemon sees pairings made by the
/// pairing tool without a restart, and writes are atomic (temp file + rename).
public struct PairedDeviceStore: Sendable {
    private static let logger = Logger(subsystem: "dev.touchbridge", category: "PairedDeviceStore")
    public static let filename = "paired-devices.json"

    /// Location of the JSON file.
    public let fileURL: URL

    private struct Stored: Codable {
        var version: Int = 1
        var devices: [PairedDevice]
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The store every TouchBridge binary on this Mac shares.
    ///
    /// The first time it is used it imports any records that a previous
    /// version left in the legacy Keychain, so upgrading does not force a
    /// re-pair. Records the Keychain will not hand over (denied without a
    /// user prompt) are left in place and retried on the next launch, so the
    /// file is not created until the import is complete.
    public static func standard() -> PairedDeviceStore {
        let store = PairedDeviceStore(fileURL: TouchBridgePaths.supportDirectory.appendingPathComponent(filename))
        store.importLegacyKeychainIfNeeded()
        return store
    }

    // MARK: - Public API

    /// Store a paired device, replacing any existing record with the same ID.
    public func storePairedDevice(_ device: PairedDevice) throws {
        var devices = try loadDevices()
        devices.removeAll { $0.deviceID == device.deviceID }
        devices.append(device)
        try save(devices)
    }

    /// Retrieve a paired device record by device ID.
    public func retrievePairedDevice(deviceID: String) throws -> PairedDevice {
        guard let device = try loadDevices().first(where: { $0.deviceID == deviceID }) else {
            throw PairedDeviceStoreError.deviceNotFound(deviceID)
        }
        return device
    }

    /// Reconstruct a `SecKey` from a paired device's stored public key bytes.
    public func retrievePublicKey(for deviceID: String) throws -> SecKey {
        let device = try retrievePairedDevice(deviceID: deviceID)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(device.publicKey as CFData, attributes as CFDictionary, &error) else {
            throw PairedDeviceStoreError.publicKeyReconstructionFailed(
                error?.takeRetainedValue().localizedDescription ?? "unknown"
            )
        }

        return key
    }

    /// List all paired devices, in pairing order.
    public func listPairedDevices() throws -> [PairedDevice] {
        try loadDevices()
    }

    /// Remove a paired device by ID. Removing an unknown ID is not an error.
    public func removePairedDevice(deviceID: String) throws {
        var devices = try loadDevices()
        let before = devices.count
        devices.removeAll { $0.deviceID == deviceID }
        if devices.count != before {
            try save(devices)
        }
    }

    /// Remove all paired devices.
    public func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone.
        } catch {
            throw PairedDeviceStoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - File I/O

    private func loadDevices() throws -> [PairedDevice] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return []
        }
        do {
            return try JSONDecoder().decode(Stored.self, from: data).devices
        } catch {
            throw PairedDeviceStoreError.corruptStore(fileURL.path, error.localizedDescription)
        }
    }

    private func save(_ devices: [PairedDevice]) throws {
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Stored(devices: devices))
            try data.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            // rename(2) is atomic and replaces any existing file.
            guard rename(tmp.path, fileURL.path) == 0 else {
                throw PairedDeviceStoreError.writeFailed(String(cString: strerror(errno)))
            }
        } catch let error as PairedDeviceStoreError {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw PairedDeviceStoreError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Legacy Keychain import

    /// One-time import from the Keychain used by versions before the file store.
    ///
    /// Returns without touching anything if the file already exists. If any
    /// legacy record could not be read (the Keychain denied access rather
    /// than reporting it missing) the file is not written, so the import is
    /// retried next launch when the user may be present to approve it.
    func importLegacyKeychainIfNeeded(legacy: LegacyKeychainStore = LegacyKeychainStore()) {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let result = legacy.readAll()
        if result.deniedCount > 0 {
            Self.logger.warning(
                "Legacy Keychain import incomplete: \(result.deniedCount) record(s) denied — will retry next launch"
            )
            return
        }
        do {
            try save(result.devices)
            Self.logger.info("Imported \(result.devices.count) paired device(s) from the legacy Keychain")
        } catch {
            Self.logger.error("Legacy Keychain import failed to write store: \(error.localizedDescription)")
        }
    }
}

public enum PairedDeviceStoreError: Error, Sendable {
    case deviceNotFound(String)
    case publicKeyReconstructionFailed(String)
    case corruptStore(String, String)
    case writeFailed(String)
}

// MARK: - Legacy Keychain

/// Read-only access to the generic-password Keychain items TouchBridge used
/// before `PairedDeviceStore`. Kept only for the one-time import.
struct LegacyKeychainStore: Sendable {
    let service: String

    init(service: String = TouchBridgeConstants.keychainService) {
        self.service = service
    }

    struct ReadResult {
        var devices: [PairedDevice] = []
        /// Items whose data the Keychain refused to release (ACL / partition denial).
        var deniedCount = 0
    }

    /// Read every record under the service. Listing attributes never prompts;
    /// reading each item's data may, and is denied when no prompt can be shown.
    func readAll() -> ReadResult {
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)
        guard listStatus == errSecSuccess, let items = listResult as? [[String: Any]] else {
            return ReadResult()
        }

        var result = ReadResult()
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var data: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &data)
            if status == errSecSuccess, let data = data as? Data,
               let device = try? JSONDecoder().decode(PairedDevice.self, from: data) {
                result.devices.append(device)
            } else if status != errSecItemNotFound {
                result.deniedCount += 1
            }
        }
        return result
    }
}
