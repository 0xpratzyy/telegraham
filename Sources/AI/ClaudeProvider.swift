import Foundation

final class ClaudeProvider: AIProvider {
    private let apiKey: String
    private let model: String
    private let session = URLSession.shared
    private let baseURL = URL(string: "https://api.anthropic.com/v1/messages")!

    init(apiKey: String, model: String = "claude-sonnet-4-20250514") {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - AIProvider

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let userMessage = SummaryPrompt.userMessage(snippets: snippets)
        return try await makeRequest(systemPrompt: SummaryPrompt.systemPrompt, userMessage: userMessage)
    }

    func classify(query: String) async throws -> QueryIntent {
        let response = try await makeRequest(
            systemPrompt: ClassifyPrompt.systemPrompt,
            userMessage: ClassifyPrompt.userMessage(query: query)
        )
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return QueryIntent(rawValue: cleaned) ?? .messageSearch
    }

    func categorize(messages: [MessageSnippet]) async throws -> [CategorizedMessageDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await makeRequest(
            systemPrompt: CategorizationPrompt.systemPrompt,
            userMessage: CategorizationPrompt.userMessage(snippets: snippets)
        )
        return try parseJSON(response)
    }

    func generateActionItems(messages: [MessageSnippet]) async throws -> [ActionItemDTO] {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await makeRequest(
            systemPrompt: ActionPrompt.systemPrompt,
            userMessage: ActionPrompt.userMessage(snippets: snippets)
        )
        return try parseJSON(response)
    }

    func generateDigest(messages: [MessageSnippet], period: DigestPeriod) async throws -> DigestResult {
        let snippets = MessageSnippet.truncateToTokenBudget(messages)
        let response = try await makeRequest(
            systemPrompt: DigestPrompt.systemPrompt(period: period),
            userMessage: DigestPrompt.userMessage(snippets: snippets)
        )
        return try DigestPrompt.parseResponse(response, period: period)
    }

    // MARK: - HTTP

    private func makeRequest(systemPrompt: String, userMessage: String) async throws -> String {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
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
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw AIError.invalidResponse
        }

        return text
    }

    private func parseJSON<T: Decodable>(_ response: String) throws -> T {
        // Extract JSON from response (may be wrapped in markdown code blocks)
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw AIError.parsingError("Could not convert response to data")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.parsingError(error.localizedDescription)
        }
    }

    private func extractJSON(from text: String) -> String {
        // Try to extract JSON from markdown code blocks
        if let jsonStart = text.range(of: "```json"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let jsonStart = text.range(of: "```"),
           let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
            return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find raw JSON array or object
        if let bracketStart = text.firstIndex(of: "["),
           let bracketEnd = text.lastIndex(of: "]") {
            return String(text[bracketStart...bracketEnd])
        }
        if let braceStart = text.firstIndex(of: "{"),
           let braceEnd = text.lastIndex(of: "}") {
            return String(text[braceStart...braceEnd])
        }
        return text
    }
}
