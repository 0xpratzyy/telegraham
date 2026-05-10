//
//  OnboardingFlow.swift
//  Pidgy
//
//  First-launch onboarding modeled on the Pidgy Desktop design handoff —
//  five-step flow (Welcome → Tour → Connect → QR → Done) presented in a
//  680×620 modal window. Drives the existing TelegramService auth state
//  machine; the QR step renders the real TDLib-issued QR link with the
//  design's corner brackets, sweep, and status pill on top.
//
//  Lives in its own NSWindow so it cleanly owns the first-launch
//  experience without fighting the menu-bar panel sizing.
//

import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TDLibKit

// MARK: - Notifications

extension Foundation.Notification.Name {
    /// Posted when the user wants to replay the onboarding flow (Preferences →
    /// About → Replay onboarding). The AppDelegate observes and reopens the
    /// onboarding window.
    static let pidgyReplayOnboarding = Foundation.Notification.Name("pidgyReplayOnboarding")
}

// MARK: - Onboarding window controller

@MainActor
final class OnboardingWindowController {
    private weak var telegramService: TelegramService?
    private weak var aiService: AIService?
    private var window: NSWindow?
    private let onComplete: () -> Void

    init(telegramService: TelegramService, aiService: AIService, onComplete: @escaping () -> Void) {
        self.telegramService = telegramService
        self.aiService = aiService
        self.onComplete = onComplete
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let telegramService, let aiService else { return }

        let view = OnboardingFlow(
            telegramService: telegramService,
            aiService: aiService,
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = ""
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.contentView = hosting
        newWindow.center()
        newWindow.minSize = NSSize(width: 680, height: 620)
        newWindow.maxSize = NSSize(width: 680, height: 620)

        // Hide the standard window buttons — design uses its own × in the
        // top-right and a progress strip across the top.
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newWindow.standardWindowButton(.closeButton)?.isHidden = true

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
        onComplete()
    }
}

// MARK: - Root flow view

private enum OnboardingStep: Int, CaseIterable {
    case welcome, tour, connect, qr, done

    var index: Int { rawValue }
    static var totalForProgress: Int { OnboardingStep.allCases.count - 1 }
}

struct OnboardingFlow: View {
    @ObservedObject var telegramService: TelegramService
    @ObservedObject var aiService: AIService
    let onClose: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var qrLink: String?
    @State private var isStartingQR = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Backdrop matching the design — dim + blur, but since this is a
            // standalone window it just renders the bg-1 color with a soft
            // radial highlight at the top.
            Color.Pidgy.bg1
                .ignoresSafeArea()

