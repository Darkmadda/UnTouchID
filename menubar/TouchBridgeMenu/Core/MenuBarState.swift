import Foundation
import SwiftUI

/// Shared observable state for the menu-bar UI: install status, whether the
/// daemon is running, the paired devices, and recent auth activity.
@MainActor
final class MenuBarState: ObservableObject {
    @Published var isInstalled = false
    @Published var isDaemonRunning = false
    @Published var pairedDevices: [PairedDeviceInfo] = []
    @Published var keychainUnlock = KeychainUnlockStore.Status()
    @Published var recentEvents: [AuthEvent] = []
    @Published var authCount = 0
    /// True while a start/stop/settings action is in flight.
    @Published var isBusy = false
    /// Which Settings tab to show when the window is opened.
    @Published var settingsTab: SettingsTab = .general

    let daemon = DaemonController()

    enum SettingsTab: Hashable { case general, devices, keychain, about }

    struct AuthEvent: Identifiable, Codable {
        let id = UUID()
        let ts: String
        let surface: String
        let result: String
        let companionDevice: String

        enum CodingKeys: String, CodingKey {
            case ts, surface, result
            case companionDevice = "companion_device"
        }
    }

    private var refreshTimer: Timer?

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Kept for the setup wizard, which calls it after installing.
    func checkInstallation() { refresh() }

    /// Recompute status off the main thread (launchctl/pgrep + file reads),
    /// then publish the results.
    func refresh() {
        let daemon = self.daemon
        DispatchQueue.global().async {
            let installed = daemon.isInstalled
            let running = daemon.isRunning()
            let devices = PairedDevicesStore.list()
            let keychain = KeychainUnlockStore.status()
            let events = Self.loadRecentEvents()
            DispatchQueue.main.async {
                self.isInstalled = installed
                self.isDaemonRunning = running
                self.pairedDevices = devices
                self.keychainUnlock = keychain
                self.recentEvents = events
                self.authCount = events.filter { $0.result == "VERIFIED" }.count
            }
        }
    }

    // MARK: - Actions

    func startDaemon() { runBusy { _ = self.daemon.start() } }
    func stopDaemon()  { runBusy { _ = self.daemon.stop() } }

    func toggleDaemon() {
        if isDaemonRunning { stopDaemon() } else { startDaemon() }
    }

    func unpair(_ device: PairedDeviceInfo) {
        try? PairedDevicesStore.remove(deviceID: device.deviceID)
        refresh()
    }

    func unpairAll() {
        try? PairedDevicesStore.removeAll()
        refresh()
    }

    private func runBusy(_ work: @escaping () -> Void) {
        guard !isBusy else { return }
        isBusy = true
        DispatchQueue.global().async {
            work()
            // Give launchd a moment to reflect the new state before polling.
            Thread.sleep(forTimeInterval: 0.6)
            DispatchQueue.main.async {
                self.isBusy = false
                self.refresh()
            }
        }
    }

    // MARK: - Log parsing

    nonisolated private static func loadRecentEvents() -> [AuthEvent] {
        let logDir = "\(NSHomeDirectory())/Library/Logs/TouchBridge"
        let fm = FileManager.default
        guard fm.fileExists(atPath: logDir),
              let files = try? fm.contentsOfDirectory(atPath: logDir)
                .filter({ $0.hasSuffix(".ndjson") })
                .sorted()
                .reversed() else { return [] }

        var events: [AuthEvent] = []
        let decoder = JSONDecoder()
        for file in files {
            guard let content = try? String(contentsOfFile: "\(logDir)/\(file)", encoding: .utf8) else { continue }
            for line in content.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let event = try? decoder.decode(AuthEvent.self, from: data) else { continue }
                events.append(event)
                if events.count >= 10 { break }
            }
            if events.count >= 10 { break }
        }
        return events
    }
}
