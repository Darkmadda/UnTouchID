import Foundation

/// Read-only view of the opt-in "unlock the login keychain from your phone"
/// state, mirroring `TouchBridgeCore.KeychainSecretStore`'s on-disk shape in
/// `~/Library/Application Support/TouchBridge/keychain-unlock.json`.
///
/// The app only *reads* this file — it never re-keys the keychain itself.
/// Setup and recovery re-key the login keychain, show a one-time recovery
/// password, and prompt for the current password without echoing it; that flow
/// is inherently interactive and lockout-sensitive, so the app hands it off to
/// the installed `touchbridge-test keychain …` CLI in a Terminal window rather
/// than duplicating the security-critical logic.
enum KeychainUnlockStore {
    static let toolPath = "/usr/local/bin/touchbridge-test"

    struct Status: Equatable {
        var enabled = false
        var keychainPath: String?
        var enrollments: [Enrollment] = []

        struct Enrollment: Identifiable, Equatable {
            let deviceID: String
            let displayName: String
            /// A wrapped copy of the keychain password exists for this phone —
            /// i.e. setup has run and this phone can unlock.
            let ready: Bool
            let enrolledAt: Date
            var id: String { deviceID }
        }

        /// Switched on AND at least one phone can actually unlock.
        var active: Bool { enabled && enrollments.contains { $0.ready } }
        var hasEnrollments: Bool { !enrollments.isEmpty }
        /// A phone has offered a key but setup hasn't wrapped to it yet.
        var hasPendingEnrollment: Bool { enrollments.contains { !$0.ready } }
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TouchBridge/keychain-unlock.json")
    }

    static func status() -> Status {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Status()
        }
        let enrollments = (stored.enrollments ?? [:]).values
            .map { e in
                Status.Enrollment(
                    deviceID: e.deviceID,
                    displayName: e.displayName,
                    ready: e.wrapped != nil,
                    enrolledAt: e.enrolledAt
                )
            }
            .sorted { $0.enrolledAt < $1.enrolledAt }
        return Status(
            enabled: stored.enabled ?? false,
            keychainPath: stored.keychainPath,
            enrollments: enrollments
        )
    }

    // MARK: - Interactive CLI hand-off

    /// Run `touchbridge-test keychain <subcommand>` in a new Terminal window so
    /// its password prompts and one-time recovery output work as designed.
    /// Returns false if the CLI isn't installed.
    @discardableResult
    static func runInTerminal(subcommand: String) -> Bool {
        guard FileManager.default.fileExists(atPath: toolPath) else { return false }
        let command = "\(toolPath) keychain \(subcommand)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch { return false }
        return true
    }

    // MARK: - Decoding

    private struct Stored: Codable {
        var version: Int?
        var enabled: Bool?
        var keychainPath: String?
        var enrollments: [String: Enrollment]?

        struct Enrollment: Codable {
            var deviceID: String
            var displayName: String
            var enrolledAt: Date
            /// Presence-only: an empty struct decodes from the wrapped-secret
            /// object (ignoring its fields) and stays nil when absent/null.
            var wrapped: WrappedPresence?
        }

        struct WrappedPresence: Codable {}
    }
}
