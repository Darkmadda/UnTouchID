import Foundation
import Security

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
        /// Current lock state of the managed login keychain: true = locked,
        /// false = unlocked, nil = couldn't be determined.
        var locked: Bool?

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
        let path = stored.keychainPath ?? defaultLoginKeychainPath
        return Status(
            enabled: stored.enabled ?? false,
            keychainPath: stored.keychainPath,
            enrollments: enrollments,
            locked: isLocked(path: path)
        )
    }

    /// The current user's default login keychain path.
    static var defaultLoginKeychainPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
    }

    /// Whether the keychain at `path` is locked (nil if it can't be read).
    ///
    /// Uses the same deprecated-but-only-way `SecKeychain*` file-keychain APIs the
    /// daemon uses; reading lock state needs no unlock and no admin rights.
    @available(macOS, deprecated: 10.10)
    static func isLocked(path: String) -> Bool? {
        var keychain: SecKeychain?
        guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { return nil }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return nil }
        // kSecUnlockStateStatus is set when the keychain is unlocked.
        return (status & UInt32(kSecUnlockStateStatus)) == 0
    }

    // MARK: - On-demand unlock (daemon socket)

    enum UnlockResult: Equatable {
        case success
        case notConfigured
        case noDeviceConnected
        case daemonUnreachable
        case failed(String)

        /// A short, user-facing description of a non-success result.
        var message: String {
            switch self {
            case .success: return "Keychain unlocked"
            case .notConfigured: return "Keychain unlock isn't set up yet"
            case .noDeviceConnected: return "No enrolled phone is connected"
            case .daemonUnreachable: return "The TouchBridge service isn't running"
            case .failed(let r): return "Unlock failed (\(r))"
            }
        }
    }

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TouchBridge/daemon.sock").path
    }

    /// Ask the running daemon to unlock the login keychain now: it waits for an
    /// enrolled phone and triggers a Face ID on it. Blocking — call off the main
    /// thread. The daemon may take up to ~20s waiting for the phone.
    static func requestUnlock() -> UnlockResult {
        let request = #"{"action":"unlock_keychain","user":"","service":"menubar","pid":\#(getpid())}"#
        guard let reply = sendToDaemon(request) else { return .daemonUnreachable }
        guard let data = reply.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String else {
            return .failed("bad_response")
        }
        if result == "success" { return .success }
        let reason = obj["reason"] as? String ?? "unknown"
        switch reason {
        case "not_configured": return .notConfigured
        case "no_device": return .noDeviceConnected
        default: return .failed(reason)
        }
    }

    /// Send one newline-terminated JSON line to the daemon's Unix socket and read
    /// one line back. Returns nil if the socket can't be reached.
    private static func sendToDaemon(_ line: String, timeout: TimeInterval = 30) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count { dest[i] = pathBytes[i] }
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // Bound the wait so the UI can't hang forever if the daemon stalls.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = Array((line + "\n").utf8)
        let sent = payload.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == payload.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buffer, buffer.count - 1, 0)
        guard n > 0 else { return nil }
        buffer[n] = 0
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
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
