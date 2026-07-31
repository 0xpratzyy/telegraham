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
//  This runs LABELLED cases — real transcripts, hand-checked expectations —
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

    /// Every case below is a REAL window from the developer's own chats that
    /// the current prompt got right or wrong on 2026-07-25. Names are kept as
    /// they appear so failures are recognisable.
    private static let cases: [EvalCase] = [
        EvalCase(
            name: "subject/named-person-not-unknown",
            messages: [
                ("Ahaan", "can you review the deck once before I send it to the investor", false),
                ("[ME]", "sure send it over", true)
            ],
            chatTitle: "Ahaan Raizada | Brainstorm",
            isGroup: false,
            expected: [(.iOwe, "Ahaan")],
            why: "Subject must be the real counterparty — live data still had 7 loops with subject Unknown/me."
        ),
        EvalCase(
            name: "they-ask-me/rahul-git-link",
            messages: [
                ("Rahul", "git bheja?", false),
                ("[ME]", "😆", true),
                ("Rahul", "bhejo bhai", false),
                ("Rahul", "kidahr", false)
            ],
            chatTitle: "Rahul Singh Bhadoriya",
            isGroup: false,
            expected: [(.iOwe, "Rahul")],
            why: "THEY ask ME to send → i_owe. Shipped prompt produced owes_me (inverted)."
        ),
        EvalCase(
            name: "they-ask-me/yj-support-from-fd",
            messages: [
                ("YJ", "hey bro, we recently announced our flagship partnership with venice", false),
                ("YJ", "would appreciate if u can support over it personally and from FD as well if possible  would mean a lot.", false),
                ("[ME]", "did from personal", true)
            ],
            chatTitle: "YJ ( / Acc )",
            isGroup: false,
            expected: [(.iOwe, "YJ")],
            why: "THEY ask ME for support → i_owe. Shipped prompt produced owes_me (inverted)."
        ),
        EvalCase(
            name: "they-promise/arghya-will-confirm",
            messages: [
                ("[ME]", "@0xArghya any plans on running this as campaign? Can get good traction on the post and in general about myrad", true),
                ("Arghya", "thanks a lot", false),
                ("Arghya", "had some plans but ill confirm once this week ends hopefully cuz this week we got the partnership and some crucial updates lined up", false),
                ("[ME]", "Yes aligned  Will check back next week", true)
            ],
            chatTitle: "Myrad <> First Dollar",
            isGroup: true,
            expected: [(.owesMe, "Arghya")],
            why: "THEY promise to confirm → owes_me, subject THEM. Shipped prompt used the USER as subject."
        ),
        EvalCase(
            name: "i-promise/aditya-proposal",
            messages: [
                ("[ME]", "@adityakiteapp nice talking to you, will share the proposal by eod", true),
                ("Aditya", "Adding my team here as well", false)
            ],
            chatTitle: "First Dollar <> Kite",
            isGroup: true,
            expected: [(.iOwe, "Aditya")],
            why: "[ME] promises; the @handle is only the addressee → i_owe."
        ),
        EvalCase(
            name: "i-request/daya-check-dm",
            messages: [
                ("[ME]", "Hey @dayadzn check dm whenever you can", true),
                ("Daya", "sure", false)
            ],
            chatTitle: "Inner Circle",
            isGroup: true,
            expected: [(.owesMe, "Daya")],
            why: "[ME] asks THEM to act → owes_me (the mirror of the case above)."
        ),
        EvalCase(
            name: "settled-in-window/aditya-calendar-link",
            messages: [
                ("[ME]", "Hey Aditya, saw you posted in Inner Circle that you are building", true),
                ("Aditya", "Sure happy to share my calendar link here shortly", false),
                ("[ME]", "Perfect", true),
                ("Aditya", "https://calendar.app.google/TRRuEnymP8WX7tTs6", false),
                ("[ME]", "booked a slot for tomorrow 2:30 IST", true),
                ("Aditya", "Okay", false)
            ],
            chatTitle: "Aditya Chintawar | Kite",
            isGroup: false,
            expected: [],
            why: "The link IS delivered two lines later — a loop born here could never close, so emit none."
        ),
        EvalCase(
            name: "not-settled/ahaan-frog-reply",
            messages: [
                ("[ME]", "Bhai intro BD message update kaar dena", true),
                ("Ahaan", "ill pen it", false),
                ("Ahaan", "🐸", false)
            ],
            chatTitle: "Ahaan Raizada | Brainstorm",
            isGroup: false,
            expected: [(.owesMe, "Ahaan")],
            why: "Conversation continuing (an emoji) is NOT delivery — the loop stays open."
        ),
        EvalCase(
            name: "they-report-gap/akhil-invoice",
            messages: [
                ("[ME]", "Bro I think you never sent invoice for this", true),
                ("Akhil", "ohh let me check", false)
            ],
            chatTitle: "Akhil B",
            isGroup: false,
            expected: [(.owesMe, "Akhil")],
            why: "[ME] points out THEY never sent it → owes_me even though [ME] spoke."
        ),
        EvalCase(
            name: "kind/reply-not-action",
            messages: [
                ("Isha", "hey are we doing the bounty in USDC or INR?", false),
                ("[ME]", "let me think", true)
            ],
            chatTitle: "Isha Parekh",
            isGroup: false,
            expected: [(.iOwe, "Isha")],
            expectedKind: .reply,
            why: "A question one message answers is REPLY kind. Live data pushed almost everything to action (On me had 3 of 59)."
        ),
        EvalCase(
            name: "kind/action-not-reply",
            messages: [
                ("Tushar", "bhai edit kar ke reels bhej dena gym ke posts ke liye", false),
                ("[ME]", "haan karta hoon", true)
            ],
            chatTitle: "Tushar",
            isGroup: false,
            expected: [(.iOwe, "Tushar")],
            expectedKind: .action,
            why: "Editing + sending files is real work → ACTION kind, belongs in Tasks not the Reply queue."
        ),
        EvalCase(
            name: "banter/no-loop",
            messages: [
                ("Tushar", "haha that was wild", false),
                ("[ME]", "ikr 😂", true),
                ("Tushar", "ok", false)
            ],
            chatTitle: "Tushar",
            isGroup: false,
            expected: [],
            why: "Pure banter must produce nothing — guards against loop inflation."
        )
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
        let chat = TGChat(
            id: -999, title: c.chatTitle,
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
        let result = try await aiService.extractFacts(
            chat: chat,
            newMessages: messages,
            contextMessages: [],
            openLoops: [],
            myUserId: 1,
            myUser: TGUser(
                id: 1, firstName: "Pratyush", lastName: "", username: "pratzyy",
                phoneNumber: nil, isBot: false, smallPhotoFileId: nil
            )
        )
        let loops = result.drafts.filter { $0.predicate.isOpenLoop }

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
        let shown = loops.map { l -> String in
            let kind = l.loopKind.map { "·\($0.rawValue)" } ?? ""
            return "\(l.predicate.rawValue)\(kind)/\(l.subjectEntity)"
        }
        return (shown, ok)
    }

    private static func describe(_ expected: [(FactPredicate, String)], kind: LoopKind?) -> String {
        guard !expected.isEmpty else { return "(nothing)" }
        let k = kind.map { "·\($0.rawValue)" } ?? ""
        return expected.map { "\($0.0.rawValue)\(k)/\($0.1)" }.joined(separator: ", ")
    }
}
