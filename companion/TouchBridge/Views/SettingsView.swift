import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var showUnpairConfirm = false
    @State private var keychainUnlockOn = false
    @State private var keychainUnlockError: String?

    var body: some View {
        List {
            if appState.keyInvalidated {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Re-pair required")
                                .font(.subheadline.bold())
                            Text("Your Face ID / Touch ID enrollment changed since pairing. Unpair and pair again to restore authentication.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if let macName = UserDefaults.standard.string(forKey: "pairedMacName") {
                    LabeledContent("Paired Mac", value: macName)
                }

                LabeledContent("Auth Requests", value: "\(appState.challengeCount)")
            }

            Section("Device") {
                LabeledContent("Biometric") {
                    Text(appState.coordinator.localAuth.isBiometricAvailable() ? "Available" : "Not Available")
                        .foregroundStyle(appState.coordinator.localAuth.isBiometricAvailable() ? .green : .red)
                }

                LabeledContent("BLE", value: appState.coordinator.isConnected ? "Active" : "Idle")
            }

            Section {
                Toggle("Unlock Mac Keychain", isOn: $keychainUnlockOn)
                    .onChange(of: keychainUnlockOn) { newValue in
                        if newValue {
                            do {
                                try appState.coordinator.enableKeychainUnlock()
                                keychainUnlockError = nil
                            } catch {
                                keychainUnlockOn = false
                                keychainUnlockError = "Couldn't enable: \(error.localizedDescription)"
                            }
                        } else {
                            appState.coordinator.disableKeychainUnlock()
                            keychainUnlockError = nil
                        }
                    }
                if let keychainUnlockError {
                    Text(keychainUnlockError).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Mac Keychain")
            } footer: {
                Text("Approve unlocking your Mac's login keychain from this phone (Face ID / Touch ID), so it unlocks together with the screen. After turning this on, run `touchbridge-test keychain setup` on your Mac to finish. Your private key never leaves this device's Secure Enclave.")
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")

                Link(destination: URL(string: "https://github.com/HMAKT99/UnTouchID")!) {
                    HStack {
                        Text("Source Code")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Unpair This Device", role: .destructive) {
                    showUnpairConfirm = true
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            keychainUnlockOn = appState.coordinator.isKeychainUnlockEnabled
        }
        .confirmationDialog(
            "Unpair from Mac?",
            isPresented: $showUnpairConfirm,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                appState.unpair()
            }
        } message: {
            Text("You will need to pair again to use TouchBridge.")
        }
    }
}
