import AppKit
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
        self == .debugWindow
    }

    var showsLauncherOnLaunch: Bool {
        self == .debugWindow
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let telegramService = TelegramService()
    let aiService = AIService()
    private var menuBarManager: MenuBarManager?
    private var panelManager: PanelManager?
    private var hotkeyManager: HotkeyManager?
    private var settingsWindow: NSWindow?
    private var dashboardWindow: NSWindow?
    private var graphBuildTask: Task<Void, Never>?
    private let launchPresentationMode = AppLaunchPresentationMode.resolve()
    private let opensDashboardOnLaunch = ProcessInfo.processInfo.environment["PIDGY_DASHBOARD_ON_LAUNCH"] == "1"
    private var terminationCleanupStarted = false
    private var terminationCleanupCompleted = false
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if launchPresentationMode.activatesAsRegularApp {
            NSApp.setActivationPolicy(.regular)
        }

        panelManager = PanelManager(
            telegramService: telegramService,
            aiService: aiService,
            presentationMode: launchPresentationMode
        )
        panelManager?.onOpenSettings = { [weak self] in self?.openSettings() }
        panelManager?.onOpenDashboard = { [weak self] in self?.openDashboard() }

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

            // Start TDLib if credentials exist
            if let apiIdStr = try? KeychainManager.retrieve(for: .apiId),
               let apiHash = try? KeychainManager.retrieve(for: .apiHash),
               let apiId = Int(apiIdStr) {
                telegramService.start(apiId: apiId, apiHash: apiHash)
            }
        }

        guard !isRunningTests else { return }

        if launchPresentationMode.showsLauncherOnLaunch {
            panelManager?.showForDebugTesting()
        }
        if opensDashboardOnLaunch {
            openDashboard()
        }

        graphBuildTask = Task { [weak self] in
            guard let self else { return }
            await waitForGraphBuildReadiness()
            guard !Task.isCancelled else { return }
            await RecentSyncCoordinator.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            await GraphBuilder.shared.buildIfNeeded(using: telegramService)
            guard !Task.isCancelled else { return }
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

    func applicationDidBecomeActive(_ notification: Notification) {
        Task {
            await RecentSyncCoordinator.shared.recoverNow()
        }
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
            await IndexScheduler.shared.stop()
            await DatabaseManager.shared.close()
            terminationCleanupCompleted = true
            onComplete?()
        }
    }

    private func openSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
            .environmentObject(telegramService)
            .environmentObject(aiService)

        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pidgy Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openDashboard() {
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
        window.title = "Pidgy Dashboard"
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

        while !Task.isCancelled {
            let isReady = telegramService.authState == .ready && telegramService.currentUser != nil
            let chatsLoaded = !telegramService.visibleChats.isEmpty || !telegramService.isLoading

            if isReady && chatsLoaded {
                return
            }

            if Date() >= timeoutAt, isReady {
                return
            }

            try? await Task.sleep(
                for: .milliseconds(Int(AppConstants.Graph.startupReadinessPollMilliseconds))
            )
        }
    }
}
