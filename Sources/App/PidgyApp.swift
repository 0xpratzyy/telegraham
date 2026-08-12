import AppKit
import SwiftUI

/// Non-observing access to the Telegram client for views that only need to
/// call a method (for example, loading an avatar). Using `@EnvironmentObject`
/// for those views subscribed every visible row to the service's high-volume
/// chat publications and fanned one source update into hundreds of redraws.
private struct TelegramServiceReferenceKey: EnvironmentKey {
    static let defaultValue: TelegramService? = nil
}

extension EnvironmentValues {
    var telegramServiceReference: TelegramService? {
        get { self[TelegramServiceReferenceKey.self] }
        set { self[TelegramServiceReferenceKey.self] = newValue }
    }
}

@main
struct PidgyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes: panel and dashboard windows are managed manually.
        Settings {
            DashboardPreferencesRedirectView()
        }
        .commands {
            // "Check for Updates…" right after "About Pidgy" in the
            // app menu. Declared here (not spliced into NSApp.mainMenu
            // by hand) so it survives SwiftUI's menu rebuilds.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.triggerCheckForUpdates()
                }
                // No `.disabled` guard: SwiftUI evaluates the menu's
                // enabled state once at build time — before
                // applicationDidFinishLaunching wires up the updater —
                // and `canCheckForUpdates` (a plain computed property)
                // isn't observable, so a disabled state would stick
                // forever. The action safely no-ops if the updater
                // isn't ready, and by the time a user can click it,
                // it always is.
            }
        }
    }
}

private struct DashboardPreferencesRedirectView: View {
    @State private var didRequestOpen = false

    var body: some View {
        SettingsWindowCloser()
            .frame(width: 1, height: 1)
            .onAppear {
                guard !didRequestOpen else { return }
                didRequestOpen = true
                PreferencesRouting.requestAuthoritativePreferences()
            }
    }
}

private struct SettingsWindowCloser: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        closeWindow(owning: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        closeWindow(owning: nsView)
    }

    private func closeWindow(owning view: NSView) {
        DispatchQueue.main.async {
            view.window?.close()
        }
    }
}
