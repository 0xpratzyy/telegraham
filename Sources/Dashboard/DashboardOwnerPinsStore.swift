//
//  DashboardOwnerPinsStore.swift
//  Pidgy
//
//  Persists which owner names the user has pinned as filter chips on the
//  Tasks page. The chip bar previously auto-derived chips from current task
//  data, which meant the visible chips churned every time a new sync wiped
//  or repopulated the task table. The user only wants chips that they have
//  explicitly added — anything else lives behind the "+" picker.
//

import Foundation

@MainActor
final class DashboardOwnerPinsStore: ObservableObject {
    static let shared = DashboardOwnerPinsStore()

    @Published private(set) var pinnedNames: [String]

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = AppConstants.Preferences.dashboardTaskPinnedOwnersKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.pinnedNames = (userDefaults.array(forKey: storageKey) as? [String]) ?? []
    }

    func pin(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = DashboardTaskOwnership.normalizedOwnerName(trimmed)
        guard !normalized.isEmpty else { return }

        if pinnedNames.contains(where: {
            DashboardTaskOwnership.normalizedOwnerName($0) == normalized
        }) {
            return
        }

        pinnedNames.append(trimmed)
        persist()
    }

    func unpin(_ name: String) {
        let normalized = DashboardTaskOwnership.normalizedOwnerName(name)
        guard !normalized.isEmpty else { return }
        let filtered = pinnedNames.filter {
            DashboardTaskOwnership.normalizedOwnerName($0) != normalized
        }
        guard filtered.count != pinnedNames.count else { return }
        pinnedNames = filtered
        persist()
    }

    func isPinned(_ name: String) -> Bool {
        let normalized = DashboardTaskOwnership.normalizedOwnerName(name)
        guard !normalized.isEmpty else { return false }
        return pinnedNames.contains {
            DashboardTaskOwnership.normalizedOwnerName($0) == normalized
        }
    }

    private func persist() {
        userDefaults.set(pinnedNames, forKey: storageKey)
    }
}
