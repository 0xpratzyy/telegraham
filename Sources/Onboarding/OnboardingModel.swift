//
//  OnboardingModel.swift
//  Pidgy
//
//  Onboarding as a conversation with the pigeon, held in a floating glass
//  panel the size of the launcher. The pigeon flies in and perches on the
//  panel's top edge; each step is a turn — Pidgy says one line, you answer
//  in the panel's input or by picking a chip — and previous turns collapse
//  into a dimmed transcript above. At the end the pigeon flies to the menu
//  bar and the panel hands off to the dashboard.
//
//  This file: the step graph (`OnboardingStep` + `OnboardingRouting`, unit-
//  tested), the state machine (`OnboardingConversationModel`), and the
//  window controller that owns the panel + pigeon overlay windows.
//

import AppKit
import Combine
import SwiftUI
import TDLibKit

// MARK: - Notifications

extension Foundation.Notification.Name {
    /// Replay onboarding (Preferences → About) or right after a Reset.
    static let pidgyReplayOnboarding = Foundation.Notification.Name("pidgyReplayOnboarding")
    /// Bring the onboarding panel forward without resetting progress.
    static let pidgyShowOnboardingWindow = Foundation.Notification.Name("pidgyShowOnboardingWindow")
    /// "Log out" buttons — AppDelegate runs the full logout.
    static let pidgyLogOut = Foundation.Notification.Name("pidgyLogOut")
    /// ⌘⇧T pressed while onboarding is up — routed here instead of toggling
    /// the launcher so the "try the shortcut" turn can react.
    static let pidgyOnboardingHotkey = Foundation.Notification.Name("pidgyOnboardingHotkey")
}

// MARK: - Steps

enum OnboardingStep: Equatable {
    case welcome, signIn, invite, sources
    case telegramPhone, telegramCode, telegramPassword
    case intelligence, shortcut, launchAtLogin
    case plan, byokKey
    case done

    var isTelegramAuth: Bool {
        switch self {
        case .telegramPhone, .telegramCode, .telegramPassword: return true
        default: return false
        }
    }
}

/// Pure routing so the skip rules are testable without views.
enum OnboardingRouting {
    static func canOpenDashboard(didComplete: Bool, hasTelegramCredentials: Bool) -> Bool {
        // A completed setup may use Slack/Gmail/WhatsApp, or defer sources.
        didComplete || hasTelegramCredentials
    }
    static func afterWelcome(accountConfigured: Bool, signedIn: Bool, inviteGateRequired: Bool, inviteRegistered: Bool) -> OnboardingStep {
        if accountConfigured && !signedIn { return .signIn }
        return afterSignIn(inviteGateRequired: inviteGateRequired, inviteRegistered: inviteRegistered)
    }

    static func afterSignIn(inviteGateRequired: Bool, inviteRegistered: Bool) -> OnboardingStep {
        (inviteGateRequired && !inviteRegistered) ? .invite : .sources
    }

    static func afterLaunchAtLogin(showBillingUI: Bool, aiSetupVisited: Bool = false) -> OnboardingStep {
        showBillingUI && !aiSetupVisited ? .plan : .done
    }

    static func back(from step: OnboardingStep, accountConfigured: Bool, inviteGateRequired: Bool, inviteRegistered: Bool) -> OnboardingStep? {
        switch step {
        case .welcome, .done: return nil
        case .plan: return .launchAtLogin
        case .byokKey: return .plan
        case .signIn: return .welcome
        case .invite: return accountConfigured ? .signIn : .welcome
        case .sources:
            if inviteGateRequired && !inviteRegistered { return .invite }
            return accountConfigured ? .signIn : .welcome
        case .telegramPhone: return .sources
        // TDLib cannot return to an earlier challenge without restarting auth.
        case .telegramCode, .telegramPassword: return .sources
        case .intelligence: return .sources
        case .shortcut: return .intelligence
        case .launchAtLogin: return .shortcut
        }
    }
}

// MARK: - Model

