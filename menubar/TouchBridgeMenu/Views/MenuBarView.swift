import SwiftUI

/// The dropdown shown when the menu-bar icon is clicked: live status plus the
/// core actions — start/stop the service, pair a device, open settings, manage
/// paired devices, and quit.
struct MenuBarView: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if state.isInstalled {
                statusRow
                Divider()
                actions
            } else {
                notInstalled
            }

            Divider()
            MenuRow(title: "Quit TouchBridge", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .frame(width: 300)
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "touchid")
                .font(.title2)
                .foregroundStyle(state.isDaemonRunning ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("TouchBridge").font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(state.isDaemonRunning ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(state.isDaemonRunning ? "Service running" : "Service stopped")
                .font(.subheadline)
            Spacer()
            Text(pairedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(
                title: state.isDaemonRunning ? "Stop Service" : "Start Service",
                systemImage: state.isDaemonRunning ? "stop.circle" : "play.circle"
            ) {
                state.toggleDaemon()
            }
            .disabled(state.isBusy)

            MenuRow(title: "Pair New Device…", systemImage: "iphone.radiowaves.left.and.right") {
                AppWindows.shared.showPairing(state)
            }
            .disabled(state.isBusy)

            MenuRow(
                title: state.pairedDevices.isEmpty ? "Paired Devices…" : "Paired Devices (\(state.pairedDevices.count))…",
                systemImage: "list.bullet"
            ) {
                AppWindows.shared.showSettings(state, tab: .devices)
            }

            MenuRow(title: "Keychain Unlock…", systemImage: "key") {
                AppWindows.shared.showSettings(state, tab: .keychain)
            }

            MenuRow(title: "Settings…", systemImage: "gearshape") {
                AppWindows.shared.showSettings(state, tab: .general)
            }
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TouchBridge isn't installed yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            MenuRow(title: "Set Up TouchBridge…", systemImage: "arrow.right.circle") {
                AppWindows.shared.showSetup(state)
            }
        }
    }

    // MARK: - Copy

    private var statusText: String {
        if !state.isInstalled { return "Not installed" }
        if state.isBusy { return "Working…" }
        return state.isDaemonRunning ? "Ready" : "Stopped"
    }

    private var pairedSummary: String {
        switch state.pairedDevices.count {
        case 0: return "No devices"
        case 1: return "1 device"
        case let n: return "\(n) devices"
        }
    }
}

/// A full-width, hover-highlighted menu row that looks native inside a
/// `.window`-style `MenuBarExtra`.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                Text(title)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(hovering && isEnabled ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
