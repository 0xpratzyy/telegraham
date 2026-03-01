import AppKit

final class MenuBarManager: NSObject {
    private var statusItem: NSStatusItem?
    private let onTogglePanel: () -> Void
    private let onOpenSettings: () -> Void

    init(onTogglePanel: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.onTogglePanel = onTogglePanel
        self.onOpenSettings = onOpenSettings
        super.init()
        setup()
    }

    private func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "TGSearch")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        let menu = NSMenu()

        let searchItem = NSMenuItem(title: "Search Telegram", action: #selector(togglePanel), keyEquivalent: "")
        searchItem.keyEquivalentModifierMask = [.command, .shift]
        searchItem.target = self
        menu.addItem(searchItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TGSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func togglePanel() {
        onTogglePanel()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
