import Foundation

/// Controls whether the menu-bar app launches automatically at login.
///
/// This manages the very same per-user LaunchAgent the installer creates
/// (`dev.touchbridge.menubar`), so the in-app toggle and the installer stay in
/// sync and there is only ever one startup mechanism. Everything is user-level
/// — the plist lives in `~/Library/LaunchAgents` and runs in `gui/<uid>`, so no
/// admin rights are needed.
///
/// Disabling only removes the plist (the file launchd reads at login); it
/// deliberately does *not* `bootout` the job, because that would terminate the
/// app you're currently using. Turning startup off should stop it launching next
/// login, not quit it now.
struct LoginItemController {
    static let label = "dev.touchbridge.menubar"

    var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }

    private var domain: String { "gui/\(getuid())" }

    /// The binary launchd should start at login: this app's own executable,
    /// wherever it happens to be installed (e.g. /Applications/TouchBridge.app).
    private var executablePath: String? { Bundle.main.executableURL?.path }

    /// Startup is on when the LaunchAgent plist exists.
    var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    func enable() -> Bool {
        guard let exe = executablePath else { return false }
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } catch { return false }
        // Register it now so launchd matches the file; harmless if already
        // loaded. Not strictly required (RunAtLoad only matters at login).
        _ = DaemonController.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        return true
    }

    @discardableResult
    func disable() -> Bool {
        // Remove the file so it won't load next login. Intentionally no bootout
        // — that would kill the running app.
        do {
            try FileManager.default.removeItem(at: plistURL)
        } catch let e as NSError
            where e.domain == NSCocoaErrorDomain && e.code == NSFileNoSuchFileError {
            // Already gone — nothing to do.
        } catch {
            return false
        }
        return true
    }

    @discardableResult
    func set(_ enabled: Bool) -> Bool {
        enabled ? enable() : disable()
    }
}
