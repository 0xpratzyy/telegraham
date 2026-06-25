import Foundation

final class OpenAIProvider: AIProvider {
    private let apiKey: String
    private let model: String
    /// Sent as `X-Pidgy-License` on every request when set. Only the managed
    /// (proxy) path passes one — the Worker gates managed AI on an active
    /// subscription. BYO-key requests go direct to the provider and omit it.
    private let licenseKey: String?
    /// Where requests are sent. Defaults to OpenAI directly; the zero-setup
    /// flow overrides this with the AI proxy Worker URL (issue #26), in
    /// which case `apiKey` is the revocable proxy gate token rather than a
    /// raw OpenAI key. The request/response shape is identical either way —
    /// the proxy forwards the body verbatim.
    let endpointURL: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConstants.AI.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConstants.AI.requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }()

    init(
        apiKey: String,
        model: String = AppConstants.AI.defaultOpenAIModel,
        endpointURL: URL = AppConstants.AI.openAIBaseURL,
        licenseKey: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpointURL = endpointURL
        self.licenseKey = licenseKey
    }

    // MARK: - AIProvider

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let userMessage = SummaryPrompt.userMessage(snippets: snippets)
        return try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: prompt,
                userMessage: userMessage,
                requestKind: .summary
            )
        }
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: SemanticSearchPrompt.systemPrompt,
                userMessage: SemanticSearchPrompt.userMessage(query: query, snippets: snippets),
                requestKind: .semanticSearch
            )
        }
        return try JSONExtractor.parseJSON(response)
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        try await RetryHelper.withRetry {
            let response = try await self.makeRequest(
                systemPrompt: QueryPlanningPrompt.systemPrompt,
                userMessage: QueryPlanningPrompt.userMessage(
                    query: query,
                    activeFilter: activeFilter,
                    deterministicSpec: deterministicSpec
                ),
                requestKind: .queryPlanning,
                responseFormat: self.queryPlanningResponseFormat()
            )
            return try JSONExtractor.parseJSON(response)
        }
    }

    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64] {
        guard !candidates.isEmpty else { return [] }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: SearchRerankPrompt.systemPrompt,
                userMessage: SearchRerankPrompt.userMessage(query: query, candidates: candidates),
                requestKind: .semanticSearch
            )
        }
        let dto: SearchRerankResultDTO = try JSONExtractor.parseJSON(response)
        return dto.rankedChatIds
    }

    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO] {
        guard !candidates.isEmpty else { return [] }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: AgenticSearchPrompt.systemPrompt,
                userMessage: AgenticSearchPrompt.userMessage(
                    query: query,
                    constraints: constraints,
                    candidates: candidates
                ),
                requestKind: .agenticSearch,
                responseFormat: self.agenticSearchResponseFormat(candidates: candidates)
            )
        }
        persistLatestAgenticResponse(response: response)
        do {
            let parsed = try AgenticSearchResultParser.parse(response)
            // Keep only decisions for known candidate ids, deduped. We dropped
            // the integer-`enum` id constraint from the schema (Gemini rejects
            // it), so the model can occasionally echo a stray or duplicate id —
            // drop those rows and proceed with the valid subset instead of
            // failing the whole batch (a candidate with no decision is simply
            // not surfaced this pass). Genuine JSON parse failures still throw
            // via the catch below.
            let expectedIds = Set(candidates.map(\.chatId))
            var seenIds = Set<Int64>()
            return parsed.filter { expectedIds.contains($0.chatId) && seenIds.insert($0.chatId).inserted }
        } catch {
            persistAgenticParseFailure(response: response, error: error)
            throw AIError.parsingError("agentic JSON parse failure; raw payload saved to debug")
        }
    }

    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO] {
        guard !candidates.isEmpty else { return [] }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: ReplyQueueTriagePrompt.systemPrompt,
                userMessage: ReplyQueueTriagePrompt.userMessage(
                    query: query,
                    scope: scope,
                    candidates: candidates
                ),
                requestKind: .replyQueueTriage,
                responseFormat: self.replyQueueTriageResponseFormat(candidates: candidates)
            )
        }

        let parsed = try ReplyQueueTriageResultParser.parse(response)
        // Tolerate model id drift (the integer-`enum` id constraint is gone for
        // Gemini compatibility): keep decisions for known candidate ids,
        // deduped, and proceed with the valid subset rather than failing the
        // batch. A candidate with no decision is simply not surfaced this pass.
        let expectedIds = Set(candidates.map(\.chatId))
        var seenIds = Set<Int64>()
        return parsed.filter { expectedIds.contains($0.chatId) && seenIds.insert($0.chatId).inserted }
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        let snippets = MessageSnippet.truncateToTokenBudget(messages, maxChars: 4000)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: FollowUpPrompt.systemPrompt,
                userMessage: FollowUpPrompt.userMessage(chatTitle: chatTitle, snippets: snippets),
                requestKind: .followUpSuggestion
            )
        }
        let dto: FollowUpSuggestionDTO = try JSONExtractor.parseJSON(response)
        return (dto.relevant ?? true, dto.suggestedAction)
    }

    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO {
        let snippets = MessageSnippet.truncateToTokenBudget(messages, maxChars: 4000)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: PipelineCategoryPrompt.systemPrompt,
                userMessage: PipelineCategoryPrompt.userMessage(context: context, snippets: snippets),
                requestKind: .pipelineTriage,
                chatId: context.chatId
            )
        }
        return try JSONExtractor.parseJSON(response)
    }

    func discoverDashboardTopics(messages: [MessageSnippet]) async throws -> [DashboardTopicDTO] {
        let snippets = Array(messages.prefix(AppConstants.Dashboard.topicDiscoveryMessageLimit))
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: DashboardTopicPrompt.systemPrompt,
                userMessage: DashboardTopicPrompt.userMessage(snippets: snippets),
                requestKind: .dashboardTopicDiscovery
            )
        }
        return try DashboardTopicParser.parse(response)
    }

    func extractDashboardTasks(
        chat: TGChat,
        topics: [DashboardTopic],
        messages: [MessageSnippet]
    ) async throws -> [DashboardTaskCandidate] {
        guard !messages.isEmpty else { return [] }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: DashboardTaskPrompt.systemPrompt,
                userMessage: DashboardTaskPrompt.userMessage(
                    chat: chat,
                    topics: topics,
                    snippets: messages
                ),
                requestKind: .dashboardTaskExtraction,
                responseFormat: self.dashboardTaskExtractionResponseFormat(),
                chatId: chat.id
            )
        }
        return try DashboardTaskParser.parse(response)
    }

    func extractPersonProfile(
        personName: String,
        messages: [MessageSnippet]
    ) async throws -> String {
        guard !messages.isEmpty else { return "" }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: PersonProfilePrompt.systemPrompt,
                userMessage: PersonProfilePrompt.userMessage(
                    personName: personName,
                    snippets: messages
                ),
                requestKind: .personProfile
            )
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func triageDashboardTaskCandidates(
        candidates: [DashboardTaskTriageCandidateDTO]
    ) async throws -> [DashboardTaskTriageResultDTO] {
        guard !candidates.isEmpty else { return [] }
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: DashboardTaskTriagePrompt.systemPrompt,
                userMessage: DashboardTaskTriagePrompt.userMessage(candidates: candidates),
                requestKind: .dashboardTaskTriage,
                responseFormat: self.dashboardTaskTriageResponseFormat(candidates: candidates)
            )
        }

        let parsed = try DashboardTaskTriageParser.parse(response)
        // Tolerate model id drift (the integer-`enum` id constraint is gone for
        // Gemini compatibility): keep decisions for known candidate ids,
        // deduped, and proceed with the valid subset rather than failing the
        // batch. A candidate with no decision keeps its existing tasks
        // untouched this pass and is re-triaged on its next change.
        let expectedIds = Set(candidates.map(\.chatId))
        var seenIds = Set<Int64>()
        return parsed.filter { expectedIds.contains($0.chatId) && seenIds.insert($0.chatId).inserted }
    }

    func testConnection() async throws -> Bool {
        _ = try await makeRequest(systemPrompt: "Reply with OK", userMessage: "test")
        return true
    }

    // MARK: - HTTP

    private func makeRequest(
        systemPrompt: String,
        userMessage: String,
        requestKind: AIRequestKind? = nil,
        responseFormat: [String: Any]? = nil,
        // Optional Telegram chat_id passed through to local trace
        // metadata so per-chat decisions can be filtered + replayed.
        // Only the per-chat methods (categorizePipelineChat,
        // extractDashboardTasks) populate this; batch/cross-chat calls
        // leave it nil.
        chatId: Int64? = nil
    ) async throws -> String {
        // Local trace recording — captures start/end so we can replay
        // and compare prompt versions while iterating on accuracy. No-op when
        // PIDGY_BUNDLED_LANGSMITH_API_KEY is empty.
        let startedAt = Date()

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let licenseKey, !licenseKey.isEmpty {
            request.setValue(licenseKey, forHTTPHeaderField: "X-Pidgy-License")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
        if let responseFormat {
            body["response_format"] = responseFormat
        }
        // gpt-5 reasoning models default to medium effort, which produces
        // 1,000-2,500 reasoning tokens per call (billed at output rate)
        // before the final JSON. Our prompts ask for structured triage
        // decisions ~80 tokens long; we don't need long internal reasoning.
        // "low" cuts the reasoning tokens 3-5× and keeps quality on
        // structured outputs. Only emit for gpt-5* models — older
        // chat-completions models 400 on this param.
        //
        // pipelineTriage is the high-volume single-chat per-message call and
        // the bulk of our gpt-5 spend. There "minimal" cuts cost ~66% (skips
        // the ~260 reasoning tokens/call) with no measured drop in the critical
        // on_me recall — see docs/model_swap_eval_RESULTS.md. The larger
        // multi-candidate calls (agenticSearch, dashboardTaskTriage) stay on
        // "low": minimal saves little there (~25%) and reasoning does real
        // cross-candidate work. NB: gpt-5.1+ renamed "minimal" → "none", so
        // this value must change if we move off gpt-5.0.
        // Gemini 3 / 2.5 are also thinking models on the OpenAI-compat path and
        // take the same reasoning_effort (valid: minimal|low|medium|high — NOT
        // "none", which 400s). Default thinking is the bulk of Gemini latency
        // AND cost — measured ~360 reasoning tokens on a trivial triage, billed
        // at the output rate — so cap it the same way we do for gpt-5: minimal
        // on the hot triage path, low elsewhere.
        if model.hasPrefix("gpt-5") || model.contains("gemini") {
            body["reasoning_effort"] = requestKind == .pipelineTriage ? "minimal" : "low"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var data: Data
        var response: URLResponse
        var rateLimitAttempt = 0
        while true {
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                // Skip tracing cancellations — they're benign Swift Task aborts
                // (a newer refresh superseded this one). Tracing them clutters
                // the local trace log with red errors that are not real failures.
                if !(error is CancellationError) && (error as NSError).code != NSURLErrorCancelled {
                    LocalAITraceRecorder.shared.record(
                        provider: "openai",
                        model: model,
                        runName: requestKind?.rawValue ?? "openai_chat",
                        systemPrompt: systemPrompt,
                        userMessage: userMessage,
                        startedAt: startedAt,
                        completedAt: Date(),
                        response: nil,
                        error: "transport: \(error.localizedDescription)",
                        inputTokens: nil,
                        outputTokens: nil,
                        costUSD: nil,
                        chatId: chatId
                    )
                    PidgyTelemetry.captureAIFailure(provider: "openai", model: model, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "transport")
                }
                throw error
            }

            // Shared-quota providers (Vertex/Gemini, OpenAI) return 429 — and
            // sometimes 503 — when the per-minute pool is saturated, which is
            // common during a reindex burst. Back off and retry a few times so
            // the call recovers instead of failing into a generic fallback.
            // Honor Retry-After when the server sends it.
            if let http = response as? HTTPURLResponse,
               http.statusCode == 429 || http.statusCode == 503,
               rateLimitAttempt < Self.maxRateLimitRetries {
                rateLimitAttempt += 1
                let delay = Self.rateLimitBackoffSeconds(attempt: rateLimitAttempt, response: http)
                // `try` (not `try?`) so a superseding refresh cancelling this
                // task aborts the backoff promptly instead of sleeping it out.
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            break
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            LocalAITraceRecorder.shared.record(
                provider: "openai", model: model,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: nil, error: "invalidResponse: non-HTTP",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: model, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "invalid_response")
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            LocalAITraceRecorder.shared.record(
                provider: "openai", model: model,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: errorBody, error: "http_\(httpResponse.statusCode)",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: model, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "http_\(httpResponse.statusCode)")
            // 429/503 reach here only after the in-loop backoff above exhausted
            // its retries. Surface a distinct rate-limit error so RetryHelper
            // treats it as terminal and does not re-retry on top of that backoff.
            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                throw AIError.rateLimited(retryAfter: retryAfter)
            }
            throw AIError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = extractMessageContent(from: message["content"]) else {
            LocalAITraceRecorder.shared.record(
                provider: "openai", model: model,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: String(data: data, encoding: .utf8),
                error: "invalidResponse: parse",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: model, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "parse")
            throw AIError.invalidResponse
        }

        let usage = parseUsage(from: json["usage"])

        if let requestKind {
            await AIUsageStore.shared.record(
                provider: .openAI,
                model: model,
                requestKind: requestKind,
                usage: usage
            )
        }

        // gpt-* families cache prompt prefixes (≥1024 tokens) at a 50%
        // discount; parseUsage folds that into usage.cachedInputTokens. Surface
        // it on the trace so we can confirm caching is live for the hot
        // pipelineTriage prompt (~80% of LLM volume).
        var extraTags: [String: String] = [:]
        if let cached = usage?.cachedInputTokens, cached > 0 {
            extraTags["cached_tokens"] = String(cached)
        }

        LocalAITraceRecorder.shared.record(
            provider: "openai",
            model: model,
            runName: requestKind?.rawValue ?? "openai_chat",
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            startedAt: startedAt,
            completedAt: Date(),
            response: content,
            error: nil,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            costUSD: AIUsagePricingCatalog
                .pricing(for: .openAI, model: model)
                .flatMap { p in
                    guard let usage else { return nil }
                    return p.estimatedCostUSD(
                        inputTokens: usage.inputTokens,
                        cachedInputTokens: usage.cachedInputTokens,
                        outputTokens: usage.outputTokens
                    )
                },
            chatId: chatId,
            extraTags: extraTags
        )

        return content
    }

    private func extractMessageContent(from rawContent: Any?) -> String? {
        if let content = rawContent as? String {
            return content
        }

        if let parts = rawContent as? [[String: Any]] {
            let joined = parts.compactMap { part -> String? in
                if let text = part["text"] as? String {
                    return text
                }
                if let nested = part["text"] as? [String: Any],
                   let value = nested["value"] as? String {
                    return value
                }
                return nil
            }.joined()

            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func agenticSearchResponseFormat(candidates: [AgenticCandidateDTO]) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "results": [
                    "type": "array",
                    "minItems": candidates.count,
                    "maxItems": candidates.count,
                    "items": [
                        "type": "object",
                        "properties": [
                            // NB: no integer `enum` here — Gemini's structured
                            // output rejects enum on non-string types (400
                            // INVALID_ARGUMENT). The candidate ids are listed in
                            // the prompt and callers match decisions by id, so
                            // the hard constraint isn't required.
                            "chatId": ["type": "integer"],
                            "score": ["type": "integer", "minimum": 0, "maximum": 100],
                            "warmth": ["type": "string", "enum": ["hot", "warm", "cold"]],
                            "replyability": ["type": "string", "enum": ["reply_now", "waiting_on_them", "unclear"]],
                            "reason": ["type": "string"],
                            "suggestedAction": ["type": "string"],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                            "supportingMessageIds": [
                                "type": "array",
                                "items": ["type": "integer"]
                            ]
                        ],
                        "required": [
                            "chatId",
                            "score",
                            "warmth",
                            "replyability",
                            "reason",
                            "suggestedAction",
                            "confidence",
                            "supportingMessageIds"
                        ],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["results"],
            "additionalProperties": false
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "agentic_search_results",
                "strict": true,
                "schema": schema
            ]
        ]
    }

    private func queryPlanningResponseFormat() -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "family": [
                    "type": "string",
                    "enum": ["summary", "reply_queue", "topic_search", "exact_lookup", "relationship"]
                ],
                "scope": [
                    "type": "string",
                    "enum": ["inherit", "all", "dms", "groups"]
                ],
                "timeRange": [
                    "type": "string",
                    "enum": ["inherit", "none", "today", "yesterday", "last_week", "this_week", "last_30_days"]
                ],
                "people": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "topicTerms": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "confidence": [
                    "type": "number",
                    "minimum": 0,
                    "maximum": 1
                ]
            ],
            "required": ["family", "scope", "timeRange", "people", "topicTerms", "confidence"],
            "additionalProperties": false
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "query_plan",
                "schema": schema,
                "strict": true
            ]
        ]
    }

    private func replyQueueTriageResponseFormat(candidates: [ReplyQueueCandidateDTO]) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "results": [
                    "type": "array",
                    "minItems": candidates.count,
                    "maxItems": candidates.count,
                    "items": [
                        "type": "object",
                        "properties": [
                            // NB: no integer `enum` here — Gemini's structured
                            // output rejects enum on non-string types (400
                            // INVALID_ARGUMENT). The candidate ids are listed in
                            // the prompt and callers match decisions by id, so
                            // the hard constraint isn't required.
                            "chatId": ["type": "integer"],
                            "classification": [
                                "type": "string",
                                "enum": ["on_me", "worth_checking", "on_them", "quiet", "need_more"]
                            ],
                            "urgency": [
                                "type": "string",
                                "enum": ["high", "medium", "low"]
                            ],
                            "reason": ["type": "string"],
                            "suggestedAction": ["type": "string"],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                            "supportingMessageIds": [
                                "type": "array",
                                "items": ["type": "integer"]
                            ]
                        ],
                        "required": [
                            "chatId",
                            "classification",
                            "urgency",
                            "reason",
                            "suggestedAction",
                            "confidence",
                            "supportingMessageIds"
                        ],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["results"],
            "additionalProperties": false
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "reply_queue_triage_results",
                "strict": true,
                "schema": schema
            ]
        ]
    }

    private func dashboardTaskTriageResponseFormat(candidates: [DashboardTaskTriageCandidateDTO]) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "decisions": [
                    "type": "array",
                    "minItems": candidates.count,
                    "maxItems": candidates.count,
                    "items": [
                        "type": "object",
                        "properties": [
                            // NB: no integer `enum` here — Gemini's structured
                            // output rejects enum on non-string types (400
                            // INVALID_ARGUMENT). The candidate ids are listed in
                            // the prompt and callers match decisions by id, so
                            // the hard constraint isn't required.
                            "chatId": ["type": "integer"],
                            "route": [
                                "type": "string",
                                "enum": ["effort_task", "reply_queue", "completed_task", "ignore"]
                            ],
                            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                            "reason": ["type": "string"],
                            "supportingMessageIds": [
                                "type": "array",
                                "items": ["type": "integer"]
                            ],
                            "completedTaskIds": [
                                "type": "array",
                                "items": ["type": "integer"]
                            ]
                        ],
                        "required": [
                            "chatId",
                            "route",
                            "confidence",
                            "reason",
                            "supportingMessageIds",
                            "completedTaskIds"
                        ],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["decisions"],
            "additionalProperties": false
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "dashboard_task_triage_results",
                "strict": true,
                "schema": schema
            ]
        ]
    }

    private func dashboardTaskExtractionResponseFormat() -> [String: Any] {
        let sourceMessageSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "chatId": ["type": ["integer", "string", "null"]],
                "messageId": ["type": ["integer", "string"]],
                "senderName": ["type": "string"],
                "text": ["type": "string"],
                "dateISO8601": ["type": ["string", "null"]]
            ],
            "required": ["chatId", "messageId", "senderName", "text", "dateISO8601"],
            "additionalProperties": false
        ]
        let taskSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "stableFingerprint": ["type": "string"],
                "title": ["type": "string"],
                "summary": ["type": "string"],
                "suggestedAction": ["type": "string"],
                "ownerName": ["type": "string"],
                "personName": ["type": "string"],
                "chatId": ["type": ["integer", "string"]],
                "chatTitle": ["type": "string"],
                "topicName": ["type": ["string", "null"]],
                "priority": ["type": "string", "enum": ["high", "medium", "low"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "dueAtISO8601": ["type": ["string", "null"]],
                "sourceMessages": [
                    "type": "array",
                    "items": sourceMessageSchema
                ]
            ],
            "required": [
                "stableFingerprint",
                "title",
                "summary",
                "suggestedAction",
                "ownerName",
                "personName",
                "chatId",
                "chatTitle",
                "topicName",
                "priority",
                "confidence",
                "dueAtISO8601",
                "sourceMessages"
            ],
            "additionalProperties": false
        ]
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "tasks": [
                    "type": "array",
                    "items": taskSchema
                ]
            ],
            "required": ["tasks"],
            "additionalProperties": false
        ]

        return [
            "type": "json_schema",
            "json_schema": [
                "name": "dashboard_task_extraction_results",
                "strict": true,
                "schema": schema
            ]
        ]
    }

    /// How many times a 429/503 is retried before giving up to the caller.
    private static let maxRateLimitRetries = 4

    /// Backoff before retrying a rate-limited request: honor Retry-After if the
    /// server sends it, else exponential (~1s, 2s, 4s, 8s) with light jitter,
    /// capped at 30s so a single chat never stalls indexing for too long.
    private static func rateLimitBackoffSeconds(attempt: Int, response: HTTPURLResponse) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return min(max(seconds, 0.5), 30)
        }
        let exponential = pow(2.0, Double(attempt - 1))
        return min(exponential + Double.random(in: 0...0.5), 30)
    }

    private func parseUsage(from rawUsage: Any?) -> AIProviderUsage? {
        guard let usage = rawUsage as? [String: Any] else { return nil }

        let promptTokens = intValue(usage["prompt_tokens"])
        let completionTokens = intValue(usage["completion_tokens"]) ?? 0
        let totalTokens = intValue(usage["total_tokens"])
        let inputTokens = promptTokens ?? 0
        // Billed output = everything that isn't input. Providers disagree on
        // where reasoning tokens land: OpenAI folds them INTO completion_tokens,
        // but Gemini's OpenAI-compat layer reports reasoning_tokens SEPARATELY
        // (total = prompt + completion + reasoning), so completion_tokens alone
        // undercounts Gemini badly. `total - prompt` is correct for both — but
        // ONLY when both fields are actually present; a missing prompt_tokens
        // would otherwise make us bill the whole total as output. Fall back to
        // completion_tokens otherwise.
        let outputTokens: Int
        if let promptTokens, let totalTokens, totalTokens > promptTokens {
            outputTokens = totalTokens - promptTokens
        } else {
            outputTokens = completionTokens
        }
        // OpenAI's prompt_tokens INCLUDES the cached prefix — pull the cached
        // portion so the meter bills it at the 50% cached rate, not list price.
        let cachedInputTokens = (usage["prompt_tokens_details"] as? [String: Any])
            .flatMap { intValue($0["cached_tokens"]) } ?? 0

        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return AIProviderUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cachedInputTokens: cachedInputTokens
        )
    }

    private func persistLatestAgenticResponse(response: String) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }

            let debugDirectory = appSupport
                .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
            let responseURL = debugDirectory.appendingPathComponent("last_openai_agentic_response.txt", isDirectory: false)

            do {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
                try response.write(to: responseURL, atomically: true, encoding: .utf8)
            } catch {
                print("[OpenAIProvider] Failed to persist successful agentic response: \(error)")
            }
        }
    }

    private func persistAgenticParseFailure(response: String, error: Error) {
        Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }

            let debugDirectory = appSupport
                .appendingPathComponent(AppConstants.Storage.appSupportFolderName, isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
            let textURL = debugDirectory.appendingPathComponent("last_openai_agentic_parse_failure.txt", isDirectory: false)

            do {
                try fileManager.createDirectory(at: debugDirectory, withIntermediateDirectories: true)

                let lines = [
                    "capturedAt: \(ISO8601DateFormatter().string(from: Date()))",
                    "model: \(self.model)",
                    "error: \(error.localizedDescription)",
                    "",
                    "rawResponse:",
                    response
                ]
                try lines.joined(separator: "\n").write(to: textURL, atomically: true, encoding: .utf8)
            } catch {
                print("[OpenAIProvider] Failed to persist agentic parse failure: \(error)")
            }
        }
    }

    private func intValue(_ rawValue: Any?) -> Int? {
        switch rawValue {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
