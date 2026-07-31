//
//  RetrievalRecallEval.swift
//  Pidgy — what the user actually sees, and where the arms run out.
//
//  Search has no reranker any more. An LLM used to reorder the top
//  candidates; measured over 100 labelled queries it moved end-to-end top-5
//  from 19% to 21%, for a round trip and a paid call on every search, so it
//  was removed. The fused FTS + vector ranking below is now the final answer,
//  which makes recall@5 the product metric rather than an input to a later
//  stage.
//
//  Why the wider cutoffs stay: they separate a RANKING problem from a
//  COVERAGE one. Per-arm ceiling — whether an arm contains the target chat
//  anywhere in its output — is the diagnostic the old precision-only runs
//  never printed. An arm with a high ceiling and low recall@5 can be fixed by
//  combining differently; an arm with a low ceiling cannot be fixed by any
//  amount of fusion tuning, because the answer was never in its candidate set.
//  (The entity arm is the second kind: 13% ceiling, 192 facts across 1282
//  chats.)
//
//  It also tests the fusion SHAPE, not just its inputs. Production blends
//  min-maxed scores with fixed weights (ftsWeight 0.6 / vectorWeight 0.4).
//  A weighted sum lets a dense, well-scaled arm drown a sparse one. RRF ranks
//  instead of scores, so a sparse arm's top hit still contributes its full
//  1/(k+rank) regardless of how the arm scales. Same inputs, different
//  combiner, and the difference is the finding: 62% vs 58% at the wide end.
//
//  Run:
//    TEST_RUNNER_PIDGY_RUN_RECALL_EVAL=1 xcodebuild test \
//      -project Pidgy.xcodeproj -scheme Pidgy -destination 'platform=macOS' \
//      -only-testing:PidgyTests/RetrievalRecallEval
//

import XCTest
@testable import Pidgy

final class RetrievalRecallEval: XCTestCase {

    private struct OracleEntry: Decodable {
        let id: String
        let query: String
        let expectedKind: String
        let expectedChatIds: [Int64]?
        let acceptableChatIds: [Int64]?
        var targets: Set<Int64> { Set((expectedChatIds ?? []) + (acceptableChatIds ?? [])) }
    }
    private struct Oracle: Decodable { let entries: [OracleEntry] }
    private struct Bucket { let name: String; let entries: [OracleEntry] }

    private static let oracleFiles = [
        "topic_search_oracle_v1.json",
        "topic_search_oracle_v2.json",
        "summary_oracle_v3.json",
        "exact_lookup_oracle_v2.json"
    ]
    private static let e5Version = "e5-multilingual-small-v1"
    private static let staticVersion = "static-multilingual-v1"

    /// 5 is what the user sees; the wider cutoffs are diagnostic — the gap
    /// between recall@5 and recall@30 is how much a better combiner could
    /// still recover without touching retrieval.
    private static let cutoffs = [5, 10, 20, 30]

    /// RRF's rank-damping constant. 60 is the value production already uses
    /// in `mergeLocalSemanticHits`, kept identical so this measures the
    /// fusion shape rather than a retuned constant.
    private static let rrfK: Double = 60

