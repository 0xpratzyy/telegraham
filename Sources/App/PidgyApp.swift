import SwiftUI

@main
struct PidgyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — panel and settings are managed manually
        Settings {
            EmptyView()
        }
    }
}
