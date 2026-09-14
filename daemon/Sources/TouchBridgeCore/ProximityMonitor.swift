import Foundation
import OSLog

/// Monitors companion device proximity via BLE RSSI and auto-locks
/// the Mac when the device moves out of range.
///
/// When the paired iPhone leaves BLE range (RSSI drops below threshold
/// for sustained period), the Mac screen is locked.
///
/// This is the inverse of "unlock with iPhone" — "lock when iPhone walks away."
public final class ProximityMonitor: @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")

    private let rssiThreshold: Int
    private let disconnectDelay: TimeInterval
    private var isEnabled: Bool = false
    private var disconnectTimer: DispatchWorkItem?
    private var lastConnectedState: Bool = true
    private let queue = DispatchQueue(label: "dev.touchbridge.proximity")
    private let lockAction: () -> Void

    /// Callback when the Mac should be locked.
    public var onShouldLock: (() -> Void)?

    /// Human-readable status updates (countdown started, cancelled, locked).
    /// The daemon CLI prints these so the user can see what auto-lock is doing
    /// without digging through the unified log.
    public var onStatus: ((String) -> Void)?

    /// Initialize with configurable RSSI threshold and delay.
    ///
    /// - Parameters:
    ///   - rssiThreshold: Lock when average RSSI drops below this (default -80 dBm)
    ///   - disconnectDelay: Wait this long after disconnect before locking (default 30s)
    public convenience init(rssiThreshold: Int = -80, disconnectDelay: TimeInterval = 30) {
        self.init(
            rssiThreshold: rssiThreshold,
            disconnectDelay: disconnectDelay,
            lockAction: ProximityMonitor.systemLockScreen
        )
    }

    init(rssiThreshold: Int, disconnectDelay: TimeInterval, lockAction: @escaping () -> Void) {
        self.rssiThreshold = rssiThreshold
        self.disconnectDelay = disconnectDelay
        self.lockAction = lockAction
    }

    /// Enable proximity-based auto-lock.
    public func enable() {
        isEnabled = true
        logger.info("Proximity auto-lock enabled (threshold: \(self.rssiThreshold) dBm, delay: \(self.disconnectDelay)s)")
    }

    /// Disable proximity-based auto-lock.
    public func disable() {
        isEnabled = false
        disconnectTimer?.cancel()
        disconnectTimer = nil
        logger.info("Proximity auto-lock disabled")
    }

    /// Called when BLE connection state changes.
    public func connectionStateChanged(connected: Bool) {
        guard isEnabled else { return }

        if connected {
            // Cancel any pending lock
            disconnectTimer?.cancel()
            disconnectTimer = nil
            let hadPendingLock = !lastConnectedState
            lastConnectedState = true
            if hadPendingLock {
                logger.info("Companion reconnected — auto-lock cancelled")
                onStatus?("Companion reconnected — auto-lock cancelled")
            }
        } else if lastConnectedState {
            // Device disconnected — start countdown
            lastConnectedState = false
            logger.info("Companion disconnected — will lock in \(self.disconnectDelay)s if not reconnected")
            onStatus?("Companion disconnected — locking in \(Int(disconnectDelay))s unless it reconnects")

            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.isEnabled, !self.lastConnectedState else { return }
                self.logger.info("Proximity auto-lock triggered — locking screen")
                self.lockScreen()
            }
            disconnectTimer = workItem
            queue.asyncAfter(deadline: .now() + disconnectDelay, execute: workItem)
        }
    }

    /// Called with RSSI updates from BLE.
    public func rssiUpdated(_ rssi: Int) {
        guard isEnabled else { return }

        if rssi < rssiThreshold {
            logger.info("RSSI \(rssi) below threshold \(self.rssiThreshold) — companion moving out of range")
        }
    }

    /// Lock the Mac screen.
    private func lockScreen() {
        onShouldLock?()
        onStatus?("Locking screen")

        lockAction()
        logger.info("Screen lock action completed")
    }

    /// Lock the screen the same way the Apple menu's "Lock Screen" (⌃⌘Q) does.
    ///
    /// Uses `SACLockScreenImmediate` from the private login.framework — the only
    /// reliable way to lock (rather than merely sleep the display) without
    /// requiring Accessibility permission for synthesized keystrokes. Falls back
    /// to `pmset displaysleepnow`, which only locks if the user has "Require
    /// password immediately after sleep" enabled.
    private static func systemLockScreen() {
        let logger = Logger(subsystem: "dev.touchbridge", category: "ProximityMonitor")

        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW) {
            defer { dlclose(handle) }
            if let sym = dlsym(handle, "SACLockScreenImmediate") {
                typealias LockFn = @convention(c) () -> Int32
                let lock = unsafeBitCast(sym, to: LockFn.self)
                let rc = lock()
                if rc == 0 {
                    logger.info("Locked screen via SACLockScreenImmediate")
                    return
                }
                logger.warning("SACLockScreenImmediate returned \(rc); falling back to display sleep")
            } else {
                logger.warning("SACLockScreenImmediate not found; falling back to display sleep")
            }
        } else {
            logger.warning("Could not load login.framework; falling back to display sleep")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to lock screen: \(error.localizedDescription)")
        }
    }

    public var enabled: Bool { isEnabled }
}
