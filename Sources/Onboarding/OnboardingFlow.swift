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
    /// About → Replay onboarding) or right after a Reset. The AppDelegate
    /// observes, clears the completion flag, and reopens the onboarding
    /// window from the welcome step.
    static let pidgyReplayOnboarding = Foundation.Notification.Name("pidgyReplayOnboarding")

    /// Posted when something in the dashboard or launcher needs the
    /// onboarding window brought forward without resetting its progress
    /// (e.g. the launcher panel's "Open welcome window" button when the
    /// user is mid-flow). AppDelegate observes and either reopens the
    /// window if it was closed, or brings the existing one to focus.
    static let pidgyShowOnboardingWindow = Foundation.Notification.Name("pidgyShowOnboardingWindow")

    /// Posted by the "Log out" buttons. AppDelegate observes and runs the
    /// full logout (confirm → unlink device → wipe local data → welcome).
    static let pidgyLogOut = Foundation.Notification.Name("pidgyLogOut")
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
            // markCompleted differentiates "user reached Done" (set the
            // flag, never bother them again) from "user dismissed midway"
            // (don't set the flag — the modal pops up again next launch
            // until they actually finish setup).
            onClose: { [weak self] markCompleted in
                self?.close(markCompleted: markCompleted)
            }
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

    func close(markCompleted: Bool) {
        window?.orderOut(nil)
        window = nil
        if markCompleted {
            UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
        }
        onComplete()
    }
}

// MARK: - Root flow view

private enum OnboardingStep: Int, CaseIterable {
    case welcome, tour, connect, qr, phone, code, password, plan, byokKey, done

    /// Position used for the top progress strip. Phone / code / password
    /// share the QR slot since they're alternative paths through the same
    /// "auth in progress" milestone — no point making the bar bounce
    /// backwards if a tester switches between QR and phone login.
    var progressIndex: Int {
        switch self {
        case .welcome: return 0
        case .tour: return 1
        case .connect: return 2
        case .qr, .phone, .code, .password: return 3
        case .plan, .byokKey: return 4
        case .done: return 5
        }
    }

    static var totalProgressSlots: Int { 5 }
}

