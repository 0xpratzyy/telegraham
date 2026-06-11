import XCTest
@testable import Pidgy

/// Pins the privacy contract that replaced the LangSmith tracer: LLM
/// traces (which contain raw Telegram message text) are written to a
/// local file only, and the remote-tracing key plumbing stays dead.
final class LocalAITraceRecorderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        await LocalAITraceRecorder.shared.configureForTesting(directoryOverride: tempDirectory)
    }

    override func tearDown() async throws {
        await LocalAITraceRecorder.shared.configureForTesting(directoryOverride: nil)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try await super.tearDown()
    }

    /// The Info.plist must not carry LangSmith key entries in ANY
    /// configuration — their absence is what guarantees no build can be
    /// keyed for remote tracing. (Tests are hosted in the real app
    /// bundle, so this inspects the actual built Info.plist.)
    func testInfoPlistCarriesNoRemoteTracingKeys() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "PidgyBundledLangSmithApiKey"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "PidgyBundledLangSmithProject"))
    }

    func testPersistWritesOneJSONLineToTheLocalFileOnly() async throws {
        await LocalAITraceRecorder.shared.persist(
            provider: "openai",
            model: "gpt-5",
            runName: "pipeline_triage",
            systemPrompt: "You are a triage assistant.",
            userMessage: "[2m ago] Alice: my new number is +1 555 123 4567",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            completedAt: Date(timeIntervalSince1970: 1_750_000_002),
            response: "{\"category\": \"on_me\"}",
            error: nil,
            inputTokens: 120,
            outputTokens: 12,
            costUSD: 0.0004,
            chatId: 42,
            extraTags: ["cached_tokens": "0"]
        )

        let fileURL = tempDirectory.appendingPathComponent("llm-traces.jsonl")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 1)

        let entry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        XCTAssertEqual(entry["provider"] as? String, "openai")
        XCTAssertEqual(entry["name"] as? String, "pipeline_triage")
        XCTAssertEqual(entry["chat_id"] as? String, "42")
        let inputs = try XCTUnwrap(entry["inputs"] as? [String: Any])
        XCTAssertEqual(inputs["user"] as? String, "[2m ago] Alice: my new number is +1 555 123 4567")
        XCTAssertEqual(entry["output"] as? String, "{\"category\": \"on_me\"}")
    }

    func testPersistAppendsSubsequentRecordsAsSeparateLines() async throws {
        for index in 0..<3 {
            await LocalAITraceRecorder.shared.persist(
                provider: "anthropic",
                model: "claude-sonnet-4-20250514",
                runName: "run_\(index)",
                systemPrompt: "system",
                userMessage: "message \(index)",
                startedAt: Date(timeIntervalSince1970: 1_750_000_000),
                completedAt: Date(timeIntervalSince1970: 1_750_000_001),
                response: nil,
                error: "transport: timed out",
                inputTokens: nil,
                outputTokens: nil,
                costUSD: nil,
                chatId: nil,
                extraTags: [:]
            )
        }

        let fileURL = tempDirectory.appendingPathComponent("llm-traces.jsonl")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any]
        )
        XCTAssertEqual(last["name"] as? String, "run_2")
        XCTAssertEqual(last["error"] as? String, "transport: timed out")
    }
}
