//
//  FactExtractionEval.swift
//  Pidgy — extraction accuracy eval (env-gated, makes REAL AI calls)
//
//  Why this exists: every extraction-prompt change until now was judged by
//  eyeballing the live DB, and the live DB is the wrong instrument. Re-running
//  the SAME messages swung the fact count 100→152 (±20%) purely from sampling,
//  so a prompt edit's effect was indistinguishable from noise, and a count of
//  "loops that have a later inbound message" turned out to mostly flag loops
//  that were legitimately open. Both mistakes are on record (2026-07-25).
//
//  This runs LABELLED cases — synthetic transcripts, hand-checked expectations —
//  through the REAL prompt builder and the REAL parser, N times each, and
//  reports per-case match plus a total % match. That is the only signal a
//  prompt change should ever be judged on.
//
//  Run:
//    PIDGY_RUN_EXTRACTION_EVAL=1 xcodebuild test -project Pidgy.xcodeproj \
//      -scheme Pidgy -destination 'platform=macOS' \
//      -only-testing:PidgyTests/FactExtractionEval
//
//  Needs a configured provider (managed proxy or BYOK key) — it is skipped
//  otherwise, so CI stays offline.
//

import XCTest
@testable import Pidgy

/// One labelled window. `expected` is what a careful human says the loops are.
private struct EvalCase {
    let name: String
    /// (senderFirstName, text, isOutgoing) — [ME] is substituted for outgoing.
    let messages: [(String, String, Bool)]
    let chatTitle: String
    let isGroup: Bool
    /// Expected open loops as (predicate, subjectContains). Empty = the model
    /// must emit NO open loop for this window.
    let expected: [(FactPredicate, String)]
    /// Set only on cases that exist to pin the Reply-queue/Tasks split.
    /// nil = don't score kind (most cases care only about direction).
    var expectedKind: LoopKind? = nil
    /// What makes this case interesting — printed on failure.
    let why: String
}

final class FactExtractionEval: XCTestCase {

