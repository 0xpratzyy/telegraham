import AppKit
import OSLog
import Sparkle
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
    /// Sparkle's standard updater controller. Starts checking the
    /// appcast (SUFeedURL in Info.plist) on launch and on the
    /// `SUScheduledCheckInterval` cadence after that. Held as a
    /// property so the "Check for Updates…" menu item can call into
    /// it, and so its target/action wiring isn't garbage collected.
    private var updaterController: SPUStandardUpdaterController?
    private var dashboardWindow: NSWindow?
    private var onboardingController: OnboardingWindowController?
    private var logoutProgressWindow: NSWindow?
    private var graphBuildTask: Task<Void, Never>?
    /// Retains the inner detached graph-build loop separately from the
    /// outer `graphBuildTask` orchestrator. Without this handle,
    /// `graphBuildTask?.cancel()` only cancelled the outer Task — the
    /// inner `Task.detached` kept running its `while !Task.isCancelled`
    /// loop forever because nothing was setting its cancellation flag.
    /// On reset, that meant GraphBuilder could continue writing to the
    /// `nodes` table after `PreferencesResetService.deleteAllLocalData`
    /// had wiped the DB, recreating ghost rows the user expected gone.
    private var graphBuildLoopTask: Task<Void, Never>?
    private var backgroundActivityToken: NSObjectProtocol?
    private var preferencesOpenObserver: NSObjectProtocol?
    private var replayOnboardingObserver: NSObjectProtocol?
    private var showOnboardingObserver: NSObjectProtocol?
    private var logOutObserver: NSObjectProtocol?
    private let launchPresentationMode = AppLaunchPresentationMode.resolve()
    private let opensDashboardOnLaunch = AppDashboardLaunchPolicy.opensDashboardOnLaunch()
    private var terminationCleanupStarted = false
    private var terminationCleanupCompleted = false
    private var logoutInProgress = false
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "Startup"
    )
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bring up telemetry first so any crash/error in subsequent
        // startup (font registration, TDLib bring-up, panel manager,
        // etc.) gets captured. Skipped automatically when no Sentry DSN
        // is bundled — source builds make zero network calls.
        PidgyTelemetry.start()

        // Sparkle auto-updater. `startingUpdater: true` kicks off an
        // immediate background appcast check; the periodic cadence
        // then follows `SUScheduledCheckInterval` from Info.plist.
        // Held on `self` so the "Check for Updates…" menu item below
        // can call `checkForUpdates(_:)` on it.
        //
        // Skipped under XCTest so the test runner isn't fighting
        // the updater for network or UI focus.
        if !isRunningTests {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            // The manual NSMenu insertion (installCheckForUpdatesMenuItem)
            // was unreliable: SwiftUI owns the main menu under the App
            // lifecycle and rebuilds it after launch, dropping any item
            // we splice in by hand — so "Check for Updates…" never
            // appeared. The menu item is now declared in PidgyApp via
            // `.commands`, which routes to `triggerCheckForUpdates()`
            // below and survives SwiftUI's menu management.
        }

        PidgyFontRegistrar.registerBundledFonts()

        // macOS App Nap aggressively throttles tasks that sleep for tens of
        // seconds when the app's UI is idle. Our short-poll coordinators
        // (RecentSync at 1.5 s, MajorChatCoverage at 8 s) tick through fine,
        // but TaskIndex (8 min) and the GraphBuilder loop (2 min) get
        // suspended indefinitely — both stop logging after the very first
        // cycle. Asserting a `.userInitiated` activity tells the OS this
        // process needs to stay scheduled for background work; it does NOT
        // prevent display sleep or system sleep, just App Nap throttling.
        backgroundActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Pidgy keeps Telegram messages, tasks, and the people graph in sync in the background."
        )

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

        // Launcher "Flag answer" → dashboard feedback sheet. The prefill
        // itself travels via FeedbackPrefillStore; this just makes sure
        // the dashboard window exists for DashboardView to consume it.
        NotificationCenter.default.addObserver(
            forName: .pidgyOpenFeedbackWithPrefill,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openDashboard()
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

        showOnboardingObserver = NotificationCenter.default.addObserver(
            forName: .pidgyShowOnboardingWindow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.presentOnboardingIfNeeded(force: true)
            }
        }

        // "Log out" routes here so there's a single, safe logout path. We
        // deliberately do NOT re-initialize TDLib in-process during logout —
        // recreating the client while the old one is still closing the
        // logout makes TDLib LOG(FATAL)/abort on its receive loop. Instead we
        // log out server-side, wipe all local data via the proven reset path,
        // and drop the user back to the welcome screen (where they reconnect
        // manually — TDLib is created fresh only then).
        logOutObserver = NotificationCenter.default.addObserver(
            forName: .pidgyLogOut,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.performLogout() }
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

        // Only open the dashboard at launch when the user has completed
        // onboarding before AND usable Telegram credentials still exist.
        // Without the credential check, a leftover `didCompleteOnboarding`
        // flag from a prior session silently opens the dashboard with
        // stale local cache (followups, tasks, people) while
        // Settings → Account reads "Not initialized / Visible chats = 0"
        // — the user has no signal that the keychain entries vanished
        // (dev rebuild, manual wipe) or that bundled creds were dropped
        // from this build. After onboarding completes, the `onComplete`
        // callback on OnboardingWindowController opens the dashboard, so
        // first-time users still land there immediately after finishing
        // the flow.
        let didCompleteOnboarding = UserDefaults.standard.bool(
            forKey: AppConstants.Preferences.didCompleteOnboardingKey
        )
        let hasTelegramCredentials = telegramCredentialsAvailable()
        if opensDashboardOnLaunch && didCompleteOnboarding && hasTelegramCredentials {
            openDashboard()
        }

        // First-launch onboarding modal. We show it whenever the user hasn't
        // completed the flow yet AND Telegram isn't already authenticated. If
        // they're already signed in (e.g. dev rebuilds, Keychain still holds
        // the session) we just mark onboarding done so the modal never pops.
        //
        // Special case: flag is set but credentials are gone — force the
        // onboarding window so the user can re-enter them. Otherwise
        // `presentOnboardingIfNeeded(force: false)` would early-return on
        // the stale flag and leave the user staring at nothing.
        let stalled = didCompleteOnboarding && !hasTelegramCredentials
        presentOnboardingIfNeeded(force: stalled)

        graphBuildTask = Task { [weak self] in
            guard let self else { return }
            logger.info("Startup pipeline waiting for Telegram readiness")
            await waitForGraphBuildReadiness()
            guard !Task.isCancelled else { return }

            // One-shot person-node backfill from the local messages table.
            // MajorChatCoverageCoordinator only fully indexes recent +
            // small + DM-style chats (~80 out of ~1,600 in a typical
            // account); without this pass the People page only ever
            // shows the small fraction of contacts the graph builder
            // walked. Fills nodes for every distinct sender already in
            // the DB — pure local SQL, idempotent, ~1s on cold start.
            logger.info("Startup pipeline running person-node backfill")
            await DatabaseManager.shared.backfillPersonNodesFromMessages()
            guard !Task.isCancelled else { return }

            // Unstick chats whose coverage retry window already lapsed
            // — e.g. the coordinator was busy timing out on neighbors
            // and the queue cycled past them, or the app was force-quit
            // mid-pass. Bounded to past-due rows so we don't undo a
            // legitimate exponential backoff that's still in flight.
            // MajorChatCoverageCoordinator picks them up on the next
            // sweep with the (newly halved) 50-message batch size, so
            // individual TDLib calls finish faster and have a better
            // shot at completing inside the 300s ceiling.
            logger.info("Startup pipeline resetting stuck coverage retries")
            await DatabaseManager.shared.resetStuckCoverageRetries(forceAllPending: true)
            guard !Task.isCancelled else { return }

            // The sync coordinators all return quickly from start() — they
            // spawn their own loops. Keep them serialized so we don't spam
            // TDLib in the same instant, but each only takes a few ms to
            // arm itself.
            logger.info("Startup pipeline starting recent sync")
            await RecentSyncCoordinator.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting major chat coverage")
            await MajorChatCoverageCoordinator.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }
            logger.info("Startup pipeline starting index scheduler")
            await IndexScheduler.shared.start(using: telegramService)
            guard !Task.isCancelled else { return }

            // Task extraction used to be the LAST thing in the chain — gated
            // behind the full graph build, which on a fresh install can take
            // many minutes. Move it here so the Tasks page populates roughly
            // in step with reply queue. TaskIndexCoordinator.start() spawns
            // its own loop and returns immediately.
            logger.info("Startup pipeline starting task index")
            let includeBotsInAISearch = UserDefaults.standard.bool(
                forKey: AppConstants.Preferences.includeBotsInAISearchKey
            )
            TaskIndexCoordinator.shared.start(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: includeBotsInAISearch
            )

            // GraphBuilder.buildIfNeeded actually awaits the full graph
            // build to complete (writes nodes incrementally as it goes).
            // Run it as a detached loop so it doesn't block any of the
            // above — the People page picks up the new nodes as they land.
            //
            // The loop re-evaluates every couple of minutes because TDLib
            // streams the chat list in over time. If we only ran the build
            // once at startup, any chats that arrived after the first pass
            // would never be added to the graph.
            logger.info("Startup pipeline kicking off graph build (background)")
            // Retain the detached loop on `graphBuildLoopTask` so reset /
            // termination can actually stop it. Previously this was a
            // fire-and-forget Task.detached that survived
            // `graphBuildTask?.cancel()` and kept rebuilding the relation
            // graph indefinitely.
            self.graphBuildLoopTask = Task.detached { [telegramService] in
                while !Task.isCancelled {
                    await GraphBuilder.shared.buildIfNeeded(using: telegramService)
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(120))
                }
            }
        }
    }

    deinit {
        if let preferencesOpenObserver {
            NotificationCenter.default.removeObserver(preferencesOpenObserver)
        }
        if let replayOnboardingObserver {
            NotificationCenter.default.removeObserver(replayOnboardingObserver)
        }
        if let showOnboardingObserver {
            NotificationCenter.default.removeObserver(showOnboardingObserver)
        }
        if let logOutObserver {
            NotificationCenter.default.removeObserver(logOutObserver)
        }
    }

    /// Inserts a "Check for Updates…" item into Pidgy's app menu
    /// (the bold "Pidgy" menu next to the Apple logo). Targets
    /// `SPUStandardUpdaterController.checkForUpdates(_:)`, which
    /// shows the Sparkle "you're up to date" or "1.0.1 available"
    /// dialog. macOS's default app menu layout puts "About Pidgy"
    /// at index 0; we slot the new item right after it, matching
    /// the convention every other AppKit app uses.
    /// Manual "Check for Updates…" trigger, invoked from the SwiftUI
    /// `.commands` menu item in PidgyApp. Forces an immediate appcast
    /// check and shows Sparkle's standard update UI (or the "you're up
    /// to date" dialog). Safe to call before the updater is ready —
    /// it just no-ops.
    func triggerCheckForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    /// Cancel the background graph-build loop. Called by
    /// `PreferencesResetService.deleteAllLocalData` before the DB file is
    /// removed — otherwise the loop's next iteration would `await
    /// GraphBuilder.shared.buildIfNeeded` and start writing fresh `nodes`
    /// rows to the just-recreated DB, recreating the "ghost contacts after
    /// reset" the audit flagged.
    func cancelGraphBuildLoop() {
        graphBuildLoopTask?.cancel()
        graphBuildLoopTask = nil
        graphBuildTask?.cancel()
        graphBuildTask = nil
    }

    /// True iff the app can actually start TDLib right now — either the
    /// user has their own credentials in the Keychain, or this build was
    /// stamped with usable bundled beta credentials. Used to gate the
    /// launch-time `openDashboard()` so we never render stale cached data
    /// on top of a Telegram session that can't actually authenticate.
    /// Mirrors the keychain-vs-bundled fallback in the launch Task above
    /// so the two paths can't drift.
    private func telegramCredentialsAvailable() -> Bool {
        if let apiIdStr = try? KeychainManager.retrieve(for: .apiId),
           (try? KeychainManager.retrieve(for: .apiHash)) != nil,
           Int(apiIdStr) != nil {
            return true
        }
        if BundledSecrets.telegramApiId != nil,
           let bundledHash = BundledSecrets.telegramApiHash,
           !bundledHash.isEmpty {
            return true
        }
        return false
    }

    private func presentOnboardingIfNeeded(force: Bool) {
        let defaults = UserDefaults.standard
        let didComplete = defaults.bool(
            forKey: AppConstants.Preferences.didCompleteOnboardingKey
        )

        if !force && didComplete { return }

        // If TDLib is already authenticated (existing user reopening the app),
        // there's nothing to onboard — just mark the flag so we never bother
        // them again. Also open the dashboard if it isn't already up; the
        // launch path gates `openDashboard()` on this key, so without this
        // we'd silently render no UI for the rare returning-user-with-
        // cleared-key edge case.
        if !force && telegramService.authState == .ready {
            defaults.set(true, forKey: AppConstants.Preferences.didCompleteOnboardingKey)
            if dashboardWindow == nil && opensDashboardOnLaunch {
                openDashboard()
            }
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

    /// Whether a Telegram auth-state change should bounce the UI back to the
    /// login screen. Pure so the gating is unit-testable: fire only when an
    /// authenticated session (we'd seen `.ready`) transitions to logging-out
    /// / closed, and never while the app is quitting (telegramService.stop()
    /// closes the session during termination — we must not pop a window then)
    /// or during first-run auth (no prior `.ready`).
    /// Full logout. Confirms (destructive — wipes all local data), then:
    /// log out server-side so Telegram unlinks this device, wait briefly for
    /// TDLib to process it, wipe every local trace via the proven reset path,
    /// and drop back to the welcome screen. Crucially this never recreates the
    /// TDLib client while the old one is closing (that's what crashed before);
    /// the client is built fresh only when the user reconnects in onboarding.
    @MainActor
    func performLogout() async {
        if logoutInProgress { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Log out of Pidgy?"
        alert.informativeText = """
            This unlinks this device from Telegram and removes ALL local Pidgy \
            data on this Mac — indexed messages, tasks, the people graph, and \
            your saved credentials. You'll return to the welcome screen and can \
            sign in again (Pidgy will re-index from scratch).
            """
        alert.addButton(withTitle: "Log Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        logoutInProgress = true
        showLogoutProgress()

        // 1. Best-effort server-side unlink. Fire-and-forget: a slow or wedged
        //    TDLib must NEVER hang logout (that's the bug we're fixing). The
        //    bounded pause only gives the request time to reach Telegram
        //    before we tear the process down.
        Task { try? await telegramService.logOut() }
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        // 2. Wipe everything directly — NO coordinator / TDLib `stop()` awaits.
        //    Those block on a wedged TDLib roundtrip, which is what left logout
        //    hung for 30s+. We relaunch into a fresh process next, so open file
        //    handles don't matter.
        if let dir = PreferencesResetPlan.defaultPidgyDataDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
        for key in PreferencesResetPlan.credentialKeysToDelete {
            try? KeychainManager.delete(for: key)
        }
        for key in PreferencesResetPlan.userDefaultsKeysToDelete {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // 3. Relaunch into a clean process → welcome screen. exit() can't hang.
        relaunchAfterLogout()
    }

    /// Spawns a fresh instance (after a 1s delay so this one is gone) and
    /// exits immediately. Bulletproof — no graceful-shutdown awaits to wedge.
    private func relaunchAfterLogout() -> Never {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        exit(0)
    }

    /// Small floating spinner shown while logout wipes data + relaunches, so
    /// the few seconds aren't a frozen-looking window.
    private func showLogoutProgress() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 128),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Signing out & clearing data…")
        label.alignment = .center
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logoutProgressWindow = panel
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
        if let backgroundActivityToken {
            ProcessInfo.processInfo.endActivity(backgroundActivityToken)
            self.backgroundActivityToken = nil
        }
        hotkeyManager?.unregister()
        graphBuildTask?.cancel()
        graphBuildLoopTask?.cancel()
        TaskIndexCoordinator.shared.stop()
        telegramService.stop()

        // Reply exactly once — whichever fires first, the async stops or
        // the watchdog below.
        let finish = { [weak self] in
            guard let self, !self.terminationCleanupCompleted else { return }
            self.terminationCleanupCompleted = true
            onComplete?()
        }

        // Cleanup is best-effort and MUST NOT wedge quit. A hung TDLib stop
        // or a DB close blocked on in-flight index writes used to leave the
        // app stuck "quitting" forever (applicationShouldTerminate returned
        // .terminateLater and the reply never came). Reply after a short
        // grace period regardless, so the app always quits.
        if onComplete != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: finish)
        }

        Task { @MainActor in
            await RecentSyncCoordinator.shared.stop()
            await MajorChatCoverageCoordinator.shared.stop()
            await IndexScheduler.shared.stop()
            await DatabaseManager.shared.close()
            finish()
        }
    }

    private func openSettings() {
        openDashboard(page: PreferencesRouting.authoritativePage)
    }

    private func openDashboard(page: DashboardPage = .dashboard) {
        // Hard gate: never reveal the dashboard when Telegram credentials
        // aren't available, regardless of which path called us. The
        // launch-time gate above only covers `applicationDidFinishLaunching`;
        // menu bar items, the dock-icon reopen handler, the search panel's
        // "Open dashboard" action, and the Settings opener all funnel
        // through here, and without this guard a single dismiss of the
        // onboarding modal lets every one of those reveal the cached
        // dashboard ("Investigate DMG installer issue" over an empty
        // Telegram session etc.). Funnel everyone to onboarding instead
        // — credentials get entered there, and once entered, every path
        // works normally again.
        guard telegramCredentialsAvailable() else {
            presentOnboardingIfNeeded(force: true)
            return
        }

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
        // Hide the centered "Pidgy" title text — the sidebar already
        // brands the app, and the bare title in the transparent
        // titlebar just adds noise. Traffic lights + titlebar accessory
        // (sidebar toggle) stay.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false

        // Sidebar toggle pinned to the title bar, immediately to the
        // right of the traffic lights (Granola-style). A `.leading`
        // titlebar accessory always shows there regardless of which
        // page is up; it posts `.pidgyToggleSidebar`, which
        // DashboardView animates.
        let toggle = NSTitlebarAccessoryViewController()
        toggle.layoutAttribute = .leading
        let toggleHost = NSHostingView(rootView: SidebarToggleTitlebarButton())
        toggleHost.frame = NSRect(x: 0, y: 0, width: 42, height: 28)
        toggle.view = toggleHost
        window.addTitlebarAccessoryViewController(toggle)

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
