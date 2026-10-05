import Foundation

/// ChatGPT plan tokens use Responses exclusively; API-key chat completions are
/// a separate provider. An incomplete/failed stream never becomes a success.
final class ChatGPTProvider: AIProvider {
    private let model: String
    private let token: @Sendable () async throws -> String
    private let stillActive: @Sendable () async -> Bool
    private let session: URLSession
    private let recordUsage: @Sendable (String, AIRequestKind, AIProviderUsage?) async -> Void

    init(model: String, token: @escaping @Sendable () async throws -> String,
         stillActive: @escaping @Sendable () async -> Bool = { true }, session: URLSession = .shared,
         recordUsage: @escaping @Sendable (String, AIRequestKind, AIProviderUsage?) async -> Void = { model, kind, usage in
             await AIUsageStore.shared.record(provider: .chatGPT, model: model, requestKind: kind, usage: usage)
         }) {
        self.model = model; self.token = token; self.stillActive = stillActive; self.session = session
        self.recordUsage = recordUsage
    }
    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        try await answer(systemPrompt: prompt, userMessage: SummaryPrompt.userMessage(snippets: MessageSnippet.truncateToTokenBudget(messages)), kind: .summary)
    }
    func answer(systemPrompt: String, userMessage: String) async throws -> String {
        try await answer(systemPrompt: systemPrompt, userMessage: userMessage, kind: .answerEngine)
    }
    func answer(systemPrompt: String, userMessage: String, kind: AIRequestKind) async throws -> String {
        let access = try await token()
        var request = URLRequest(url: URL(string: ChatGPTAuth.resource + "/responses")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, instructions: systemPrompt, input: userMessage))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count >= 65_536 { break } }
            try ChatGPTService.checkResponse(data, response)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else { throw AIError.invalidResponse }
        var stream = ChatGPTResponseStream()
        var framing = ChatGPTSSEFraming()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let event = try framing.append(byte) {
                try stream.consume(event)
                if stream.completed { break }
            }
        }
        let text = try stream.result()
        guard await stillActive() else { throw CancellationError() }
        await recordUsage(model, kind, stream.usage)
        return text
    }
    static func body(model: String, instructions: String, input: String) -> [String: Any] {
        ["model": model, "instructions": instructions,
         "input": [["role": "user", "content": input]], "store": false, "stream": true]
    }
    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        let response = try await answer(systemPrompt: SemanticSearchPrompt.systemPrompt,
            userMessage: SemanticSearchPrompt.userMessage(query: query, snippets: MessageSnippet.truncateToTokenBudget(messages)), kind: .semanticSearch)
        return try JSONExtractor.parseJSON(response)
    }
    func planQuery(query: String, activeFilter: QueryScope, deterministicSpec: QuerySpec) async throws -> QueryPlannerResultDTO {
        let response = try await answer(systemPrompt: QueryPlanningPrompt.systemPrompt,
            userMessage: QueryPlanningPrompt.userMessage(query: query, activeFilter: activeFilter, deterministicSpec: deterministicSpec), kind: .queryPlanning)
        return try JSONExtractor.parseJSON(response)
    }
    func extractPersonProfile(personName: String, messages: [MessageSnippet]) async throws -> String {
        guard !messages.isEmpty else { return "" }
        return try await answer(systemPrompt: PersonProfilePrompt.systemPrompt,
            userMessage: PersonProfilePrompt.userMessage(personName: personName, snippets: messages), kind: .personProfile)
    }
    func testConnection() async throws -> Bool {
        _ = try await answer(systemPrompt: "Reply exactly OK.", userMessage: "Connection test.")
        return true
    }
}

/// Frame bytes directly so blank SSE delimiters and split UTF-8 sequences are
/// preserved. Transport termination never promotes an unfinished event.
struct ChatGPTSSEFraming {
    private var line = Data()
    private var event = ""
    mutating func append(_ byte: UInt8) throws -> String? {
        guard byte == 10 else {
            line.append(byte)
            guard line.count <= 2_000_000 else { throw AIError.invalidResponse }
            return nil
        }
        if line.last == 13 { line.removeLast() }
        guard let text = String(data: line, encoding: .utf8) else { throw AIError.invalidResponse }
        line.removeAll(keepingCapacity: true)
        if text.isEmpty {
            guard !event.isEmpty else { return nil }
            defer { event = "" }
            return event
        }
        if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            event += (event.isEmpty ? "" : "\n") + value
            guard event.utf8.count <= 2_000_000 else { throw AIError.invalidResponse }
        }
        return nil
    }
}

struct ChatGPTResponseStream {
    private(set) var text = ""
    private(set) var completed = false
    private(set) var usage: AIProviderUsage?
    mutating func consume(_ data: String) throws {
        guard !completed else { return }
        guard data != "[DONE]", let bytes = data.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = event["type"] as? String else { throw AIError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String else { throw AIError.invalidResponse }
            text += delta
            guard text.utf8.count <= 8_000_000 else { throw AIError.invalidResponse }
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else { throw AIError.invalidResponse }
            completed = true
            if let counters = response["usage"] as? [String: Any] {
                usage = AIProviderUsage(inputTokens: counters["input_tokens"] as? Int ?? 0,
                                        outputTokens: counters["output_tokens"] as? Int ?? 0,
                                        cachedInputTokens: (counters["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0)
            }
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = event["error"] as? [String: Any] ?? response?["error"] as? [String: Any] ?? event
            throw ChatGPTAuth.Failure.remote(status: 0, code: error["code"] as? String ?? "stream_failed", requestID: nil)
        case "response.incomplete": throw AIError.invalidResponse
        default: break
        }
    }
    func result() throws -> String {
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.invalidResponse }
        return text
    }
}
