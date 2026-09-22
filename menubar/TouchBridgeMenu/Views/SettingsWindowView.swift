import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        TabView(selection: $state.settingsTab) {
            GeneralSettingsView(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(MenuBarState.SettingsTab.general)

            DevicesSettingsView(state: state)
                .tabItem { Label("Devices", systemImage: "iphone") }
                .tag(MenuBarState.SettingsTab.devices)

            KeychainSettingsView(state: state)
                .tabItem { Label("Keychain", systemImage: "key") }
                .tag(MenuBarState.SettingsTab.keychain)

            AboutView(state: state)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(MenuBarState.SettingsTab.about)
        }
        .frame(width: 500, height: 460)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var state: MenuBarState

    @State private var settings = DaemonController.Settings()
    @State private var loaded = DaemonController.Settings()
    @State private var applying = false
    @State private var launchAtLogin = false

    private let loginItem = LoginItemController()

    private var dirty: Bool { settings != loaded }

    var body: some View {
        Form {
            Section("Service") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isDaemonRunning ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(state.isDaemonRunning ? "Running" : "Stopped")
                    }
                }
                HStack {
                    Button(state.isDaemonRunning ? "Stop" : "Start") { state.toggleDaemon() }
                        .disabled(state.isBusy)
                    if state.isBusy { ProgressView().controlSize(.small) }
                }
            }

            Section("Startup") {
                Toggle("Launch TouchBridge at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        // Ignore the programmatic sync in load(); only act on a
                        // real user change.
                        guard newValue != loginItem.isEnabled else { return }
                        applyLaunchAtLogin(newValue)
                    }
                Text("Automatically start the menu-bar app when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Proximity Auto-Lock") {
                Toggle("Lock the Mac when my phone goes away", isOn: $settings.autoLock)
                Stepper(
                    "Lock \(settings.lockDelay)s after the phone disconnects",
                    value: $settings.lockDelay,
                    in: 0...600,
                    step: 5
                )
                .disabled(!settings.autoLock)
                Text("Requires the phone to stay connected over Bluetooth while you're nearby.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Proximity Threshold") {
                Stepper(
                    "Signal threshold: \(settings.rssiThreshold) dBm",
                    value: $settings.rssiThreshold,
                    in: (-100)...(-40),
                    step: 5
                )
                Text("Lower (more negative) values let the phone be farther away. Default is \(DaemonController.defaultRSSI) dBm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Revert") { settings = loaded }
                        .disabled(!dirty || applying)
                    Spacer()
                    if applying { ProgressView().controlSize(.small) }
                    Button("Apply & Restart") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!dirty || applying)
                }
                Text("Applying rewrites the daemon's launch settings and restarts the service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        let current = state.daemon.readSettings()
        settings = current
        loaded = current
        launchAtLogin = loginItem.isEnabled
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        let item = loginItem
        DispatchQueue.global().async {
            _ = item.set(enabled)
            // Reflect the on-disk truth in case the write failed.
            DispatchQueue.main.async { launchAtLogin = item.isEnabled }
        }
    }

    private func apply() {
        applying = true
        let toWrite = settings
        let daemon = state.daemon
        DispatchQueue.global().async {
            let ok = daemon.writeSettings(toWrite)
            DispatchQueue.main.async {
                applying = false
                if ok { loaded = toWrite }
                state.refresh()
            }
        }
    }
}

// MARK: - Devices

struct DevicesSettingsView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.pairedDevices.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No paired devices")
                        .font(.headline)
                    Text("Pair a phone from the menu bar to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Pair New Device…") { AppWindows.shared.showPairing(state) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List {
                    ForEach(state.pairedDevices) { device in
                        DeviceRow(device: device) { confirmRemove(device) }
                    }
                }

                HStack {
                    Button("Pair New Device…") { AppWindows.shared.showPairing(state) }
                    Spacer()
                    Button("Remove All…", role: .destructive) { confirmRemoveAll() }
                }
                .padding()
            }
        }
    }

    private func confirmRemove(_ device: PairedDeviceInfo) {
        let alert = NSAlert()
        alert.messageText = "Unpair “\(device.displayName)”?"
        alert.informativeText = "This Mac will no longer accept authentication from this device. You'll need to pair it again to use it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Unpair")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            state.unpair(device)
        }
    }

    private func confirmRemoveAll() {
        let alert = NSAlert()
        alert.messageText = "Remove all paired devices?"
        alert.informativeText = "This Mac will forget every paired device. You'll need to pair again to use TouchBridge."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            state.unpairAll()
        }
    }
}

struct DeviceRow: View {
    let device: PairedDeviceInfo
    let onRemove: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text("Paired \(Self.dateFormatter.string(from: device.pairedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) { onRemove() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Keychain Unlock

/// Manage the opt-in "unlock your login keychain from your phone" feature.
///
/// Setup and recovery re-key the login keychain, prompt for the current
/// password without echoing it, and print a one-time recovery password. That
/// flow is interactive and lockout-sensitive, so this view shows status and
/// hands the actual work to `touchbridge-test keychain …` in Terminal.
struct KeychainSettingsView: View {
    @ObservedObject var state: MenuBarState

    private var status: KeychainUnlockStore.Status { state.keychainUnlock }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Keychain unlock") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status.active ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(status.active ? "Active" : (status.enabled ? "Enabled" : "Off"))
                    }
                }
                if let path = status.keychainPath {
                    LabeledContent("Keychain") {
                        Text((path as NSString).lastPathComponent)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Enrolled Phones") {
                if status.enrollments.isEmpty {
                    Text("No phone has offered a keychain-unlock key yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("On your paired iPhone: open TouchBridge → Settings → turn on “Unlock Mac keychain”, keep it connected, then set up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(status.enrollments) { e in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.tint)
                            Text(e.displayName)
                            Spacer()
                            Text(e.ready ? "Ready" : "Not set up")
                                .font(.caption)
                                .foregroundStyle(e.ready ? .green : .orange)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Button(status.active ? "Re-run Setup…" : "Set Up Keychain Unlock…") {
                        launch(subcommand: "setup")
                    }
                    .disabled(!status.hasEnrollments)
                    Spacer()
                    Button("Recover / Disable…", role: .destructive) {
                        launch(subcommand: "recover")
                    }
                    .disabled(!status.enabled)
                }
                Text("Setup re-keys your login keychain to a random password and shows a one-time recovery password to save — it opens a Terminal window to do this safely. Recover restores a password you type and turns the feature off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refresh() }
    }

    private func launch(subcommand: String) {
        if !KeychainUnlockStore.runInTerminal(subcommand: subcommand) {
            let alert = NSAlert()
            alert.messageText = "Command-line tool not found"
            alert.informativeText = "The touchbridge-test tool isn't installed at \(KeychainUnlockStore.toolPath). Reinstall TouchBridge and try again."
            alert.alertStyle = .warning
            alert.runModal()
        }
        // The Terminal flow runs asynchronously; refresh so status updates once
        // the user returns and reopens Settings.
        state.refresh()
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "touchid")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("TouchBridge").font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Use your phone's fingerprint to\nauthenticate on your Mac.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Uninstall TouchBridge…", role: .destructive) { confirmUninstall() }

            Link("GitHub", destination: URL(string: "https://github.com/HMAKT99/UnTouchID")!)
                .font(.caption)
            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall TouchBridge?"
        alert.informativeText = "This removes the daemon, PAM module, and restores your original sudo config. Requires your admin password."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \"/bin/bash /usr/local/share/touchbridge/uninstall.sh\" with administrator privileges",
        ]
        try? process.run()
        state.refresh()
    }
}
