import AppKit

final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        // Global monitor: when app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Local monitor: when app IS focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleKeyEvent(event) == true {
                return nil // Consume the event
            }
            return event
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Cmd+Shift+T (keyCode 17 = T)
        let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
        guard event.modifierFlags.contains(requiredFlags),
              event.keyCode == 17
        else { return false }

        DispatchQueue.main.async { [weak self] in
            self?.action()
        }
        return true
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        unregister()
    }
}
