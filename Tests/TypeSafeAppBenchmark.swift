import XCTest
import AppKit
@testable import Pidgy

/// Manual, synthetic-only benchmark of the real application entry points.
/// No message database is opened. Real API access requires explicit opt-in.
@MainActor
final class TypeSafeAppBenchmark: XCTestCase {
    struct Run: Codable {
        let stage: String
        let variant: String
        let scenario: String
        let round: Int
        let milliseconds: Double
        let correct: Bool
        let fallbackCount: Int
        let decisions: Int
        let requests: Int
        let inputTokens: Int
        let outputTokens: Int
        let estimatedCostUSD: Double
        let output: String
    }
    struct QueryCase {
        let query: String
        let family: QueryFamily
        var scope: QueryScope = .all
        var people: [String] = []
        var topics: [String] = []
    }
    static let queries: [QueryCase] = [
        .init(query: "summarize pricing discussions", family: .summary, topics: ["pricing"]),
        .init(query: "who needs my reply", family: .replyQueue),
        .init(query: "Alex ka kya scene hai", family: .summary, people: ["alex"]),
        .init(query: "find messages about invoices", family: .topicSearch, topics: ["invoices"]),
        .init(query: "summarize groups from yesterday", family: .summary, scope: .groups),
        .init(query: "find pricing in DMs this week", family: .topicSearch, scope: .dms, topics: ["pricing"]),
        .init(query: "what did we decide with Maya on pricing", family: .summary, people: ["maya"], topics: ["pricing"]),
        .init(query: "kisko reply karna hai", family: .replyQueue),
        .init(query: "firstdollar ki latest discussions batao", family: .summary, topics: ["firstdollar"]),
        .init(query: "find messages about the Orion launch", family: .topicSearch, topics: ["orion", "launch"]),
        .init(query: "summarize messages between June 1 and June 5", family: .summary),
        .init(query: "昨日の会話を要約して", family: .summary),
        .init(query: "what is happening with Priya", family: .summary, people: ["priya"]),
        .init(query: "refund policy", family: .topicSearch, topics: ["refund", "policy"]),
        .init(query: "find group messages about hiring last week", family: .topicSearch, scope: .groups, topics: ["hiring"]),
        .init(query: "summarize all chats today", family: .summary)
    ]
    static let loops: [(String, LoopKind)] = TypeSafeBenchmark.fixtures + [
        ("Haan bol do ki main kal meeting mein aaunga.", .reply),
        ("Invoice ka payment Friday se pehle karna hai.", .action),
        ("Send the known link to the already-completed deck.", .reply),
        ("Prepare a new deck and send it to Maya.", .action),
        ("Tell Alex the bug was fixed yesterday.", .reply),
        ("Investigate why the app freezes on launch.", .action),
        ("Reply that the invoice was already paid.", .reply),
        ("Check the bank statement to verify whether payment arrived.", .action),
        ("Answer yes to the lunch invitation.", .reply),
        ("Book the restaurant for Friday lunch.", .action),
        ("Share my phone number in response to Sam's question.", .reply),
        ("Review the new API documentation before recommending an approach.", .action),
        ("Tell Maya I cannot attend tomorrow.", .reply),
        ("Create the account and configure billing.", .action),
        ("Confirm that the already-approved budget is $500.", .reply),
        ("Calculate next month's budget from the expense records.", .action),
        ("Reply with the known delivery address.", .reply),
        ("Chase the vendor for an overdue delivery.", .action)
    ]
    struct SummaryCase {
        let name: String
        let query: String
        let texts: [(String, String)]
        let relevant: Set<Int64>
        let requiredText: [String]
    }
    static let summaries: [SummaryCase] = [
        .init(name: "launch with unrelated chats", query: "What is the Orion launch status?", texts: [
            ("Orion team", "Orion launch is confirmed for Friday. QA is complete. No remaining blockers."),
            ("Finance", "The Orion launch budget is approved at $500."),
            ("Lunch", "Order noodles for lunch. Extra chilli please."),
            ("Weekend", "Let's play tennis on Sunday.")
        ], relevant: [1, 2], requiredText: ["friday", "500"]),
        .init(name: "negation and partial evidence", query: "Did we approve Orion's new pricing?", texts: [
            ("Pricing team", "The proposed Orion price is $99. Do NOT launch it: pricing has not been approved."),
            ("Sales", "We are waiting for finance to review Orion pricing. No final decision yet."),
            ("Travel", "Flights to Goa were cheap last week."),
            ("Food", "The cafe raised coffee prices again.")
        ], relevant: [1, 2], requiredText: ["99"]),
        .init(name: "Hinglish evidence", query: "Orion launch ka kya scene hai?", texts: [
            ("Orion", "Orion Friday ko launch hoga. QA complete hai, blocker nahi hai."),
            ("Design", "Orion ke assets ready hain, Maya ne approve kar diya."),
            ("Friends", "Kal cricket khelenge, bat le aana.")
        ], relevant: [1, 2], requiredText: ["friday"]),
        .init(name: "all evidence relevant", query: "Summarize the Orion launch updates", texts: [
            ("Engineering", "Orion launch is Friday. The crash fix shipped."),
            ("Design", "Orion artwork is approved by Maya."),
            ("Finance", "Orion has a $500 approved budget.")
        ], relevant: [1, 2, 3], requiredText: ["friday", "500"])
    ]