struct OnboardingFlow: View {
    @ObservedObject var telegramService: TelegramService
    @ObservedObject var aiService: AIService
    /// Closes the onboarding window. Pass `true` only when the user has
    /// actually finished setup (auth ready + tapped Open Pidgy on Done).
    let onClose: (_ markCompleted: Bool) -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var qrLink: String?
    @State private var isStartingQR = false
    @State private var errorMessage: String?
    @State private var phoneNumber: String = ""
    @State private var verificationCode: String = ""
    @State private var twoFactorPassword: String = ""
    @State private var isSubmitting = false

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
                                errorMessage: errorMessage,
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
                                onUsePhone: { advance(to: .phone) }
                            )
                        case .phone:
                            PhoneStep(
                                phoneNumber: $phoneNumber,
                                errorMessage: errorMessage,
                                isSubmitting: isSubmitting,
                                onBack: { advance(to: .qr) },
                                onSubmit: { Task { await submitPhoneNumber() } }
                            )
                        case .code:
                            CodeStep(
                                phoneNumber: phoneNumber,
                                code: $verificationCode,
                                errorMessage: errorMessage,
                                isSubmitting: isSubmitting,
                                onBack: { advance(to: .phone) },
                                onSubmit: { Task { await submitVerificationCode() } }
                            )
                        case .password:
                            PasswordStep(
                                password: $twoFactorPassword,
                                hint: telegramService.authState.twoFactorPasswordHint,
                                errorMessage: errorMessage,
                                isSubmitting: isSubmitting,
                                onBack: { advance(to: .code) },
                                onSubmit: { Task { await submitPassword() } }
                            )
                        case .plan:
                            PlanStep(onChoosePlan: { plan in
                                EntitlementStore.shared.startTrial(plan: plan)
                                // BYOK needs a key before AI works; bundled
                                // is ready immediately via the proxy.
                                advance(to: plan == .byok ? .byokKey : .done)
                            })
                        case .byokKey:
                            ByokKeyStep(
                                aiService: aiService,
                                onContinue: { advance(to: .done) }
                            )
                        case .done:
                            DoneStep(onFinish: completeOnboarding)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 36)
                    .padding(.top, 56)
                    .padding(.bottom, 36)

                    // No × close button — onboarding is mandatory. Without
                    // Telegram credentials in place, nothing else in the
                    // app actually works, so letting users dismiss the
                    // modal mid-flow just dropped them into a non-functional
                    // dashboard. They can quit the app to abort.
                }
            }
        }
        .frame(width: 680, height: 620)
        .onChange(of: telegramService.authState) { _, newValue in
            handleAuthStateChange(newValue)
        }
        .onAppear {
            // Sync from the current TDLib state on first appear too — if a
            // tester opens the onboarding with TDLib already mid-auth (e.g.
            // a cached 2FA session restored on launch), `onChange` won't
            // fire because the value didn't change from the first reading,
            // and we'd otherwise leave them stuck on Welcome / Connect.
            handleAuthStateChange(telegramService.authState)
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
        let pct = CGFloat(step.progressIndex) / CGFloat(OnboardingStep.totalProgressSlots)
        return total * pct
    }

    private func advance(to next: OnboardingStep) {
        withAnimation(.easeOut(duration: 0.32)) { step = next }
    }

    private func completeOnboarding() {
        // Reaching Done is the only path that marks the user as fully
        // onboarded. Anything else (skip / system close / app crash) keeps
        // the modal in rotation.
        onClose(true)
    }

    private func beginTelegramAuth() async {
        errorMessage = nil

        // If TDLib is already past phone-number entry, just route the UI
        // to the matching step instead of forcing a QR. handleAuthStateChange
        // owns this logic — the previous version blindly advanced to .qr,
        // which left users with cached 2FA sessions stuck on a blank QR
        // card waiting on a state change that would never come.
        switch telegramService.authState {
        case .ready, .waitingForCode, .waitingForPassword:
            handleAuthStateChange(telegramService.authState)
            return
        case .waitingForQrCode(let link):
            qrLink = link
            advance(to: .qr)
            return
        default:
            break
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
                // Source builds without baked-in credentials land here. Tell
                // the user exactly what to do instead of a vague "reinstall".
                errorMessage = "Missing Telegram API credentials. Building from source? Copy Config/BetaSecrets.local.xcconfig.template to Config/BetaSecrets.local.xcconfig, fill in PIDGY_TG_API_ID and PIDGY_TG_API_HASH from https://my.telegram.org/apps, then rerun xcodegen and rebuild."
                return
            }
        }

        advance(to: .qr)

        // Wait until TDLib settles into a state we can act on. It normally
        // transitions uninitialized → waitingForParameters → waitingForPhoneNumber,
        // at which point we can call requestQrCodeAuthentication. If it
        // jumps further on its own (e.g. resumed cached session), let
        // handleAuthStateChange take over.
        let deadline = Date().addingTimeInterval(15)
        actionableLoop: while Date() < deadline {
            switch telegramService.authState {
            case .waitingForPhoneNumber:
                break actionableLoop
            case .ready, .waitingForQrCode, .waitingForCode, .waitingForPassword:
                handleAuthStateChange(telegramService.authState)
                return
            default:
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        guard case .waitingForPhoneNumber = telegramService.authState else { return }

        do {
            try await telegramService.requestQrCodeAuth()
        } catch {
            errorMessage = Self.extractErrorMessage(error)
        }
    }

    private func handleAuthStateChange(_ newState: AuthState) {
        switch newState {
        case .waitingForQrCode(let link):
            qrLink = link
            // Only auto-jump to QR if the user is on Connect / hasn't already
            // chosen the phone path — otherwise switching to phone-login would
            // get yanked back when TDLib re-issues a QR link in the
            // background.
            if step == .connect { advance(to: .qr) }
        case .waitingForCode:
            // Can fire after the phone path submits a number, OR right after
            // a QR scan if Telegram wants extra verification. Route to the
            // code-entry step from anywhere except where we already are.
            errorMessage = nil
            if step != .done && step != .code && step != .password {
                advance(to: .code)
            }
        case .waitingForPassword:
            // 2FA cloud password — surface the password step regardless of
            // whether the user came in via QR or phone+code. The previous
            // gate (only-from-.code) left QR-scan users stuck on the QR
            // card with the "Linking your account…" overlay.
            errorMessage = nil
            if step != .done && step != .password {
                advance(to: .password)
            }
        case .ready:
            // Auth done → choose a plan (starts the free trial) → done.
            // Don't bounce back to plan if we're already past it.
            if step != .done {
                // Pre-cutover the plan step is hidden (BillingGate.showBillingUI),
                // so auth-ready goes straight to Done — the bundled AI just works.
                advance(to: BillingGate.showBillingUI ? .plan : .done)
            }
        default:
            break
        }
    }

    // MARK: - Phone-login submit handlers

    private func submitPhoneNumber() async {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Phone number is required."
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        // Connect step starts TDLib if needed; the phone path skips Connect,
        // so make sure the service is running here too.
        await ensureTelegramServiceRunning()

        do {
            try await telegramService.setPhoneNumber(trimmed)
            // handleAuthStateChange will move us to .code when TDLib responds.
        } catch {
            errorMessage = Self.extractErrorMessage(error)
        }
    }

    private func submitVerificationCode() async {
        let trimmed = verificationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Code is required."
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await telegramService.submitVerificationCode(trimmed)
            // → handleAuthStateChange routes to .password (2FA) or .done.
        } catch {
            errorMessage = Self.extractErrorMessage(error)
        }
    }

    private func submitPassword() async {
        guard !twoFactorPassword.isEmpty else {
            errorMessage = "Password is required."
            return
        }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await telegramService.submitPassword(twoFactorPassword)
            // → handleAuthStateChange routes to .done on .ready.
        } catch {
            errorMessage = Self.extractErrorMessage(error)
        }
    }

    private func ensureTelegramServiceRunning() async {
        guard telegramService.authState == .uninitialized || telegramService.authState == .closed else {
            return
        }
        if let bundledId = BundledSecrets.telegramApiId,
           let bundledHash = BundledSecrets.telegramApiHash {
            telegramService.start(apiId: Int(bundledId), apiHash: bundledHash)
        } else if let storedIdRaw = (try? KeychainManager.retrieve(for: .apiId)),
                  let storedId = Int(storedIdRaw),
                  let storedHash = (try? KeychainManager.retrieve(for: .apiHash)) {
            telegramService.start(apiId: storedId, apiHash: storedHash)
        }
        // Wait briefly for TDLib to reach a state where it accepts auth
        // input. setPhoneNumber on .uninitialized would fail.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .waitingForPhoneNumber = telegramService.authState { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func extractErrorMessage(_ error: Swift.Error) -> String {
        if let tdError = error as? TDLibKit.Error {
            return friendlyAuthMessage(code: tdError.code, message: tdError.message)
        }
        return error.localizedDescription
    }

    /// Maps raw TDLib auth errors (e.g. "PASSWORD_HASH_INVALID",
    /// code 400) to plain-language copy. Telegram surfaces these as
    /// SCREAMING_SNAKE_CASE tokens with an HTTP-ish code, which read
    /// as scary developer noise to a normal user ("Error 400:
    /// PASSWORD_HASH_INVALID"). Anything we don't have a friendly
    /// mapping for falls back to a sanitized version of the token.
    private static func friendlyAuthMessage(code: Int, message: String) -> String {
        let token = message.uppercased()
        switch token {
        case let t where t.contains("PASSWORD_HASH_INVALID"):
            return "Incorrect password. Please try again."
        case let t where t.contains("PHONE_CODE_INVALID"):
            return "That code didn't match. Double-check it and try again."
        case let t where t.contains("PHONE_CODE_EXPIRED"):
            return "That code expired. Request a new one and try again."
        case let t where t.contains("PHONE_NUMBER_INVALID"):
            return "That phone number doesn't look right. Check the country code and try again."
        case let t where t.contains("PHONE_NUMBER_BANNED"):
            return "This phone number is banned from Telegram."
        case let t where t.contains("PHONE_NUMBER_FLOOD"):
            return "Too many attempts from this number. Wait a bit before trying again."
        case let t where t.contains("FLOOD_WAIT"):
            return "Too many attempts. Please wait a moment and try again."
        case let t where t.contains("PASSWORD_TOO_FRESH"):
            return "Telegram is still securing this password change. Try again in a little while."
        case let t where t.contains("SESSION_PASSWORD_NEEDED"):
            return "This account needs its two-factor password to continue."
        default:
            // Sanitize the raw token into something readable rather
            // than exposing "Error 400: SOME_RAW_TOKEN".
            let readable = message
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
            return "Couldn't continue (\(readable)). Please try again."
        }
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
                .fill(Color(hex: 0x161616))
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
    private let rows: [(icon: String, title: String, sub: String)] = [
        ("arrow.uturn.left", "Reply needed", "Direct message · 3h"),
        ("checkmark.square", "Task", "Due today"),
        ("at", "Mention", "Group chat · 1h")
    ]

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06))
                        Image(systemName: row.icon)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF0F0F0))
                        Text(row.sub)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.white.opacity(0.45))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

