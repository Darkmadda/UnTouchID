import SwiftUI
import CoreImage
import AppKit

/// The pairing flow window. Shows a QR code (and the raw payload for manual
/// entry) while `touchbridge-test pair` advertises, then a success or failure
/// state. Closing the window cancels an in-flight session; the controller
/// restarts the daemon on the way out.
struct PairingView: View {
    @ObservedObject var controller: PairingController
    /// Asks the window to close (wired up by AppWindows).
    let requestClose: () -> Void

    init(controller: PairingController, requestClose: @escaping () -> Void) {
        self.controller = controller
        self.requestClose = requestClose
    }

    var body: some View {
        VStack(spacing: 16) {
            switch controller.phase {
            case .preparing:
                preparing
            case .waiting:
                waiting
            case .success:
                success
            case .failed, .cancelled:
                failed
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Phases

    private var preparing: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Preparing to pair…")
                .font(.headline)
            Text("Stopping the service so it can advertise for pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            Text("Scan with your phone")
                .font(.title3.bold())
            Text("Open the TouchBridge app and scan this code, or paste the text below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            qrImage

            if !controller.pairingPayload.isEmpty {
                ScrollView {
                    Text(controller.pairingPayload)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 70)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.pairingPayload, forType: .string)
                } label: {
                    Label("Copy pairing data", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for your phone to connect…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel", role: .cancel) { requestClose() }
        }
    }

    private var success: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("Paired!")
                .font(.title2.bold())
            if !controller.pairedDeviceName.isEmpty {
                Text(controller.pairedDeviceName)
                    .font(.headline)
            }
            Text("The service is starting back up. You can close this window.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { requestClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text(controller.phase == .cancelled ? "Pairing cancelled" : "Pairing failed")
                .font(.title3.bold())
            if !controller.errorMessage.isEmpty {
                Text(controller.errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text("The service has been restarted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Close") { requestClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - QR

    @ViewBuilder
    private var qrImage: some View {
        if let image = Self.makeQR(controller.pairingPayload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 220, height: 220)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 220, height: 220)
                .overlay(ProgressView())
        }
    }

    /// Render the pairing payload as a QR code, matching what the CLI writes.
    private static func makeQR(_ string: String) -> NSImage? {
        guard !string.isEmpty,
              let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
