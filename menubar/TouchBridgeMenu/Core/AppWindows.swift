import AppKit
import SwiftUI

/// Manages the app's auxiliary windows.
///
/// TouchBridge runs as a menu-bar accessory (`LSUIElement`), which has no Dock
/// icon and no standard window management. Opening real, focusable windows from
/// a menu-bar item is most reliable done by hand with AppKit: create the
/// `NSWindow`, host the SwiftUI view, flip the activation policy to `.regular`
/// so the window can take focus, and drop back to `.accessory` when the last
/// window closes.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    static let shared = AppWindows()

    private var settingsWindow: NSWindow?
    private var pairingWindow: NSWindow?
    private var setupWindow: NSWindow?

    /// Called when a pairing window closes so the owner can cancel + refresh.
    private var onPairingClose: (() -> Void)?

    // MARK: - Settings

    func showSettings(_ state: MenuBarState, tab: MenuBarState.SettingsTab = .general) {
        state.settingsTab = tab
        if settingsWindow == nil {
            let window = makeWindow(
                title: "TouchBridge Settings",
                size: NSSize(width: 500, height: 460),
                content: SettingsWindowView(state: state)
            )
            settingsWindow = window
        }
        present(settingsWindow)
    }

    // MARK: - Pairing

    func showPairing(_ state: MenuBarState) {
        // Bring an existing pairing window forward rather than starting a
        // second session (which would fight over BLE).
        if let existing = pairingWindow {
            present(existing)
            return
        }

        let controller = PairingController(daemon: state.daemon)
        onPairingClose = { [weak controller, weak state] in
            controller?.cancel()
            state?.refresh()
        }

        let window = makeWindow(
            title: "Pair a Device",
            size: NSSize(width: 420, height: 560),
            content: PairingView(controller: controller) { [weak self] in
                self?.pairingWindow?.performClose(nil)
            }
        )
        pairingWindow = window
        present(window)
        controller.start()
    }

    // MARK: - Setup wizard

    func showSetup(_ state: MenuBarState) {
        if setupWindow == nil {
            let window = makeWindow(
                title: "TouchBridge Setup",
                size: NSSize(width: 500, height: 600),
                content: SetupWizardView(state: state)
            )
            setupWindow = window
        }
        present(setupWindow)
    }

    // MARK: - Window plumbing

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }

        if closing == pairingWindow {
            onPairingClose?()
            onPairingClose = nil
            pairingWindow = nil
        } else if closing == settingsWindow {
            settingsWindow = nil
        } else if closing == setupWindow {
            setupWindow = nil
        }

        // If nothing is left on screen, become an accessory again so we don't
        // linger in the Dock / app switcher.
        DispatchQueue.main.async {
            let anyVisible = [self.settingsWindow, self.pairingWindow, self.setupWindow]
                .compactMap { $0 }
                .contains { $0.isVisible }
            if !anyVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