private struct TourArtSearch: View {
    private let results: [(icon: String, title: String, sub: String)] = [
        ("doc.text", "Shared file", "report-q3.pdf · last week"),
        ("text.bubble", "Group chat", "sent it over · Mon")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("where's the file from last week?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0xF0F0F0))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.06))
                        Image(systemName: r.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xF0F0F0))
                        Text(r.sub)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private struct TourArtLocal: View {
    var body: some View {
        HStack(spacing: 26) {
            VStack(spacing: 9) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.38))
                Text("No cloud")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 46)

            VStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.82))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xF0F0F0))
                        .padding(4)
                        .background(Circle().fill(Color(hex: 0x161616)))
                        .offset(x: 5, y: 3)
                }
                Text("On your Mac")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Connect step

private struct ConnectStep: View {
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

private struct PlanStep: View {
    let onChoosePlan: (PidgyPlan) -> Void

    @State private var selected: PidgyPlan = .bundled

    var body: some View {
        VStack(spacing: 0) {
            Text("Pick your plan")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Both start with a \(Subscription.trialDays)-day free trial. No charge today — cancel anytime before it ends.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 460)

            HStack(alignment: .top, spacing: 14) {
                planCard(
                    .bundled,
                    blurb: "We run the AI — nothing to set up. Reply suggestions, summaries, and semantic search work out of the box.",
                    bullets: ["Zero setup", "Managed AI via our non-logging proxy", "Best for getting started"]
                )
                planCard(
                    .byok,
                    blurb: "Bring your own OpenAI or Claude key. It goes straight to the provider — never through Pidgy. Maximum privacy.",
                    bullets: ["Your key, your bill", "Nothing transits our servers", "For the privacy-max user"]
                )
            }
            .padding(.top, 28)
            .frame(maxWidth: 720)

            OnboardingPrimaryButton(
                title: "Start \(Subscription.trialDays)-day free trial",
                trailingChevron: true,
                action: { onChoosePlan(selected) }
            )
            .padding(.top, 28)

            Text("You can update your AI key anytime in Preferences. Plan changes go through Manage subscription.")
                .font(.system(size: 11))
                .foregroundStyle(Color.Pidgy.fg4)
                .padding(.top, 14)
        }
        .frame(maxWidth: 720)
    }

