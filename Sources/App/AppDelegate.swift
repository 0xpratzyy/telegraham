import AppKit
import OSLog
import SwiftUI

enum AppLaunchPresentationMode: Equatable {
    case menuBarPanel
    case debugWindow

    static let environmentKey = "PIDGY_DEBUG_WINDOW_MODE"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsDebugWindow: Bool = {
#if DEBUG
            true
#else
            false
#endif
        }()
    ) -> AppLaunchPresentationMode {
        guard allowsDebugWindow else { return .menuBarPanel }

        let value = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch value {
        case "1", "true", "yes", "window":
            return .debugWindow
        default:
            return .menuBarPanel
        }
    }

    var activatesAsRegularApp: Bool {
        true
    }

    var showsLauncherOnLaunch: Bool {
        self == .debugWindow
    }
}

enum AppDashboardLaunchPolicy {
    static let environmentKey = "PIDGY_DASHBOARD_ON_LAUNCH"

    static func opensDashboardOnLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let value = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch value {
        case "0", "false", "no", "off":
            return false
        default:
            return true
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let telegramService = TelegramService()
    let aiService = AIService()
    private var menuBarManager: MenuBarManager?
    private var panelManager: PanelManager?
    private var hotkeyManager: HotkeyManager?
    private var dashboardWindow: NSWindow?
    private var onboardingController: OnboardingWindowController?
    private var graphBuildTask: Task<Void, Never>?
    private var preferencesOpenObserver: NSObjectProtocol?
    private var replayOnboardingObserver: NSObjectProtocol?
    private let launchPresentationMode = AppLaunchPresentationMode.resolve()
    private let opensDashboardOnLaunch = AppDashboardLaunchPolicy.opensDashboardOnLaunch()
    private var terminationCleanupStarted = false
    private var terminationCleanupCompleted = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "Startup"
    )
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PidgyFontRegistrar.registerBundledFonts()

        if launchPresentationMode.activatesAsRegularApp {
            NSApp.setActivationPolicy(.regular)
        }

        panelManager = PanelManager(
            telegramService: telegramService,
            aiService: aiService,
            presentationMode: launchPresentationMode
        )
        panelManager?.onOpenDashboard = { [weak self] in self?.openDashboard() }

