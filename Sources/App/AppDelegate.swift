import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let telegramService = TelegramService()
    let aiService = AIService()
    private var menuBarManager: MenuBarManager?
    private var panelManager: PanelManager?
    private var hotkeyManager: HotkeyManager?
    private var settingsWindow: NSWindow?
    private var periodicCacheFlushTask: Task<Void, Never>?
    private let periodicCacheFlushIntervalNanos: UInt64 = 15_000_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelManager = PanelManager(telegramService: telegramService, aiService: aiService)
        panelManager?.onOpenSettings = { [weak self] in self?.openSettings() }

        menuBarManager = MenuBarManager(
            onTogglePanel: { [weak self] in self?.panelManager?.toggle() },
            onOpenSettings: { [weak self] in self?.openSettings() }
        )

        hotkeyManager = HotkeyManager { [weak self] in
            self?.panelManager?.toggle()
        }
        hotkeyManager?.register()

        // Start TDLib if credentials exist
        if let apiIdStr = try? KeychainManager.retrieve(for: .apiId),
           let apiHash = try? KeychainManager.retrieve(for: .apiHash),
           let apiId = Int(apiIdStr) {
            Task {
                telegramService.start(apiId: apiId, apiHash: apiHash)
            }
        }

        startPeriodicCacheFlush()
    }

    func applicationWillTerminate(_ notification: Notification) {
        periodicCacheFlushTask?.cancel()
        periodicCacheFlushTask = nil
        hotkeyManager?.unregister()
        telegramService.stop()
        flushCachesBeforeTermination()
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
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

    private func flushCachesBeforeTermination(timeout: TimeInterval = 2) {
        let flushGroup = DispatchGroup()
        flushGroup.enter()

        Task.detached {
            await MessageCacheService.shared.flushToDisk()
            flushGroup.leave()
        }

        _ = flushGroup.wait(timeout: .now() + timeout)
    }

    /// Periodically persists incremental message updates to disk.
    /// This does not trigger any Telegram fetches; it only flushes dirty in-memory cache entries.
    private func startPeriodicCacheFlush() {
        periodicCacheFlushTask?.cancel()
        periodicCacheFlushTask = Task.detached(priority: .utility) { [intervalNanos = periodicCacheFlushIntervalNanos] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                guard !Task.isCancelled else { break }
                await MessageCacheService.shared.flushToDisk()
            }
        }
    }
}
