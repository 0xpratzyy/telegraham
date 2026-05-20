import AppKit
import SwiftUI

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
