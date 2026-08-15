import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WhatsAppPairingView: View {
    @ObservedObject var connection: WhatsAppConnectionManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.isConnected ? "WhatsApp connected" : "Connect WhatsApp")
                        .font(.system(size: 20, weight: .semibold))
                    Text(connection.isConnected ? connection.statusLabel : "Scan from WhatsApp → Linked devices")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            VStack(spacing: 18) {
                if connection.isConnected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 58))
                        .foregroundStyle(Color.Pidgy.success)
                    Text("Pidgy is reading new messages and the history WhatsApp shares with this linked device.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.Pidgy.fg2)
                } else if let code = connection.qrCode,
                          let image = WhatsAppQRCodeRenderer.image(for: code) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 250, height: 250)
                        .padding(14)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("On your phone: WhatsApp → Settings → Linked devices → Link a device")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.Pidgy.fg2)
                        .multilineTextAlignment(.center)
                } else if case .failed(let message) = connection.state {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 42))
                        .foregroundStyle(Color.Pidgy.warning)
                    Text(message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.Pidgy.fg2)
                        .multilineTextAlignment(.center)
                    Button("Try again") { connection.reconnect() }
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text(connection.statusLabel)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.Pidgy.fg2)
                }

                Label(
                    "Experimental read-only connection. Pidgy does not send messages, read receipts, or presence. This uses an unofficial linked-device library and may stop working if WhatsApp changes its service.",
                    systemImage: "lock.shield"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.Pidgy.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        }
        .frame(width: 470, height: 520)
        .background(Color.Pidgy.bg1)
    }
}

private enum WhatsAppQRCodeRenderer {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