            RadialGradient(
                colors: [Color.white.opacity(0.04), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress strip across the top — neutral gray fill, hidden
                // until we leave the welcome screen.
                progressStrip
                    .frame(height: 2)

                ZStack(alignment: .topTrailing) {
                    // Step content centered.
                    Group {
                        switch step {
                        case .welcome:
                            WelcomeStep { advance(to: .tour) }
                        case .tour:
                            TourStep(
                                onAdvance: { advance(to: .connect) },
                                onBack: { advance(to: .welcome) }
                            )
                        case .connect:
                            ConnectStep(
                                isAuthReady: telegramService.authState == .ready,
                                onPickTelegram: { Task { await beginTelegramAuth() } },
                                onBack: { advance(to: .tour) }
                            )
                        case .qr:
                            QRStep(
                                authState: telegramService.authState,
                                qrLink: qrLink,
                                isStarting: isStartingQR,
                                errorMessage: errorMessage,
                                onBack: { advance(to: .connect) },
                                onUsePhone: { Task { await switchToPhoneAuth() } }
                            )
                        case .done:
                            DoneStep(onFinish: completeOnboarding)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    .padding(.top, 56)
                    .padding(.bottom, 36)

                    // × close — present on every step except .done where the
                    // primary CTA replaces it.
                    if step != .done {
                        Button(action: skipFlow) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.Pidgy.fg3)
                                .frame(width: 30, height: 30)
                                .background(
                                    Circle().fill(Color.Pidgy.bg2)
                                )
                                .overlay(
                                    Circle().stroke(Color.Pidgy.border1, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 18)
                        .padding(.trailing, 18)
                    }
                }
            }
        }
        .frame(width: 680, height: 620)
        .onChange(of: telegramService.authState) { _, newValue in
            handleAuthStateChange(newValue)
        }
    }

    private var progressStrip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color.Pidgy.bg2
                Color.Pidgy.fg2.opacity(0.5)
                    .frame(width: progressFillWidth(total: geo.size.width))
                    .animation(.easeOut(duration: 0.42), value: step)
            }
        }
    }

    private func progressFillWidth(total: CGFloat) -> CGFloat {
        let pct = CGFloat(step.index) / CGFloat(OnboardingStep.totalForProgress)
        return total * pct
    }

    private func advance(to next: OnboardingStep) {
        withAnimation(.easeOut(duration: 0.32)) { step = next }
    }

    private func skipFlow() {
        // Skip leaves onboarding without auth completion. The AppDelegate's
        // existing AuthView path will pick up wherever the user is in the
        // state machine.
        UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
        onClose()
    }

    private func completeOnboarding() {
        onClose()
    }

    private func beginTelegramAuth() async {
        errorMessage = nil

        // If the user is already signed in (replaying onboarding mid-session),
        // skip the QR rigmarole entirely and jump straight to Done.
        if telegramService.authState == .ready {
            advance(to: .done)
            return
        }

        isStartingQR = true
        defer { isStartingQR = false }

        // Make sure TDLib is started. AppDelegate already kicks it off with
        // bundled or stored credentials, but a tester replaying onboarding
        // mid-session might land here while the service is still uninitialized.
        if telegramService.authState == .uninitialized || telegramService.authState == .closed {
            if let bundledId = BundledSecrets.telegramApiId,
               let bundledHash = BundledSecrets.telegramApiHash {
                telegramService.start(apiId: Int(bundledId), apiHash: bundledHash)
            } else if let storedIdRaw = (try? KeychainManager.retrieve(for: .apiId)),
                      let storedId = Int(storedIdRaw),
                      let storedHash = (try? KeychainManager.retrieve(for: .apiHash)) {
                telegramService.start(apiId: storedId, apiHash: storedHash)
            } else {
                errorMessage = "Missing Telegram credentials. Reinstall the app or contact the developer."
                return
            }
        }

        advance(to: .qr)

        // Wait until TDLib settles into a state where we can request the QR.
        // It transitions uninitialized → waitingForParameters → waitingForPhoneNumber,
        // and only then will requestQrCodeAuthentication produce a link.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .waitingForPhoneNumber = telegramService.authState { break }
            if case .ready = telegramService.authState { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        guard case .waitingForPhoneNumber = telegramService.authState else { return }

        do {
            try await telegramService.requestQrCodeAuth()
        } catch {
            errorMessage = Self.extractErrorMessage(error)
        }
    }

    private func switchToPhoneAuth() async {
        // Phone fallback isn't part of the design's onboarding flow but we
        // keep the option for testers whose Telegram clients can't scan a QR.
        // Skip onboarding wrapper and let AuthView take over — it has the
        // full phone/code/password chain.
        UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
        onClose()
    }

    private func handleAuthStateChange(_ newState: AuthState) {
        switch newState {
        case .waitingForQrCode(let link):
            qrLink = link
            if step == .connect { advance(to: .qr) }
        case .ready:
            advance(to: .done)
        default:
            break
        }
    }

    private static func extractErrorMessage(_ error: Swift.Error) -> String {
        if let tdError = error as? TDLibKit.Error {
            return "Error \(tdError.code): \(tdError.message)"
        }
        return error.localizedDescription
    }
}

// MARK: - Welcome step

private struct WelcomeStep: View {
    let onNext: () -> Void

    @State private var float: CGFloat = 0
    @State private var glow: Double = 0.6

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Soft glow ring, pulsing.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0x7BA3F0).opacity(0.25), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .opacity(glow)

                PidgyMascotMark(size: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .offset(y: float)
            }
            .padding(.bottom, 28)

            Text("Welcome to Pidgy")
                .font(.Pidgy.heroTitle)
                .tracking(-1.0)
                .foregroundStyle(Color.Pidgy.fg1)
                .lineSpacing(2)

            Text("Your local-first command center for replies, tasks, people, and topics across every conversation you keep.")
                .font(.custom("Newsreader", size: 17))
                .italic()
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 480)

            OnboardingPrimaryButton(title: "Get started", trailingChevron: true, action: onNext)
                .padding(.top, 32)
        }
        .frame(maxWidth: 480)
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                float = -6
            }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                glow = 1.0
            }
        }
    }
}

// MARK: - Tour step

private struct TourSlide: Identifiable {
    let id = UUID()
    let eyebrow: String
    let title: String
    let body: String
    let kind: TourArtKind
}

private enum TourArtKind { case inbox, search, local }

private let tourSlides: [TourSlide] = [
    TourSlide(
        eyebrow: "Triage",
        title: "Your inbox, finally on your side",
        body: "Pidgy reads every chat in the background and decides what actually needs you. Replies, tasks, mentions — surfaced. Group spam — gone.",
        kind: .inbox
    ),
    TourSlide(
        eyebrow: "Search",
        title: "Ask in plain English",
        body: "Find the message, file, or person you need with a sentence. Pidgy reasons across all your chats and pulls the receipts.",
        kind: .search
    ),
    TourSlide(
        eyebrow: "Local",
        title: "Yours, on your machine",
        body: "Everything stays on your Mac. Your AI key, your messages, your decisions. Pidgy never phones home.",
        kind: .local
    )
]

