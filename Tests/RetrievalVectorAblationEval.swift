//
//  RetrievalVectorAblationEval.swift
//  Pidgy — does the on-device embedding model earn its keep?
//
//  The e5 model is the single most expensive thing in the app: measured
//  2026-07-26 on a live install, ~2.2 GB of heap
//  (MetalPerformanceShadersGraph + sentencepiece) plus ~0.5 GB of GPU
//  IOSurfaces while loaded, 25-40% CPU for the duration of an indexing
//  pass, a model download, and a whole dependency. It buys 40% of the
//  ranking score in semantic search (`vectorWeight`).
//
//  Nobody has ever measured whether that 40% actually finds anything FTS
//  misses. This does: it replays the labelled topic-search oracle against
//  the LIVE local database twice — once with the shipped fusion weights,
//  once with the vector half zeroed — and reports recall for both.
//
//  Read the result honestly: it measures the RETRIEVAL SIGNAL (does the
//  right chat surface at all), not the full production ranking, which also
//  applies title weight, coverage bonuses, a topic guard and an optional
//  AI rerank. A tie here means the vectors are not pulling their weight in
//  the part of the pipeline they exist for.
//
//  Run:
//    TEST_RUNNER_PIDGY_RUN_RETRIEVAL_EVAL=1 xcodebuild test \
//      -project Pidgy.xcodeproj -scheme Pidgy -destination 'platform=macOS' \
//      -only-testing:PidgyTests/RetrievalVectorAblationEval
//

import XCTest
@testable import Pidgy

final class RetrievalVectorAblationEval: XCTestCase {

    private struct OracleEntry: Decodable {
        let id: String
        let query: String
        let expectedKind: String
        let expectedChatIds: [Int64]?
    }

    private struct Oracle: Decodable {
        let name: String
        let entries: [OracleEntry]
    }

    /// How deep a hit still counts. The launcher shows a handful of chats,
    /// so "did it surface at all" is top-5, and top-1 is the sharper signal.
    private static let topN = 5

    func testVectorsVersusFTSOnly() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_RETRIEVAL_EVAL"] == "1",
            "Set PIDGY_RUN_RETRIEVAL_EVAL=1 to run the live-DB retrieval ablation."
        )
        let oracle = try Self.loadOracle()
        let entries = oracle.entries.filter { $0.expectedKind == "hit" && !($0.expectedChatIds ?? []).isEmpty }
        try XCTSkipIf(entries.isEmpty, "Oracle has no scorable hit entries.")

        // The eval reads the developer's own indexed database. Skip cleanly
        // when it isn't there (CI, fresh clone) instead of scoring zeros.
        let probe = await DatabaseManager.shared.localSearchFTSRaw(rawFTSQuery: "the OR a OR hai", limit: 5)
        try XCTSkipIf(probe.isEmpty, "No local indexed messages — nothing to retrieve against.")

        var fusedTop1 = 0, fusedTopN = 0
        var ftsTop1 = 0, ftsTopN = 0
        var vectorOnlyRescues: [String] = []
        var lines: [String] = []

        for entry in entries {
            let expected = Set(entry.expectedChatIds ?? [])
            let fused = await Self.rankedChatIds(for: entry.query, vectorWeight: AppConstants.AI.SemanticSearch.vectorWeight)
            let ftsOnly = await Self.rankedChatIds(for: entry.query, vectorWeight: 0)

            let fHit1 = fused.first.map(expected.contains) ?? false
            let fHitN = fused.prefix(Self.topN).contains(where: expected.contains)
            let tHit1 = ftsOnly.first.map(expected.contains) ?? false
            let tHitN = ftsOnly.prefix(Self.topN).contains(where: expected.contains)

            if fHit1 { fusedTop1 += 1 }
            if fHitN { fusedTopN += 1 }
            if tHit1 { ftsTop1 += 1 }
            if tHitN { ftsTopN += 1 }
            // The whole question in one number: queries the vectors RESCUE.
            if fHitN && !tHitN { vectorOnlyRescues.append(entry.id) }

            lines.append(
                "\(fHitN ? "✅" : "❌")fused \(tHitN ? "✅" : "❌")fts-only  \(entry.id): \(entry.query.prefix(52))"
            )
        }

        let n = entries.count
        func pct(_ x: Int) -> String { "\(Int((Double(x) / Double(n) * 100).rounded()))%" }

        print("""

        ═════════════ RETRIEVAL: VECTORS vs FTS-ONLY ═════════════
        \(lines.joined(separator: "\n"))
        ──────────────────────────────────────────────────────────
        queries: \(n)   (top-\(Self.topN) = surfaced at all, top-1 = ranked first)

                        top-1        top-\(Self.topN)
        WITH vectors    \(pct(fusedTop1))          \(pct(fusedTopN))
        FTS only        \(pct(ftsTop1))          \(pct(ftsTopN))

        QUERIES ONLY VECTORS FOUND: \(vectorOnlyRescues.isEmpty ? "none" : vectorOnlyRescues.joined(separator: ", "))
        → none, and identical scores, means the model's 2.7 GB buys nothing here.
        ══════════════════════════════════════════════════════════

        """)

        XCTAssertGreaterThan(n, 0)
    }

    // MARK: - Retrieval under a chosen vector weight

    /// Chat ids ranked by the same fusion the launcher uses for the message
    /// signal: FTS score and vector score blended by weight. Title matching,
    /// coverage bonuses and the AI rerank are deliberately NOT replicated —
    /// this isolates the question the model exists to answer.
    private static func rankedChatIds(for query: String, vectorWeight: Double) async -> [Int64] {
        let ftsWeight = AppConstants.AI.SemanticSearch.ftsWeight
        var scoreByChat: [Int64: Double] = [:]

        // Same graduated variants production runs, best-scoring variant per
        // chat (production fuses them by RRF; for "did the chat surface at
        // all" the max is equivalent and keeps this harness honest-simple).
        var bestFTSByChat: [Int64: Double] = [:]
        for expression in buildFTSVariants(rawQuery: query) {
            let hits = await DatabaseManager.shared.localSearchFTSRaw(
                rawFTSQuery: expression,
                limit: AppConstants.AI.SemanticSearch.ftsTopMessages
            )
            let best = hits.map(\.score).max() ?? 0
            guard best > 0 else { continue }
            for hit in hits {
                let normalized = hit.score / best
                bestFTSByChat[hit.message.chatId] = max(bestFTSByChat[hit.message.chatId] ?? 0, normalized)
            }
        }
        for (chatId, score) in bestFTSByChat {
            scoreByChat[chatId, default: 0] += score * ftsWeight
        }

        if vectorWeight > 0 {
            let vectorHits = await VectorStore.shared.searchText(
                query, topK: AppConstants.AI.SemanticSearch.vectorTopMessages
            )
            for hit in vectorHits {
                scoreByChat[hit.chatId, default: 0] += hit.score * vectorWeight
            }
        }

        return scoreByChat
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    private static func loadOracle() throws -> Oracle {
        // Walk up from this file to the repo root so the eval doesn't depend
        // on the test bundle carrying resources.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("evals/topic_search_oracle_v2.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: candidate))
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("evals/topic_search_oracle_v2.json not found")
    }
}
