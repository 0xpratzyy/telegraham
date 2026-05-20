import Foundation

extension Notification.Name {
    static let pidgyOpenDashboardPreferences = Notification.Name("com.pidgy.openDashboardPreferences")
    /// Posted by the title-bar sidebar toggle (the button pinned next
    /// to the traffic lights). DashboardView observes it and animates
    /// the sidebar collapse/expand. Lives here rather than in the view
    /// so AppDelegate (which builds the title-bar accessory) can post
    /// it without importing the view layer.
    static let pidgyToggleSidebar = Notification.Name("com.pidgy.toggleSidebar")
}

enum PreferencesRouting {
    static let authoritativePage = DashboardPage.preferences

    @MainActor
    static func showAuthoritativePreferences() {
        showAuthoritativePreferences(in: .shared)
    }

    @MainActor
    static func showAuthoritativePreferences(in store: DashboardNavigationStore) {
        store.show(authoritativePage)
    }

    static func requestAuthoritativePreferences() {
        NotificationCenter.default.post(name: .pidgyOpenDashboardPreferences, object: nil)
    }
}
