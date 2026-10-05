import XCTest
@testable import Pidgy

/// Explicitly opt-in: ordinary test runs never spend API credits or read real keys.
@MainActor
final class TypeSafeLiveBenchmarkTests: XCTestCase {
    func testLiveComparison() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_LIVE_TYPESAFE_BENCHMARK"] == "1" else {
            throw XCTSkip("Live comparison requires explicit opt-in and saved credentials")
        }
        let service = AIService()
        guard service.isTypeSafeEnabled, service.isConfigured else {
            XCTFail("Save TypeSafe and text-provider credentials in Pidgy first")
            return
        }
        let before = await AIUsageStore.shared.loadOverview()
        let report = try await service.benchmarkTypeSafe()
        let after = await AIUsageStore.shared.loadOverview()
        let usage: [[String: Any]] = after.byModel30Days.compactMap { row in
            let previous = before.byModel30Days.first { $0.id == row.id }?.metrics ?? .zero
            let requests = row.metrics.requestCount - previous.requestCount
            guard requests > 0 else { return nil }
            return [
                "model": row.title, "requests": requests,
                "inputTokens": row.metrics.inputTokens - previous.inputTokens,
                "outputTokens": row.metrics.outputTokens - previous.outputTokens,
                "estimatedCostUSD": row.metrics.estimatedCostUSD - previous.estimatedCostUSD,
                "unmeteredRequests": row.metrics.unmeteredRequestCount - previous.unmeteredRequestCount
            ]
        }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Build/TypeSafeBenchmark")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact: [String: Any] = [
            "measuredAt": ISO8601DateFormatter().string(from: Date()),
            "report": report, "usage": usage,
            "pricingSource": "Pidgy pricing catalog; estimates, not invoices"
        ]
        try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        print("TYPESAFE_LIVE_BENCHMARK: \(report)")
    }
}

final class TypeSafeTests: XCTestCase {
    private let items = [
        LoopClassificationItem(id: 17, text: "Confirm the meeting."),
        LoopClassificationItem(id: 28, text: "Build the checkout fix.")
    ]