    @ViewBuilder
    private func planCard(_ plan: PidgyPlan, blurb: String, bullets: [String]) -> some View {
        let isSelected = selected == plan
        Button {
            selected = plan
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(plan.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Spacer(minLength: 0)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.Pidgy.accentFg : Color.Pidgy.border2)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("$\(plan.monthlyPriceUSD)")
                        .font(.custom("Newsreader", size: 30).weight(.medium))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Text("/mo")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                Text(blurb)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.Pidgy.accentFg)
                                .padding(.top, 2)
                            Text(bullet)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.Pidgy.fg2)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg3 : Color.Pidgy.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isSelected ? Color.Pidgy.accentFg.opacity(0.7) : Color.Pidgy.border2,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(PidgyMotion.easeOut, value: isSelected)
    }
}

private struct ByokKeyStep: View {
    @ObservedObject var aiService: AIService
    let onContinue: () -> Void

    @State private var provider: AIProviderConfig.ProviderType = .openai
    @State private var key: String = ""
    @State private var isVerifying = false
    @State private var errorMessage: String?

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add your AI key")
                .font(.custom("Newsreader", size: 36).weight(.medium))
                .tracking(-0.8)
                .foregroundStyle(Color.Pidgy.fg1)

            Text("Your key goes straight to the provider — never through Pidgy. We just verify it works.")
                .font(.system(size: 14))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 12)
                .frame(maxWidth: 440)

            HStack(spacing: 8) {
                ForEach([AIProviderConfig.ProviderType.openai, .claude], id: \.self) { option in
                    Button {
                        provider = option
                        errorMessage = nil
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(provider == option ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(provider == option ? Color.Pidgy.bg4 : Color.clear)
                                    .overlay(Capsule().stroke(
                                        provider == option ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2
                                    ))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 22)

            SecureField(provider == .openai ? "sk-…" : "sk-ant-…", text: $key)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .frame(maxWidth: 440)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg1)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Pidgy.border2))
                )
                .padding(.top, 14)
                .onChange(of: key) { errorMessage = nil }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 8)
            }

            OnboardingPrimaryButton(
                title: isVerifying ? "Verifying…" : "Verify & continue",
                trailingChevron: !isVerifying,
                isDisabled: trimmedKey.isEmpty || isVerifying,
                action: verify
            )
            .padding(.top, 22)

            Button("Skip — I'll add it later in Preferences") { onContinue() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.Pidgy.fg4)
                .padding(.top, 14)
        }
        .frame(maxWidth: 520)
    }

    private func verify() {
        let candidate = trimmedKey
        guard !candidate.isEmpty else { return }
        isVerifying = true
        errorMessage = nil
        // BYO key goes direct to the provider (no proxy endpoint).
        aiService.configure(type: provider, apiKey: candidate)
        Task { @MainActor in
            do {
                let ok = try await aiService.testConnection()
                isVerifying = false
                if ok {
                    onContinue()
                } else {
                    errorMessage = "Couldn't verify that key. Double-check and try again."
                }
            } catch {
                isVerifying = false
                errorMessage = "Couldn't verify that key. Double-check and try again."
            }
        }
    }
}

