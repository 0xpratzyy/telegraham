import Foundation

final class OpenAIProvider: AIProvider {
    private let apiKey: String
    private let model: String
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConstants.AI.requestTimeoutSeconds
        config.timeoutIntervalForResource = AppConstants.AI.requestTimeoutSeconds * 2
        return URLSession(configuration: config)
    }()

    init(apiKey: String, model: String = AppConstants.AI.defaultOpenAIModel) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - AIProvider

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let userMessage = SummaryPrompt.userMessage(snippets: snippets)
        return try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: SummaryPrompt.systemPrompt,
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
            let expectedIds = Set(candidates.map(\.chatId))
            let returnedIds = Set(parsed.map(\.chatId))
            guard parsed.count == candidates.count, returnedIds == expectedIds else {
                let error = AIError.parsingError(
                    "agentic response cardinality mismatch: expected \(candidates.count) candidates but got \(parsed.count)"
                )
                persistAgenticParseFailure(response: response, error: error)
                throw error
            }
            return parsed
        } catch {
            persistAgenticParseFailure(response: response, error: error)
            throw AIError.parsingError("agentic JSON parse failure; raw payload saved to debug")
        }
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
                requestKind: .pipelineTriage
            )
        }
        return try JSONExtractor.parseJSON(response)
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
        responseFormat: [String: Any]? = nil
    ) async throws -> String {
        var request = URLRequest(url: AppConstants.AI.openAIBaseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.httpError(httpResponse.statusCode, errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = extractMessageContent(from: message["content"]) else {
            throw AIError.invalidResponse
        }

        if let requestKind {
            let usage = parseUsage(from: json["usage"])
            await AIUsageStore.shared.record(
                provider: .openAI,
                model: model,
                requestKind: requestKind,
                usage: usage
            )
        }

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
        let candidateIds: [Any] = candidates.map { NSNumber(value: $0.chatId) }
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
                            "chatId": [
                                "type": "integer",
                                "enum": candidateIds
                            ],
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

    private func parseUsage(from rawUsage: Any?) -> AIProviderUsage? {
        guard let usage = rawUsage as? [String: Any] else { return nil }

        let inputTokens = intValue(usage["prompt_tokens"]) ?? 0
        let outputTokens = intValue(usage["completion_tokens"]) ?? 0

        guard inputTokens > 0 || outputTokens > 0 else { return nil }
        return AIProviderUsage(inputTokens: inputTokens, outputTokens: outputTokens)
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
