import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TDLibKit

// MARK: - Connect step

struct ConnectStep: View {
    let isAuthReady: Bool
    let errorMessage: String?
    let onPickTelegram: () -> Void
    let onBack: () -> Void

    @State private var hoveredId: String?

    private struct Provider: Identifiable {
        let id: String
        let name: String
        let desc: String
        let bg: AnyShapeStyle
        let isComingSoon: Bool
        let glyph: AnyView
    }

    private var providers: [Provider] {
        [
            // Telegram glyph is a self-contained SVG (gradient circle +
            // white paper-plane mark) so the tile background is fully
            // taken over by the asset and we set the row chip to a
            // transparent style.
            Provider(
                id: "telegram",
                name: "Telegram",
                desc: "Personal account · TDLib",
                bg: AnyShapeStyle(Color.clear),
                isComingSoon: false,
                glyph: AnyView(BrandSVGGlyph(name: "TelegramGlyph"))
            ),
            Provider(
                id: "slack",
                name: "Slack",
                desc: "Workspaces · DMs · Channels",
                bg: AnyShapeStyle(Color.white),
                isComingSoon: true,
                glyph: AnyView(BrandSVGGlyph(name: "SlackGlyph", inset: 8))
            ),
            Provider(
                id: "gmail",
                name: "Gmail",
                desc: "Threads · Senders · Labels",
                bg: AnyShapeStyle(Color.white),
                isComingSoon: true,
                glyph: AnyView(BrandSVGGlyph(name: "GmailGlyph", inset: 8))
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("Connect a source")
                    .font(.custom("Newsreader", size: 34).weight(.medium))
                    .tracking(-0.7)
                    .foregroundStyle(Color.Pidgy.fg1)
                Text("Pidgy is built for Telegram first. More integrations are on the way.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.bottom, 32)

            VStack(spacing: 10) {
                ForEach(providers) { p in
                    providerRow(p)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Pidgy.danger)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity)
            }

            HStack {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                Spacer()

                if isAuthReady {
                    OnboardingPrimaryButton(title: "Continue", trailingChevron: false) {
                        // No-op — onAuthState=.ready already advances to Done.
                    }
                }
            }
            .padding(.top, 32)
        }
        .frame(maxWidth: 460)
    }

    @ViewBuilder
    private func providerRow(_ p: Provider) -> some View {
        let isHover = hoveredId == p.id && !p.isComingSoon

        HStack(spacing: 14) {
            ZStack {
                Rectangle().fill(p.bg)
                p.glyph
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 1.5, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.Pidgy.fg1)
                    if p.isComingSoon {
                        Text("Coming soon")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.Pidgy.fg4)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Color.Pidgy.border2, lineWidth: 1)
                            )
                    }
                }
                Text(p.desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.fg3)
            }

            Spacer()

            if !p.isComingSoon {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHover ? Color.Pidgy.bg3 : Color.Pidgy.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHover ? Color.Pidgy.fg2 : Color.Pidgy.border1, lineWidth: 1)
        )
        .opacity(p.isComingSoon ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in hoveredId = hovering ? p.id : nil }
        .onTapGesture { if !p.isComingSoon { onPickTelegram() } }
    }
}

// MARK: - QR step

struct QRStep: View {
    let authState: AuthState
    let qrLink: String?
    let isStarting: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onUsePhone: () -> Void

    @State private var sweepOffset: CGFloat = -50
    @State private var sweepActive = false

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Telegram")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.32)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Pidgy.accentFg)

                Text("Scan to connect")
                    .font(.custom("Newsreader", size: 30).weight(.medium))
                    .tracking(-0.6)
                    .foregroundStyle(Color.Pidgy.fg1)
                    .padding(.top, 8)

