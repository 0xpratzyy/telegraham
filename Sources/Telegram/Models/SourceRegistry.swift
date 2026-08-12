import Foundation
import Combine

/// Merges connected sources and routes source-specific reads.
@MainActor
final class SourceRegistry: ObservableObject {
    static let shared = SourceRegistry()

    private var registered: [any MessageSource] = []
    private var sourceCancellables: [ObjectIdentifier: AnyCancellable] = [:]
    /// Source arrays are published wholesale. Build the merged/sorted views
    /// once per publication instead of once per SwiftUI row evaluation.
    private var chatSnapshotDirty = true
    private var cachedChats: [TGChat] = []
    private var cachedVisibleChats: [TGChat] = []
    private var cachedChatsByID: [Int64: TGChat] = [:]
    private var cachedPrivateChatsByUserID: [Int64: TGChat] = [:]

    func register<S>(_ source: S) where S: MessageSource & ObservableObject {
        guard !registered.contains(where: { $0 === source }) else { return }
        chatSnapshotDirty = true
        objectWillChange.send()
        registered.append(source)
        sourceCancellables[ObjectIdentifier(source)] = source.objectWillChange
            // Keep imperative lookups coherent immediately, even while UI
            // invalidations are batched below.
            .handleEvents(receiveOutput: { [weak self] _ in
                self?.chatSnapshotDirty = true
            })
            // Telegram publishes its chat array repeatedly while TDLib sends
            // the initial chat/update burst. The dashboard only needs a
            // human-scale refresh cadence, not one full SwiftUI invalidation
            // per individual TDLib update.
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func unregister<S>(_ source: S) where S: MessageSource & ObservableObject {
        guard let index = registered.firstIndex(where: { $0 === source }) else { return }
        chatSnapshotDirty = true
        objectWillChange.send()
        registered.remove(at: index)
        sourceCancellables.removeValue(forKey: ObjectIdentifier(source))
    }

    var sources: [any MessageSource] { registered }
    var chats: [TGChat] {
        rebuildChatSnapshotIfNeeded()
        return cachedChats
    }
    var visibleChats: [TGChat] {
        rebuildChatSnapshotIfNeeded()
        return cachedVisibleChats
    }

    /// O(1) row/detail lookup. Previously every task row asked for
    /// `visibleChats`, rebuilding and sorting the full multi-source array.
    func chat(id: Int64) -> TGChat? {
        rebuildChatSnapshotIfNeeded()
        return cachedChatsByID[id]
    }

    func privateChat(userId: Int64) -> TGChat? {
        rebuildChatSnapshotIfNeeded()
        return cachedPrivateChatsByUserID[userId]
    }

    private func rebuildChatSnapshotIfNeeded() {
        guard chatSnapshotDirty else { return }
        let allChats = registered.flatMap(\.chats)
        let visible = registered.flatMap(\.visibleChats).sorted {
            ($0.lastActivityDate ?? .distantPast) > ($1.lastActivityDate ?? .distantPast)
        }

        cachedChats = allChats
        cachedVisibleChats = visible
        cachedChatsByID = Dictionary(
            (allChats + visible).map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        cachedPrivateChatsByUserID = Dictionary(
            allChats.compactMap { chat -> (Int64, TGChat)? in
                guard case .privateChat(let userId) = chat.chatType else { return nil }
                return (userId, chat)
            },
            uniquingKeysWith: { first, _ in first }
        )
        chatSnapshotDirty = false
    }

    func source(for chat: TGChat) -> (any MessageSource)? {
        registered.first { $0.sourceID == chat.source }
    }

    func source(for sourceID: SourceID) -> (any MessageSource)? {
        registered.first { $0.sourceID == sourceID }
    }

    func sources(of kind: MessageSourceKind) -> [any MessageSource] {
        registered.filter { $0.kind == kind }
    }

    func chatHistory(for chat: TGChat, fromMessageId: Int64 = 0, limit: Int = 50) async throws -> [TGMessage] {
        guard let source = source(for: chat) else { return [] }
        return try await source.chatHistory(chatId: chat.id, fromMessageId: fromMessageId, limit: limit)
    }

    func isLikelyBot(chat: TGChat) -> Bool {
        source(for: chat)?.isLikelyBot(chat: chat) ?? false
    }

    func currentUser(for kind: MessageSourceKind) -> TGUser? {
        registered.first { $0.kind == kind }?.currentUser
    }

    func currentUser(forAccount sourceID: SourceID) -> TGUser? {
        source(for: sourceID)?.currentUser
    }

    func isMine(senderUserId: Int64?, source: SourceID) -> Bool {
        guard let senderUserId, let me = currentUser(forAccount: source)?.id, me > 0 else { return false }
        return senderUserId == me
    }

    var allReady: Bool { !registered.isEmpty && registered.allSatisfy(\.isReady) }
    var anyReady: Bool { registered.contains { $0.isReady } }
}