private struct DoneStep: View {
    let onFinish: () -> Void

    @State private var checkScale: CGFloat = 0.4
    @State private var checkOpacity: Double = 0
    /// Asked once, here, right after the user connected Telegram —
    /// pre-selected by detecting whether a tg:// handler is installed.
    /// Changeable any time in Preferences → "Open chats in".
    @State private var chatOpenTarget: ChatOpenTarget = .current

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

            VStack(spacing: 10) {
                Text("Where should chats open?")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg2)
                HStack(spacing: 8) {
                    ForEach(ChatOpenTarget.allCases) { option in
                        Button {
                            chatOpenTarget = option
                            UserDefaults.standard.set(
                                option.rawValue,
                                forKey: AppConstants.Preferences.chatOpenTargetKey
                            )
                        } label: {
                            Text(option.label)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(chatOpenTarget == option ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(chatOpenTarget == option ? Color.Pidgy.bg4 : Color.clear)
                                        .overlay(
                                            Capsule().stroke(
                                                chatOpenTarget == option ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2
                                            )
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("You can change this anytime in Preferences.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
            .padding(.top, 24)

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
    var isDisabled: Bool = false
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
            .foregroundStyle(isDisabled ? Color.Pidgy.fg3 : Color.Pidgy.bg1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDisabled ? Color.Pidgy.bg3 : Color.Pidgy.fg1.opacity(hovering ? 0.9 : 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Auth state convenience

private extension AuthState {
    /// Pulls the optional 2FA hint out of `.waitingForPassword(hint:)`.
    /// Returns nil for any other state — the password step degrades to
    /// just the input field if no hint is set on the account.
    var twoFactorPasswordHint: String? {
        if case .waitingForPassword(let hint) = self { return hint }
        return nil
    }
}

// MARK: - Phone-login step

private struct PhoneStep: View {
    @Binding var phoneNumber: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Sign in with phone number")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            Text("Telegram will text you a 5-digit code. Use international format with the country code.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 380)

            OnboardingTextField(
                title: "Phone number",
                placeholder: "+1 555 123 4567",
                text: $phoneNumber
            )
            .padding(.top, 26)
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back to QR")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Sending…" : "Send code",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - Verification code step

private struct CodeStep: View {
    let phoneNumber: String
    @Binding var code: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Enter the code")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            (
                Text("We sent a 5-digit code to ")
                    .foregroundColor(Color.Pidgy.fg3)
                + Text(phoneNumber.isEmpty ? "your phone" : phoneNumber)
                    .foregroundColor(Color.Pidgy.fg1)
                    .fontWeight(.medium)
                + Text(". Open Telegram on the device that received it if it doesn't auto-fill.")
                    .foregroundColor(Color.Pidgy.fg3)
            )
            .font(.system(size: 13.5))
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.top, 14)
            .frame(maxWidth: 400)

            OnboardingTextField(
                title: "Verification code",
                placeholder: "12345",
                text: $code
            )
            .padding(.top, 26)
            .frame(maxWidth: 240)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Verifying…" : "Verify",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - 2FA password step

private struct PasswordStep: View {
    @Binding var password: String
    let hint: String?
    let errorMessage: String?
    let isSubmitting: Bool
    let onBack: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Telegram")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.32)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.accentFg)

            Text("Two-factor password")
                .font(.custom("Newsreader", size: 30).weight(.medium))
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .padding(.top, 8)

            Text("Your account has 2FA on. Enter the cloud password you set in Telegram → Privacy → Two-Step Verification.")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 14)
                .frame(maxWidth: 400)

            if let hint, !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.fg2)
                    .padding(.top, 8)
            }

            OnboardingTextField(
                title: "Password",
                placeholder: "Your 2FA password",
                text: $password,
                isSecure: true
            )
            .padding(.top, 24)
            .frame(maxWidth: 320)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Pidgy.danger)
                    .padding(.top, 12)
            }

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("← Back")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)

                OnboardingPrimaryButton(
                    title: isSubmitting ? "Verifying…" : "Sign in",
                    trailingChevron: !isSubmitting,
                    isDisabled: isSubmitting,
                    action: onSubmit
                )
            }
            .padding(.top, 28)
        }
        .frame(maxWidth: 480)
    }
}

// MARK: - Shared text field for the auth steps

private struct OnboardingTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: PidgySpace.s1) {
            Text(title)
                .font(Font.Pidgy.eyebrow)
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.fg3)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Font.Pidgy.body)
            .padding(PidgySpace.s3)
            .background(Color.Pidgy.bg3)
            .cornerRadius(PidgyRadius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: PidgyRadius.sm, style: .continuous)
                    .stroke(Color.Pidgy.border2, lineWidth: 1)
            )
        }
    }
}
