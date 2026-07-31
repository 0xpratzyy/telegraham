//
//  SummaryRetrievalEval.swift
//  Pidgy — is the RETRIEVAL UNIT the problem, not the model?
//
//  Everything measured so far tried to fix retrieval by changing the model:
//  e5, a static model, both fused, plus an entity signal. Ceiling reached:
//  29% top-5 (from a 19% FTS-only baseline). Each step cost machinery and
//  bought a few points.
//
//  Then look at what is actually being searched. A random sample of the
//  11,635 indexed messages:
//
//      "Bill.pdf"  ·  "Ye kar sakte"  ·  "whenever you get a chance please."
//
//  No embedding model — 2023's or 2026's — can match "what's the latest on
//  the case studies?" to "Ye kar sakte". The information is not in the
//  message; it is in the conversation. Chat messages are terrible retrieval
//  units: short, context-free, and 11,635 of them.
//
//  Meanwhile the app already writes 168 rolling per-chat summaries that read
//  like actual documents ("Technical support and workspace management chat.
//  The banger-tweets playbook is at … OpenClaw updated to v2026.4.15 …") —
//  and retrieval never touches them.
//
//  This measures the strip: embed 168 summaries instead of 11,635 messages
//  and rank chats by summary similarity. 70x fewer vectors, each dense and
//  topical. If it beats 29%, most of the retrieval machinery can be deleted
//  rather than tuned.
//
//  Run:
//    TEST_RUNNER_PIDGY_RUN_SUMMARY_EVAL=1 xcodebuild test \
//      -project Pidgy.xcodeproj -scheme Pidgy -destination 'platform=macOS' \
//      -only-testing:PidgyTests/SummaryRetrievalEval
//

import XCTest
@testable import Pidgy

final class SummaryRetrievalEval: XCTestCase {

    private struct OracleEntry: Decodable {
        let id: String
        let query: String
        let expectedKind: String
        let expectedChatIds: [Int64]?
        let acceptableChatIds: [Int64]?
        var targets: Set<Int64> { Set((expectedChatIds ?? []) + (acceptableChatIds ?? [])) }
    }
    private struct Oracle: Decodable { let entries: [OracleEntry] }

    private static let oracleFiles = [
        "topic_search_oracle_v1.json",
        "topic_search_oracle_v2.json",
        "summary_oracle_v3.json",
        "exact_lookup_oracle_v2.json"
    ]
    private static let staticVersion = "static-multilingual-v1"
    private static let topN = 5