    func testRecallAtK() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_RECALL_EVAL"] == "1",
            "Set PIDGY_RUN_RECALL_EVAL=1 to run the recall eval."
        )
        let buckets = try Self.loadAllOracles()
        try XCTSkipIf(buckets.isEmpty, "No scorable oracle entries.")

        // The summary arm's index is built here rather than read from the
        // vector store: 71 rows embed in seconds, and keeping it in-memory
        // means the arm can be added or dropped without a migration.
        let summaryIndex = await Self.buildSummaryIndex()
        let chatUniverse = await Self.chatUniverseSize()

        var recall: [String: [Int: Int]] = [:]   // config -> cutoff -> hits
        var ceiling: [String: Int] = [:]         // arm -> queries where target appears at all
        var armDepth: [String: Int] = [:]        // arm -> summed candidate-list length
        var total = 0
        var perBucketRecall: [String: [String: [Int: Int]]] = [:]

        for bucket in buckets {
            for entry in bucket.entries {
                total += 1
                let expected = entry.targets

                // Each arm is an independently RANKED list of chat ids.
                // Keeping them as lists (not score maps) is the point: RRF
                // consumes ranks, and the ceiling diagnostic needs to know
                // what an arm returned even below the fusion cutoff.
                let arms: [(String, [Int64])] = [
                    ("fts", Self.rank(await Self.ftsScores(entry.query))),
                    ("e5", Self.rank(await Self.vectorScores(entry.query, version: Self.e5Version))),
                    ("static", Self.rank(await Self.vectorScores(entry.query, version: Self.staticVersion))),
                    ("entity", await Self.entityArm(entry.query)),
                    ("summary", Self.rank(await Self.summaryScores(entry.query, index: summaryIndex)))
                ]
                let byName = Dictionary(uniqueKeysWithValues: arms)

                for (name, list) in arms {
                    armDepth[name, default: 0] += list.count
                    if list.contains(where: expected.contains) { ceiling[name, default: 0] += 1 }
                }

                // What ships today: min-maxed scores, fixed weights, FTS
                // and the e5 vector arm only.
                let production = Self.rank(Self.blend(
                    await Self.ftsScores(entry.query), AppConstants.AI.SemanticSearch.ftsWeight,
                    await Self.vectorScores(entry.query, version: Self.e5Version),
                    AppConstants.AI.SemanticSearch.vectorWeight
                ))

                let configs: [(String, [Int64])] = [
                    ("fts only", byName["fts"] ?? []),
                    ("PRODUCTION (blend fts+e5)", production),
                    ("rrf: fts+e5", Self.rrf([byName["fts"], byName["e5"]])),
                    ("rrf: fts+e5+static", Self.rrf([byName["fts"], byName["e5"], byName["static"]])),
                    ("rrf: fts+entity", Self.rrf([byName["fts"], byName["entity"]])),
                    ("rrf: fts+summary", Self.rrf([byName["fts"], byName["summary"]])),
                    ("rrf: fts+entity+summary", Self.rrf([byName["fts"], byName["entity"], byName["summary"]])),
                    ("rrf: ALL FIVE ARMS", Self.rrf(arms.map { $0.1 }))
                ]

                for (name, ranked) in configs {
                    for cutoff in Self.cutoffs where ranked.prefix(cutoff).contains(where: expected.contains) {
                        recall[name, default: [:]][cutoff, default: 0] += 1
                    }
                    for cutoff in Self.cutoffs where ranked.prefix(cutoff).contains(where: expected.contains) {
                        perBucketRecall[bucket.name, default: [:]][name, default: [:]][cutoff, default: 0] += 1
                    }
                }
            }
        }

        // MARK: report

        func pct(_ x: Int, of n: Int) -> String {
            n == 0 ? "  -" : String(format: "%3d%%", Int((Double(x) / Double(n) * 100).rounded()))
        }
        func recallRow(_ name: String, _ table: [String: [Int: Int]], of n: Int) -> String {
            let cells = Self.cutoffs.map { pct(table[name]?[$0] ?? 0, of: n) }.joined(separator: "\t")
            return "\(name.padding(toLength: 28, withPad: " ", startingAt: 0))\(cells)"
        }

        let armRows = ["fts", "e5", "static", "entity", "summary"].map { name -> String in
            let avgDepth = total == 0 ? 0 : (armDepth[name] ?? 0) / total
            return "\(name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(pct(ceiling[name] ?? 0, of: total))   avg \(avgDepth) chats returned"
        }.joined(separator: "\n")

        let bucketRows = buckets.map { bucket -> String in
            let n = bucket.entries.count
            let table = perBucketRecall[bucket.name] ?? [:]
            let rows = ["fts only", "PRODUCTION (blend fts+e5)", "rrf: fts+e5+static", "rrf: ALL FIVE ARMS"]
                .map { "  " + recallRow($0, table, of: n) }
                .joined(separator: "\n")
            return "\(bucket.name) (\(n))\n\(rows)"
        }.joined(separator: "\n\n")

        print("""

        ═══════════════ RECALL@K — WHAT SHIPS ═══════════════
        queries: \(total)   ·   chats in corpus: \(chatUniverse)
        summary index: \(summaryIndex.count)

        ── PER-ARM CEILING (target present ANYWHERE in the arm) ──
        \(armRows)

        ── RECALL@K ──────────────────────────────────────────────
        \("config".padding(toLength: 28, withPad: " ", startingAt: 0))\
        \(Self.cutoffs.map { "@\($0)" }.joined(separator: "\t"))
        \(["fts only",
           "PRODUCTION (blend fts+e5)",
           "rrf: fts+e5",
           "rrf: fts+e5+static",
           "rrf: fts+entity",
           "rrf: fts+summary",
           "rrf: fts+entity+summary",
           "rrf: ALL FIVE ARMS"].map { recallRow($0, recall, of: total) }.joined(separator: "\n"))

        ── BY TASK TYPE ──────────────────────────────────────────
        \(bucketRows)
        ══════════════════════════════════════════════════════════

        """)
        XCTAssertGreaterThan(total, 0)
    }

    /// Is the wall real, or are the arms simply starved?
    ///
    /// The recall run above showed every configuration converging near 54%
    /// @20 and 56% @30 — which reads as "half these queries are
    /// unanswerable" until you notice `ftsTopMessages` and
    /// `vectorTopMessages` are both 50. Fifty MESSAGES collapse to ~26-30
    /// distinct chats, so no arm was ever allowed to nominate more than a
    /// fiftieth of the 1282-chat corpus. A ceiling measured under that cap
    /// is a measurement of the cap.
    ///
    /// This sweeps the cap and reports the UNION ceiling — the fraction of
    /// queries where ANY arm surfaces the target anywhere. That number is
    /// the true wall: no fusion, reranker, or model can retrieve a chat
    /// that never entered a candidate list. If it climbs with depth, the
    /// fix is a constant. If it plateaus, the fix is coverage.
    func testCandidateDepthSweep() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_RECALL_EVAL"] == "1",
            "Set PIDGY_RUN_RECALL_EVAL=1 to run the recall eval."
        )
        let buckets = try Self.loadAllOracles()
        try XCTSkipIf(buckets.isEmpty, "No scorable oracle entries.")
        let summaryIndex = await Self.buildSummaryIndex()
        let depths = [50, 150, 400, 1200]
        var rows: [String] = []

        for depth in depths {
            var unionCeiling = 0
            var armCeiling: [String: Int] = [:]
            var recall20 = 0
            var recall30 = 0
            var pool = 0
            var total = 0
            let start = Date()

            for bucket in buckets {
                for entry in bucket.entries {
                    total += 1
                    let expected = entry.targets
                    let arms: [(String, [Int64])] = [
                        ("fts", Self.rank(await Self.ftsScores(entry.query, limit: depth))),
                        ("e5", Self.rank(await Self.vectorScores(entry.query, version: Self.e5Version, limit: depth))),
                        ("static", Self.rank(await Self.vectorScores(entry.query, version: Self.staticVersion, limit: depth))),
                        ("entity", await Self.entityArm(entry.query)),
                        ("summary", Self.rank(await Self.summaryScores(entry.query, index: summaryIndex)))
                    ]
                    for (name, list) in arms where list.contains(where: expected.contains) {
                        armCeiling[name, default: 0] += 1
                    }
                    let fused = Self.rrf(arms.map { $0.1 })
                    pool += fused.count
                    if fused.contains(where: expected.contains) { unionCeiling += 1 }
                    if fused.prefix(20).contains(where: expected.contains) { recall20 += 1 }
                    if fused.prefix(30).contains(where: expected.contains) { recall30 += 1 }
                }
            }

            func pct(_ x: Int) -> String {
                total == 0 ? "  -" : String(format: "%3d%%", Int((Double(x) / Double(total) * 100).rounded()))
            }
            let arms = ["fts", "e5", "static"].map { "\($0) \(pct(armCeiling[$0] ?? 0))" }.joined(separator: "  ")
            rows.append(
                "\(String(depth).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(pct(unionCeiling))\t\(pct(recall20))\t\(pct(recall30))\t"
                + "\(pool / max(total, 1))\t\(String(format: "%.0fs", Date().timeIntervalSince(start)))\t\(arms)"
            )
        }

        print("""

        ═══════ CANDIDATE-DEPTH SWEEP — is the wall real? ═══════
        entity ceiling is depth-invariant (facts are capped at 40 rows);
        summary ceiling is coverage-capped at \(summaryIndex.count) of 1282 chats.

        depth  union\trec@20\trec@30\tpool\ttime\tper-arm ceiling
        \(rows.joined(separator: "\n"))
        ═════════════════════════════════════════════════════════

        """)
        XCTAssertFalse(rows.isEmpty)
    }

    // MARK: - Arms

    /// Facts as a recall arm rather than a score contribution. `searchFacts`
    /// returns best-first, so rank position is the whole signal — which is
    /// exactly what RRF wants and what a weighted blend destroyed by having
    /// to invent a similarity number for it.
    private static func entityArm(_ query: String) async -> [Int64] {
        let facts = await DatabaseManager.shared.searchFacts(query: query, limit: 40)
        var seen = Set<Int64>()
        var ordered: [Int64] = []
        for fact in facts where seen.insert(fact.sourceChatId).inserted {
            ordered.append(fact.sourceChatId)
        }
        return ordered
    }

    private static func buildSummaryIndex() async -> [(chatId: Int64, vector: [Double])] {
        let summaries = await DatabaseManager.shared.currentChatSummariesForEval()
        var index: [(chatId: Int64, vector: [Double])] = []
        for summary in summaries {
            guard let vector = await EmbeddingService.shared.embed(
                text: summary.text, modelVersion: staticVersion, isQuery: false
            ) else { continue }
            index.append((summary.chatId, vector))
        }
        return index
    }

    private static func summaryScores(
        _ query: String, index: [(chatId: Int64, vector: [Double])]
    ) async -> [Int64: Double] {
        guard !index.isEmpty,
              let q = await EmbeddingService.shared.embed(
                  text: query, modelVersion: staticVersion, isQuery: true
              ) else { return [:] }
        var best: [Int64: Double] = [:]
        for entry in index {
            best[entry.chatId] = max(best[entry.chatId] ?? 0, cosine(q, entry.vector))
        }
        return best
    }

    private static func vectorScores(
        _ query: String, version: String, limit: Int = AppConstants.AI.SemanticSearch.vectorTopMessages
    ) async -> [Int64: Double] {
        guard let queryVector = await EmbeddingService.shared.embed(
            text: query, modelVersion: version, isQuery: true
        ) else { return [:] }
        let hits = await VectorStore.shared.search(
            query: queryVector, topK: limit, modelVersion: version
        )
        var best: [Int64: Double] = [:]
        for hit in hits { best[hit.chatId] = max(best[hit.chatId] ?? 0, hit.score) }
        return best
    }

    private static func ftsScores(
        _ query: String, limit: Int = AppConstants.AI.SemanticSearch.ftsTopMessages
    ) async -> [Int64: Double] {
        var best: [Int64: Double] = [:]
        for expression in buildFTSVariants(rawQuery: query) {
            let hits = await DatabaseManager.shared.localSearchFTSRaw(
                rawFTSQuery: expression, limit: limit
            )
            guard let top = hits.map(\.score).max(), top > 0 else { continue }
            for hit in hits {
                best[hit.message.chatId] = max(best[hit.message.chatId] ?? 0, hit.score / top)
            }
        }
        return best
    }

    // MARK: - Combiners

    /// Reciprocal-rank fusion over already-ranked arms. Nil arms are
    /// skipped so a config can be written declaratively.
    private static func rrf(_ lists: [[Int64]?]) -> [Int64] {
        var score: [Int64: Double] = [:]
        for list in lists.compactMap({ $0 }) {
            for (rank, id) in list.enumerated() {
                score[id, default: 0] += 1.0 / (rrfK + Double(rank))
            }
        }
        return rank(score)
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

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: - Fixtures

    /// Recall is only meaningful against the size of the field it is drawn
    /// from — @20 out of 30 chats would be a different claim than @20 out
    /// of a thousand.
    private static func chatUniverseSize() async -> Int {
        await DatabaseManager.shared.chatCountWithMessagesForEval()
    }

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