@MainActor
final class OnboardingConversationModel: ObservableObject {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var line: String
        var reply: String?
    }

    enum SourceKind: String, CaseIterable, Identifiable {
        case telegram, slack, gmail, whatsapp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .telegram: return "Telegram"
            case .slack: return "Slack"
            case .gmail: return "Gmail"
            case .whatsapp: return "WhatsApp"
            }
        }
    }

    enum SourceState: Equatable {
        case available, busy(String), connected(String), failed(String), unavailable
        var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    /// What's expanded under the source chips.
    enum SourceDetail: Equatable {
        case telegramQR(link: String?)
        case whatsAppQR
    }

    let telegramService: TelegramService
    let aiService: AIService
    let pigeon: PigeonActor
    let onFinished: () -> Void

    @Published private(set) var step: OnboardingStep = .welcome
    @Published private(set) var transcript: [Turn] = []
    @Published var inputText = ""
    @Published private(set) var errorText: String?
    @Published private(set) var isBusy = false
    @Published private(set) var signingInProvider: AccountService.Provider?
    @Published private(set) var sourceDetail: SourceDetail?
    @Published private(set) var panelBounceToken = 0
    @Published private(set) var byokProvider: AIProviderConfig.ProviderType = .openai
    /// Sources the user has actually tapped this session — spinners only
    /// show for these, not for background reconnects.
    @Published private(set) var picked: Set<SourceKind> = []

    private var cancellables: Set<AnyCancellable> = []
    private var lastTelegramState: AuthState?
    private var didStartTelegramQR = false
    private var telegramAuthTask: Task<Void, Never>?
    @Published private var sourceRequestsInFlight: Set<SourceKind> = []
    private var didFinish = false
    private var completionTask: Task<Void, Never>?
    private let browserConnector: @MainActor (SourceKind) async -> Void
    /// Restore this setup session after the browser returns a success or error.
    var browserConnectionFinished: (() -> Void)?
    @Published private(set) var codeResendAvailableAt: Foundation.Date?
    @Published private(set) var statusText: String?
    private var keySetupFromIntelligence = false
    private var planSetupFromIntelligence = false

    var account: AccountService { AccountService.shared }
    var invites: InviteService { InviteService.shared }
    var slack: SlackConnectionManager { SlackConnectionManager.shared }
    var gmail: GmailConnectionManager { GmailConnectionManager.shared }
    var whatsApp: WhatsAppConnectionManager { WhatsAppConnectionManager.shared }

    init(telegramService: TelegramService, aiService: AIService, pigeon: PigeonActor, observeServices: Bool = true,
         browserConnector: @escaping @MainActor (SourceKind) async -> Void = { kind in
             switch kind {
             case .slack: await SlackConnectionManager.shared.connect()
             case .gmail: await GmailConnectionManager.shared.connect()
             default: break
             }
         }, onFinished: @escaping () -> Void) {
        self.telegramService = telegramService
        self.aiService = aiService
        self.pigeon = pigeon
        self.onFinished = onFinished
        self.browserConnector = browserConnector
        transcript = [Turn(line: "A little clarity for every chat.")]
        if observeServices { observe() }
    }

    // MARK: Derived

    var currentTurn: Turn? { transcript.last }
    var heading: String {
        if step == .sources {
            switch sourceDetail {
            case .telegramQR: return "Connect Telegram"
            case .whatsAppQR: return "Connect WhatsApp"
            case nil: return "Where do people reach you?"
            }
        }
        return opener(for: step)
    }
    var sourceInstructions: String {
        "Choose one to start. You can add more later."
    }
    var canSubmitInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }
    var pastTurns: [Turn] { Array(transcript.dropLast()) }

    var canGoBack: Bool {
        !isBusy && OnboardingRouting.back(
            from: step,
            accountConfigured: AccountService.isConfigured,
            inviteGateRequired: InviteService.gateRequired,
            inviteRegistered: invites.isRegistered
        ) != nil
    }

    #if DEBUG
    // Deterministic view previews and regression tests never connect real accounts.
    private var previewSources: [SourceKind: SourceState]?
    func configurePreview(step: OnboardingStep, sources: [SourceKind: SourceState] = [.telegram: .available, .slack: .available, .whatsapp: .available], detail: SourceDetail? = nil, error: String? = nil) {
        self.step = step
        self.sourceDetail = detail
        self.errorText = error
        self.previewSources = sources
        self.transcript = [Turn(line: opener(for: step))]
    }
    #endif

    func sourceState(_ kind: SourceKind) -> SourceState {
        #if DEBUG
        if let previewSources { return previewSources[kind] ?? .unavailable }
        #endif
        if sourceRequestsInFlight.contains(kind) { return .busy("In your browser…") }
        switch kind {
        case .telegram:
            switch telegramService.authState {
            case .ready: return .connected(telegramService.currentUser?.firstName ?? "Signed in")
            case .waitingForQrCode, .waitingForCode, .waitingForPassword:
                return picked.contains(.telegram) ? .busy("Linking…") : .available
            default: return .available
            }
        case .slack:
            switch slack.state {
            case .unavailable: return .unavailable
            case .disconnected: return .available
            case .connecting: return .busy("In your browser…")
            case .connected(let ws): return .connected(ws)
            case .failed(let m): return .failed(m)
            }
        case .gmail:
            if gmail.isConnecting { return .busy("In your browser…") }
            if let first = gmail.accounts.first {
                return .connected(gmail.accounts.count == 1 ? first.email : "\(gmail.accounts.count) accounts")
            }
            if !gmail.canAddAccount { return .unavailable }
            if case .failed(let m) = gmail.state { return .failed(m) }
            return .available
        case .whatsapp:
            switch whatsApp.state {
            case .unavailable: return .unavailable
            case .connected: return .connected(whatsApp.accountName ?? "Linked")
            case .pairing: return picked.contains(.whatsapp) ? .busy("Scan the code") : .available
            case .connecting: return picked.contains(.whatsapp) || whatsApp.hasPairedSession ? .busy("Connecting…") : .available
            case .failed(let m): return .failed(m)
            case .disconnected: return .available
            }
        }
    }

    var connectedCount: Int { SourceKind.allCases.filter { sourceState($0).isConnected }.count }

    /// Keep every supported source discoverable, even in a source build
    /// without OAuth configuration. Unavailable rows explain their state.
    var visibleSources: [SourceKind] {
        SourceKind.allCases
    }

    var sourceSelectionIndices: [Int] {
        visibleSources.indices.filter { sourceState(visibleSources[$0]) != .unavailable }
            + (connectedCount > 0 ? [visibleSources.count] : [])
    }

    // MARK: Turn helpers

    private func say(_ line: String, replyingWith reply: String? = nil) {
        if let reply, !transcript.isEmpty {
            transcript[transcript.count - 1].reply = reply
        }
        transcript.append(Turn(line: line))
        errorText = nil
        statusText = nil
        inputText = ""
    }

    /// Append a follow-up without closing the current turn (e.g. "Telegram's in.").
    private func aside(_ line: String) {
        transcript.append(Turn(line: line))
    }

    private func go(_ next: OnboardingStep, reply: String? = nil) {
        telegramAuthTask?.cancel()
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.3)) {
            step = next
            if next == .shortcut { keyShortcutAcknowledged = false }
            sourceDetail = nil
            say(opener(for: next), replyingWith: reply)
        }
    }

    private func opener(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "A little clarity for every chat."
        case .signIn: return "Sign in to Pidgy"
        case .invite: return "This beta is invite-only. Got a code?"
        case .sources: return "Where do people reach you?"
        case .telegramPhone: return "Your Telegram number, with the country code."
        case .telegramCode: return "Telegram just sent you a code."
        case .telegramPassword: return "And your two-step password."
        case .intelligence: return "Choose how Pidgy thinks."
        case .shortcut: return "One shortcut. Every conversation."
        case .launchAtLogin: return "Ready when you are."
        case .plan: return "How should the AI run?"
        case .byokKey: return "Add your AI key"
        case .done: return "You’re all set."
        }
    }

    // MARK: - Actions

    func start() {
        // Welcome is already the first turn.
    }

    /// Return key / default chip.
    func primaryAction() {
        guard !isBusy else { return }
        switch step {
        case .welcome: advanceFromWelcome()
        case .signIn:
            if account.isSignedIn { continueWithoutAccount() } else { signIn(with: .google) }
        case .invite: redeemInvite()
        case .sources: if connectedCount > 0 { finishSources() }
        case .intelligence: continueFromIntelligence()
        case .telegramPhone: Task { await submitPhoneNumber() }
        case .telegramCode: Task { await submitVerificationCode() }
        case .telegramPassword: Task { await submitPassword() }
        case .shortcut: skipShortcut()
        case .launchAtLogin: setLaunchAtLogin(false)
        case .plan: choosePlan(.bundled)
        case .byokKey: verifyKey()
        case .done: finish()
        }
    }

    func back() {
        guard !isBusy else { return }
        telegramAuthTask?.cancel()
        if step == .byokKey && keySetupFromIntelligence {
            go(.intelligence)
            return
        }
        if step == .plan && planSetupFromIntelligence {
            go(.intelligence)
            return
        }
        guard let prev = OnboardingRouting.back(
            from: step,
            accountConfigured: AccountService.isConfigured,
            inviteGateRequired: InviteService.gateRequired,
            inviteRegistered: invites.isRegistered
        ) else { return }
        // Drop the current turn instead of stacking a "went back" line.
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.25)) {
            if transcript.count > 1 { transcript.removeLast() }
            if !transcript.isEmpty { transcript[transcript.count - 1].reply = nil }
            step = prev
            if !transcript.isEmpty { transcript[transcript.count - 1].line = opener(for: prev) }
            sourceDetail = nil
            errorText = nil
            statusText = nil
            inputText = ""
        }
    }

    // Welcome
    func advanceFromWelcome() {
        let next = OnboardingRouting.afterWelcome(
            accountConfigured: AccountService.isConfigured,
            signedIn: account.isSignedIn,
            inviteGateRequired: InviteService.gateRequired,
            inviteRegistered: invites.isRegistered
        )
        go(next, reply: "Let's go")
    }

    // Account
    func signIn(with provider: AccountService.Provider) {
        guard step == .signIn, !isBusy else { return }
        isBusy = true
        signingInProvider = provider
        errorText = nil
        pigeon.glance()
        Task { @MainActor in
            defer { isBusy = false; signingInProvider = nil }
            do {
                try await account.signIn(with: provider)
                let name = account.profile?.displayName?.split(separator: " ").first.map(String.init)
                aside(name.map { "Hey \($0)." } ?? "Hey.")
                pigeon.hop()
                try? await Task.sleep(for: .milliseconds(900))
                go(OnboardingRouting.afterSignIn(inviteGateRequired: InviteService.gateRequired, inviteRegistered: invites.isRegistered),
                   reply: account.profile?.email ?? provider.title)
            } catch let error as AccountService.SignInError {
                if error != .cancelled {
                    errorText = error.errorDescription
                    pigeon.shake()
                }
            } catch {
                errorText = error.localizedDescription
                pigeon.shake()
            }
        }
    }

    func switchAccount() {
        guard step == .signIn, !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            await account.signOut()
        }
    }

    func continueWithoutAccount() {
        guard !isBusy else { return }
        go(OnboardingRouting.afterSignIn(inviteGateRequired: InviteService.gateRequired, inviteRegistered: invites.isRegistered),
           reply: account.isSignedIn ? (account.profile?.email ?? "Signed in") : "Skip for now")
    }

    // Invite
    func redeemInvite() {
        let code = inputText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard step == .invite, !code.isEmpty, !isBusy, !invites.isRedeeming else { return }
        isBusy = true
        errorText = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await invites.redeem(code: code)
                pigeon.hop()
                aside(invites.codes.isEmpty ? "You're in." : "You're in. I minted \(invites.codes.count) codes for you to hand out.")
                try? await Task.sleep(for: .milliseconds(900))
                go(.sources, reply: code)
            } catch let error as InviteService.RedeemError {
                errorText = error.errorDescription
                pigeon.shake()
            } catch {
                errorText = InviteService.RedeemError.network.errorDescription
                pigeon.shake()
            }
        }
    }

    #if DEBUG
    func debugSkipInvite() { guard !isBusy else { return }; go(.sources, reply: "Skipped (debug)") }
    #endif

    // Sources
    func pick(_ kind: SourceKind) {
        guard step == .sources, !isBusy else { return }
        switch sourceState(kind) {
        case .connected, .unavailable: return
        case .busy where kind == .slack || kind == .gmail: return
        default: break
        }
        errorText = nil
        picked.insert(kind)
        switch kind {
        case .telegram:
            if case .connected = sourceState(.telegram) { return }
            telegramAuthTask?.cancel()
            telegramAuthTask = Task { await beginTelegramAuth() }
        case .slack, .gmail:
            pigeon.glance()
            sourceRequestsInFlight.insert(kind)
            Task {
                await browserConnector(kind)
                sourceRequestsInFlight.remove(kind)
                // Connecting a source never advances or completes onboarding.
                // A closed session clears this callback, so late OAuth results
                // cannot resurrect a discarded setup window.
                if step == .sources { browserConnectionFinished?() }
            }
        case .whatsapp:
            if case .connected = sourceState(.whatsapp) { return }
            switch whatsApp.state {
            case .failed: whatsApp.reconnect()
            case .pairing, .connecting: break
            default: whatsApp.connect()
            }
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.25)) { sourceDetail = .whatsAppQR }
        }
    }

    func retrySourceDetail() {
        guard step == .sources else { return }
        errorText = nil
        switch sourceDetail {
        case .whatsAppQR: whatsApp.reconnect()
        case .telegramQR: pick(.telegram)
        case nil: break
        }
    }

    private var isTelegramQRActive: Bool {
        if case .telegramQR = sourceDetail { return true }
        return false
    }

    func closeSourceDetail() {
        telegramAuthTask?.cancel()
        errorText = nil
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.25)) { sourceDetail = nil }
    }

    func finishSources() {
        guard step == .sources, connectedCount > 0, !isBusy else { return }
        let names = SourceKind.allCases.filter { sourceState($0).isConnected }.map(\.title)
        go(.intelligence, reply: names.joined(separator: ", "))
    }

    func skipSources() {
        guard step == .sources, !isBusy else { return }
        go(.intelligence, reply: "I'll connect a source later")
    }

    func continueFromIntelligence() {
        guard step == .intelligence, !isBusy, !ChatGPTService.shared.isBusy else { return }
        go(.shortcut, reply: aiService.isConfigured ? "AI connected" : "I'll choose later")
    }

    func beginKeySetup() {
        guard step == .intelligence, !isBusy else { return }
        keySetupFromIntelligence = true
        go(.byokKey)
    }

    func exploreAIPlans() {
        guard step == .intelligence, !isBusy else { return }
        planSetupFromIntelligence = true
        go(.plan)
    }

    func skipPlan() {
        guard step == .plan, !isBusy else { return }
        go(planSetupFromIntelligence ? .intelligence : .done)
    }

    func usePhoneInstead() {
        go(.telegramPhone)
    }

    // Shortcut
    private var keyShortcutAcknowledged = false

    func hotkeyPressed() {
        guard step == .shortcut, !keyShortcutAcknowledged else { return }
        keyShortcutAcknowledged = true
        panelBounceToken += 1
        pigeon.hop()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        aside("Nice. That's your door.")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard step == .shortcut else { return }
            go(.launchAtLogin, reply: "⌘⇧T")
        }
    }

    func skipShortcut() {
        go(.launchAtLogin, reply: "Later")
    }

    // Launch at login
    func setLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            do {
                try LaunchAtLogin.set(enabled: true)
            } catch {
                errorText = "macOS declined that — you can turn it on later in Preferences."
                pigeon.shake()
                return
            }
        }
        go(OnboardingRouting.afterLaunchAtLogin(showBillingUI: BillingGate.showBillingUI, aiSetupVisited: true), reply: enabled ? "Yes" : "Not now")
    }

    // Plan
    func choosePlan(_ plan: PidgyPlan) {
        EntitlementStore.shared.startTrial(plan: plan)
        if plan == .byok {
            keySetupFromIntelligence = planSetupFromIntelligence
            go(.byokKey, reply: plan.title)
        } else {
            go(planSetupFromIntelligence ? .shortcut : .done, reply: plan.title)
        }
    }

    func setByokProvider(_ provider: AIProviderConfig.ProviderType) {
        guard !isBusy else { return }
        inputText = ""
        byokProvider = provider
        errorText = nil
    }

    func verifyKey() {
        let key = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isBusy else { return }
        isBusy = true
        errorText = nil
        let selectedProvider = byokProvider
        let candidate: AIProvider = selectedProvider == .claude
            ? ClaudeProvider(apiKey: key) : OpenAIProvider(apiKey: key)
        Task { @MainActor in
            defer { isBusy = false }
            let ok = (try? await candidate.testConnection()) ?? false
            if ok {
                aiService.configure(type: selectedProvider, apiKey: key)
                pigeon.hop()
                go(keySetupFromIntelligence ? .shortcut : .done, reply: "\(byokProvider.rawValue) key added")
            } else {
                errorText = "Couldn't verify that key. Double-check and try again."
                pigeon.shake()
            }
        }
    }

    func skipKey() {
        guard !isBusy else { return }
        go(keySetupFromIntelligence ? .intelligence : .done, reply: "I'll add it later")
    }

    // Done
    var flyOutRequested: (() -> Void)?

    func finish() {
        guard step == .done, !didFinish else { return }
        didFinish = true
        flyOutRequested?()
        completionTask = Task { @MainActor in
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    func cancelPendingOperations() {
        browserConnectionFinished = nil
        telegramAuthTask?.cancel()
        completionTask?.cancel()
        cancellables.removeAll()
    }

    // MARK: - Telegram

    private func beginTelegramAuth() async {
        switch telegramService.authState {
        case .ready:
            return
        case .waitingForCode:
            go(.telegramCode); return
        case .waitingForPassword:
            go(.telegramPassword); return
        case .waitingForQrCode(let link):
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.25)) { sourceDetail = .telegramQR(link: link) }
            return
        default:
            break
        }

        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.25)) { sourceDetail = .telegramQR(link: nil) }

        if telegramService.authState == .uninitialized || telegramService.authState == .closed {
            if let bundledId = BundledSecrets.telegramApiId, let bundledHash = BundledSecrets.telegramApiHash {
                telegramService.start(apiId: Int(bundledId), apiHash: bundledHash)
            } else if let storedIdRaw = (try? KeychainManager.retrieve(for: .apiId)),
                      let storedId = Int(storedIdRaw),
                      let storedHash = (try? KeychainManager.retrieve(for: .apiHash)) {
                telegramService.start(apiId: storedId, apiHash: storedHash)
            } else {
                errorText = "Telegram isn’t available in this build. Choose another source or contact Pidgy support for an updated build."
                sourceDetail = nil
                return
            }
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard !Task.isCancelled else { return }
            switch telegramService.authState {
            case .waitingForPhoneNumber:
                guard !didStartTelegramQR else { return }
                didStartTelegramQR = true
                defer { didStartTelegramQR = false }
                do {
                    try await telegramService.requestQrCodeAuth()
                } catch {
                    guard !Task.isCancelled else { return }
                    errorText = Self.friendly(error)
                    didStartTelegramQR = false
                }
                return
            case .ready, .waitingForQrCode, .waitingForCode, .waitingForPassword:
                return
            default:
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard !Task.isCancelled else { return }
        errorText = "Telegram took too long to respond. Check your connection and try again."
    }

    private func observe() {
        telegramService.$authState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.telegramStateChanged(state) }
            .store(in: &cancellables)
        Publishers.Merge(account.objectWillChange, invites.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Any connection-manager change re-renders the chips.
        Publishers.Merge3(
            slack.objectWillChange.map { _ in () },
            gmail.objectWillChange.map { _ in () },
            whatsApp.objectWillChange.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
        whatsApp.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, case .connected = state, self.sourceDetail == .whatsAppQR else { return }
                self.closeSourceDetail()
                self.pigeon.hop()
                self.aside("WhatsApp's in.")
            }
            .store(in: &cancellables)
        slack.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, case .connected(let ws) = state, self.step == .sources else { return }
                self.pigeon.hop()
                self.aside("Slack's in — \(ws).")
            }
            .store(in: &cancellables)
        gmail.$accounts
            .receive(on: RunLoop.main)
            .scan((0, 0)) { ($0.1, $1.count) }
            .sink { [weak self] prev, now in
                guard let self, now > prev, self.step == .sources else { return }
                self.pigeon.hop()
                self.aside("Gmail's in.")
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .pidgyOnboardingHotkey)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hotkeyPressed() }
            .store(in: &cancellables)
    }

    private func telegramStateChanged(_ state: AuthState) {
        defer { lastTelegramState = state }
        switch state {
        case .waitingForQrCode(let link):
            if case .telegramQR = sourceDetail {
                sourceDetail = .telegramQR(link: link)
            }
        case .waitingForCode(let info):
            codeResendAvailableAt = info?.canResend == true ? Date().addingTimeInterval(Double(info?.timeout ?? 0)) : nil
            errorText = nil
            if (step == .sources && isTelegramQRActive) || step == .telegramPhone { go(.telegramCode) }
        case .waitingForPassword:
            errorText = nil
            if (step == .sources && isTelegramQRActive) || step.isTelegramAuth, step != .telegramPassword { go(.telegramPassword) }
        case .ready:
            didStartTelegramQR = false
            guard lastTelegramState != .ready else { return }
            if step.isTelegramAuth {
                go(.sources, reply: "Linked")
                pigeon.hop()
                aside("Telegram's in.")
            } else if step == .sources {
                if isTelegramQRActive { closeSourceDetail() }
                pigeon.hop()
                aside("Telegram's in.")
            }
        default:
            break
        }
    }

    private func submitPhoneNumber() async {
        guard !isBusy, step == .telegramPhone else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = "I need a number."; return }
        isBusy = true
        defer { isBusy = false }
        errorText = nil
        await ensureTelegramServiceRunning()
        do {
            try await telegramService.setPhoneNumber(trimmed)
            transcript[transcript.count - 1].reply = trimmed
        } catch {
            errorText = Self.friendly(error)
            pigeon.shake()
        }
    }

    private func submitVerificationCode() async {
        guard !isBusy, step == .telegramCode else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = "Type the code Telegram sent you."; return }
        isBusy = true
        defer { isBusy = false }
        errorText = nil
        do {
            try await telegramService.submitVerificationCode(trimmed)
            transcript[transcript.count - 1].reply = "•••••"
        } catch {
            errorText = Self.friendly(error)
            pigeon.shake()
        }
    }

    func resendTelegramCode() {
        guard step == .telegramCode, !isBusy,
              let availableAt = codeResendAvailableAt, Date() >= availableAt else { return }
        isBusy = true
        errorText = nil
        statusText = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await telegramService.resendVerificationCode()
                statusText = "A new code was requested. Check Telegram or your SMS."
            } catch {
                errorText = Self.friendly(error)
            }
        }
    }

    private func submitPassword() async {
        guard !isBusy, step == .telegramPassword else { return }
        guard !inputText.isEmpty else { errorText = "Password, please."; return }
        isBusy = true
        defer { isBusy = false }
        errorText = nil
        do {
            try await telegramService.submitPassword(inputText)
            transcript[transcript.count - 1].reply = "••••••••"
        } catch {
            errorText = Self.friendly(error)
            pigeon.shake()
        }
    }

    private func ensureTelegramServiceRunning() async {
        guard telegramService.authState == .uninitialized || telegramService.authState == .closed else { return }
        if let bundledId = BundledSecrets.telegramApiId, let bundledHash = BundledSecrets.telegramApiHash {
            telegramService.start(apiId: Int(bundledId), apiHash: bundledHash)
        } else if let storedIdRaw = (try? KeychainManager.retrieve(for: .apiId)),
                  let storedId = Int(storedIdRaw),
                  let storedHash = (try? KeychainManager.retrieve(for: .apiHash)) {
            telegramService.start(apiId: storedId, apiHash: storedHash)
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .waitingForPhoneNumber = telegramService.authState { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func friendly(_ error: Swift.Error) -> String {
        guard let td = error as? TDLibKit.Error else { return error.localizedDescription }
        let t = td.message.uppercased()
        if t.contains("PASSWORD_HASH_INVALID") { return "Wrong password. Try again." }
        if t.contains("PHONE_CODE_INVALID") { return "That code didn't match." }
        if t.contains("PHONE_CODE_EXPIRED") { return "That code expired — request a new one." }
        if t.contains("PHONE_NUMBER_INVALID") { return "That number doesn't look right. Check the country code." }
        if t.contains("PHONE_NUMBER_BANNED") { return "Telegram has banned this number." }
        if t.contains("FLOOD") { return "Too many attempts. Give it a minute." }
        if t.contains("PASSWORD_TOO_FRESH") { return "Telegram is still securing a recent password change. Try again shortly." }
        return "Couldn't continue (\(td.message.replacingOccurrences(of: "_", with: " ").lowercased()))."
    }
}

// MARK: - Window

/// Full-screen, borderless. Takes keyboard focus (the invite / phone / code
/// fields need it). Opaque during the film (backdrop), transparent after.
private final class OnboardingStageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OnboardingWindowController {
    private weak var telegramService: TelegramService?
    private weak var aiService: AIService?
    private let onComplete: () -> Void
    /// Screen-space frame of the menu bar status item, for the final flight.
    private let menuBarAnchor: () -> NSRect?

    private var window: NSWindow?
    private var model: OnboardingConversationModel?
    private var choreography: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?
    private let pigeon = PigeonActor()
    private let scene = OnboardingSceneState()
    private var layout: OnboardingLayout?

    var isActive: Bool { window?.isVisible == true }
    var hasSession: Bool { window != nil }

    @discardableResult
    func resumeIfNeeded() -> Bool {
        guard hasSession else { return false }
        show()
        return true
    }

    init(
        telegramService: TelegramService,
        aiService: AIService,
        menuBarAnchor: @escaping () -> NSRect? = { nil },
        onComplete: @escaping () -> Void
    ) {
        self.telegramService = telegramService
        self.aiService = aiService
        self.menuBarAnchor = menuBarAnchor
        self.onComplete = onComplete
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let telegramService, let aiService else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let model = OnboardingConversationModel(
            telegramService: telegramService,
            aiService: aiService,
            pigeon: pigeon,
            onFinished: { [weak self] in self?.close(markCompleted: true) }
        )
        self.model = model
        model.browserConnectionFinished = { [weak self] in
            self?.resumeIfNeeded()
        }

        let frame = screen.frame
        let menuBar = menuBarAnchor().map { CGPoint(x: $0.midX - frame.minX, y: frame.maxY - $0.midY) }
        let layout = OnboardingLayout(size: frame.size, menuBarPoint: menuBar)
        self.layout = layout

        let window = OnboardingStageWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovable = false
        window.contentView = NSHostingView(rootView: OnboardingRootView(
            model: model,
            scene: scene,
            layout: layout,
            onSkip: { [weak self] in self?.endFilm() },
            onDismiss: { [weak self] in self?.hide() }
        ).environmentObject(aiService))
        window.setFrame(frame, display: true)
        self.window = window

        // Switching to another app (⌘-tab, Dock) steps out too. Progress is
        // kept; the menu bar item or the launcher's handoff brings it back.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Ignore a queued resign event if the OAuth callback has
                // already brought this window back to the front.
                guard self?.window?.isKeyWindow != true else { return }
                guard self?.model?.isBusy != true else { return }
                self?.hide()
            }
        }

        model.flyOutRequested = { [weak self] in self?.revealDesktop() }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scene.phase = .cards
            return
        }

        scene.filmStart = Date()
        choreography = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(OnboardingFilmView.duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.endFilm()
        }
    }

    /// Step out without losing progress. If the film is still running it
    /// ends here — nobody wants to rewatch it.
    func hide() {
        guard let window, window.isVisible else { return }
        if scene.phase == .film { endFilm() }
        pigeon.stopAnimations()
        window.orderOut(nil)
    }

    /// Film → steps: the stage stays lit, the demo clears, the bird goes
    /// back to the parapet to watch you set up.
    private func endFilm() {
        guard scene.phase == .film else { return }
        choreography?.cancel()
        choreography = nil
        scene.filmEnded = true
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: 0.25)) {
            scene.phase = .cards
        }
    }

    /// Done: the light comes back — the stage fades to the real desktop as
    /// the bird heads for the menu bar.
    private func revealDesktop() {
        withAnimation(.easeInOut(duration: 1.4)) {
            scene.backdropOpacity = 0
        }
    }

    func close(markCompleted: Bool) {
        choreography?.cancel()
        model?.cancelPendingOperations()
        pigeon.stopAnimations()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        window?.orderOut(nil)
        window = nil
        model = nil
        if markCompleted {
            UserDefaults.standard.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
            onComplete()
        }
    }
}