    func testSummaryLevelRetrieval() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_SUMMARY_EVAL"] == "1",
            "Set PIDGY_RUN_SUMMARY_EVAL=1 to run the summary-unit retrieval eval."
        )
        let buckets = try Self.loadAllOracles()
        try XCTSkipIf(buckets.isEmpty, "No scorable oracle entries.")

        // Embed every current chat summary once. This is the whole index.
        let summaries = await Self.loadCurrentSummaries()
        try XCTSkipIf(summaries.isEmpty, "No chat summaries yet — run the crawl first.")
        let embedStart = Date()
        var summaryVectors: [(chatId: Int64, vector: [Double])] = []
        for summary in summaries {
            guard let vector = await EmbeddingService.shared.embed(
                text: summary.text, modelVersion: Self.staticVersion, isQuery: false
            ) else { continue }
            summaryVectors.append((summary.chatId, vector))
        }
        let embedSeconds = Date().timeIntervalSince(embedStart)
        try XCTSkipIf(summaryVectors.isEmpty, "Could not embed summaries.")

        var score: [String: (t1: Int, tN: Int)] = [:]
        func credit(_ key: String, _ ranked: [Int64], _ expected: Set<Int64>) {
            var s = score[key] ?? (0, 0)
            if ranked.first.map(expected.contains) ?? false { s.t1 += 1 }
            if ranked.prefix(Self.topN).contains(where: expected.contains) { s.tN += 1 }
            score[key] = s
        }

        var perBucket: [String] = []
        var total = 0
        for bucket in buckets {
            total += bucket.entries.count
            for entry in bucket.entries {
                let expected = entry.targets
                let fts = await Self.ftsScores(entry.query)
                let summaryScores = await Self.summaryScores(entry.query, index: summaryVectors)

                credit("fts-only", Self.rank(fts), expected)
                credit("summary-only", Self.rank(summaryScores), expected)
                credit("fts+summary", Self.rank(Self.blend(fts, 0.5, summaryScores, 0.5)), expected)

                credit("\(bucket.name)|fts-only", Self.rank(fts), expected)
                credit("\(bucket.name)|summary-only", Self.rank(summaryScores), expected)
                credit("\(bucket.name)|fts+summary", Self.rank(Self.blend(fts, 0.5, summaryScores, 0.5)), expected)
            }
        }

        func pct(_ x: Int, of n: Int) -> Int { n == 0 ? 0 : Int((Double(x) / Double(n) * 100).rounded()) }
        func row(_ label: String, _ key: String, of n: Int) -> String {
            let s = score[key] ?? (0, 0)
            return "\(label.padding(toLength: 24, withPad: " ", startingAt: 0))\(pct(s.t1, of: n))%\t\(pct(s.tN, of: n))%"
        }
        for bucket in buckets {
            let n = bucket.entries.count
            perBucket.append("""
            \(bucket.name) (\(n))          top-1\ttop-\(Self.topN)
            \(row("  fts only", "\(bucket.name)|fts-only", of: n))
            \(row("  summary vectors", "\(bucket.name)|summary-only", of: n))
            \(row("  fts + summary", "\(bucket.name)|fts+summary", of: n))
            """)
        }

        print("""

        ═════════ SUMMARY-UNIT RETRIEVAL ═════════
        index: \(summaryVectors.count) summaries (vs 11,635 messages)
        embedded in \(String(format: "%.1f", embedSeconds))s
        queries: \(total)

        OVERALL                     top-1\ttop-\(Self.topN)
        \(row("fts only", "fts-only", of: total))
        \(row("summary vectors only", "summary-only", of: total))
        \(row("fts + summary", "fts+summary", of: total))

        for reference, message-level ceiling reached earlier:
          fts + e5 + static ............. 11%\t29%

        ── BY TASK TYPE ──────────────────────────
        \(perBucket.joined(separator: "\n\n"))
        ══════════════════════════════════════════

        """)
        XCTAssertGreaterThan(total, 0)
    }

    // MARK: - Helpers

    private static func loadCurrentSummaries() async -> [(chatId: Int64, text: String)] {
        await DatabaseManager.shared.currentChatSummariesForEval()
    }

    /// Cosine of the query against every summary — 168 comparisons, so the
    /// brute force that would be fatal over 11k message vectors is free here.
    private static func summaryScores(
        _ query: String,
        index: [(chatId: Int64, vector: [Double])]
    ) async -> [Int64: Double] {
        guard let q = await EmbeddingService.shared.embed(
            text: query, modelVersion: staticVersion, isQuery: true
        ) else { return [:] }
        var best: [Int64: Double] = [:]
        for entry in index {
            let score = cosine(q, entry.vector)
            best[entry.chatId] = max(best[entry.chatId] ?? 0, score)
        }
        return best
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func ftsScores(_ query: String) async -> [Int64: Double] {
        var best: [Int64: Double] = [:]
        for expression in buildFTSVariants(rawQuery: query) {
            let hits = await DatabaseManager.shared.localSearchFTSRaw(
                rawFTSQuery: expression,
                limit: AppConstants.AI.SemanticSearch.ftsTopMessages
            )
            guard let top = hits.map(\.score).max(), top > 0 else { continue }
            for hit in hits {
                best[hit.message.chatId] = max(best[hit.message.chatId] ?? 0, hit.score / top)
            }
        }
        return best
    }

    private static func blend(
        _ a: [Int64: Double], _ aw: Double, _ b: [Int64: Double], _ bw: Double
    ) -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for (id, s) in a { out[id, default: 0] += s * aw }
        for (id, s) in b { out[id, default: 0] += s * bw }
        return out
    }

    private static func rank(_ scores: [Int64: Double]) -> [Int64] {
        scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    private struct Bucket { let name: String; let entries: [OracleEntry] }

    private static func loadAllOracles() throws -> [Bucket] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var root: URL?
        for _ in 0..<4 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("evals").path) {
                root = dir; break
            }
            dir = dir.deletingLastPathComponent()
        }
        guard let root else { throw XCTSkip("evals/ not found") }
        var seen = Set<String>()
        var buckets: [Bucket] = []
        for file in oracleFiles {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("evals/\(file)")),
                  let oracle = try? JSONDecoder().decode(Oracle.self, from: data) else { continue }
            let scorable = oracle.entries.filter { entry in
                guard entry.expectedKind == "hit", !entry.targets.isEmpty else { return false }
                let key = entry.query.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            if !scorable.isEmpty {
                buckets.append(Bucket(name: file.replacingOccurrences(of: ".json", with: ""), entries: scorable))
            }
        }
        return buckets
    }
}
