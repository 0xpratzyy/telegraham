import Foundation

/// A read-only adapter for a messaging backend.
///
/// Pidgy started Telegram-only; this protocol is the seam that lets a
/// second source (Slack, eventually others) plug into the dashboard,
/// reply queue, tasks, search, and AI pipeline without those features
/// knowing which backend produced a given chat or message. Everything
/// downstream consumes the `TG*` domain structs, now tagged with
/// `MessageSourceKind`, so adding a new source is a matter of writing
/// an adapter that produces correctly-tagged `TGChat` / `TGMessage`
/// values rather than touching every consumer.
///
/// Method names are deliberately *not* `getChatHistory` / `getUser` —
/// `TelegramService` already exposes those with extra Telegram-specific
/// parameters (`onlyLocal`, `RateLimiter.Priority`) that we don't want
/// to leak into a source-neutral protocol. Using distinct names also
/// sidesteps Swift overload-resolution ambiguity between the concrete
/// 5-parameter methods and the protocol's 3-parameter form.
///
/// `@MainActor` because the existing service publishes UI state on the
/// main actor; concrete sources are expected to follow that convention
/// so SwiftUI `@Published` observers don't have to hop actors.
@MainActor
protocol MessageSource: AnyObject {
    /// Identifies this source — provider *and which account*. Routing,
    /// identity, and "is this mine?" key off the full `SourceID` so two
    /// accounts of the same provider (two Slack workspaces, a work +
    /// personal Gmail) stay distinct. Read `kind` for provider-level
    /// badges / filters that don't care which account.
    nonisolated var sourceID: SourceID { get }

    /// The signed-in identity for this source. Nil while connecting or
    /// before authentication completes. Multi-source / multi-workspace
    /// identity (one `currentUser` per source) is finalized in Phase 3.
    var currentUser: TGUser? { get }

    /// All known chats from this source, in the source's preferred order.
    var chats: [TGChat] { get }

    /// Chats the source has chosen to surface in the main list (excludes
    /// archived / hidden by the backend itself).
    var visibleChats: [TGChat] { get }

    /// True when the source is connected, authenticated, and ready to
    /// answer reads. Consumers gate task generation / sync on this.
    var isReady: Bool { get }

    /// Fetch recent messages for a chat in reverse-chronological order.
    /// Pass `fromMessageId == 0` to start from the newest message.
    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage]

    /// Resolve a user by id (sources may cache).
    func user(id: Int64) async throws -> TGUser?

    /// Best-effort check: is `chat` a bot / automated counterpart?
    /// Sources with no bot concept (e.g. Slack channels in v1) return
    /// `false`. The reply queue uses this to optionally hide bots, so
    /// routing the check per-source keeps the rest of the app from
    /// having to know what "bot" means on each backend.
    func isLikelyBot(chat: TGChat) -> Bool

    /// Fetch + cache the thread a message belongs to and return its messages
    /// (parent + replies) tagged with `threadRootId`, so the evidence panel
    /// can render them nested. Needed for sources whose main history call
    /// omits replies (Slack); sources without that gap return `[]` via the
    /// default below. `threadRootId` is the caller's known parent id, if any.
    func hydrateThread(messageId: Int64, threadRootId: Int64?) async -> [TGMessage]
}

extension MessageSource {
    /// Provider of this source, derived from `sourceID`. Convenient for
    /// badges / filters that don't care *which* account it is.
    nonisolated var kind: MessageSourceKind { sourceID.kind }

    /// Default: nothing to hydrate — the source's history already contains
    /// whatever replies exist, or it has no thread concept.
    func hydrateThread(messageId: Int64, threadRootId: Int64?) async -> [TGMessage] { [] }
}