    private static func payload(probability: Double = 0.95, includeSecond: Bool = true) -> Data {
        var answers: [String: Any] = [
            "17": ["type": "choice", "choice": "reply", "probabilities": ["reply": probability, "action": 1 - probability], "confidence": 0.7],
            "999": ["type": "choice", "choice": "reply", "probabilities": ["reply": 1.0, "action": 0.0], "confidence": 1.0]
        ]
        if includeSecond {
            answers["28"] = ["type": "choice", "choice": "action", "probabilities": ["reply": 0.05, "action": 0.95], "confidence": 0.7]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "model": "jev-1.13.0", "answers": answers,
            "usage": ["input_tokens": 1000, "output_tokens": 30]
        ])
    }

    private func client(data: Data? = nil, status: Int = 200) -> TypeSafeClient {
        let body = data ?? Self.payload()
        return TypeSafeClient(apiKey: "fake-test-key", recordUsage: false) { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testWireContractPinsModelAndExplicitlyIdentifiesEachQuestion() async throws {
        let client = TypeSafeClient(apiKey: "fake-test-key", recordUsage: false) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-test-key")
            XCTAssertEqual(request.timeoutInterval, 4)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "jev-1.13.0")
            let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
            XCTAssertTrue((questions["17"]?["instructions"] as? String)?.contains("id 17") == true)
            XCTAssertTrue((questions["28"]?["instructions"] as? String)?.contains("id 28") == true)
            XCTAssertEqual(questions["17"]?["type"] as? String, "choice")
            return (Self.payload(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await client.classify(items)
        XCTAssertEqual(result.decisions, [17: .reply, 28: .action])
        XCTAssertNil(result.decisions[999])
        XCTAssertEqual(try XCTUnwrap(result.estimatedCostUSD), 0.000042, accuracy: 1e-10)
    }

    func testOnlyUncertainItemsFallbackAndCannotOverwriteAcceptedResults() async throws {
        let result = try await LoopDecisionRouter.classify(items, typeSafe: client(data: Self.payload(probability: 0.55))) { pending in
            XCTAssertEqual(pending.map(\.id), [17])
            return [17: .reply, 28: .reply, 999: .action]
        }
        XCTAssertEqual(result, [17: .reply, 28: .action])
    }

    func testMissingAnswerFallsBack() async throws {
        let result = try await LoopDecisionRouter.classify(items, typeSafe: client(data: Self.payload(includeSecond: false))) { pending in
            XCTAssertEqual(pending.map(\.id), [28])
            return [28: .action]
        }
        XCTAssertEqual(result.count, 2)
    }

    func testHTTPAndMalformedResponsesFallbackWithoutExposingResponseBodies() async throws {
        for status in [200, 401, 429, 503] {
            let result = try await LoopDecisionRouter.classify(items, typeSafe: client(data: Data("sensitive upstream error".utf8), status: status)) { pending in
                XCTAssertEqual(pending.count, 2)
                return [17: .reply, 28: .action]
            }
            XCTAssertEqual(result.count, 2)
        }
    }

    func testInvalidProbabilityAndChoiceFallback() async throws {
        let invalid = Data(#"{"model":"jev-1.13.0","answers":{"17":{"type":"choice","choice":"reply","confidence":0.9,"probabilities":{"reply":0.95,"action":0.95}},"28":{"type":"choice","choice":"unknown","confidence":1,"probabilities":{"reply":0,"action":1}}}}"#.utf8)
        let result = try await LoopDecisionRouter.classify(items, typeSafe: client(data: invalid)) { pending in
            XCTAssertEqual(pending.count, 2)
            return [17: .reply, 28: .action]
        }
        XCTAssertEqual(result.count, 2)
    }

    func testCancellationDoesNotStartFallback() async throws {
        let cancelled = TypeSafeClient(apiKey: "fake", recordUsage: false) { _ in throw URLError(.cancelled) }
        do {
            _ = try await LoopDecisionRouter.classify(items, typeSafe: cancelled) { _ in
                XCTFail("Cancellation must not trigger a second paid request")
                return [:]
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDisabledUsesCurrentProviderAndPropagatesItsFailure() async throws {
        enum TestError: Error { case unavailable }
        do {
            _ = try await LoopDecisionRouter.classify(items, typeSafe: nil) { pending in
                XCTAssertEqual(pending.count, 2)
                throw TestError.unavailable
            }
            XCTFail("Expected provider failure")
        } catch TestError.unavailable {} catch { XCTFail("Unexpected error") }
    }

    func testPricingFreeOutputUnknownModelsAndCredentialReset() throws {
        let pricing = try XCTUnwrap(AIUsagePricingCatalog.pricing(for: .typeSafe, model: "jev-1.13.0"))
        XCTAssertEqual(pricing.estimatedCostUSD(inputTokens: 1_000_000, outputTokens: 5_000_000), 0.042, accuracy: 1e-10)
        XCTAssertNil(AIUsagePricingCatalog.pricing(for: .typeSafe, model: "jev-future"))
        XCTAssertTrue(PreferencesResetPlan.credentialKeysToDelete.contains(.aiApiKeyTypeSafe))
    }

    func testInvalidKeyAndOversizedInputNeverReachNetwork() async {
        for (key, text) in [("bad\nkey", "task"), ("fake", String(repeating: "x", count: 24_001))] {
            let client = TypeSafeClient(apiKey: key, recordUsage: false) { _ in
                XCTFail("Invalid input must not reach the network")
                throw URLError(.badURL)
            }
            do {
                _ = try await client.classify([LoopClassificationItem(id: 1, text: text)])
                XCTFail("Expected input validation failure")
            } catch TypeSafeClient.ClientError.invalidInput {} catch { XCTFail("Unexpected error") }
        }
    }
}
