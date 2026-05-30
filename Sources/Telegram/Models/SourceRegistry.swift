import Foundation
import Combine

/// Coordinates one or more `MessageSource` adapters and exposes a
/// unified view of "the user's inbox" to the rest of the app.
///
/// As Pidgy adds backends (Slack now, others later) every screen that
/// today reads `telegramService.visibleChats` switches to reading
/// `registry.visibleChats` so chats from multiple sources land in the
/// same lists, queue, and search. The registry also routes per-chat
/// reads (history fetches, identity lookups) to the right backend by
/// matching `chat.source` against each registered source's `kind`.
///
/// ## Reactivity
/// The registry forwards each registered source's `objectWillChange`
/// to its own, so SwiftUI views observing the registry as an
/// `ObservableObject` re-render whenever any source updates. The
/// unified `chats` / `visibleChats` are kept *computed* so a freshly
/// registered source slots in immediately without a republish step.
///
/// ## Multi-account
/// In v1 there is at most one source per `kind` (one Telegram + one
/// Slack). Multi-workspace Slack — multiple sources with `.slack` —
/// is handled in Phase 3 (per-source/per-workspace identity).
@MainActor
final class SourceRegistry: ObservableObject {
    /// The shared instance the rest of the app reads from. Constructed
    /// once at app startup; sources are `register(_:)`ed onto it as
    /// each adapter is wired in. Tests use their own instances.
    static let shared = SourceRegistry()

    private var registered: [any MessageSource] = []
    private var sourceCancellables: [ObjectIdentifier: AnyCancellable] = [:]

    init() {}

    // MARK: - Registration

    /// Add a source. Sources are concrete `ObservableObject`s so the
    /// registry can mirror their reactivity onto its own
    /// `objectWillChange`. Re-registering the same instance is a no-op.
    func register<S>(_ source: S) where S: MessageSource & ObservableObject {
        guard !registered.contains(where: { $0 === source }) else { return }
        objectWillChange.send()
        registered.append(source)
        sourceCancellables[ObjectIdentifier(source)] = source.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Remove a source (e.g. when a Slack workspace is disconnected). Its
    /// chats stop contributing immediately and its reactivity sink is
    /// cancelled. No-op if the source isn't registered.
    func unregister<S>(_ source: S) where S: MessageSource & ObservableObject {
        guard let index = registered.firstIndex(where: { $0 === source }) else { return }
        objectWillChange.send()
        registered.remove(at: index)
        sourceCancellables.removeValue(forKey: ObjectIdentifier(source))
    }

    // MARK: - Unified inbox

    /// Registered sources, in registration order.
    var sources: [any MessageSource] { registered }

    /// All chats from every registered source. Order within a source
    /// is preserved; cross-source ordering is "first registered first."
    /// Call sites that need a merged sort (e.g. the reply queue) re-sort
    /// at the point of use.
    var chats: [TGChat] { registered.flatMap { $0.chats } }

    /// Chats each source has chosen to surface in its main list (i.e.
    /// not archived / hidden by the backend). Same merge behavior as
    /// `chats`.
    var visibleChats: [TGChat] { registered.flatMap { $0.visibleChats } }

    // MARK: - Routing

    /// The source that produced `chat`, matched on the full `SourceID`
    /// so the right *account* is chosen, not merely the right provider.
    func source(for chat: TGChat) -> (any MessageSource)? {
        registered.first { $0.sourceID == chat.source }
    }

    /// The registered source with this exact `SourceID`, if any.
    func source(for sourceID: SourceID) -> (any MessageSource)? {
        registered.first { $0.sourceID == sourceID }
    }

    /// Every registered source for a provider (e.g. all Slack workspaces).
    func sources(of kind: MessageSourceKind) -> [any MessageSource] {
        registered.filter { $0.kind == kind }
    }

    /// Convenience: route a history fetch through the chat's source.
    /// Returns an empty array if no source of the matching kind is
    /// registered — callers that need to surface that case should check
    /// `source(for:)` first.
    func chatHistory(for chat: TGChat, fromMessageId: Int64 = 0, limit: Int = 50) async throws -> [TGMessage] {
        guard let source = source(for: chat) else { return [] }
        return try await source.chatHistory(chatId: chat.id, fromMessageId: fromMessageId, limit: limit)
    }

    /// Source-aware bot check. Routes to the chat's source; returns
    /// `false` if no matching source is registered (defensive default,
    /// matches the legacy behavior of treating unknown chats as
    /// non-bots).
    func isLikelyBot(chat: TGChat) -> Bool {
        source(for: chat)?.isLikelyBot(chat: chat) ?? false
    }

    // MARK: - Identity

    /// The signed-in user for a backend kind, or `nil` if no source of
    /// that kind is registered or it hasn't authed yet. With multiple
    /// accounts of one kind this returns the first registered — use the
    /// `SourceID` overload to disambiguate.
    func currentUser(for kind: MessageSourceKind) -> TGUser? {
        registered.first { $0.kind == kind }?.currentUser
    }

    /// The signed-in user for one specific account. Distinct label from
    /// the kind overload so a bare `.telegram` literal stays unambiguous.
    func currentUser(forAccount sourceID: SourceID) -> TGUser? {
        source(for: sourceID)?.currentUser
    }

    /// Source-aware "is this from me?" check that replaces the scattered
    /// `senderId == telegramService.currentUser?.id` calls. Returns
    /// `false` for nil sender ids, unknown identity, or zero id (the
    /// historical fallback used when `currentUser` wasn't ready).
    func isMine(senderUserId: Int64?, source: SourceID) -> Bool {
        guard let senderUserId,
              let me = currentUser(forAccount: source)?.id,
              me > 0 else { return false }
        return senderUserId == me
    }

    // MARK: - Readiness

    /// `true` when there is at least one registered source AND all of
    /// them report `isReady`. Use this where the app previously gated
    /// on `telegramService.authState == .ready` and the operation
    /// genuinely needs every connected backend live (e.g. cross-source
    /// task indexing).
    var allReady: Bool {
        !registered.isEmpty && registered.allSatisfy { $0.isReady }
    }

    /// `true` when at least one source is ready — useful when a partial
    /// inbox (e.g. only Telegram connected, Slack mid-setup) should
    /// still surface what it has.
    var anyReady: Bool {
        registered.contains { $0.isReady }
    }
}