                Text("Open Telegram on your phone and go to:")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .lineSpacing(3)
                    .padding(.top, 14)

                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(num: 1, text: "Settings → Devices")
                    instructionRow(num: 2, text: "Tap \"Link Desktop Device\"")
                    instructionRow(num: 3, text: "Point your camera at the QR")
                }
                .padding(.top, 14)

                HStack(spacing: 10) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Pidgy.fg3)
                    Text("The QR refreshes every 30 seconds.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.Pidgy.border1, lineWidth: 1)
                )
                .padding(.top, 24)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Pidgy.danger)
                        .padding(.top, 12)
                }

                HStack(spacing: 10) {
                    Button(action: onBack) {
                        Text("← Back")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Pidgy.fg3)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)

                    Button(action: onUsePhone) {
                        Text("Log in with phone instead")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Pidgy.fg3)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        Color.Pidgy.border2,
                                        style: StrokeStyle(lineWidth: 1, dash: [3])
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 24)
            }

            qrCard
        }
        .frame(maxWidth: 520)
    }

    private func instructionRow(num: Int, text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Pidgy.fg2)
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.Pidgy.bg2)
                )
                .overlay(
                    Circle().stroke(Color.Pidgy.border1, lineWidth: 1)
                )
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.Pidgy.fg2)
        }
    }

    @ViewBuilder
    private var qrCard: some View {
        VStack(spacing: 14) {
            ZStack {
                // Gradient frame
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x7BA3F0).opacity(0.18),
                                Color(hex: 0xB58CE2).opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.Pidgy.border1, lineWidth: 1)
                    )
                    .frame(width: 248, height: 248)
                    .shadow(color: .black.opacity(0.45), radius: 40, y: 20)

                // Corner brackets
                cornerBrackets

                // The actual QR (or a placeholder)
                Group {
                    if let link = qrLink, let qrImage = generateQRImage(from: link) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 220, height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 220, height: 220)
                            .overlay {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(Color.Pidgy.bg1)
                            }
                    }
                }
                .blur(radius: isLinking ? 4 : 0)
                .brightness(isLinking ? -0.4 : 0)
                .animation(.easeOut(duration: 0.28), value: isLinking)

                // Sweep line — only while waiting for scan
                if qrLink != nil && !isLinking {
                    sweepLine
                }

                // Linking spinner overlay
                if isLinking {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(hex: 0x5BD18B))
                        Text("Linking your account…")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.Pidgy.fg1)
                    }
                }
            }

            // Status pill
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: 0x5BD18B))
                    .frame(width: 6, height: 6)
                    .opacity(0.9)
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
        }
        .onAppear {
            sweepActive = true
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false)) {
                sweepOffset = 220
            }
        }
    }

    private var isLinking: Bool {
        switch authState {
        case .waitingForCode, .waitingForPassword, .ready: return true
        default: return false
        }
    }

    private var statusText: String {
        if isStarting { return "Initializing secure session…" }
        if isLinking { return "Establishing secure session" }
        if qrLink == nil { return "Waiting for code…" }
        return "Waiting for scan"
    }

    @ViewBuilder
    private var cornerBrackets: some View {
        ZStack {
            // Top-left
            BracketShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                .stroke(Color(hex: 0x7BA3F0), lineWidth: 2.4)
                .frame(width: 18, height: 18)
                .position(x: 13, y: 13)
            // Top-right
            BracketShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                .stroke(Color(hex: 0x7BA3F0), lineWidth: 2.4)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(90))
                .position(x: 235, y: 13)
            // Bottom-right
            BracketShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                .stroke(Color(hex: 0x7BA3F0), lineWidth: 2.4)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(180))
                .position(x: 235, y: 235)
            // Bottom-left
            BracketShape().path(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                .stroke(Color(hex: 0x7BA3F0), lineWidth: 2.4)
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(270))
                .position(x: 13, y: 235)
        }
        .frame(width: 248, height: 248)
    }

    @ViewBuilder
    private var sweepLine: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .clear,
                    Color(hex: 0x7BA3F0).opacity(0.55),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 220, height: 50)
            .offset(y: sweepOffset - 110)
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .allowsHitTesting(false)
    }

    private func generateQRImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

private struct BracketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Two strokes meeting at top-left corner.
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.height))
        return p
    }
}

// MARK: - Provider glyphs

/// Renders one of the brand SVG assets (Telegram / Slack / Gmail) inside
/// the 40×40 chip the connect rows draw. Asset catalog SVGs preserve
/// vector representation, so they stay crisp at any DPI. `inset` lets us
/// pad the glyph against the white tile background (Slack and Gmail want
/// a margin so they don't hug the corners).
private struct BrandSVGGlyph: View {
    let name: String
    var inset: CGFloat = 0

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.original)
            .interpolation(.high)
            .scaledToFit()
            .padding(inset)
            .frame(width: 40, height: 40)
    }
}
