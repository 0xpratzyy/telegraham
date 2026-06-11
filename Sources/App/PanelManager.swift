import AppKit
import SwiftUI

// MARK: - Keyboard Navigation Notifications

extension Notification.Name {
    static let launcherArrowDown = Notification.Name("launcherArrowDown")
    static let launcherArrowUp = Notification.Name("launcherArrowUp")
    static let launcherEnter = Notification.Name("launcherEnter")
    /// Posted by UI that wants to surface the launcher panel (e.g. the
    /// dashboard sidebar's "Jump to anything…" search button). AppDelegate
    /// listens for this and calls `PanelManager.toggle()` so we don't have
    /// to thread the panel manager all the way down into SwiftUI views.
    static let requestLauncherToggle = Notification.Name("requestLauncherToggle")
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

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        // The hosted LauncherView's .onDisappear does NOT fire for an
        // ordered-out panel, so its paired IndexScheduler.resume()
        // never runs from SwiftUI. Release the pause at the actual
        // visibility boundary instead. (The pause lease would expire on
        // its own within 30s — this just resumes indexing immediately.)
        Task { await IndexScheduler.shared.resume() }
    }

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
    private var launcherWindow: NSWindow?
    private let telegramService: TelegramService
    private let aiService: AIService
    private let presentationMode: AppLaunchPresentationMode
    var onOpenDashboard: (() -> Void)?

    init(
        telegramService: TelegramService,
        aiService: AIService,
        presentationMode: AppLaunchPresentationMode = .menuBarPanel
    ) {
        self.telegramService = telegramService
        self.aiService = aiService
        self.presentationMode = presentationMode
        createLauncherWindow()  // Eager: LauncherView lifecycle starts immediately for background pipeline refresh
    }

    func toggle() {
        if let launcherWindow, launcherWindow.isVisible {
            launcherWindow.orderOut(nil)
        } else {
            show()
        }
    }

    func showForDebugTesting() {
        show()
    }

    private func show() {
        if launcherWindow == nil {
            createLauncherWindow()
        }

        guard let launcherWindow else { return }

        switch presentationMode {
        case .menuBarPanel:
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let panelWidth = AppConstants.Panel.width
                let panelHeight = AppConstants.Panel.height
                let x = screenFrame.midX - panelWidth / 2
                let y = screenFrame.maxY - panelHeight - screenFrame.height * AppConstants.Panel.topOffsetRatio
                launcherWindow.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
            }
        case .debugWindow:
            if !launcherWindow.isVisible {
                launcherWindow.center()
            }
        }

        launcherWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContainerView() -> NSView {
        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.Pidgy.bg1.cgColor
        containerView.layer?.cornerRadius = PidgyRadius.lg

        let hostingView = NSHostingView(
            rootView: LauncherView(onOpenDashboard: { [weak self] in
                    self?.onOpenDashboard?()
                })
                .environmentObject(telegramService)
                .environmentObject(aiService)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        return containerView
    }

    private func createLauncherWindow() {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: AppConstants.Panel.width,
            height: AppConstants.Panel.height
        )

        let window: NSWindow
        switch presentationMode {
        case .menuBarPanel:
            window = FloatingPanel(
                contentRect: contentRect,
                styleMask: [],
                backing: .buffered,
                defer: false
            )
        case .debugWindow:
            let debugWindow = NSWindow(
                contentRect: contentRect,
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            debugWindow.title = "Pidgy Debug Launcher"
            debugWindow.isReleasedWhenClosed = false
            debugWindow.collectionBehavior = [.moveToActiveSpace]
            window = debugWindow
        }

        window.contentView = buildContainerView()
        self.launcherWindow = window
    }
}
