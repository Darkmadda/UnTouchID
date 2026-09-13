import Foundation
@testable import TouchBridgeCore

/// A paired-device store backed by a fresh temp file, so parallel tests never share state.
func makeTempDeviceStore() -> PairedDeviceStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-store-\(UUID().uuidString)", isDirectory: true)
    return PairedDeviceStore(fileURL: dir.appendingPathComponent(PairedDeviceStore.filename))
}
