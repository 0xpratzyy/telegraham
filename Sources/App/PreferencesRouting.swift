import Foundation

extension Notification.Name {
    static let pidgyOpenDashboardPreferences = Notification.Name("com.pidgy.openDashboardPreferences")
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