    /// Manual cost/quality/latency A/B for the production extraction shape.
    ///
    /// Bulk sends the complete labelled conversation in one paid call.
    /// Separate mirrors the live micro-batch path: one new message per call,
    /// up to eight already-processed context messages, and carried open loops.
    /// A unique title marker keeps the paid calls out of the exact-response
    /// cache and makes their usage traces independently attributable.
    func testBulkVersusSeparateExtractionBenchmark() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_BATCH_BENCH"] == "1"
                || FileManager.default.fileExists(atPath: "/tmp/pidgy-run-batch-bench"),
            "Set PIDGY_RUN_BATCH_BENCH=1 to run the paid bulk-vs-separate benchmark."
        )
        let aiService = await AIService()
        guard await aiService.isConfigured else {
            throw XCTSkip("No AI provider configured — benchmark needs managed AI or a BYOK key.")
        }

        let markerFile = "/tmp/pidgy-run-batch-bench"
        let requestedMarker = (try? String(contentsOfFile: markerFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = requestedMarker?.hasPrefix("BatchBench-") == true
            ? requestedMarker!
            : "BatchBench-\(UUID().uuidString.prefix(8))"
        print("BATCH_BENCH_MARKER=\(marker)")

        let bulkStarted = Date()
        var bulkRows: [(name: String, produced: [String], ok: Bool)] = []
        var bulkErrors = 0
        for c in Self.cases {
            do {
                let outcome = try await evaluateBulk(c, marker: marker, using: aiService)
                bulkRows.append((c.name, outcome.produced, outcome.ok))
            } catch {
                bulkErrors += 1
                print("BATCH_BENCH_ERROR mode=bulk case=\(c.name) error=\(error)")
            }
        }
        let bulkElapsed = Date().timeIntervalSince(bulkStarted)

        let separateStarted = Date()
        var separateRows: [(name: String, produced: [String], ok: Bool)] = []
        var separateErrors = 0
        var separateCalls = 0
        for c in Self.cases {
            do {
                let outcome = try await evaluateSeparate(c, marker: marker, using: aiService)
                separateRows.append((c.name, outcome.produced, outcome.ok))
                separateCalls += c.messages.count
            } catch {
                separateErrors += 1
                print("BATCH_BENCH_ERROR mode=separate case=\(c.name) error=\(error)")
            }
        }
        let separateElapsed = Date().timeIntervalSince(separateStarted)

        let bulkPassed = bulkRows.filter(\.ok).count
        let separatePassed = separateRows.filter(\.ok).count
        for c in Self.cases {
            let bulk = bulkRows.first { $0.name == c.name }
            let separate = separateRows.first { $0.name == c.name }
            print(
                "BATCH_BENCH_CASE name=\(c.name) "
                + "bulk=\(bulk?.ok == true ? "pass" : "fail") "
                + "separate=\(separate?.ok == true ? "pass" : "fail")\n"
                + "  bulk_output=\(bulk?.produced.joined(separator: ", ") ?? "ERROR")\n"
                + "  separate_output=\(separate?.produced.joined(separator: ", ") ?? "ERROR")\n"
                + "  expected=\(Self.describe(c.expected, kind: c.expectedKind))"
            )
        }
        print("""

        BATCH_BENCH_SUMMARY marker=\(marker)
        bulk_cases=\(bulkRows.count) bulk_calls=\(Self.cases.count) bulk_passed=\(bulkPassed) bulk_errors=\(bulkErrors) bulk_elapsed_s=\(String(format: "%.3f", bulkElapsed))
        separate_cases=\(separateRows.count) separate_calls=\(separateCalls) separate_passed=\(separatePassed) separate_errors=\(separateErrors) separate_elapsed_s=\(String(format: "%.3f", separateElapsed))

        """)

        XCTAssertGreaterThan(bulkRows.count + separateRows.count, 0)
    }

    // Synthetic conversations preserve the direction/settlement regression cases.
    private static let cases: [EvalCase] = [
        EvalCase(name: "they-ask-me/send-file", messages: [
            ("Morgan", "Can you send the demo slide deck?", false),
            ("[ME]", "Yes, I will prepare it this afternoon.", true)
        ], chatTitle: "Morgan", isGroup: false, expected: [(.iOwe, "Morgan")],
        why: "A request to the user is i_owe."),
        EvalCase(name: "they-ask-me/support", messages: [
            ("Taylor", "Could you share our fictional demo announcement from the team account?", false),
            ("[ME]", "I shared it from my personal account so far.", true)
        ], chatTitle: "Taylor", isGroup: false, expected: [(.iOwe, "Taylor")],
        why: "Personal sharing does not settle the team-account request."),
        EvalCase(name: "they-promise/confirm", messages: [
            ("[ME]", "Can you confirm the demo date?", true),
            ("Casey", "I will confirm at the end of this week.", false)
        ], chatTitle: "Demo planning", isGroup: true, expected: [(.owesMe, "Casey")],
        why: "Their commitment is owes_me with them as subject."),
        EvalCase(name: "i-promise/proposal", messages: [
            ("[ME]", "@demo_alex I'll share the fictional proposal by end of day.", true),
            ("Alex", "Thanks, I added the demo team.", false)
        ], chatTitle: "Demo team", isGroup: true, expected: [(.iOwe, "Alex")],
        why: "The handle is an addressee; the user makes the promise."),
        EvalCase(name: "i-request/check-dm", messages: [
            ("[ME]", "Diana, please check the demo document in your DM.", true),
            ("Diana", "Sure, I will check it tonight.", false)
        ], chatTitle: "Demo group", isGroup: true, expected: [(.owesMe, "Diana")],
        why: "The user requests an action from someone else."),
        EvalCase(name: "settled/calendar", messages: [
            ("[ME]", "Can you share the demo calendar link?", true),
            ("Alex", "I will send it shortly.", false),
            ("Alex", "https://example.com/demo-calendar", false),
            ("[ME]", "Booked the demo slot, thanks.", true)
        ], chatTitle: "Alex", isGroup: false, expected: [],
        why: "Delivery settles the commitment within this window."),
        EvalCase(name: "not-settled/emoji", messages: [
            ("[ME]", "Please revise the demo intro message.", true),
            ("Robin", "I will draft it.", false), ("Robin", "🐸", false)
        ], chatTitle: "Robin", isGroup: false, expected: [(.owesMe, "Robin")],
        why: "An emoji is not delivery of the promised work."),
        EvalCase(name: "kind/reply", messages: [
            ("Diana", "What color should the fictional demo banner be?", false),
            ("[ME]", "Let me think.", true)
        ], chatTitle: "Diana", isGroup: false, expected: [(.iOwe, "Diana")], expectedKind: .reply,
        why: "A question answered by one message is reply kind."),
        EvalCase(name: "kind/action", messages: [
            ("Morgan", "Please edit and send the sample demo video.", false),
            ("[ME]", "Yes, I will do it tomorrow.", true)
        ], chatTitle: "Morgan", isGroup: false, expected: [(.iOwe, "Morgan")], expectedKind: .action,
        why: "Editing and delivering a file requires action."),
        EvalCase(name: "banter/no-loop", messages: [
            ("Casey", "That fictional demo was funny!", false),
            ("[ME]", "Haha 😂", true), ("Casey", "Yep", false)
        ], chatTitle: "Casey", isGroup: false, expected: [], why: "Banter has no commitment.")
    ]

    /// Runs per case. >1 also measures determinism: with temperature pinned
    /// the same window must score identically every time.
    private static let runsPerCase = 3

    func testExtractionAccuracyAgainstLabelledCases() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PIDGY_RUN_EXTRACTION_EVAL"] == "1",
            "Set PIDGY_RUN_EXTRACTION_EVAL=1 to run the live-AI extraction eval."
        )
        let aiService = await AIService()
        guard await aiService.isConfigured else {
            throw XCTSkip("No AI provider configured — eval needs the managed proxy or a BYOK key.")
        }

        var totalChecks = 0
        var passedChecks = 0
        var lines: [String] = []
        var perCaseOutcomes: [String: [Bool]] = [:]

        var transportErrors = 0
        for c in Self.cases {
            for run in 1...Self.runsPerCase {
                // One flaky network call must not destroy a whole run's signal
                // (a single timeout used to abort all 36 checks). Retry once,
                // then record the case as an error and carry on.
                var attempt: ([String], Bool)?
                for tryIndex in 0..<3 {
                    // Pace the calls. Firing ~36 extractions back-to-back
                    // saturates the provider's per-minute pool, and because
                    // the sequence is deterministic the SAME case landed in
                    // the throttled window on consecutive runs (it read as a
                    // flaky network, it was really self-inflicted load).
                    try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (tryIndex + 1)))
                    do {
                        attempt = try await evaluate(c, using: aiService)
                        break
                    } catch {
                        continue
                    }
                }
                guard let (produced, ok) = attempt else {
                    transportErrors += 1
                    lines.append("⚠️ \(c.name) [run \(run)] — transport error, not counted")
                    continue
                }
                totalChecks += 1
                if ok { passedChecks += 1 }
                perCaseOutcomes[c.name, default: []].append(ok)
                lines.append(
                    "\(ok ? "✅" : "❌") \(c.name) [run \(run)]\n"
                    + "    AI SAID : \(produced.isEmpty ? "(nothing)" : produced.joined(separator: ", "))\n"
                    + "    EXPECTED: \(Self.describe(c.expected, kind: c.expectedKind))"
                    + (ok ? "" : "\n    WHY     : \(c.why)")
                )
            }
        }

        let pct = totalChecks == 0 ? 0 : Int((Double(passedChecks) / Double(totalChecks) * 100).rounded())
        let flaky = perCaseOutcomes.filter { Set($0.value).count > 1 }.keys.sorted()

        print("""

        ═══════════════ EXTRACTION EVAL ═══════════════
        \(lines.joined(separator: "\n"))
        ───────────────────────────────────────────────
        MATCH: \(passedChecks)/\(totalChecks) = \(pct)%
        NON-DETERMINISTIC CASES: \(flaky.isEmpty ? "none (temperature is pinned)" : flaky.joined(separator: ", "))
        TRANSPORT ERRORS (excluded): \(transportErrors)
        ═══════════════════════════════════════════════

        """)

        // Not an assertion on a target number — the eval's job is to REPORT.
        // Failing the build on a live-AI score would make the suite flaky and
        // hide the number, which is the only thing worth having.
        XCTAssertGreaterThan(totalChecks, 0)
    }

    // MARK: - Harness

    /// Runs one case through the real prompt + real parser. Returns the loops
    /// the model produced (as readable strings) and whether they match the label.
    private func evaluate(_ c: EvalCase, using aiService: AIService) async throws -> ([String], Bool) {
        let (chat, messages) = Self.makeConversation(c, title: c.chatTitle)
        let result = try await benchmarkExtract {
            try await aiService.extractFacts(
                chat: chat,
                newMessages: messages,
                contextMessages: [],
                openLoops: [],
                myUserId: 1,
                myUser: Self.benchmarkUser
            )
        }
        let loops = result.drafts.filter { $0.predicate.isOpenLoop }
        return (Self.describe(loops), Self.matches(loops, expectedBy: c))
    }

    private func evaluateBulk(
        _ c: EvalCase,
        marker: String,
        using aiService: AIService
    ) async throws -> (produced: [String], ok: Bool) {
        let (chat, messages) = Self.makeConversation(c, title: "\(c.chatTitle) [\(marker)]")
        let result = try await aiService.extractFacts(
            chat: chat,
            newMessages: messages,
            contextMessages: [],
            openLoops: [],
            myUserId: 1,
            myUser: Self.benchmarkUser
        )
        let loops = result.drafts.filter { $0.predicate.isOpenLoop }
        return (Self.describe(loops), Self.matches(loops, expectedBy: c))
    }

    private func evaluateSeparate(
        _ c: EvalCase,
        marker: String,
        using aiService: AIService
    ) async throws -> (produced: [String], ok: Bool) {
        let (chat, messages) = Self.makeConversation(c, title: "\(c.chatTitle) [\(marker)]")
        var openLoops: [Fact] = []

        for index in messages.indices {
            let contextStart = max(messages.startIndex, index - 8)
            let context = Array(messages[contextStart..<index])
            let result = try await benchmarkExtract {
                try await aiService.extractFacts(
                    chat: chat,
                    newMessages: [messages[index]],
                    contextMessages: context,
                    openLoops: openLoops,
                    myUserId: 1,
                    myUser: Self.benchmarkUser
                )
            }
            let resolved = Set(result.resolvedFingerprints)
            openLoops.removeAll { resolved.contains($0.fingerprint) }
            for draft in result.drafts where draft.predicate.isOpenLoop {
                let fact = Self.fact(from: draft, id: Int64(openLoops.count + 1))
                if let existing = openLoops.firstIndex(where: { $0.fingerprint == fact.fingerprint }) {
                    openLoops[existing] = fact
                } else {
                    openLoops.append(fact)
                }
            }
        }

        let drafts = openLoops.map(Self.draft(from:))
        return (Self.describe(drafts), Self.matches(drafts, expectedBy: c))
    }

    /// The managed provider already performs a short in-request backoff. This
    /// outer benchmark pacing avoids turning the measurement itself into a
    /// burst-load test, then gives a depleted quota window time to recover.
    private func benchmarkExtract(
        operation: () async throws -> FactExtractionResult
    ) async throws -> FactExtractionResult {
        try await Task.sleep(nanoseconds: 6_000_000_000)
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                return try await operation()
            } catch AIError.rateLimited(let retryAfter) {
                lastError = AIError.rateLimited(retryAfter: retryAfter)
                let delay = retryAfter ?? Double(20 * (attempt + 1))
                print("BATCH_BENCH_RATE_LIMIT attempt=\(attempt + 1) sleep_s=\(Int(delay))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw error
            }
        }
        throw lastError ?? AIError.rateLimited(retryAfter: nil)
    }

    private static var benchmarkUser: TGUser {
        TGUser(
            id: 1, firstName: "Sam", lastName: "", username: "pratzyy",
            phoneNumber: nil, isBot: false, smallPhotoFileId: nil
        )
    }

    private static func makeConversation(_ c: EvalCase, title: String) -> (TGChat, [TGMessage]) {
        let chat = TGChat(
            id: -999, title: title,
            chatType: c.isGroup ? .supergroup(supergroupId: 999, isChannel: false) : .privateChat(userId: 999),
            unreadCount: 0, lastMessage: nil,
            memberCount: c.isGroup ? 8 : nil, order: 1, isInMainList: true, smallPhotoFileId: nil
        )
        let base = Date().addingTimeInterval(-3600)
        let messages: [TGMessage] = c.messages.enumerated().map { i, m in
            TGMessage(
                id: Int64(1000 + i),
                chatId: chat.id,
                senderId: m.2 ? .user(1) : .user(999),
                date: base.addingTimeInterval(Double(i) * 60),
                textContent: m.1,
                mediaType: nil,
                isOutgoing: m.2,
                chatTitle: c.chatTitle,
                senderName: m.2 ? "Me" : m.0
            )
        }
        return (chat, messages)
    }

    private static func fact(from draft: FactDraft, id: Int64) -> Fact {
        Fact(
            id: id,
            subjectEntity: draft.subjectEntity,
            subjectPersonId: draft.subjectPersonId,
            predicate: draft.predicate,
            objectText: draft.objectText,
            action: draft.action,
            loopKind: draft.loopKind,
            objectEntity: draft.objectEntity,
            confidence: draft.confidence,
            validFrom: draft.validFrom,
            invalidAt: nil,
            closeReason: nil,
            sourceChatId: draft.sourceChatId,
            sourceChatTitle: draft.sourceChatTitle,
            sourceMessageId: draft.sourceMessageId,
            sourceText: draft.sourceText,
            senderName: draft.senderName,
            fingerprint: draft.fingerprint,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private static func draft(from fact: Fact) -> FactDraft {
        FactDraft(
            subjectEntity: fact.subjectEntity,
            subjectPersonId: fact.subjectPersonId,
            predicate: fact.predicate,
            objectText: fact.objectText,
            action: fact.action,
            loopKind: fact.loopKind,
            objectEntity: fact.objectEntity,
            confidence: fact.confidence,
            validFrom: fact.validFrom,
            sourceChatId: fact.sourceChatId,
            sourceChatTitle: fact.sourceChatTitle,
            sourceMessageId: fact.sourceMessageId,
            sourceText: fact.sourceText,
            senderName: fact.senderName
        )
    }

    private static func matches(_ loops: [FactDraft], expectedBy c: EvalCase) -> Bool {
        // Match = same number of open loops, and each expected (predicate,
        // subject) has a counterpart. Object wording is deliberately NOT
        // compared: phrasing varies harmlessly, direction and person do not.
        var ok = loops.count == c.expected.count
        if ok {
            for (predicate, subjectNeedle) in c.expected {
                let hit = loops.contains {
                    $0.predicate == predicate
                        && $0.subjectEntity.localizedCaseInsensitiveContains(subjectNeedle)
                }
                if !hit { ok = false; break }
            }
        }
        // Kind is scored only where the case exists to pin it, so a harmless
        // reply/action wobble doesn't mask a direction regression elsewhere.
        if ok, let expectedKind = c.expectedKind {
            ok = loops.allSatisfy { $0.loopKind == expectedKind }
        }
        return ok
    }

    private static func describe(_ loops: [FactDraft]) -> [String] {
        loops.map { l -> String in
            let kind = l.loopKind.map { "·\($0.rawValue)" } ?? ""
            return "\(l.predicate.rawValue)\(kind)/\(l.subjectEntity)"
        }
    }

    private static func describe(_ expected: [(FactPredicate, String)], kind: LoopKind?) -> String {
        guard !expected.isEmpty else { return "(nothing)" }
        let k = kind.map { "·\($0.rawValue)" } ?? ""
        return expected.map { "\($0.0.rawValue)\(k)/\($0.1)" }.joined(separator: ", ")
    }
}
