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

    func classify(query: String) async throws -> QueryIntent {
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: ClassifyPrompt.systemPrompt,
                userMessage: ClassifyPrompt.userMessage(query: query)
            )
        }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return QueryIntent(rawValue: cleaned) ?? .messageSearch
    }

    func categorize(messages: [MessageSnippet]) async throws -> [CategorizedMessageDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: CategorizationPrompt.systemPrompt,
                userMessage: CategorizationPrompt.userMessage(snippets: snippets)
            )
        }
        return try JSONExtractor.parseJSON(response)
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

    func generateDigest(messages: [MessageSnippet], period: DigestPeriod) async throws -> DigestResult {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await RetryHelper.withRetry {
            try await self.makeRequest(
                systemPrompt: DigestPrompt.systemPrompt(period: period),
                userMessage: DigestPrompt.userMessage(snippets: snippets)
            )
        }
        return try DigestPrompt.parseResponse(response, period: period)
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
