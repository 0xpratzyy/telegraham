import Foundation
import SwiftUI

/// Central AI service manager. Owns the current provider, manages configuration,
/// and exposes high-level AI operations that combine TelegramService data with AI.
@MainActor
final class AIService: ObservableObject {
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
    /// Internal-readable so module peers like ReplyQueueEngine can capture
    /// the live key into a Sendable snapshot for parallel-batch work
    /// without having to re-await the @MainActor service mid-loop. Setter
    /// stays private — the only writer is the configuration path.
    private(set) var configuredAPIKey: String = ""

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

    func configure(
        type: AIProviderConfig.ProviderType,
        apiKey: String,
        model: String? = nil,
        persist: Bool = true
    ) {
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
        // The bundled-key bootstrap calls this with `persist: false` so the
        // baked-in beta key never lands in the user's Keychain — that way
        // rotating the key in a follow-up build actually takes effect, and
        // "Reset all local data" doesn't leave a stale key behind.
        if persist {
            saveConfiguration(type: type, apiKey: apiKey, model: resolvedModel)
        }
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

    /// Suggested-reply chips for the reply-queue detail pane.
    /// Returns up to 3 short reply options the user can copy or
    /// click-to-send. Uses the existing `summarize` provider entry
    /// point with a focused prompt rather than introducing a new
    /// AIProvider method — same call shape, just parsed differently.
    func suggestReplies(chatTitle: String, messages: [TGMessage], myUserId: Int64) async throws -> [String] {
        let snippets = conversationSnippets(messages: messages, chatTitle: chatTitle, myUserId: myUserId)
        guard !snippets.isEmpty else { return [] }
        let prompt = """
        You are helping a user (marked [ME] in the transcript) draft \
        a reply to the latest message in this chat. Read the recent \
        conversation, then suggest exactly 3 short reply options the \
        user could send. Each option must be ONE LINE, at most 18 \
        words, plain text only (no markdown, no quotes, no numbering, \
        no leading dash). Output the 3 options separated by newlines, \
        nothing else.
        """
        let response = try await provider.summarize(messages: snippets, prompt: prompt)
        let lines = response
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-*•\"' ")) }
            .filter { !$0.isEmpty }
        return Array(lines.prefix(3))
    }

    /// Catch-up summary for a quiet group — what the user missed in
    /// the last week or so. Used by the reply-queue detail pane's
    /// "Catch me up" action on QUIET items.
    func catchUpSummary(chatTitle: String, messages: [TGMessage], myUserId: Int64) async throws -> String {
        let snippets = conversationSnippets(messages: messages, chatTitle: chatTitle, myUserId: myUserId)
        guard !snippets.isEmpty else { return "" }
        let prompt = """
        Summarize the recent activity in this group chat for a user \
        who has been quiet. Write 2-3 short sentences capturing the \
        main topics, any open questions, and whose turn it is to \
        respond. Plain text only. No bullet points.
        """
        return try await provider.summarize(messages: snippets, prompt: prompt)
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
            chatId: chat.id,
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
        return extracted.map { $0.resolvingSourceMetadata(from: messages, myUserId: myUserId) }
    }

    /// Extract a compiled-truth profile for a single person. Messages
    /// can span multiple chats — chat title is per-message rather than
    /// per-call. Caller is responsible for caching; this just runs the
    /// LLM round-trip.
    func extractPersonProfile(
        personName: String,
        messages: [TGMessage],
        myUserId: Int64,
        chatTitleResolver: (Int64) -> String
    ) async throws -> String {
        let snippets: [MessageSnippet] = messages
            .sorted { $0.date > $1.date }
            .compactMap { msg in
                guard let text = msg.textContent, !text.isEmpty else { return nil }
                let isMe: Bool
                if msg.isOutgoing {
                    isMe = true
                } else if case .user(let uid) = msg.senderId, myUserId > 0 {
                    isMe = uid == myUserId
                } else {
                    isMe = false
                }
                let name = isMe ? "[ME]" : (msg.senderName?.split(separator: " ").first.map(String.init) ?? "Unknown")
                return MessageSnippet(
                    messageId: msg.id,
                    senderFirstName: name,
                    text: text,
                    relativeTimestamp: msg.relativeDate,
                    chatId: msg.chatId,
                    chatName: chatTitleResolver(msg.chatId)
                )
            }
        guard !snippets.isEmpty else { return "" }
        return try await provider.extractPersonProfile(
            personName: personName,
            messages: snippets
        )
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
                messages: snippets,
                openTasks: candidate.openTasks.map {
                    Self.dashboardTaskTriageOpenTaskDTO(
                        from: $0,
                        evidence: candidate.openTaskEvidenceByTaskId[$0.id] ?? []
                    )
                }
            )
        }
        guard !candidateDTOs.isEmpty else { return [] }
        return try await provider.triageDashboardTaskCandidates(candidates: candidateDTOs)
    }

    private static func dashboardTaskTriageOpenTaskDTO(
        from task: DashboardTask,
        evidence: [DashboardTaskSourceMessage]
    ) -> DashboardTaskTriageOpenTaskDTO {
        DashboardTaskTriageOpenTaskDTO(
            taskId: task.id,
            title: task.title,
            summary: task.summary,
            suggestedAction: task.suggestedAction,
            ownerName: task.ownerName,
            personName: task.personName.isEmpty ? task.ownerName : task.personName,
            latestSourceDateISO8601: task.latestSourceDate.map {
                ISO8601DateFormatter.dashboard.string(from: $0)
            },
            sourceMessages: evidence
                .sorted { $0.date < $1.date }
                .map(Self.dashboardTaskSourceDTO)
        )
    }

    private static func dashboardTaskSourceDTO(
        from source: DashboardTaskSourceMessage
    ) -> DashboardTaskSourceMessageDTO {
        DashboardTaskSourceMessageDTO(
            chatId: source.chatId,
            messageId: source.messageId,
            senderName: source.senderName,
            text: source.text,
            dateISO8601: ISO8601DateFormatter.dashboard.string(from: source.date)
        )
    }

    private func conversationSnippets(messages: [TGMessage], chatTitle: String, myUserId: Int64) -> [MessageSnippet] {
        messages
            .sorted { $0.date < $1.date }
            .compactMap { msg -> MessageSnippet? in
            guard let text = msg.textContent, !text.isEmpty else { return nil }
            let isMe: Bool
            if msg.isOutgoing {
                isMe = true
            } else if case .user(let uid) = msg.senderId, myUserId > 0 {
                isMe = uid == myUserId
            } else {
                isMe = false
            }
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
            // Nothing in Keychain. If this beta build ships with a baked-in
            // OpenAI key, auto-configure so the dashboard's AI features work
            // on first launch without the user pasting anything.
            applyBundledOpenAIKeyIfAvailable()
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
        if !legacyApiKey.isEmpty {
            let legacyModel = (((try? KeychainManager.retrieve(for: .aiModel)) ?? nil) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedLegacyModel = normalizedModel(
                type: type,
                model: legacyModel.isEmpty ? type.defaultModel : legacyModel
            )
            configure(type: type, apiKey: legacyApiKey, model: normalizedLegacyModel)
            return
        }

        // Provider was set but its key is missing — likely a fresh keychain
        // on a beta tester's machine. Fall back to the bundled key so the
        // dashboard isn't stuck in "AI not configured".
        applyBundledOpenAIKeyIfAvailable()
    }

    private func applyBundledOpenAIKeyIfAvailable() {
        guard let bundled = BundledSecrets.openAIApiKey else { return }
        let model = normalizedModel(type: .openai, model: AppConstants.AI.defaultOpenAIModel)
        configure(type: .openai, apiKey: bundled, model: model, persist: false)
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
