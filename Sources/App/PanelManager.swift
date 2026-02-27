import AppKit
import SwiftUI

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
        backgroundColor = NSColor(white: 0.04, alpha: 0.97)

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
        if event.keyCode == 53 { // Escape
            orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

final class PanelManager {
    private var panel: FloatingPanel?
    private let telegramService: TelegramService

    init(telegramService: TelegramService) {
        self.telegramService = telegramService
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
            let panelWidth: CGFloat = 680
            let panelHeight: CGFloat = 520
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.maxY - panelHeight - screenFrame.height * 0.15
            panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        }

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createPanel() {
        let hostingView = NSHostingView(
            rootView: MainPanelView()
                .environmentObject(telegramService)
        )

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [],
            backing: .buffered,
            defer: false
        )

        panel.contentView = hostingView
        self.panel = panel
    }
}