private struct TourStep: View {
    let onAdvance: () -> Void
    let onBack: () -> Void

    @State private var idx: Int = 0

    var body: some View {
        let slide = tourSlides[idx]
        VStack(spacing: 0) {
            TourArt(kind: slide.kind)
                .id(slide.id)
                .frame(maxWidth: 320, maxHeight: 160)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            Text(slide.eyebrow)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.fg3)
                .padding(.top, 26)

            Text(slide.title)
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 10)

            Text(slide.body)
                .font(.system(size: 14.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            HStack(spacing: 16) {
                circularChevronButton(symbol: "chevron.left", filled: false) {
                    if idx > 0 {
                        withAnimation(.easeOut(duration: 0.32)) { idx -= 1 }
                    } else {
                        onBack()
                    }
                }

                HStack(spacing: 6) {
                    ForEach(0..<tourSlides.count, id: \.self) { i in
                        Capsule()
                            .fill(i == idx ? Color.Pidgy.fg1 : Color.Pidgy.border2)
                            .frame(width: i == idx ? 22 : 6, height: 6)
                            .animation(.easeOut(duration: 0.28), value: idx)
                    }
                }

                circularChevronButton(symbol: "chevron.right", filled: true) {
                    if idx < tourSlides.count - 1 {
                        withAnimation(.easeOut(duration: 0.32)) { idx += 1 }
                    } else {
                        onAdvance()
                    }
                }
            }
            .padding(.top, 36)

            Button(action: onAdvance) {
                Text("Skip tour →")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .frame(maxWidth: 540)
    }

    @ViewBuilder
    private func circularChevronButton(symbol: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Color.Pidgy.bg1 : Color.Pidgy.fg2)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(filled ? Color.Pidgy.fg1 : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(filled ? Color.Pidgy.fg1 : Color.Pidgy.border2, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tour art (monochrome SVG-equivalent in SwiftUI)

private struct TourArt: View {
    let kind: TourArtKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x1A1B1F))
            switch kind {
            case .inbox: TourArtInbox()
            case .search: TourArtSearch()
            case .local: TourArtLocal()
            }
        }
        .frame(height: 160)
    }
}

private struct TourArtInbox: View {
    var body: some View {
        GeometryReader { geo in
            let rows: [(label: String, sub: String, opacity: Double)] = [
                ("Reply needed", "Rahul · 3h", 0.85),
                ("Task", "Pay rent · today", 0.67),
                ("Mention", "@you in FBI Loop", 0.49)
            ]
            let scale = geo.size.width / 360.0
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                let y = (22 + CGFloat(i) * 38) * scale
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(hex: 0x15161A))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .frame(width: 220 * scale, height: 30 * scale)

                    HStack(spacing: 8 * scale) {
                        Capsule()
                            .fill(Color.white.opacity(row.opacity))
                            .frame(width: 2.5 * scale, height: 16 * scale)
                            .padding(.leading, 8 * scale)
                        Circle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 10 * scale, height: 10 * scale)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.label)
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundStyle(Color(hex: 0xE8E9EC))
                            Text(row.sub)
                                .font(.system(size: 8 * scale))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        Spacer()
                        Circle()
                            .fill(Color.white.opacity(0.7 - Double(i) * 0.18))
                            .frame(width: 4 * scale, height: 4 * scale)
                            .padding(.trailing, 12 * scale)
                    }
                    .frame(width: 220 * scale, height: 30 * scale)
                }
                .position(x: 230 * scale, y: y + 15 * scale)
            }
        }
    }
}

private struct TourArtSearch: View {
    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 360.0
            VStack(alignment: .leading, spacing: 8 * scale) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: 0x15161A))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    HStack(spacing: 8 * scale) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                        Text("where did Sahil send the wireframes")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(Color(hex: 0xE8E9EC))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 16 * scale)
                }
                .frame(width: 312 * scale, height: 40 * scale)

                ForEach(0..<2) { i in
                    let r: (who: String, hl: String, when: String) = i == 0
                        ? ("Sahil", "wireframes_v3.fig", "yesterday")
                        : ("You", "check the new wires", "Mon")
                    HStack(spacing: 10 * scale) {
                        Circle()
                            .fill(Color.white.opacity(i == 0 ? 0.22 : 0.14))
                            .frame(width: 16 * scale, height: 16 * scale)
                            .overlay(
                                Text(String(r.who.prefix(1)))
                                    .font(.system(size: 8 * scale, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                        VStack(alignment: .leading, spacing: 2 * scale) {
                            Text("\(r.who) · Design Loop")
                                .font(.system(size: 9.5 * scale, weight: .medium))
                                .foregroundStyle(Color(hex: 0xE8E9EC))
                            HStack(spacing: 4 * scale) {
                                Text(r.hl)
                                    .font(.system(size: 8.5 * scale, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4 * scale)
                                    .padding(.vertical, 1 * scale)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(Color.white.opacity(0.10))
                                    )
                                Text("· \(r.when)")
                                    .font(.system(size: 8 * scale))
                                    .foregroundStyle(Color.white.opacity(0.4))
                            }
                        }
                        Spacer()
                    }
                    .frame(width: 312 * scale, height: 32 * scale)
                    .padding(.leading, 8 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                    )
                }
            }
            .padding(.leading, 24 * scale)
            .padding(.top, 20 * scale)
        }
    }
}

