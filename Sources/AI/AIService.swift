import Foundation
import SwiftUI

/// Central AI service manager. Owns the current provider, manages configuration,
/// and exposes high-level AI operations that combine TelegramService data with AI.
@MainActor
final class AIService: ObservableObject {
    @Published var isConfigured = false
    @Published var providerType: AIProviderConfig.ProviderType = .none
    @Published var showAIPreview = false

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

    func summarizeGroup(messages: [TGMessage], chatTitle: String) async throws -> String {
        let snippets = MessageSnippet.fromMessages(messages, chatTitle: chatTitle)
        guard !snippets.isEmpty else { return "No recent activity" }
        return try await provider.summarize(messages: snippets, prompt: "")
    }

    func categorizedDMs(messages: [TGMessage], chats: [TGChat]) async throws -> [CategorizedMessage] {
        let snippets = MessageSnippet.fromMessages(messages)
        guard !snippets.isEmpty else { return [] }

        let dtos = try await provider.categorize(messages: snippets)

        return dtos.compactMap { dto in
            guard dto.index >= 0, dto.index < messages.count else { return nil }
            let msg = messages[dto.index]
            let category = DMCategory(rawValue: dto.category) ?? .fyi
            return CategorizedMessage(
                id: msg.id,
                message: msg,
                category: category,
                reason: dto.reason,
                chatTitle: msg.chatTitle ?? "DM"
            )
        }
    }

    func actionItems(messages: [TGMessage]) async throws -> [ActionItem] {
        let snippets = MessageSnippet.fromMessages(messages)
        guard !snippets.isEmpty else { return [] }

        let dtos = try await provider.generateActionItems(messages: snippets)

        return dtos.map { dto in
            let urgency = ActionItem.Urgency(rawValue: dto.urgency) ?? .medium
            return ActionItem(
                chatTitle: dto.chatName,
                senderName: dto.senderName,
                summary: dto.summary,
                suggestedAction: dto.suggestedAction,
                urgency: urgency,
                originalMessages: []
            )
        }
    }

    func generateDigest(messages: [TGMessage], period: DigestPeriod) async throws -> DigestResult {
        let snippets = MessageSnippet.fromMessages(messages)
        guard !snippets.isEmpty else {
            return DigestResult(period: period, sections: [
                DigestSection(emoji: "📭", title: "All Quiet", content: "- No significant activity to report")
            ], generatedAt: Date())
        }
        return try await provider.generateDigest(messages: snippets, period: period)
    }

    /// Get the current snippets that would be sent to AI (for preview mode).
    func previewSnippets(from messages: [TGMessage]) -> [MessageSnippet] {
        MessageSnippet.truncateToTokenBudget(MessageSnippet.fromMessages(messages))
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
}
