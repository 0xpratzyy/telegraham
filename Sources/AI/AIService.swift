import Foundation
import SwiftUI

/// Central AI service manager. Owns the current provider, manages configuration,
/// and exposes high-level AI operations that combine TelegramService data with AI.
@MainActor
final class AIService: ObservableObject {
    @Published var isConfigured = false
    @Published var providerType: AIProviderConfig.ProviderType = .none
    private(set) var provider: AIProvider = NoAIProvider()
    let queryRouter: QueryRouter

    init() {
        self.queryRouter = QueryRouter(aiProvider: NoAIProvider())
        loadConfiguration()
    }

    // MARK: - Configuration

    func configure(type: AIProviderConfig.ProviderType, apiKey: String, model: String? = nil) {
        let resolvedModel = model?.isEmpty == false ? model! : type.defaultModel

        switch type {
        case .claude:
            provider = ClaudeProvider(apiKey: apiKey, model: resolvedModel)
        case .openai:
            provider = OpenAIProvider(apiKey: apiKey, model: resolvedModel)
        case .none:
            provider = NoAIProvider()
        }

        queryRouter.updateProvider(provider)
        providerType = type
        isConfigured = type != .none && !apiKey.isEmpty
        saveConfiguration(type: type, apiKey: apiKey, model: resolvedModel)
    }

    // MARK: - High-Level AI Operations

    /// Semantic search: find chats relevant to a query by analyzing messages.
    func semanticSearch(query: String, messages: [TGMessage]) async throws -> [SemanticSearchResult] {
        let snippets = MessageSnippet.fromMessages(messages)
        guard !snippets.isEmpty else { return [] }
        let dtos = try await provider.semanticSearch(query: query, messages: snippets)
        return dtos.map {
            SemanticSearchResult(
                chatId: $0.chatId,
                chatTitle: $0.chatName,
                reason: $0.reason,
                relevance: $0.relevance == "high" ? .high : .medium,
                matchingMessages: $0.matchingMessages ?? []
            )
        }
    }

    /// Generate a follow-up suggestion for a conversation. Marks the user's own messages with [ME].
    /// Returns (isRelevant, suggestedAction). AI decides if the chat is BD-relevant.
    func followUpSuggestion(chatTitle: String, messages: [TGMessage], myUserId: Int64) async throws -> (Bool, String) {
        let snippets = conversationSnippets(messages: messages, chatTitle: chatTitle, myUserId: myUserId)
        guard !snippets.isEmpty else { return (true, "") }
        return try await provider.generateFollowUpSuggestion(chatTitle: chatTitle, messages: snippets)
    }

    /// AI-powered pipeline categorization. Marks [ME] messages and sends to AI.
    /// Returns (category, suggestedAction, isConfident).
    func categorizePipelineChat(chat: TGChat, messages: [TGMessage], myUserId: Int64, myUser: TGUser?) async throws -> (FollowUpItem.Category, String, Bool) {
        let snippets = conversationSnippets(messages: messages, chatTitle: chat.title, myUserId: myUserId)
        guard !snippets.isEmpty else { return (.quiet, "", true) }

        let context = PipelineChatContext(
            chatTitle: chat.title,
            chatType: chat.chatType.displayName,
            unreadCount: chat.unreadCount,
            myName: myUser?.firstName ?? "Me",
            myUsername: myUser?.username
        )

        let dto = try await provider.categorizePipelineChat(context: context, messages: snippets)

        let category: FollowUpItem.Category
        switch dto.category.lowercased() {
        case "on_me": category = .onMe
        case "on_them": category = .onThem
        default: category = .quiet
        }

        return (category, dto.suggestedAction, dto.confident ?? true)
    }

    private func conversationSnippets(messages: [TGMessage], chatTitle: String, myUserId: Int64) -> [MessageSnippet] {
        messages
            .sorted { $0.date < $1.date }
            .compactMap { msg -> MessageSnippet? in
            guard let text = msg.textContent, !text.isEmpty else { return nil }
            let isMe: Bool
            if case .user(let uid) = msg.senderId { isMe = uid == myUserId } else { isMe = false }
            let name = isMe ? "[ME]" : (msg.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown")
            return MessageSnippet(
                messageId: msg.id,
                senderFirstName: name,
                text: text,
                relativeTimestamp: msg.relativeDate,
                chatId: msg.chatId,
                chatName: chatTitle
            )
        }
    }

    /// Validates AI provider connection by making a minimal test request.
    func testConnection() async throws -> Bool {
        return try await provider.testConnection()
    }

    // MARK: - Persistence

    private func loadConfiguration() {
        guard let typeStr = try? KeychainManager.retrieve(for: .aiProviderType),
              let type = AIProviderConfig.ProviderType(rawValue: typeStr),
              let apiKey = try? KeychainManager.retrieve(for: .aiApiKey),
              !apiKey.isEmpty else {
            return
        }

        let model = try? KeychainManager.retrieve(for: .aiModel)
        configure(type: type, apiKey: apiKey, model: model)
    }

    private func saveConfiguration(type: AIProviderConfig.ProviderType, apiKey: String, model: String) {
        try? KeychainManager.save(type.rawValue, for: .aiProviderType)
        try? KeychainManager.save(apiKey, for: .aiApiKey)
        try? KeychainManager.save(model, for: .aiModel)
    }

    func clearConfigurationState() {
        provider = NoAIProvider()
        queryRouter.updateProvider(provider)
        providerType = .none
        isConfigured = false
    }
}