        preferencesOpenObserver = NotificationCenter.default.addObserver(
            forName: .pidgyOpenDashboardPreferences,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openSettings()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .requestLauncherToggle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panelManager?.toggle()
            }
        }

        replayOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .pidgyReplayOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                UserDefaults.standard.removeObject(
                    forKey: AppConstants.Preferences.didCompleteOnboardingKey
                )
                // Drop the dashboard window so the user really lands on a
                // "first run" surface — otherwise the empty dashboard sits
                // behind the modal and looks broken.
                self.dashboardWindow?.orderOut(nil)
                self.presentOnboardingIfNeeded(force: true)
            }
        }

        menuBarManager = MenuBarManager(
            onTogglePanel: { [weak self] in self?.panelManager?.toggle() },
            onOpenDashboard: { [weak self] in self?.openDashboard() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        hotkeyManager = HotkeyManager { [weak self] in
            self?.panelManager?.toggle()
        }
        hotkeyManager?.register()

        Task {
            await DatabaseManager.shared.initialize()

            guard !isRunningTests else { return }

            // Start TDLib if credentials exist. Prefer Keychain (the user's
            // own pasted values) over the bundled defaults so a tester who
            // signs in with their own api_id doesn't get re-paired to the
            // app's beta credentials on every launch.
            if let apiIdStr = try? KeychainManager.retrieve(for: .apiId),
               let apiHash = try? KeychainManager.retrieve(for: .apiHash),
               let apiId = Int(apiIdStr) {
                logger.info("Starting Telegram service with stored credentials")
                telegramService.start(apiId: apiId, apiHash: apiHash)
            } else if let bundledId = BundledSecrets.telegramApiId,
                      let bundledHash = BundledSecrets.telegramApiHash {
                logger.info("Starting Telegram service with bundled beta credentials")
                telegramService.start(apiId: Int(bundledId), apiHash: bundledHash)
            } else {
                logger.warning("Telegram credentials missing; startup pipeline will wait")
            }
        }

        guard !isRunningTests else { return }

        if launchPresentationMode.showsLauncherOnLaunch {
            panelManager?.showForDebugTesting()
        }
        if opensDashboardOnLaunch {
            openDashboard()
        }

        // First-launch onboarding modal. We show it whenever the user hasn't
        // completed the flow yet AND Telegram isn't already authenticated. If
        // they're already signed in (e.g. dev rebuilds, Keychain still holds
        // the session) we just mark onboarding done so the modal never pops.
        presentOnboardingIfNeeded(force: false)

        graphBuildTask = Task { [weak self] in
            guard let self else { return }
            logger.info("Startup pipeline waiting for Telegram readiness")
            await waitForGraphBuildReadiness()
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting recent sync")
            await RecentSyncCoordinator.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting major chat coverage")
            await MajorChatCoverageCoordinator.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting graph build")
            await GraphBuilder.shared.buildIfNeeded(using: telegramService)
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting index scheduler")
            await IndexScheduler.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            let includeBotsInAISearch = UserDefaults.standard.bool(
                forKey: AppConstants.Preferences.includeBotsInAISearchKey
            )
            TaskIndexCoordinator.shared.start(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: includeBotsInAISearch
            )
        }
    }

    deinit {
        if let preferencesOpenObserver {
            NotificationCenter.default.removeObserver(preferencesOpenObserver)
        }
        if let replayOnboardingObserver {
            NotificationCenter.default.removeObserver(replayOnboardingObserver)
        }
    }

    private func presentOnboardingIfNeeded(force: Bool) {
        let defaults = UserDefaults.standard
        let didComplete = defaults.bool(
            forKey: AppConstants.Preferences.didCompleteOnboardingKey
        )

        if !force && didComplete { return }

        // If TDLib is already authenticated (existing user reopening the app),
        // there's nothing to onboard — just mark the flag so we never bother
        // them again.
        if !force && telegramService.authState == .ready {
            defaults.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
            return
        }

        let controller = OnboardingWindowController(
            telegramService: telegramService,
            aiService: aiService,
            onComplete: { [weak self] in
                guard let self else { return }
                // After onboarding completes successfully, surface the
                // dashboard so the user lands somewhere useful.
                self.openDashboard()
            }
        )
        onboardingController = controller
        controller.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await RecentSyncCoordinator.shared.recoverNow()
            await MajorChatCoverageCoordinator.shared.recoverNow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openDashboard()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupCompleted {
            return .terminateNow
        }
        if terminationCleanupStarted {
            return .terminateLater
        }

        beginTerminationCleanup {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !terminationCleanupStarted else { return }
        beginTerminationCleanup()
    }

    private func beginTerminationCleanup(onComplete: (() -> Void)? = nil) {
        terminationCleanupStarted = true
        hotkeyManager?.unregister()
        graphBuildTask?.cancel()
        TaskIndexCoordinator.shared.stop()
        telegramService.stop()
        Task { @MainActor in
            await RecentSyncCoordinator.shared.stop()
            await MajorChatCoverageCoordinator.shared.stop()
            await IndexScheduler.shared.stop()
            await DatabaseManager.shared.close()
            terminationCleanupCompleted = true
            onComplete?()
        }
    }

    private func openSettings() {
        openDashboard(page: PreferencesRouting.authoritativePage)
    }

    private func openDashboard(page: DashboardPage = .dashboard) {
        if page == PreferencesRouting.authoritativePage {
            PreferencesRouting.showAuthoritativePreferences()
        } else {
            DashboardNavigationStore.shared.show(page)
        }

        if let dashboardWindow, dashboardWindow.isVisible {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let dashboardView = DashboardView()
            .environmentObject(telegramService)
            .environmentObject(aiService)

        let hostingView = NSHostingView(rootView: dashboardView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1580, height: 980),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = PidgyBranding.dashboardWindowTitle
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        self.dashboardWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func waitForGraphBuildReadiness() async {
        let timeoutAt = Date().addingTimeInterval(AppConstants.Graph.startupReadinessTimeoutSeconds)
        var lastLoggedSecond: Int?

        while !Task.isCancelled {
            let didTimeout = Date() >= timeoutAt
            let isReady = Self.isStartupPipelineReady(
                authState: telegramService.authState,
                hasCurrentUser: telegramService.currentUser != nil,
                hasVisibleChats: !telegramService.visibleChats.isEmpty,
                isLoading: telegramService.isLoading,
                didTimeout: didTimeout
            )

            if isReady {
                logger.info(
                    "Startup readiness satisfied auth=\(String(describing: self.telegramService.authState), privacy: .public) currentUser=\(self.telegramService.currentUser != nil) visibleChats=\(self.telegramService.visibleChats.count) isLoading=\(self.telegramService.isLoading) timedOut=\(didTimeout)"
                )
                return
            }

            let elapsedSecond = max(
                0,
                Int(AppConstants.Graph.startupReadinessTimeoutSeconds - timeoutAt.timeIntervalSinceNow)
            )
            if lastLoggedSecond != elapsedSecond, elapsedSecond % 2 == 0 || didTimeout {
                lastLoggedSecond = elapsedSecond
                logger.info(
                    "Startup readiness waiting auth=\(String(describing: self.telegramService.authState), privacy: .public) currentUser=\(self.telegramService.currentUser != nil) visibleChats=\(self.telegramService.visibleChats.count) isLoading=\(self.telegramService.isLoading) timedOut=\(didTimeout)"
                )
            }

            try? await Task.sleep(
                for: .milliseconds(Int(AppConstants.Graph.startupReadinessPollMilliseconds))
            )
        }
    }

    nonisolated static func isStartupPipelineReady(
        authState: AuthState,
        hasCurrentUser: Bool,
        hasVisibleChats: Bool,
        isLoading: Bool,
        didTimeout: Bool
    ) -> Bool {
        guard authState == .ready else { return false }
        guard hasVisibleChats || !isLoading else { return false }
        return hasCurrentUser || didTimeout
    }
}
