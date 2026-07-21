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