private struct TourArtLocal: View {
    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 360.0
            ZStack {
                ForEach([78.0, 56.0, 36.0], id: \.self) { r in
                    Circle()
                        .stroke(
                            Color.white.opacity(0.10),
                            style: StrokeStyle(lineWidth: 1, dash: r == 78 ? [3, 4] : [])
                        )
                        .frame(width: r * 2 * scale, height: r * 2 * scale)
                }

                // Crossed-out cloud server (left)
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.2)
                        .frame(width: 36 * scale, height: 22 * scale)
                    HStack(spacing: 4 * scale) {
                        Circle().fill(Color.white.opacity(0.45)).frame(width: 3 * scale, height: 3 * scale)
                        Circle().fill(Color.white.opacity(0.45)).frame(width: 3 * scale, height: 3 * scale)
                        Spacer()
                    }
                    .frame(width: 36 * scale, height: 22 * scale)
                    .padding(.leading, 8 * scale)
                    Path { p in
                        p.move(to: CGPoint(x: -4 * scale, y: -4 * scale))
                        p.addLine(to: CGPoint(x: 40 * scale, y: 26 * scale))
                    }
                    .stroke(Color.white.opacity(0.7), lineWidth: 1.6 * scale)
                    .frame(width: 36 * scale, height: 22 * scale)
                }
                .opacity(0.55)
                .position(x: 92 * scale, y: 70 * scale)

                Text("no cloud")
                    .font(.system(size: 8.5 * scale))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .position(x: 92 * scale, y: 102 * scale)

                // Mac (right)
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .frame(width: 44 * scale, height: 50 * scale)

                    VStack(alignment: .leading, spacing: 3 * scale) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.7))
                            .frame(width: 14 * scale, height: 3 * scale)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 22 * scale, height: 2 * scale)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 18 * scale, height: 2 * scale)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 20 * scale, height: 2 * scale)
                    }
                    .frame(width: 32 * scale, height: 28 * scale, alignment: .topLeading)
                    .padding(6 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(hex: 0x0E0F12))
                            .frame(width: 32 * scale, height: 28 * scale)
                    )
                    .offset(y: -8 * scale)

                    Circle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 3.2 * scale, height: 3.2 * scale)
                        .offset(y: 18 * scale)
                }
                .position(x: 270 * scale, y: 80 * scale)

                Text("your Mac")
                    .font(.system(size: 8.5 * scale))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .position(x: 270 * scale, y: 122 * scale)

                // Dashed connector
                Path { p in
                    p.move(to: CGPoint(x: 214 * scale, y: 80 * scale))
                    p.addQuadCurve(
                        to: CGPoint(x: 246 * scale, y: 76 * scale),
                        control: CGPoint(x: 234 * scale, y: 80 * scale)
                    )
                }
                .stroke(
                    Color.white.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.2, dash: [2, 3])
                )
            }
        }
    }
}

// MARK: - Connect step

private struct ConnectStep: View {
    let isAuthReady: Bool
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

private struct QRStep: View {
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

// MARK: - Done step

private struct DoneStep: View {
    let onFinish: () -> Void

    @State private var checkScale: CGFloat = 0.4
    @State private var checkOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color(hex: 0x5BD18B).opacity(0.14))
                    .frame(width: 88, height: 88)
                Circle()
                    .stroke(Color(hex: 0x5BD18B).opacity(0.4), lineWidth: 1)
                    .frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x5BD18B))
            }
            .scaleEffect(checkScale)
            .opacity(checkOpacity)
            .padding(.bottom, 24)

            Text("You're all set")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Pidgy is now indexing your chats locally. Triage will populate over the next minute.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            OnboardingPrimaryButton(title: "Open Pidgy", trailingChevron: true, action: onFinish)
                .padding(.top, 28)
        }
        .frame(maxWidth: 440)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6)) {
                checkScale = 1
                checkOpacity = 1
            }
        }
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

// MARK: - Primary button

private struct OnboardingPrimaryButton: View {
    let title: String
    let trailingChevron: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if trailingChevron {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Color.Pidgy.bg1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Pidgy.fg1.opacity(hovering ? 0.9 : 1))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
