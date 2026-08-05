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

    func answer(systemPrompt: String, userMessage: String) async throws -> String {
        try await answer(systemPrompt: systemPrompt, userMessage: userMessage, kind: .summary)
    }

    func answer(systemPrompt: String, userMessage: String, kind: AIRequestKind) async throws -> String {
        // Fact extraction owns retries at the crawl level, where all chats can
        // share one pressure-aware cooldown and no cursor advances on failure.
        // Retrying a 30–45s transport hang three times inside this one request
        // monopolizes a managed quota slot and turns a small Slack update into
        // minutes of invisible lag.
        let maxAttempts = kind == .factExtraction ? 1 : 3
        return try await RetryHelper.withRetry(maxAttempts: maxAttempts) {
            try await self.makeRequest(
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                requestKind: kind
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
        return AIService.unwrapProse(response)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testConnection() async throws -> Bool {
        _ = try await makeRequest(systemPrompt: "Reply with OK", userMessage: "test")
        return true
    }

    // MARK: - HTTP

    /// Request kinds whose entire response is a JSON document, so the provider
    /// can be told to emit nothing else. (Prose kinds — summary, answerEngine —
    /// must stay free-form.)
    /// Kinds whose ENTIRE output is parsed as JSON. Membership must follow
    /// the parser, not the feature: `.personProfile` sat in this set while its
    /// prompt asked for plain prose, so the model — forced into json_object
    /// mode — invented a {"profile": "…"} wrapper that the UI then displayed
    /// verbatim, braces and \n escapes included. Prose kinds (profile, the
    /// summary fold, answers) must never appear here.
    private static let jsonOnlyKinds: Set<AIRequestKind> = [
        .factExtraction, .queryPlanning, .pipelineTriage, .replyQueueTriage,
        .dashboardTopicDiscovery, .dashboardTaskTriage, .dashboardTaskExtraction,
        .semanticSearch
    ]

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

        // Managed plan: user-facing synthesis stages route to a sharper model;
        // everything else keeps the provider's configured model. BYOK users'
        // explicit model choice is never overridden.
        let effectiveModel: String
        if model == AppConstants.AI.managedModel,
           let override = AppConstants.AI.managedModelOverride(for: requestKind) {
            effectiveModel = override
        } else {
            effectiveModel = model
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        if requestKind == .factExtraction {
            request.timeoutInterval = AppConstants.AI.factExtractionTimeoutSeconds
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let licenseKey, !licenseKey.isEmpty {
            request.setValue(licenseKey, forHTTPHeaderField: "X-Pidgy-License")
        }
        var body: [String: Any] = [
            "model": effectiveModel,
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
        if effectiveModel.hasPrefix("gpt-5") || effectiveModel.contains("gemini") {
            body["reasoning_effort"] = requestKind == .pipelineTriage ? "minimal" : "low"
        }
        // DETERMINISM. Every Pidgy prompt is a factual/structured judgement —
        // extraction, triage, routing, grounded answers — never creative
        // writing. Left unset, the provider default (1.0 on Gemini) sampled a
        // fresh answer each time: re-running the SAME window over the same
        // messages swung the fact count 100→152 (±20%), which made prompt
        // changes unmeasurable and made the product feel arbitrary
        // (measured 2026-07-25). gpt-5 reasoning models reject any value but
        // their default, so they keep it.
        if !effectiveModel.hasPrefix("gpt-5") {
            body["temperature"] = 0
        }
        // Guarantee syntactically valid JSON on the paths whose whole output
        // IS JSON. Without it a stray prose preamble becomes
        // `unparseableResponse`, which costs the extraction window 3 retries
        // and can skip it entirely. json_object (not a strict schema): the
        // Vertex OpenAI-compat layer's schema support is unverified, and the
        // tolerant parsers already handle shape.
        if responseFormat == nil, let requestKind, Self.jsonOnlyKinds.contains(requestKind) {
            body["response_format"] = ["type": "json_object"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var data: Data
        var response: URLResponse
        var rateLimitAttempt = 0
        // Fact extraction coordinates rate-limit recovery across the whole
        // crawl. Retrying each chat independently here would still multiply a
        // shared 429 into several sleeping/retrying requests before the global
        // cooldown can engage.
        let maxRateLimitRetries = requestKind == .factExtraction ? 0 : Self.maxRateLimitRetries
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
                        model: effectiveModel,
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
                    PidgyTelemetry.captureAIFailure(provider: "openai", model: effectiveModel, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "transport")
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
               rateLimitAttempt < maxRateLimitRetries {
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
                provider: "openai", model: effectiveModel,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: nil, error: "invalidResponse: non-HTTP",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: effectiveModel, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "invalid_response")
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            LocalAITraceRecorder.shared.record(
                provider: "openai", model: effectiveModel,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: errorBody, error: "http_\(httpResponse.statusCode)",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: effectiveModel, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "http_\(httpResponse.statusCode)")
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
                provider: "openai", model: effectiveModel,
                runName: requestKind?.rawValue ?? "openai_chat",
                systemPrompt: systemPrompt, userMessage: userMessage,
                startedAt: startedAt, completedAt: Date(),
                response: String(data: data, encoding: .utf8),
                error: "invalidResponse: parse",
                inputTokens: nil, outputTokens: nil, costUSD: nil,
                chatId: chatId
            )
            PidgyTelemetry.captureAIFailure(provider: "openai", model: effectiveModel, runName: requestKind?.rawValue ?? "openai_chat", errorClass: "parse")
            throw AIError.invalidResponse
        }

        let usage = parseUsage(from: json["usage"])

        if let requestKind {
            await AIUsageStore.shared.record(
                provider: .openAI,
                model: effectiveModel,
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
            model: effectiveModel,
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
                .pricing(for: .openAI, model: effectiveModel)
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
