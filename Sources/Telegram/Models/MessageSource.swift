import Foundation

/// Read-only seam implemented by every inbox source.
@MainActor
protocol MessageSource: AnyObject {
    nonisolated var sourceID: SourceID { get }
    var currentUser: TGUser? { get }
    var chats: [TGChat] { get }
    var visibleChats: [TGChat] { get }
    var isReady: Bool { get }

    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage]
    func user(id: Int64) async throws -> TGUser?
    func isLikelyBot(chat: TGChat) -> Bool
    func hydrateThread(messageId: Int64, threadRootId: Int64?) async -> [TGMessage]
}

extension MessageSource {
    nonisolated var kind: MessageSourceKind { sourceID.kind }
    func hydrateThread(messageId: Int64, threadRootId: Int64?) async -> [TGMessage] { [] }
}
