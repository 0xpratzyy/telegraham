import Combine
import Foundation

/// Pidgy-level chat archive. Archiving a chat removes it from EVERY
/// dashboard pipeline — both the reply queue and task extraction —
/// the same way bots are filtered out. This is intentionally
/// stronger than `AttentionStore`'s "Hide from queue"
/// (`excludedChatIds`), which only suppresses a chat in the reply
/// queue.
///
/// It is a Pidgy-only concept: it does NOT touch Telegram's own
/// Archived folder, so the user's actual Telegram account is
/// untouched. Fully reversible from Preferences → Archived chats.
///
/// The pipeline candidate collectors (`SearchChatEligibilityFilter`
/// for the reply queue, `TaskIndexCoordinator.candidateChats` for
/// tasks) read the archived set via the thread-safe static
/// `archivedIds()` accessor; the management UI observes the
/// `@Published` set on the shared instance.
@MainActor
final class ArchivedChatsStore: ObservableObject {
    static let shared = ArchivedChatsStore()

    @Published private(set) var ids: Set<Int64>

    private init() {
        ids = Self.read()
    }

    func archive(_ id: Int64) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        Self.write(ids)
    }

    func unarchive(_ id: Int64) {
        guard ids.contains(id) else { return }
        ids.remove(id)
        Self.write(ids)
    }

    func isArchived(_ id: Int64) -> Bool { ids.contains(id) }

    // MARK: - Thread-safe statics for off-main pipeline filters

    /// Reads the archived set straight from UserDefaults (thread-safe)
    /// so the candidate collectors can call it from any context
    /// without hopping to the main actor.
    nonisolated static func archivedIds() -> Set<Int64> {
        read()
    }

    nonisolated static func isArchived(_ id: Int64) -> Bool {
        read().contains(id)
    }

    nonisolated private static func read() -> Set<Int64> {
        let raw = UserDefaults.standard.array(forKey: AppConstants.Preferences.archivedChatsKey) ?? []
        return Set(raw.compactMap { ($0 as? NSNumber)?.int64Value })
    }

    nonisolated private static func write(_ ids: Set<Int64>) {
        let raw = ids.map { NSNumber(value: $0) }
        UserDefaults.standard.set(raw, forKey: AppConstants.Preferences.archivedChatsKey)
    }
}
