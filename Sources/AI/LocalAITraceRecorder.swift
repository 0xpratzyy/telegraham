//
//  LocalAITraceRecorder.swift
//  Pidgy
//
//  Local-only successor to the LangSmith tracer scaffold. Records each
//  LLM call (system+user prompt → response, tokens, cost, latency,
//  errors) as one JSON line in a file under Application Support, so the
//  developer loop keeps its debugging / eval-fixture source without any
//  third party ever receiving chat data.
//
//  Privacy is structural, not configurational: this type has no
//  URLSession, no endpoint, and no API key — prompts contain raw
//  Telegram message text and there is simply no code path by which
//  they can leave the machine. (Its predecessor POSTed full prompts to
//  api.smith.langchain.com in Debug builds; that path is gone.)
//
//  Debug-only: in Release builds `record` compiles to a no-op, so
//  distributed builds don't even write the local file. The traces
//  directory lives inside ~/Library/Application Support/Pidgy/, which
//  Preferences → "Reset all local data" already wipes.
//

import Foundation

actor LocalAITraceRecorder {
    static let shared = LocalAITraceRecorder()

    /// Rotate once the live file exceeds this. One previous generation
    /// is kept (`llm-traces.1.jsonl`) so a long debugging session can't
    /// grow the directory unbounded.
    static let rotationByteLimit: UInt64 = 20 * 1024 * 1024

    private var directoryOverride: URL?

    private init() {}

    /// Tests run hosted inside the real app, so without an override the
    /// recorder would append to the developer's actual trace log.
    func configureForTesting(directoryOverride: URL?) {
        self.directoryOverride = directoryOverride
    }

    /// Records a complete LLM call. Fire-and-forget — errors are logged,
    /// never propagated, and the AI request returns immediately while
    /// the trace flushes on a utility-priority task.
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
        #if DEBUG
        Task.detached(priority: .utility) {
            await self.persist(
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
        #endif
    }

    /// Synchronous core, internal so tests can await it directly instead
    /// of polling the file for the fire-and-forget wrapper to land.
    func persist(
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
    ) {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var entry: [String: Any] = [
            "name": runName,
            "provider": provider,
            "model": model,
            "start_time": isoFormatter.string(from: startedAt),
            "end_time": isoFormatter.string(from: completedAt),
            "inputs": [
                "system": systemPrompt,
                "user": userMessage
            ]
        ]
        if let response { entry["output"] = response }
        if let error { entry["error"] = error }
        if let inputTokens { entry["input_tokens"] = inputTokens }
        if let outputTokens { entry["output_tokens"] = outputTokens }
        if let costUSD { entry["cost_usd"] = costUSD }
        if let chatId { entry["chat_id"] = String(chatId) }
        if !extraTags.isEmpty { entry["tags"] = extraTags }

        do {
            let fileURL = try preparedTraceFileURL()
            var line = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: fileURL, options: .atomic)
            }
        } catch {
            print("[AITrace] local trace write failed: \(error.localizedDescription)")
        }
    }

    /// Resolves the live trace file, creating the directory and rotating
    /// the previous generation when the size cap is exceeded.
    private func preparedTraceFileURL() throws -> URL {
        let baseDirectory: URL
        if let directoryOverride {
            baseDirectory = directoryOverride
        } else {
            baseDirectory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Pidgy", isDirectory: true)
                .appendingPathComponent("traces", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let fileURL = baseDirectory.appendingPathComponent("llm-traces.jsonl")
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
           size > Self.rotationByteLimit {
            let rotatedURL = baseDirectory.appendingPathComponent("llm-traces.1.jsonl")
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        }
        return fileURL
    }
}
