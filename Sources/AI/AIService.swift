import Foundation
import SwiftUI

/// Central AI service manager. Owns the current provider, manages configuration,
/// and exposes high-level AI operations that combine TelegramService data with AI.
@MainActor
final class AIService: ObservableObject {
    @Published var isConfigured = false
    @Published var providerType: AIProviderConfig.ProviderType = .none
    @Published private(set) var providerModel: String = ""
    private(set) var provider: AIProvider = NoAIProvider()
    let queryRouter: QueryRouter
    private(set) var configuredAPIKey: String = ""
    /// Non-nil when the OpenAI provider targets the AI proxy Worker instead
    /// of api.openai.com (issue #26) — `configuredAPIKey` is then the proxy
    /// gate token, not a raw OpenAI key. Snapshot-readable for the same
    /// reason as `configuredAPIKey`; never persisted (the proxy bootstrap
    /// re-reads the bundle each launch, mirroring the bundled-key flow).
    private(set) var configuredOpenAIEndpointURL: URL?

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
        persist: Bool = true,
        // Non-nil routes OpenAI through the AI proxy Worker (issue #26);
        // `apiKey` is then the proxy gate token. Only the zero-setup
        // bootstrap passes this — BYO keys always go direct to OpenAI
        // (their key, their bill, no transit through our infra).
        openAIEndpointURL: URL? = nil,
        // Sent as X-Pidgy-License on the managed (proxy) path so the Worker can
        // gate managed AI on an active subscription. Only the managed bootstrap
        // passes one; BYO-key configs leave it nil.
        licenseKey: String? = nil
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
            provider = OpenAIProvider(
                apiKey: apiKey,
                model: resolvedModel,
                endpointURL: openAIEndpointURL ?? AppConstants.AI.openAIBaseURL,
                licenseKey: licenseKey
            )
        case .none:
            provider = NoAIProvider()
        }

        queryRouter.updateProvider(provider)
        providerType = type
        providerModel = resolvedModel
        configuredAPIKey = apiKey
        configuredOpenAIEndpointURL = type == .openai ? openAIEndpointURL : nil
        isConfigured = type != .none && !apiKey.isEmpty
        // The bundled-key bootstrap calls this with `persist: false` so the
        // baked-in beta key never lands in the user's Keychain — that way
        // rotating the key in a follow-up build actually takes effect, and
        // "Reset all local data" doesn't leave a stale key behind.
        if persist {
            saveConfiguration(
                type: type,
                apiKey: apiKey,
                model: resolvedModel,
                baseURL: type == .openai ? openAIEndpointURL : nil
            )
        }
    }

    // MARK: - High-Level AI Operations

    /// Semantic search: find chats relevant to a query by analyzing messages.
    /// Paid-feature gate. Dormant while `BillingGate.enforce` is false (the
    /// current beta) — `aiAllowed` is then always true, so this never throws.
    /// Once enforce flips on at the paywall cutover, every LLM-backed feature
    /// requires an active trial/subscription (or the founding-tester
    /// grandfather). Centralised so the paywall can't leak through one entry
    /// point that forgot to check; the Worker license gate is the server-side
    /// backstop. NOTE for cutover: if AI search should stay free, drop the
    /// guard from semanticSearch/agenticSearch/rerankSearchResults only.
    private func requireAIEntitlement() throws {
        guard BillingGate.aiAllowed(EntitlementStore.shared.status) else {
            throw AIError.providerNotConfigured
        }
    }

    func semanticSearch(query: String, messages: [TGMessage]) async throws -> [SemanticSearchResult] {
        try requireAIEntitlement()
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

    func rerankSearchResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, bestMessage: String)]
    ) async throws -> [Int64] {
        try requireAIEntitlement()
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
        try requireAIEntitlement()
        let snippets = conversationSnippets(messages: messages, chatTitle: chatTitle, myUserId: myUserId)
        guard !snippets.isEmpty else { return [] }
        // Context layer: draft in the user's own voice when we have a profile.
        let voiceBlock = (await VoiceProfileService.shared.currentProfile())
            .map { "\n\nMatch THIS user's writing voice (style only — don't copy past content):\n\($0)" } ?? ""
        let prompt = """
        You are helping a user (marked [ME] in the transcript) draft \
        a reply to the latest message in this chat. Read the recent \
        conversation, then suggest exactly 3 short reply options the \
        user could send. Each option must be ONE LINE, at most 18 \
        words, plain text only (no markdown, no quotes, no numbering, \
        no leading dash). Output the 3 options separated by newlines, \
        nothing else.\(voiceBlock)
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
        try requireAIEntitlement()
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

    /// Context layer (#48): extract facts from a chat's NEW messages, folding in
    /// its current open loops so the model can also CLOSE the ones the new
    /// messages answered. Runs through the generic `summarize` escape hatch
    /// (instructions + open loops in the system prompt, transcript as the
    /// rendered messages) so no per-provider structured-output plumbing is
    /// needed. Returns drafts to upsert + fingerprints to invalidate.
    func extractFacts(
        chat: TGChat,
        newMessages: [TGMessage],
        contextMessages: [TGMessage] = [],
        openLoops: [Fact],
        myUserId: Int64,
        myUser: TGUser?
    ) async throws -> FactExtractionResult {
        try requireAIEntitlement()
        let snippets = conversationSnippets(messages: newMessages, chatTitle: chat.title, myUserId: myUserId)
        let contextSnippets = conversationSnippets(messages: contextMessages, chatTitle: chat.title, myUserId: myUserId)
        guard !snippets.isEmpty else {
            return FactExtractionResult(drafts: [], resolvedFingerprints: [])
        }
        // Message bodies are fenced in the transcript; the standing clause makes
        // fenced text data-not-instructions (extraction output steers loop
        // CLOSING, so this prompt gets the same injection posture as the rest).
        let systemPrompt = FactExtractionPrompt.systemPrompt + FactExtractionPrompt.contextBlock(
            myName: myUser?.firstName ?? "Me",
            myUsername: myUser?.username,
            chatTitle: chat.title,
            chatType: chat.chatType.displayName,
            openLoops: openLoops
        ) + PromptSafety.untrustedContentClause
        // Numbered transcript so the model cites each loop's source by [N] (exact
        // provenance), via the answer() escape hatch instead of summarize's render.
        // Already-processed context rides along unnumbered so a tiny window
        // (one terse ping) isn't judged blind.
        let transcript = FactExtractionPrompt.numberedTranscript(snippets: snippets, context: contextSnippets)
        let response = try await provider.answer(systemPrompt: systemPrompt, userMessage: transcript, kind: .factExtraction)
        // validFrom fallback for a snippet with no date — parse() prefers each
        // fact's CITED message date.
        let newest = newMessages.max(by: { $0.date < $1.date })
        var result = try FactExtractionParser.parse(
            response,
            chatId: chat.id,
            openLoops: openLoops,
            validFrom: newest?.date ?? Date(),
            messages: snippets
        )
        // Capture the chat title on each fact so projections don't depend on the
        // live chat list being fully loaded (which showed "Chat <id>").
        let chatTitle = chat.title
        result.drafts = result.drafts.map { var d = $0; d.sourceChatTitle = chatTitle; return d }
        return result
    }

    /// Entity memory (M1): fold a chat's NEW messages into its rolling summary.
    /// Old summary + new messages → updated summary; cost stays O(new
    /// messages) and the summary compounds instead of being recomputed.
    func foldChatSummary(
        chat: TGChat,
        oldSummary: String?,
        newMessages: [TGMessage],
        myUserId: Int64,
        myUser: TGUser?
    ) async throws -> String {
        try requireAIEntitlement()
        // Cap the fold input — a deep catch-up pass can consume hundreds of
        // messages; the newest ~60 carry the state, older ones were either in
        // the old summary's window or belong to history.
        let bounded = Array(newMessages.suffix(60))
        let snippets = conversationSnippets(messages: bounded, chatTitle: chat.title, myUserId: myUserId)
        guard !snippets.isEmpty else { return oldSummary ?? "" }
        let transcript = snippets
            .map { "\($0.senderFirstName): \(PromptSafety.fence($0.text))" }
            .joined(separator: "\n")
        let system = SummaryFoldPrompt.systemPrompt + PromptSafety.untrustedContentClause
        return try await provider.answer(
            systemPrompt: system,
            userMessage: SummaryFoldPrompt.userMessage(
                chatTitle: chat.title,
                chatType: chat.chatType.displayName,
                myName: myUser?.firstName ?? "Me",
                oldSummary: oldSummary,
                transcript: transcript
            ),
            kind: .factExtraction
        )
    }

    /// Fact-grounded answer engine (#48 search). Retrieves the user's open-loop
    /// and durable facts, then asks the model the question over them — a sharp,
    /// cited answer in the question's own language. Validated offline at 98%
    /// good / 100% grounded across English/Hinglish/Hindi/Spanish.
    /// (Semantic message recall is a planned follow-up.)
    func answerQuestion(_ query: String, history: [(role: String, text: String)] = []) async throws -> String {
        try requireAIEntitlement()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let openLoops = await DatabaseManager.shared.loadOpenFacts(limit: 250)
        let durable = await DatabaseManager.shared.loadDurableFacts(limit: 50)

        // Relevance-first payload: sending the ENTIRE store every call was
        // ~10-12k input tokens (and again per follow-up). Deterministic token
        // match against the conversation ranks query-relevant items first,
        // then hard caps trim the tail. Recall stays safe: unmatched items
        // still ride along up to the cap, so "who owes me money" (no name
        // tokens) sees everything it did before.
        let convoText = ([trimmed] + history.suffix(4).map(\.text)).joined(separator: " ").lowercased()
        let tokens = Set(convoText.split { !$0.isLetter && !$0.isNumber }.filter { $0.count >= 3 }.map(String.init))

        // Rolling chat summaries give the "what's going on with X" narrative
        // context that atomic facts can't answer. Recency alone missed quiet
        // people — union the entity-title MATCHES with the recent set so
        // "whats up with vibhu" finds Vibhu's summary wherever it sits.
        let matchedSummaries = await DatabaseManager.shared.loadChatSummaries(matching: Array(tokens), limit: 6)
        let recentSummaries = await DatabaseManager.shared.loadRecentChatSummaries(limit: 20)
        var seenSummaryIds = Set<Int64>()
        let summaries = (matchedSummaries + recentSummaries).filter { seenSummaryIds.insert($0.id).inserted }
        func matches(_ hay: String...) -> Bool {
            guard !tokens.isEmpty else { return false }
            let joined = hay.joined(separator: " ").lowercased()
            return tokens.contains { joined.contains($0) }
        }
        func prioritized<T>(_ items: [T], cap: Int, isMatch: (T) -> Bool) -> [T] {
            let matched = items.filter(isMatch)
            let rest = items.filter { !isMatch($0) }
            return Array((matched + rest).prefix(cap))
        }
        let loops = prioritized(openLoops, cap: 100) { matches($0.subjectEntity, $0.sourceChatTitle) }
        let facts = prioritized(durable, cap: 30) { matches($0.subjectEntity, $0.sourceChatTitle) }
        let sums = prioritized(summaries, cap: 8) { matches($0.entityTitle) }

        return try await provider.answer(
            systemPrompt: AnswerPrompt.systemPrompt,
            userMessage: AnswerPrompt.userMessage(query: trimmed, openLoops: loops, durable: facts, summaries: sums, history: history),
            kind: .answerEngine
        )
    }

    /// One-time backfill (#48): classify existing open i_owe loops as a quick
    /// "reply" vs an "action" that takes work — the loop_kind that splits the
    /// Reply queue from Tasks. Returns id → kind for the ones it could classify.
    func classifyLoops(_ facts: [Fact]) async throws -> [Int64: LoopKind] {
        try requireAIEntitlement()
        guard !facts.isEmpty else { return [:] }
        let lines = facts.map { f in
            "\(f.id): \(f.action.isEmpty ? f.objectText : f.action)"
        }.joined(separator: "\n")
        let system = """
        You classify a user's open to-dos. For EACH item decide:
        - "reply" = the user can close it by just sending a message now (answer a question, confirm, share a quick detail).
        - "action" = it needs real work or time first (build/fix something, pay, prepare or send a deliverable, review, chase someone).
        Return EXACTLY one JSON object: {"items":[{"id":<number>,"kind":"reply"|"action"}, ...]}. Classify every id. Output ONLY the JSON.
        """
        let response = try await provider.answer(systemPrompt: system, userMessage: "ITEMS:\n\(lines)", kind: .factExtraction)
        // Unparseable must THROW, not return [:] — the backfill treats a thrown
        // error as "retry next pass"; a silent empty result would mark the
        // backfill done with 0/N classified and never retry that session.
        guard let dto: LoopKindClassificationDTO = try? JSONExtractor.parseJSON(response) else {
            throw FactExtractionError.unparseableResponse
        }
        var result: [Int64: LoopKind] = [:]
        for item in dto.items ?? [] where item.id != 0 {
            if let kind = LoopKind(rawValue: item.kind.lowercased()) { result[item.id] = kind }
        }
        return result
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
        try requireAIEntitlement()
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

    /// Build the user's own voice profile from a sample of their outgoing
    /// messages. Reuses the generic `summarize` path with a style-only prompt;
    /// returns "" (or "Not enough messages yet.") when the sample is too thin.
    func extractVoiceProfile(outgoingMessages: [DatabaseManager.MessageRecord]) async throws -> String {
        try requireAIEntitlement()
        let snippets: [MessageSnippet] = outgoingMessages.compactMap { record in
            guard let text = record.textContent,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return MessageSnippet(
                messageId: record.id,
                senderFirstName: "[ME]",
                text: text,
                relativeTimestamp: "",
                chatId: record.chatId,
                chatName: ""
            )
        }
        guard snippets.count >= 15 else { return "" }
        return try await provider.summarize(messages: snippets, prompt: VoiceProfilePrompt.systemPrompt)
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
                chatName: chatTitle,
                date: msg.date
            )
        }
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

        var baseURL: URL?
        if type == .openai {
            let storedURL = (((try? KeychainManager.retrieve(for: .aiBaseURLOpenAI)) ?? nil) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !storedURL.isEmpty { baseURL = URL(string: storedURL) }
        }

        return AIProviderConfig(providerType: type, apiKey: apiKey, model: model, baseURL: baseURL)
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
            configure(
                type: type,
                apiKey: persisted.apiKey,
                model: persisted.model,
                openAIEndpointURL: persisted.baseURL
            )
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
        // Prefer the AI proxy when the build bundles one (issue #26): the
        // gate token stands in for the key and the raw provider key no longer
        // needs to ship. `persist: false` for the same reason as the bundled
        // key — rotating the token in a follow-up build must take effect.
        //
        // Managed plan runs on Gemini 3 Flash via the proxy's Vertex path. We
        // derive that path from whatever proxy host is bundled (the release
        // pipeline injects the base URL), so no secret change is needed to
        // switch OpenAI→Gemini — just this routing + `managedModel`.
        if let proxyURL = BundledSecrets.aiProxyURL,
           let proxyToken = BundledSecrets.aiProxyToken {
            let managedURL = managedProxyEndpoint(from: proxyURL)
            configure(
                type: .openai,
                apiKey: proxyToken,
                model: AppConstants.AI.managedModel,
                persist: false,
                openAIEndpointURL: managedURL,
                // Forward the activated license so the Worker can gate managed
                // AI per-user once ENFORCE_LICENSE is on. Re-read each launch
                // (mirrors the bundled-token bootstrap); nil until activated.
                licenseKey: (try? KeychainManager.retrieve(for: .dodoLicenseKey)) ?? nil
            )
            return
        }
        let model = normalizedModel(type: .openai, model: AppConstants.AI.defaultOpenAIModel)
        guard let bundled = BundledSecrets.openAIApiKey else { return }
        configure(type: .openai, apiKey: bundled, model: model, persist: false)
    }

    /// Rewrite the bundled proxy URL onto the managed Vertex path while
    /// keeping its scheme/host/port. Falls back to the original URL if it
    /// can't be decomposed.
    private func managedProxyEndpoint(from proxyURL: URL) -> URL {
        guard var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false) else {
            return proxyURL
        }
        components.path = AppConstants.AI.managedProxyPath
        return components.url ?? proxyURL
    }

    private func saveConfiguration(type: AIProviderConfig.ProviderType, apiKey: String, model: String, baseURL: URL?) {
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

        // BYOK custom base URL. Persist only a non-default endpoint; the
        // default api.openai.com path stores nothing (so OpenAI BYOK + the
        // bundled proxy both resolve to the built-in default on load).
        if type == .openai {
            if let baseURL, baseURL != AppConstants.AI.openAIBaseURL {
                try? KeychainManager.save(baseURL.absoluteString, for: .aiBaseURLOpenAI)
            } else {
                try? KeychainManager.delete(for: .aiBaseURLOpenAI)
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
        configuredOpenAIEndpointURL = nil
        isConfigured = false
    }
}