    func testLiveDirectFactComparison() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_LIVE_DIRECT_FACTS"] == "1" else { throw XCTSkip("Opt-in extraction comparison") }
        let service = AIService()
        let jev = try XCTUnwrap(service.typeSafeClient)
        let cases: [(String, String, String, FactPredicate?)] = [
            ("inbound request", "Maya", "Please send me the invoice Friday.", .iOwe),
            ("incoming promise", "Maya", "I will send you the invoice Friday.", .owesMe),
            ("outgoing promise", "[ME]", "I will send you the invoice Friday.", .iOwe),
            ("outgoing request", "[ME]", "Please send me the invoice Friday.", .owesMe),
            ("Hinglish promise", "Maya", "main kal invoice bhej dungi", .owesMe),
            ("durable fact", "Maya", "I work at Acme as a designer.", .fact),
            ("reaction", "Maya", "😂", nil),
            ("third-party commitment", "Maya", "Alex will send Priya the invoice.", nil)
        ]
        struct Row: Codable { let scenario: String; let variant: String; let correct: Bool; let fallback: Bool; let milliseconds: Double; let costUSD: Double }
        var rows: [Row] = []
        let chat = TypeSafeAppFixtures.digest(id: 991, title: "Maya", text: "fixture").candidate.chat
        let prompt = FactExtractionPrompt.systemPrompt + FactExtractionPrompt.contextBlock(myName: "Me", myUsername: nil,
            chatTitle: "Maya", chatType: "private", openLoops: []) + PromptSafety.untrustedContentClause
        for (name, sender, text, expected) in cases {
            let snippets = [MessageSnippet(messageId: 1, senderFirstName: sender, text: text, relativeTimestamp: "now", chatId: 991, chatName: "Maya")]
            let transcript = FactExtractionPrompt.numberedTranscript(snippets: snippets)
            for variant in ["baseline", "jev-first"] {
                let before = await AIUsageStore.shared.loadOverview().lifetime
                let start = ContinuousClock.now
                var raw: String?
                if variant == "jev-first" { raw = try await jev.extractFactResponse(chat: chat, snippets: snippets, transcript: transcript, hasOpenLoops: false) }
                let fallback = variant == "jev-first" && raw == nil
                if raw == nil { raw = try await service.provider.answer(systemPrompt: prompt, userMessage: transcript, kind: .factExtraction) }
                let result = try FactExtractionParser.parse(XCTUnwrap(raw), chatId: 991, openLoops: [], validFrom: Date(), messages: snippets)
                let correct: Bool
                if let expected { correct = result.drafts.contains { ($0.predicate == expected || (expected == .fact && $0.predicate == .worksAt)) && $0.sourceMessageId == 1 } }
                else { correct = !result.drafts.contains { $0.predicate.isOpenLoop } }
                let duration = start.duration(to: .now).components
                let after = await AIUsageStore.shared.loadOverview().lifetime
                rows.append(Row(scenario: name, variant: variant, correct: correct, fallback: fallback,
                    milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                    costUSD: after.estimatedCostUSD - before.estimatedCostUSD))
                print("DIRECT_FACT \(name) \(variant) correct=\(correct) fallback=\(fallback)")
            }
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Build/TypeSafeBenchmark/direct-fact-comparison.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: output)
    }

    func testLiveSummaryCoverage() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_LIVE_SUMMARY_COVERAGE"] == "1" else { throw XCTSkip("Opt-in summary benchmark") }
        let service = AIService()
        XCTAssertNotNil(service.typeSafeClient)
        struct Result: Codable { let scenario: String; let round: Int; let correct: Bool; let milliseconds: Double; let costUSD: Double; let text: String; let selected: [Int64] }
        var results: [Result] = []
        for round in 1...2 {
            for scenario in Self.summaries {
                let digests = scenario.texts.enumerated().map { TypeSafeAppFixtures.digest(id: Int64($0.offset + 1), title: $0.element.0, text: $0.element.1) }
                let before = await AIUsageStore.shared.loadOverview().lifetime
                let start = ContinuousClock.now
                let result = await SummaryEngine.shared.summarize(query: scenario.query, scopeDescription: "synthetic test chats", perChatDigest: digests,
                    aiService: service, fallbackSnippet: "", queryContext: TypeSafeAppFixtures.context(scenario.query))
                let duration = start.duration(to: .now).components
                let after = await AIUsageStore.shared.loadOverview().lifetime
                let selected = Set(result.extracts.map { $0.chat.id })
                let correct = scenario.relevant == selected && scenario.requiredText.allSatisfy { result.text.lowercased().contains($0) }
                results.append(Result(scenario: scenario.name, round: round, correct: correct,
                    milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15,
                    costUSD: after.estimatedCostUSD - before.estimatedCostUSD, text: result.text, selected: selected.sorted()))
                print("SUMMARY_COVERAGE \(scenario.name) round=\(round) correct=\(correct)")
            }
        }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Build/TypeSafeBenchmark/summary-coverage.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output)
    }

    func testLiveAcrossApp() async throws {
        guard ProcessInfo.processInfo.environment["PIDGY_LIVE_TYPESAFE_APP_BENCHMARK"] == "1" else {
            throw XCTSkip("Manual opt-in live benchmark")
        }
        let configured = AIService()
        let client = try XCTUnwrap(configured.typeSafeClient)
        XCTAssertTrue(configured.isConfigured)
        let baseline = AIService(testingProvider: configured.provider, providerType: configured.providerType, providerModel: configured.providerModel)
        let hybrid = AIService(testingProvider: configured.provider, providerType: configured.providerType, providerModel: configured.providerModel, typeSafeClient: client)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Build/TypeSafeBenchmark")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var runs: [Run] = []
        func measure(stage: String, variant: String, scenario: String, round: Int,
                     operation: () async throws -> (Bool, Int, Int, String)) async throws {
            let before = await AIUsageStore.shared.loadOverview().lifetime
            let start = ContinuousClock.now
            let observation: (Bool, Int, Int, String)
            do { observation = try await operation() }
            catch { observation = (false, 0, 0, "ERROR: \(error.localizedDescription)") }
            let elapsed = start.duration(to: .now).components
            let after = await AIUsageStore.shared.loadOverview().lifetime
            let run = Run(stage: stage, variant: variant, scenario: scenario, round: round,
                          milliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                          correct: observation.0, fallbackCount: observation.1, decisions: observation.2,
                          requests: after.requestCount - before.requestCount,
                          inputTokens: after.inputTokens - before.inputTokens, outputTokens: after.outputTokens - before.outputTokens,
                          estimatedCostUSD: after.estimatedCostUSD - before.estimatedCostUSD, output: observation.3)
            runs.append(run)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(runs).write(to: directory.appendingPathComponent("app-results.json"), options: .atomic)
            print("APP_BENCH \(stage) \(variant) \(scenario): \(Int(run.milliseconds))ms correct=\(run.correct) fallback=\(run.fallbackCount) cost=\(run.estimatedCostUSD)")
            try await Task.sleep(for: .milliseconds(500))
        }
        // Alternate provider order on round two. New routers avoid plan-cache
        // hits: this is a cold-query comparison, not a cache benchmark.
        for round in 1...2 {
            for scenario in Self.queries {
                for variant in round == 1 ? ["baseline", "hybrid"] : ["hybrid", "baseline"] {
                    try await measure(stage: "planning", variant: variant, scenario: scenario.query, round: round) {
                        let router = QueryRouter(aiProvider: configured.provider)
                        if variant == "hybrid" { router.updateTypeSafe(client) }
                        let spec = await router.resolveQuerySpec(query: scenario.query, now: Date(timeIntervalSince1970: 1_789_640_000))
                        let people = Set(spec.plannerHints?.people ?? [])
                        let topics = Set(spec.plannerHints?.topicTerms ?? [])
                        let correct = spec.family == scenario.family && spec.scope == scenario.scope
                            && Set(scenario.people).isSubset(of: people) && Set(scenario.topics).isSubset(of: topics)
                        let output = String(data: try JSONEncoder().encode(spec), encoding: .utf8)!
                        return (correct, router.lastPlannerSource == "fallback" ? 1 : 0, 1, output)
                    }
                }
            }
            for variant in round == 1 ? ["baseline", "hybrid"] : ["hybrid", "baseline"] {
                try await measure(stage: "loops", variant: variant, scenario: "24 mixed to-dos", round: round) {
                    let items = Self.loops.enumerated().map { LoopClassificationItem(id: Int64($0.offset + 1), text: $0.element.0) }
                    let service = variant == "hybrid" ? hybrid : baseline
                    let before = await AIUsageStore.shared.loadOverview().byModel30Days
                    let decisions = try await service.classifyLoopItems(items)
                    let after = await AIUsageStore.shared.loadOverview().byModel30Days
                    let fallbackRequests = variant == "hybrid" ? after.filter { !$0.title.contains("jev-") }.reduce(0) { sum, row in
                        sum + row.metrics.requestCount - (before.first { $0.id == row.id }?.metrics.requestCount ?? 0)
                    } : 0
                    let correct = Self.loops.enumerated().filter { decisions[Int64($0.offset + 1)] == $0.element.1 }.count
                    let failures = Self.loops.enumerated().compactMap { index, fixture -> String? in
                        let actual = decisions[Int64(index + 1)]
                        return actual == fixture.1 ? nil : "\(fixture.0): expected \(fixture.1.rawValue), got \(actual?.rawValue ?? "missing")"
                    }
                    return (correct == items.count, fallbackRequests, items.count, "\(correct)/\(items.count) correct\n" + failures.joined(separator: "\n"))
                }
            }
            for scenario in Self.summaries {
                let digests = scenario.texts.enumerated().map { TypeSafeAppFixtures.digest(id: Int64($0.offset + 1), title: $0.element.0, text: $0.element.1) }
                for variant in round == 1 ? ["baseline", "hybrid"] : ["hybrid", "baseline"] {
                    try await measure(stage: "summary", variant: variant, scenario: scenario.name, round: round) {
                        let service = variant == "hybrid" ? hybrid : baseline
                        let before = await AIUsageStore.shared.loadOverview().byModel30Days
                        let result = await SummaryEngine.shared.summarize(query: scenario.query, scopeDescription: "synthetic test chats", perChatDigest: digests,
                                                                         aiService: service, fallbackSnippet: "", queryContext: TypeSafeAppFixtures.context(scenario.query))
                        let after = await AIUsageStore.shared.loadOverview().byModel30Days
                        let textRequests = after.filter { !$0.title.contains("jev-") }.reduce(0) { sum, row in
                            sum + row.metrics.requestCount - (before.first { $0.id == row.id }?.metrics.requestCount ?? 0)
                        }
                        let selected = Set(result.extracts.map { $0.chat.id })
                        let correct = scenario.relevant == selected
                            && scenario.requiredText.allSatisfy { result.text.lowercased().contains($0) }
                        return (correct, variant == "hybrid" ? max(0, textRequests - 1) : 0, digests.count, result.text + "\nSELECTED: \(selected.sorted())")
                    }
                }
            }
        }
        for (name, sample, expected) in [
            ("unpaid invoice", "INVOICE 442\nAmount due: $500\nDue: Friday\nStatus: UNPAID - NOT A PAYMENT RECEIPT", ["500", "friday"]),
            ("completed payment", "PAYMENT RECEIPT\nOrder 881\nPaid: $42\nStatus: PAYMENT COMPLETE", ["42"])
        ] {
            let image = NSImage(size: NSSize(width: 1000, height: 400))
            image.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
            (sample as NSString).draw(in: NSRect(x: 30, y: 30, width: 940, height: 340), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
            let url = directory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-" )).png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            try await measure(stage: "image", variant: "hybrid", scenario: name, round: 1) {
                let ocr = try XCTUnwrap(PhotoOCRIndexer.recognizeText(at: url))
                let generated = try await hybrid.summarizeImageText(ocr)
                let summary = try XCTUnwrap(generated)
                let correct = expected.allSatisfy { summary.lowercased().contains($0) }
                    && (name != "unpaid invoice" || summary.lowercased().contains("unpaid") || summary.lowercased().contains("due"))
                return (correct, 0, 1, summary)
            }
        }
        XCTAssertFalse(runs.contains { $0.output.hasPrefix("ERROR:") }, "See app-results.json for failed live calls")
    }
}
