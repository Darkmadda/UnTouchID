import Foundation

/// Controls the `touchbridged` LaunchAgent from the menu-bar app.
///
/// Everything here is user-level: the LaunchAgent lives in the user's
/// `~/Library/LaunchAgents`, runs in the `gui/<uid>` domain, and its config
/// files are user-owned — so start/stop/settings never need admin rights.
///
/// Daemon runtime settings (auto-lock, lock delay, RSSI threshold) are stored
/// as flags in the plist's `ProgramArguments`; changing them means rewriting
/// that array and restarting the job (launchd caches the arguments at bootstrap
/// time, so a plain kickstart would relaunch with the *old* flags).
struct DaemonController {
    static let label = "dev.touchbridge.daemon"
    static let daemonBinary = "/usr/local/bin/touchbridged"

    /// Where the installer writes the LaunchAgent plist for the current user.
    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    private var domain: String { "gui/\(getuid())" }
    private var serviceTarget: String { "\(domain)/\(Self.label)" }

    /// The daemon binary and LaunchAgent are both present.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.daemonBinary)
            && FileManager.default.fileExists(atPath: plistURL.path)
    }

    // MARK: - Running state

    /// True when a `touchbridged` process is currently alive. Uses `pgrep`,
    /// which is fast enough to poll and reflects reality even if launchd's
    /// bookkeeping lags a moment behind a start/stop.
    func isRunning() -> Bool {
        Self.run("/usr/bin/pgrep", ["-x", "touchbridged"]).status == 0
    }

    // MARK: - Start / Stop / Restart

    /// Load and launch the daemon. Safe to call when already loaded.
    @discardableResult
    func start() -> Bool {
        guard isInstalled else { return false }
        // bootstrap fails harmlessly if the job is already loaded; the
        // kickstart that follows is what actually (re)launches it.
        _ = Self.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        return Self.run("/bin/launchctl", ["kickstart", "-k", serviceTarget]).status == 0
    }

    /// Unload the daemon. KeepAlive means a plain kill would just respawn it,
    /// so we bootout the job entirely.
    @discardableResult
    func stop() -> Bool {
        Self.run("/bin/launchctl", ["bootout", serviceTarget]).status == 0
    }

    /// Full reload so freshly-written ProgramArguments take effect.
    @discardableResult
    func restart() -> Bool {
        _ = stop()
        return start()
    }

    // MARK: - Settings (stored as ProgramArguments flags)

    struct Settings: Equatable {
        var autoLock: Bool = false
        var lockDelay: Int = defaultLockDelay
        var rssiThreshold: Int = defaultRSSI
    }

    static let defaultLockDelay = 30
    static let defaultRSSI = -75

    /// Flags this app manages (and strips before rewriting). Everything else in
    /// ProgramArguments — the binary path, `serve`, and any flags set elsewhere —
    /// is preserved.
    private static let managedFlags: Set<String> = ["--auto-lock"]
    private static let managedValueFlags: Set<String> = ["--lock-delay", "--rssi-threshold"]

    private func programArguments() -> [String] {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return [] }
        return args
    }

    func readSettings() -> Settings {
        var s = Settings()
        let args = programArguments()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--auto-lock":
                s.autoLock = true
            case "--lock-delay":
                if i + 1 < args.count, let v = Int(args[i + 1]) { s.lockDelay = v; i += 1 }
            case "--rssi-threshold":
                if i + 1 < args.count, let v = Int(args[i + 1]) { s.rssiThreshold = v; i += 1 }
            default:
                break
            }
            i += 1
        }
        return s
    }

    /// Rewrite the managed flags in the plist and restart the daemon so they
    /// take effect. Returns false if the plist could not be read/written.
    @discardableResult
    func writeSettings(_ s: Settings) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let oldArgs = plist["ProgramArguments"] as? [String], !oldArgs.isEmpty
        else { return false }

        // Keep everything that isn't one of our managed flags.
        var base: [String] = []
        var i = 0
        while i < oldArgs.count {
            let a = oldArgs[i]
            if Self.managedFlags.contains(a) { i += 1; continue }
            if Self.managedValueFlags.contains(a) { i += 2; continue }
            base.append(a); i += 1
        }

        var newArgs = base
        if s.rssiThreshold != Self.defaultRSSI {
            newArgs += ["--rssi-threshold", String(s.rssiThreshold)]
        }
        if s.autoLock {
            newArgs += ["--auto-lock", "--lock-delay", String(max(0, s.lockDelay))]
        }

        plist["ProgramArguments"] = newArgs
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? out.write(to: plistURL, options: .atomic)) != nil
        else { return false }

        _ = restart()
        return true
    }

    // MARK: - Process helper

    struct ProcResult { let status: Int32; let stdout: String; let stderr: String }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return ProcResult(status: -1, stdout: "", stderr: "\(error)")
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcResult(
            status: p.terminationStatus,
            stdout: String(data: o, encoding: .utf8) ?? "",
            stderr: String(data: e, encoding: .utf8) ?? ""
        )
    }
}
