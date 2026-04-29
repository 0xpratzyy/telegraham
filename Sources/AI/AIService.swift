import Foundation
import SwiftUI

/// Central AI service manager. Owns the current provider, manages configuration,
/// and exposes high-level AI operations that combine TelegramService data with AI.
@MainActor
final class AIService: ObservableObject {
    struct ReplyQueueExecutionConfig: Sendable {
        let providerType: AIProviderConfig.ProviderType
        let apiKey: String
        let model: String
    }

    struct PipelineTriageResult {
        enum Status: Equatable {
            case decision
            case needMore
        }

        enum Urgency: String {
            case high
            case low
        }

        let status: Status
        let category: FollowUpItem.Category
        let suggestedAction: String
        let urgency: Urgency
        let reason: String?
        let additionalMessages: Int?
        let confident: Bool
    }

    @Published var isConfigured = false
    @Published var providerType: AIProviderConfig.ProviderType = .none
    @Published private(set) var providerModel: String = ""
    private(set) var provider: AIProvider = NoAIProvider()
    let queryRouter: QueryRouter
    private var configuredAPIKey: String = ""

    init() {
        self.queryRouter = QueryRouter(aiProvider: NoAIProvider())
        loadConfiguration()
    }

    init(
        testingProvider: AIProvider,
        providerType: AIProviderConfig.ProviderType = .openai,
        providerModel: String = "test-model",
        isConfigured: Bool = true
    ) {
        self.queryRouter = QueryRouter(aiProvider: testingProvider)
        self.provider = testingProvider
        self.providerType = providerType
        self.providerModel = providerModel
        self.configuredAPIKey = isConfigured ? "test-key" : ""
        self.isConfigured = isConfigured
    }

    // MARK: - Configuration

