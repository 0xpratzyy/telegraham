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
