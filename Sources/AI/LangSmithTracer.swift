//
//  LangSmithTracer.swift
//  Pidgy
//
//  Temporary observability scaffold. Posts each LLM call (system+user
//  prompt → response, tokens, cost, latency, errors) to LangSmith so we
//  can see what the model actually returned for any given chat, build
//  eval fixtures from real failures, and compare prompt versions.
//
//  This file is intentionally self-contained: one actor, two providers
//  call into it, and the AI flow never throws because of LangSmith. To
//  remove the scaffold later, delete this file + the two call sites
//  in OpenAIProvider/ClaudeProvider and the BundledSecrets entry.
//
//  Privacy: prompts contain Telegram message text. Set
//  PIDGY_BUNDLED_LANGSMITH_API_KEY to "" in BetaSecrets.local.xcconfig
//  to disable entirely — `start` early-returns when no key is bundled.
//

import Foundation

/// Actor-isolated tracer that fires each LLM call out to LangSmith
/// without ever blocking or failing the underlying request.
actor LangSmithTracer {
    static let shared = LangSmithTracer()

    private struct Configuration {
        let apiKey: String
        let projectName: String
        let endpoint: URL
    }

    private let configuration: Configuration?
    private let session: URLSession

    private init() {
        if let apiKey = BundledSecrets.langSmithApiKey, !apiKey.isEmpty {
            self.configuration = Configuration(
                apiKey: apiKey,
                projectName: BundledSecrets.langSmithProjectName ?? "pidgy-dev",
                endpoint: URL(string: "https://api.smith.langchain.com")!
            )
        } else {
            self.configuration = nil
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    var isEnabled: Bool { configuration != nil }

    /// Records a complete LLM call (start + end emitted as one POST to
    /// /runs). Fire-and-forget — exceptions are caught and logged but
    /// never propagated to the caller. Includes a tiny detached Task so
    /// the AI request returns immediately while the trace flushes.
    nonisolated func record(
        provider: String,
        model: String,
        runName: String,
        systemPrompt: String,
        userMessage: String,
        startedAt: Date,
        completedAt: Date,
        response: String?,
        error: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        costUSD: Double?,
        chatId: Int64? = nil,
        extraTags: [String: String] = [:]
    ) {
        Task.detached(priority: .utility) {
            await self.send(
                provider: provider,
                model: model,
                runName: runName,
                systemPrompt: systemPrompt,
                userMessage: userMessage,
                startedAt: startedAt,
                completedAt: completedAt,
                response: response,
                error: error,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                costUSD: costUSD,
                chatId: chatId,
                extraTags: extraTags
            )
        }
    }

    private func send(
        provider: String,
        model: String,
        runName: String,
        systemPrompt: String,
        userMessage: String,
        startedAt: Date,
        completedAt: Date,
        response: String?,
        error: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        costUSD: Double?,
        chatId: Int64?,
        extraTags: [String: String]
    ) async {
        guard let configuration else { return }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var metadata: [String: Any] = [
            "provider": provider,
            "model": model
        ]
        if let inputTokens { metadata["input_tokens"] = inputTokens }
        if let outputTokens { metadata["output_tokens"] = outputTokens }
        if let costUSD { metadata["cost_usd"] = costUSD }
        if let chatId { metadata["chat_id"] = String(chatId) }
        for (key, value) in extraTags { metadata[key] = value }

        // LangSmith's run id regex requires lowercase hex — Swift's UUID
        // emits uppercase, which 422's with "Does not match pattern ^[0-9a-f]…"
        var run: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "name": runName,
            "run_type": "llm",
            "start_time": isoFormatter.string(from: startedAt),
            "end_time": isoFormatter.string(from: completedAt),
            "inputs": [
                "system": systemPrompt,
                "user": userMessage
            ],
            "session_name": configuration.projectName,
            "extra": ["metadata": metadata]
        ]

        if let response {
            run["outputs"] = ["content": response]
        }
        if let error {
            run["error"] = error
        }

        do {
            let body = try JSONSerialization.data(withJSONObject: run)
            var request = URLRequest(url: configuration.endpoint.appendingPathComponent("runs"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
            request.httpBody = body

            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                // Don't spam logs on transient failures — single line is enough
                // for us to notice if traces stop flowing entirely.
                print("[LangSmith] non-2xx status: \(http.statusCode) for run \(runName)")
            }
        } catch {
            print("[LangSmith] trace dispatch failed: \(error.localizedDescription)")
        }
    }
}
