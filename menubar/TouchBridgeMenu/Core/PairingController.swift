import Foundation
import SwiftUI

/// Drives a pairing session for the menu-bar app.
///
/// Pairing is delegated to the installed `touchbridge-test pair` tool, which
/// owns the BLE advertisement while a phone connects. The daemon advertises on
/// the same per-Mac service UUID, so the two would collide — this controller
/// therefore **stops the daemon** before pairing and **restarts it** once the
/// session ends (success, failure, timeout, or cancel).
@MainActor
final class PairingController: ObservableObject {
    enum Phase: Equatable {
        case preparing      // stopping the daemon, launching the tool
        case waiting        // advertising, waiting for the phone
        case success
        case failed
        case cancelled
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var pairingPayload = ""   // JSON to render as a QR / paste manually
    @Published private(set) var pairedDeviceName = ""
    @Published private(set) var errorMessage = ""

    static let toolPath = "/usr/local/bin/touchbridge-test"

    private let daemon: DaemonController
    private let timeout: Int
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    private var daemonRestarted = false

    init(daemon: DaemonController, timeout: Int = 300) {
        self.daemon = daemon
        self.timeout = timeout
    }

    /// Begin pairing. Idempotent — a second call while running is ignored.
    func start() {
        guard process == nil, phase == .preparing else { return }

        guard FileManager.default.fileExists(atPath: Self.toolPath) else {
            fail("Pairing tool not found at \(Self.toolPath).\nReinstall TouchBridge and try again.")
            return
        }

        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            _ = self.daemon.stop()            // free the BLE advertisement
            Task { @MainActor in self.launch() }
        }
    }

    /// Terminate an in-flight pairing (e.g. the user closed the window).
    func cancel() {
        if let p = process, p.isRunning {
            if phase == .waiting || phase == .preparing { phase = .cancelled }
            p.terminate()
        } else {
            restartDaemonOnce()
        }
    }

    // MARK: - Private

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.toolPath)
        // --no-open: we render the QR ourselves, so the CLI must not pop Preview.
        p.arguments = ["pair", "--timeout", String(timeout), "--no-open"]

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.finished(status: status) }
        }

        do {
            try p.run()
            process = p
            outputPipe = pipe
            if phase == .preparing { phase = .waiting }
        } catch {
            fail("Could not start pairing: \(error.localizedDescription)")
            restartDaemonOnce()
        }
    }

    private func ingest(_ text: String) {
        // Accumulate everything so a payload split across reads is still found.
        outputBuffer += text

        if pairingPayload.isEmpty {
            pairingPayload = Self.extractPayload(from: outputBuffer) ?? ""
        }

        if let range = outputBuffer.range(of: "Device: ") {
            let name = outputBuffer[range.upperBound...].prefix { !$0.isNewline }
            pairedDeviceName = name.trimmingCharacters(in: .whitespaces)
        }

        if outputBuffer.contains("Pairing successful!") {
            phase = .success
        }
    }

    /// Pull the pairing payload out of the tool's output. Prefers the explicit
    /// `TB_PAIRING_PAYLOAD=` marker and only accepts a fully-terminated line, so
    /// a partially-arrived payload is never rendered as a truncated QR.
    private static func extractPayload(from buffer: String) -> String? {
        if let r = buffer.range(of: "TB_PAIRING_PAYLOAD=") {
            let rest = buffer[r.upperBound...]
            if let nl = rest.firstIndex(where: \.isNewline) {
                return String(rest[..<nl])
            }
            return nil   // marker seen but line not complete yet
        }
        // Fallback: a complete compact-JSON line (must be newline-terminated).
        guard buffer.contains("\n") else { return nil }
        for line in buffer.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") { return trimmed }
        }
        return nil
    }

    private func finished(status: Int32) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil

        if phase != .success && phase != .cancelled {
            phase = .failed
            if errorMessage.isEmpty {
                errorMessage = "Pairing did not complete — it timed out or was declined on the phone."
            }
        }

        restartDaemonOnce()
    }

    private func fail(_ message: String) {
        phase = .failed
        errorMessage = message
    }

    /// Bring the daemon back up exactly once, whatever path we exit through.
    private func restartDaemonOnce() {
        guard !daemonRestarted else { return }
        daemonRestarted = true
        DispatchQueue.global().async { [daemon] in _ = daemon.start() }
    }
}
