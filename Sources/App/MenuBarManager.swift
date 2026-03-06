import AppKit

extension Notification.Name {
    static let onMeCountChanged = Notification.Name("onMeCountChanged")
}

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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "TGSearch")
            button.image?.size = NSSize(width: 18, height: 18)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Observe "On Me" count changes from pipeline
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOnMeCountChanged(_:)),
            name: .onMeCountChanged,
            object: nil
        )

        // Build menu for right-click only
        let menu = NSMenu()

        let searchItem = NSMenuItem(title: "Search Telegram", action: #selector(togglePanel), keyEquivalent: "")
        searchItem.target = self
        menu.addItem(searchItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TGSearch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        self.menu = menu
    }

    private var menu: NSMenu?

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click → show menu
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // Remove menu after so left-click doesn't trigger it next time
            DispatchQueue.main.async { [weak self] in
                self?.statusItem?.menu = nil
            }
        } else {
            // Left-click → toggle panel directly
            onTogglePanel()
        }
    }

    @objc private func togglePanel() {
        onTogglePanel()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    // MARK: - Badge

    @objc private func handleOnMeCountChanged(_ notification: Notification) {
        let count = notification.userInfo?["count"] as? Int ?? 0
        updateBadge(count: count)
    }

    private func updateBadge(count: Int) {
        guard let button = statusItem?.button else { return }

        // Keep icon as template so it adapts to dark/light menu bar
        let icon = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "TGSearch")!
        icon.size = NSSize(width: 18, height: 18)
        icon.isTemplate = true
        button.image = icon

        if count > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.systemOrange
                ]
            )
        } else {
            button.title = ""
        }
    }
}
