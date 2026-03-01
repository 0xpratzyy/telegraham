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
            try await self.makeRequest(systemPrompt: SummaryPrompt.systemPrompt, userMessage: userMessage)
        }
    }

    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: ActionPrompt.systemPrompt,
                userMessage: ActionPrompt.userMessage(snippets: snippets)
            )
        }
        return try JSONExtractor.parseJSON(response)
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: SemanticSearchPrompt.systemPrompt,
                userMessage: SemanticSearchPrompt.userMessage(query: query, snippets: snippets)
            )
        }
        return try JSONExtractor.parseJSON(response)
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        let snippets = MessageSnippet.truncateToTokenBudget(messages, maxChars: 4000)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: FollowUpPrompt.systemPrompt,
                userMessage: FollowUpPrompt.userMessage(chatTitle: chatTitle, snippets: snippets)
            )
        }
        let dto: FollowUpSuggestionDTO = try JSONExtractor.parseJSON(response)
        return (dto.relevant ?? true, dto.suggestedAction)
    }

    func testConnection() async throws -> Bool {
        _ = try await makeRequest(systemPrompt: "Reply with OK", userMessage: "test")
        return true
    }

    // MARK: - HTTP

    private func makeRequest(systemPrompt: String, userMessage: String) async throws -> String {
        var request = URLRequest(url: AppConstants.AI.openAIBaseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ]
        ]
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
              let content = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return content
    }
}
