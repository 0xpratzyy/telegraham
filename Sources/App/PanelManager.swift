import AppKit
import SwiftUI

// MARK: - Keyboard Navigation Notifications

extension Notification.Name {
    static let launcherArrowDown = Notification.Name("launcherArrowDown")
    static let launcherArrowUp = Notification.Name("launcherArrowUp")
    static let launcherEnter = Notification.Name("launcherEnter")
}

// MARK: - Floating Panel

final class FloatingPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        backgroundColor = .clear

        // Hide traffic light buttons
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            orderOut(nil)
        case 125: // Arrow Down
            NotificationCenter.default.post(name: .launcherArrowDown, object: nil)
        case 126: // Arrow Up
            NotificationCenter.default.post(name: .launcherArrowUp, object: nil)
        case 36: // Enter / Return
            NotificationCenter.default.post(name: .launcherEnter, object: nil)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Panel Manager

final class PanelManager {
    private var panel: FloatingPanel?
    private let telegramService: TelegramService
    private let aiService: AIService
    var onOpenSettings: (() -> Void)?

    init(telegramService: TelegramService, aiService: AIService) {
        self.telegramService = telegramService
        self.aiService = aiService
    }

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    private func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Center on the active screen, upper third
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelWidth = AppConstants.Panel.width
            let panelHeight = AppConstants.Panel.height
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - panelHeight - screenFrame.height * AppConstants.Panel.topOffsetRatio
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createPanel() {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.Panel.width, height: AppConstants.Panel.height),
            styleMask: [],
            backing: .buffered,
            defer: false
        )

        // NSVisualEffectView for translucent glass background
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active

        let hostingView = NSHostingView(
            rootView: LauncherView(onOpenSettings: { [weak self] in
                    self?.onOpenSettings?()
                })
                .environmentObject(telegramService)
                .environmentObject(aiService)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        visualEffectView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
        ])

        panel.contentView = visualEffectView
        self.panel = panel
    }
}
