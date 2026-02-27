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

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelManager = PanelManager(telegramService: telegramService, aiService: aiService)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.unregister()
        telegramService.stop()
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
        window.title = "TGSearch Settings"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
