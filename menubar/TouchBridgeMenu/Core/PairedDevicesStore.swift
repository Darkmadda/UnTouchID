import Foundation

/// A paired companion device, mirroring the daemon's `PairedDevice` record so
/// the app can read and rewrite `paired-devices.json` directly.
///
/// The daemon re-reads that file on every socket request, so removing a device
/// here takes effect immediately — no daemon restart required.
struct PairedDeviceInfo: Identifiable, Codable, Equatable {
    let deviceID: String
    let publicKey: Data
    let displayName: String
    let pairedAt: Date

    var id: String { deviceID }
}

/// Reads and edits `~/Library/Application Support/TouchBridge/paired-devices.json`.
///
/// The on-disk shape and codable strategies (Data → base64, Date → reference
/// interval) match `TouchBridgeCore.PairedDeviceStore` exactly, so anything this
/// app writes stays readable by the daemon and the CLI.
enum PairedDevicesStore {
    private struct Stored: Codable {
        var version: Int = 1
        var devices: [PairedDeviceInfo]
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TouchBridge/paired-devices.json")
    }

    static func list() -> [PairedDeviceInfo] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return [] }
        return stored.devices
    }

    static func remove(deviceID: String) throws {
        var devices = list()
        devices.removeAll { $0.deviceID == deviceID }
        try save(devices)
    }

    static func removeAll() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone — nothing to clear.
        }
    }

    private static func save(_ devices: [PairedDeviceInfo]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Stored(devices: devices))

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
