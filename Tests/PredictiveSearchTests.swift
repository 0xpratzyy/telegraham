import XCTest
@testable import Pidgy

private actor PredictionCalls {
    var count = 0
    func record() { count += 1 }
}

@MainActor
final class PredictiveSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_789_640_000)
    private var chats: [TGChat] {
        [TypeSafeAppFixtures.digest(id: 1, title: "Maya", text: "Invoice 442, amount due $500 Friday, unpaid.").candidate.chat,
         TypeSafeAppFixtures.digest(id: 2, title: "Alex", text: "The launch deck is ready. Here is the link.").candidate.chat,
         TypeSafeAppFixtures.digest(id: 3, title: "Lunch", text: "Pizza at noon?").candidate.chat]
    }
    private func client(target: String = "c1", probability: Double = 0.99, calls: PredictionCalls = PredictionCalls(), delay: Int = 0) -> TypeSafeClient {
        TypeSafeClient(apiKey: "synthetic", recordUsage: false) { request in
            await calls.record()
            XCTAssertEqual(request.timeoutInterval, 1.2)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let questions = body["questions"] as! [String: [String: Any]]
            var answers: [String: Any] = [:]
            for (id, question) in questions {
                let criteria = question["criteria"] as! [String: String]
                let choice = id == "target" ? target : "clear"
                let probabilities = Dictionary(uniqueKeysWithValues: criteria.keys.map {
                    ($0, $0 == choice ? probability : (1 - probability) / Double(criteria.count - 1))
                })
                answers[id] = ["type": "choice", "choice": choice, "probabilities": probabilities, "confidence": probability]
            }
            let data = try JSONSerialization.data(withJSONObject: ["model": TypeSafeClient.model, "answers": answers, "usage": ["input_tokens": 100, "output_tokens": 0]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func ids(_ search: PredictiveSearch) -> [Int64] {
        search.results.compactMap { if case .semanticResult(let row) = $0 { return row.chatId }; return nil }
    }

    func testImmediateLocalResultsThenSemanticPromotionAndCache() async throws {
        let calls = PredictionCalls(), search = PredictiveSearch()
        let client = client(calls: calls)
        search.update(query: "Maya", chats: chats, timeRange: nil, client: client, now: now)
        XCTAssertEqual(ids(search), [1])
        try await Task.sleep(for: .milliseconds(240))
        XCTAssertEqual(ids(search).first, 2)
        XCTAssertNotNil(search.milliseconds)
        search.update(query: "Maya", chats: chats, timeRange: nil, client: client, now: now)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ids(search).first, 2)
        let count = await calls.count
        XCTAssertEqual(count, 1)
        // A different eligible scope must not reuse a previous chat selection.
        search.update(query: "Maya", chats: [chats[0]], timeRange: nil, client: client, now: now)
        XCTAssertEqual(ids(search), [1])
        search.clear()
    }

    func testAmbiguityFailureAndDisconnectKeepLocalBehavior() async throws {
        for model in [client(probability: 0.55), client(target: "none"), TypeSafeClient(apiKey: "fake", recordUsage: false, transport: { _ in throw URLError(.timedOut) })] {
            let search = PredictiveSearch()
            search.update(query: "Maya", chats: chats, timeRange: nil, client: model, now: now)
            try await Task.sleep(for: .milliseconds(230))
            XCTAssertEqual(ids(search), [1])
            XCTAssertNil(search.milliseconds)
            search.update(query: "Maya", chats: chats, timeRange: nil, client: nil, now: now)
            XCTAssertTrue(search.results.isEmpty)
        }
    }

    func testNewQueryAndKeyboardSelectionRejectLateReplies() async throws {
        let search = PredictiveSearch(), model = client(delay: 220)
        search.update(query: "Maya", chats: chats, timeRange: nil, client: model, now: now)
        try await Task.sleep(for: .milliseconds(180))
        search.update(query: "Alex", chats: chats, timeRange: nil, client: model, now: now)
        search.freeze()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(ids(search), [2])
        XCTAssertNil(search.milliseconds)
        search.clear()
        XCTAssertTrue(search.results.isEmpty)
    }

    func testRapidTypingIsDebouncedAndCandidatePayloadIsBounded() async throws {
        let calls = PredictionCalls(), search = PredictiveSearch(), model = client(calls: calls)
        for query in ["Ma", "May", "Maya"] {
            search.update(query: query, chats: chats, timeRange: nil, client: model, now: now)
        }
        try await Task.sleep(for: .milliseconds(250))
        let count = await calls.count
        XCTAssertEqual(count, 1)
        let future = TimeRangeConstraint(startDate: now.addingTimeInterval(1), endDate: now.addingTimeInterval(100), label: "Future")
        XCTAssertTrue(PredictiveSearch.candidates(query: "invoice", chats: chats, timeRange: future).isEmpty)
        XCTAssertTrue(PredictiveSearch.candidates(query: "invoice", chats: chats, timeRange: nil, scope: .groups).isEmpty)
        let many = (1...30).map { TypeSafeAppFixtures.digest(id: Int64($0), title: String(repeating: "T", count: 300), text: String(repeating: "x", count: 1000)).candidate.chat }
        let candidates = PredictiveSearch.candidates(query: "xx", chats: many, timeRange: nil)
        XCTAssertEqual(candidates.count, 15)
        XCTAssertTrue(candidates.allSatisfy { $0.title.count <= 120 && $0.snippet.count <= 400 })
    }

    func testArchiveEvidenceRespectsScopeAndDatesAndSurvivesNoRecentMatch() async throws {
        let old = TGMessage(id: 900, chatId: 1, senderId: .user(1), date: now.addingTimeInterval(-86400),
            textContent: "invoice.pdf [photo text: amount due $500]", mediaType: .document,
            isOutgoing: false, chatTitle: "Maya", senderName: "Maya")
        let excluded = TGMessage(id: 901, chatId: 999, senderId: .user(1), date: old.date,
            textContent: "private invoice", mediaType: nil, isOutgoing: false, chatTitle: nil, senderName: nil)
        let range = TimeRangeConstraint(startDate: old.date.addingTimeInterval(-1), endDate: old.date.addingTimeInterval(1), label: "Older")
        let merged = PredictiveSearch.mergeArchive(query: "invoice", chats: chats, recent: [], messages: [excluded, old], timeRange: range)
        XCTAssertEqual(merged.candidates.map(\.id), [1])
        XCTAssertEqual(merged.candidates.first?.messageId, 900)
        XCTAssertTrue(merged.candidates.first?.snippet.contains("invoice.pdf") == true)
        let outside = TimeRangeConstraint(startDate: now, endDate: now.addingTimeInterval(100), label: "Now")
        XCTAssertTrue(PredictiveSearch.mergeArchive(query: "invoice", chats: chats, recent: [], messages: [old], timeRange: outside).candidates.isEmpty)
        let search = PredictiveSearch()
        search.update(query: "invoice", chats: chats, timeRange: range, client: client(target: "c0"), now: now,
            archive: { _, _, _ in [old] })
        try await Task.sleep(for: .milliseconds(250))
        guard case .patternResult(let result) = search.results.first else { return XCTFail("Expected message evidence") }
        XCTAssertEqual(result.message.id, 900)
        XCTAssertEqual(result.message.date, old.date)
    }

    func testLateArchiveCannotReplaceNewQueryOrFrozenSelection() async throws {
        let search = PredictiveSearch()
        search.update(query: "invoice", chats: chats, timeRange: nil, client: client(), archive: { _, _, _ in
            try? await Task.sleep(for: .milliseconds(200))
            return []
        })
        try await Task.sleep(for: .milliseconds(170))
        search.update(query: "Alex", chats: chats, timeRange: nil, client: client())
        search.freeze()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(ids(search), [2])
        XCTAssertEqual(PredictiveSearch.archiveQuery("where is the invoice.pdf"), "\"invoice\"* OR \"pdf\"*".replacingOccurrences(of: "\\", with: ""))
    }

    func testLivePredictiveRanking() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_LIVE_PREDICTIVE_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in live API benchmark") }
        let key = try XCTUnwrap(KeychainManager.retrieve(for: .aiApiKeyTypeSafe))
        let model = TypeSafeClient(apiKey: key)
        let cases: [(String, Int64?)] = [("Maya", 1), ("the unpaid invoice", 1), ("invoice wala chat", 1), ("the launch deck link", 2), ("where is the ready deck", 2), ("pizza lunch", 3), ("the person waiting for payment", 1), ("send me the presentation", 2), ("flight booking to Tokyo", nil), ("summarize all my conversations", nil)]
        struct Row: Codable { let query: String; let round: Int; let selected: Int64?; let correct: Bool; let milliseconds: Double; let costUSD: Double }
        var rows: [Row] = []
        for round in 1...2 {
            for (query, expected) in cases {
                let candidates = PredictiveSearch.candidates(query: query, chats: chats, timeRange: nil)
                let before = await AIUsageStore.shared.loadOverview().lifetime
                let start = ContinuousClock.now
                let result = try await model.predictChat(query: query, candidates: candidates, now: now)
                let duration = start.duration(to: .now).components
                let after = await AIUsageStore.shared.loadOverview().lifetime
                rows.append(Row(query: query, round: round, selected: result?.id, correct: result?.id == expected,
                                milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                                costUSD: after.estimatedCostUSD - before.estimatedCostUSD))
            }
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Build/TypeSafeBenchmark/predictive-results.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: url, options: .atomic)
        print("PREDICTIVE: \(rows.filter(\.correct).count)/\(rows.count) correct; \(rows.map(\.milliseconds)) ms")
    }
}