    func configure(type: AIProviderConfig.ProviderType, apiKey: String, model: String? = nil) {
        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = normalizedModel(
            type: type,
            model: requestedModel?.isEmpty == false ? requestedModel! : type.defaultModel
        )

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
        providerModel = resolvedModel
        configuredAPIKey = apiKey
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

    /// Agentic search: rerank candidate chats for actionability and reply priority.
    func agenticSearch(
        query: String,
        querySpec: QuerySpec,
        candidates: [AgenticSearchCandidate],
        myUserId: Int64
    ) async throws -> [AgenticSearchResult] {
        guard !candidates.isEmpty else { return [] }

        let maxMessages = AppConstants.AI.AgenticSearch.maxMessagesPerChat
        let candidateDTOs: [AgenticCandidateDTO] = candidates.compactMap { candidate in
            let bounded = Array(candidate.messages.sorted { $0.date > $1.date }.prefix(maxMessages))
            let snippets = conversationSnippets(messages: bounded, chatTitle: candidate.chat.title, myUserId: myUserId)
            guard !snippets.isEmpty else { return nil }

            return AgenticCandidateDTO(
                chatId: candidate.chat.id,
                chatName: candidate.chat.title,
                pipelineCategory: candidate.pipelineCategory,
                strictReplySignal: candidate.strictReplySignal,
                messages: snippets
            )
        }
        guard !candidateDTOs.isEmpty else { return [] }

        let knownTitles = Dictionary(uniqueKeysWithValues: candidates.map { ($0.chat.id, $0.chat.title) })
        let knownIds = Set(knownTitles.keys)
        let dtos = try await provider.agenticSearch(
            query: query,
            constraints: makeAgenticConstraintsDTO(from: querySpec),
            candidates: candidateDTOs
        )

        return dtos
            .filter { knownIds.contains($0.chatId) }
            .map { dto in
                let warmth: AgenticSearchResult.Warmth
                switch dto.warmth.lowercased() {
                case "hot": warmth = .hot
                case "warm": warmth = .warm
                default: warmth = .cold
                }

                let replyability: AgenticSearchResult.Replyability
                switch dto.replyability.lowercased() {
                case "reply_now": replyability = .replyNow
                case "worth_checking": replyability = .worthChecking
                case "waiting_on_them": replyability = .waitingOnThem
                default: replyability = .unclear
                }

                return AgenticSearchResult(
                    chatId: dto.chatId,
                    chatTitle: knownTitles[dto.chatId] ?? "Unknown",
                    score: max(0, min(100, dto.score)),
                    warmth: warmth,
                    replyability: replyability,
                    reason: dto.reason,
                    suggestedAction: dto.suggestedAction,
                    confidence: max(0, min(1, dto.confidence)),
                    supportingMessageIds: dto.supportingMessageIds
                )
            }
            .sorted { $0.score > $1.score }
    }

    func rerankSearchResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, bestMessage: String)]
    ) async throws -> [Int64] {
        guard !candidates.isEmpty else { return [] }
        return try await provider.rerankResults(
            query: query,
            candidates: candidates.map { candidate in
                (
                    chatId: candidate.chatId,
                    chatTitle: candidate.chatTitle,
                    snippet: candidate.bestMessage
                )
            }
        )
    }

    /// Generate a follow-up suggestion for a conversation. Marks the user's own messages with [ME].
    /// Returns (isRelevant, suggestedAction). AI decides if the chat is BD-relevant.
    func followUpSuggestion(chatTitle: String, messages: [TGMessage], myUserId: Int64) async throws -> (Bool, String) {
        let snippets = conversationSnippets(messages: messages, chatTitle: chatTitle, myUserId: myUserId)
        guard !snippets.isEmpty else { return (true, "") }
        return try await provider.generateFollowUpSuggestion(chatTitle: chatTitle, messages: snippets)
    }

    /// AI-powered pipeline triage. Marks [ME] messages and sends to AI.
    /// Supports decision + one-step "need_more" requests.
    func categorizePipelineChat(chat: TGChat, messages: [TGMessage], myUserId: Int64, myUser: TGUser?) async throws -> PipelineTriageResult {
        let snippets = conversationSnippets(messages: messages, chatTitle: chat.title, myUserId: myUserId)
        guard !snippets.isEmpty else {
            return PipelineTriageResult(
                status: .decision,
                category: .quiet,
                suggestedAction: "",
                urgency: .low,
                reason: nil,
                additionalMessages: nil,
                confident: true
            )
        }

        let context = PipelineChatContext(
            chatTitle: chat.title,
            chatType: chat.chatType.displayName,
            unreadCount: chat.unreadCount,
            memberCount: chat.memberCount,
            myName: myUser?.firstName ?? "Me",
            myUsername: myUser?.username
        )

        let dto = try await provider.categorizePipelineChat(context: context, messages: snippets)

        let status: PipelineTriageResult.Status
        switch dto.status?.lowercased() {
        case "need_more":
            status = .needMore
        default:
            status = .decision
        }

        let category: FollowUpItem.Category
        switch dto.category?.lowercased() {
        case "on_me": category = .onMe
        case "on_them": category = .onThem
        default: category = .quiet
        }

        let urgency: PipelineTriageResult.Urgency
        switch dto.urgency?.lowercased() {
        case "high":
            urgency = .high
        default:
            urgency = .low
        }

        return PipelineTriageResult(
            status: status,
            category: category,
            suggestedAction: dto.suggestedAction,
            urgency: urgency,
            reason: dto.reason,
            additionalMessages: dto.additionalMessages,
            confident: dto.confident ?? true
        )
    }

    func discoverDashboardTopics(messages: [TGMessage]) async throws -> [DashboardTopicDTO] {
        let snippets = MessageSnippet.fromMessages(messages)
        guard !snippets.isEmpty else { return [] }
        return try await provider.discoverDashboardTopics(messages: snippets)
    }

    func extractDashboardTasks(
        chat: TGChat,
        messages: [TGMessage],
        topics: [DashboardTopic],
        myUserId: Int64
    ) async throws -> [DashboardTaskCandidate] {
        let snippets = conversationSnippets(messages: messages, chatTitle: chat.title, myUserId: myUserId)
        guard !snippets.isEmpty else { return [] }
        let extracted = try await provider.extractDashboardTasks(
            chat: chat,
            topics: topics,
            messages: snippets
        )
        return extracted.map { $0.resolvingSourceDates(from: messages) }
    }

    func triageDashboardTaskCandidates(
        _ candidates: [DashboardTaskTriageCandidate],
        myUserId: Int64
    ) async throws -> [DashboardTaskTriageResultDTO] {
        let candidateDTOs = candidates.compactMap { candidate -> DashboardTaskTriageCandidateDTO? in
            let snippets = conversationSnippets(
                messages: candidate.messages,
                chatTitle: candidate.chat.title,
                myUserId: myUserId
            )
            guard !snippets.isEmpty else { return nil }
            return DashboardTaskTriageCandidateDTO(
                chatId: candidate.chat.id,
                chatTitle: candidate.chat.title,
                chatType: candidate.chat.chatType.displayName,
                unreadCount: candidate.chat.unreadCount,
                memberCount: candidate.chat.memberCount,
                messages: snippets
            )
        }
        guard !candidateDTOs.isEmpty else { return [] }
        return try await provider.triageDashboardTaskCandidates(candidates: candidateDTOs)
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

    private func makeAgenticConstraintsDTO(from querySpec: QuerySpec) -> AgenticSearchConstraintsDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        return AgenticSearchConstraintsDTO(
            scope: querySpec.scope.rawValue,
            replyConstraint: querySpec.replyConstraint.rawValue,
            startDateISO8601: querySpec.timeRange.map { formatter.string(from: $0.startDate) },
            endDateISO8601: querySpec.timeRange.map { formatter.string(from: $0.endDate) },
            timeRangeLabel: querySpec.timeRange?.label,
            parseConfidence: querySpec.parseConfidence,
            unsupportedFragments: querySpec.unsupportedFragments
        )
    }

    /// Validates AI provider connection by making a minimal test request.
    func testConnection() async throws -> Bool {
        return try await provider.testConnection()
    }

    func loadUsageOverview() async -> AIUsageOverview {
        await AIUsageStore.shared.loadOverview()
    }

    func replyQueueExecutionConfig() -> ReplyQueueExecutionConfig? {
        guard isConfigured, providerType != .none, !configuredAPIKey.isEmpty else {
            return nil
        }

        let resolvedModel: String
        switch providerType {
        case .openai:
            resolvedModel = AppConstants.AI.replyQueueOpenAIModel
        case .claude:
            resolvedModel = providerModel
        case .none:
            return nil
        }

        return ReplyQueueExecutionConfig(
            providerType: providerType,
            apiKey: configuredAPIKey,
            model: resolvedModel
        )
    }

    func persistedConfiguration(for type: AIProviderConfig.ProviderType) -> AIProviderConfig? {
        guard type != .none else { return nil }
        guard let apiKeyKey = apiKeyStorageKey(for: type),
              let modelKey = modelStorageKey(for: type) else {
            return nil
        }

        let apiKey = (((try? KeychainManager.retrieve(for: apiKeyKey)) ?? nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        let storedModel = (((try? KeychainManager.retrieve(for: modelKey)) ?? nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = normalizedModel(
            type: type,
            model: storedModel.isEmpty ? type.defaultModel : storedModel
        )

        return AIProviderConfig(providerType: type, apiKey: apiKey, model: model)
    }

    // MARK: - Persistence

    private func loadConfiguration() {
        let storedType = ((try? KeychainManager.retrieve(for: .aiProviderType)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let providerType = storedType,
              let type = AIProviderConfig.ProviderType(rawValue: providerType) else {
            return
        }

        guard type != .none else {
            clearConfigurationState()
            return
        }

        if let persisted = persistedConfiguration(for: type) {
            configure(type: type, apiKey: persisted.apiKey, model: persisted.model)
            return
        }

        // One-time migration path from the old shared AI key slots.
        let legacyApiKey = (((try? KeychainManager.retrieve(for: .aiApiKey)) ?? nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyApiKey.isEmpty else { return }

        let legacyModel = (((try? KeychainManager.retrieve(for: .aiModel)) ?? nil) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLegacyModel = normalizedModel(
            type: type,
            model: legacyModel.isEmpty ? type.defaultModel : legacyModel
        )
        configure(type: type, apiKey: legacyApiKey, model: normalizedLegacyModel)
    }

    private func saveConfiguration(type: AIProviderConfig.ProviderType, apiKey: String, model: String) {
        try? KeychainManager.save(type.rawValue, for: .aiProviderType)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        if type == .none {
            return
        }

        if let apiKeyKey = apiKeyStorageKey(for: type) {
            if !trimmedKey.isEmpty {
                try? KeychainManager.save(trimmedKey, for: apiKeyKey)
            }
        }

        if let modelKey = modelStorageKey(for: type) {
            if !trimmedModel.isEmpty {
                try? KeychainManager.save(trimmedModel, for: modelKey)
            } else {
                try? KeychainManager.delete(for: modelKey)
            }
        }
    }

    private func apiKeyStorageKey(for type: AIProviderConfig.ProviderType) -> KeychainManager.Key? {
        switch type {
        case .openai:
            return .aiApiKeyOpenAI
        case .claude:
            return .aiApiKeyClaude
        case .none:
            return nil
        }
    }

    private func modelStorageKey(for type: AIProviderConfig.ProviderType) -> KeychainManager.Key? {
        switch type {
        case .openai:
            return .aiModelOpenAI
        case .claude:
            return .aiModelClaude
        case .none:
            return nil
        }
    }

    private func normalizedModel(type: AIProviderConfig.ProviderType, model: String) -> String {
        switch type {
        case .openai:
            if model == "gpt-5-mini" {
                return AppConstants.AI.defaultOpenAIModel
            }
            return model
        case .claude, .none:
            return model
        }
    }

    func clearConfigurationState() {
        provider = NoAIProvider()
        queryRouter.updateProvider(provider)
        providerType = .none
        providerModel = ""
        configuredAPIKey = ""
        isConfigured = false
    }
}
