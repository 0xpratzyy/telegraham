//
//  FactExtraction.swift
//  Pidgy — #48 context layer
//
//  The fold: given a chat's NEW messages + its currently-open loops, the model
//  returns new facts to add and which open loops the new messages just closed.
//  Runs through the existing `summarize(messages:prompt:)` provider escape hatch
//  (every provider implements it): instructions + open loops go in the system
//  prompt, the transcript is the rendered messages, and we parse the JSON reply.
//

import Foundation

// MARK: - Wire DTOs

struct FactDTO: Codable {
    let subject: String
    let predicate: String
    let object: String
    let action: String?
    let kind: String?          // i_owe loops only: "reply" vs "action"
    let sourceMsg: Int?        // the [N] of the transcript message this loop is about
    let confidence: Double?
    let evidence: String?

    enum CodingKeys: String, CodingKey { case subject, predicate, object, action, kind, sourceMsg, confidence, evidence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        predicate = (try? c.decode(String.self, forKey: .predicate)) ?? ""
        object = (try? c.decode(String.self, forKey: .object)) ?? ""
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        if let i = try? c.decodeIfPresent(Int.self, forKey: .sourceMsg) {
            sourceMsg = i
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .sourceMsg) {
            sourceMsg = Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[]# ")))
        } else {
            sourceMsg = nil
        }
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        evidence = try? c.decodeIfPresent(String.self, forKey: .evidence)
    }
}

/// A follow-up ping on an open loop ("any update?", "wen free tonight?") —
/// the loop's OPEN LOOPS number + the transcript [N] of the chasing message.
struct ChasedLoopDTO: Codable {
    let loop: Int?
    let sourceMsg: Int?

    enum CodingKeys: String, CodingKey { case loop, sourceMsg }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func lenientInt(_ key: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) {
                return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[]# ")))
            }
            return nil
        }
        loop = lenientInt(.loop)
        sourceMsg = lenientInt(.sourceMsg)
    }
}

struct FactExtractionDTO: Codable {
    let facts: [FactDTO]?
    let resolvedLoops: [Int]?
    let chasedLoops: [ChasedLoopDTO]?

    enum CodingKeys: String, CodingKey { case facts, resolvedLoops, chasedLoops }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = try? c.decodeIfPresent([FactDTO].self, forKey: .facts)
        if let ints = try? c.decodeIfPresent([Int].self, forKey: .resolvedLoops) {
            resolvedLoops = ints
        } else if let strs = try? c.decodeIfPresent([String].self, forKey: .resolvedLoops) {
            resolvedLoops = strs.compactMap(Int.init)
        } else {
            resolvedLoops = nil
        }
        chasedLoops = try? c.decodeIfPresent([ChasedLoopDTO].self, forKey: .chasedLoops)
    }
}

/// A resolved chase: re-anchor this open loop onto its latest follow-up ping —
/// rank date, evidence text, and deep link all move to the chase message.
struct ChasedLoopUpdate: Equatable, Sendable {
    var fingerprint: String
    var sourceMessageId: Int64
    var sourceText: String
    var date: Date
}

/// What the coordinator applies to the store: new facts + loops to close +
/// loops to bump onto their latest chase.
struct FactExtractionResult: Sendable {
    var drafts: [FactDraft]
    var resolvedFingerprints: [String]
    var chasedLoops: [ChasedLoopUpdate] = []
}

/// Wire DTO for the one-time loop_kind backfill (classify existing i_owe loops).
struct LoopKindClassificationDTO: Codable {
    struct Item: Codable {
        let id: Int64
        let kind: String
        enum CodingKeys: String, CodingKey { case id, kind }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let i = try? c.decode(Int64.self, forKey: .id) {
                id = i
            } else if let s = try? c.decode(String.self, forKey: .id), let i = Int64(s) {
                id = i
            } else {
                id = 0
            }
            kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        }
    }
    let items: [Item]?
}

enum FactExtractionError: Error, Equatable {
    /// The model's reply could not be parsed as JSON at all (distinct from a
    /// valid, empty result). The caller must NOT advance the extraction cursor.
    case unparseableResponse
}

// MARK: - Prompt

enum FactExtractionPrompt {
    static let systemPrompt = """
    You maintain a running FACT MEMORY for one Telegram user. You read NEW messages from a single chat and update the memory of OPEN LOOPS (things still owed) plus a few durable background facts.

    Return EXACTLY one JSON object, nothing else:
    {
      "facts": [
        {
          "subject": "the OTHER person's name (or \\"me\\" only for writes_in voice facts)",
          "predicate": "i_owe" | "owes_me" | "works_at" | "prefers" | "writes_in" | "fact",
          "object": "a SHORT stable noun phrase (e.g. \\"the pitch deck\\", \\"Acme\\", \\"voice notes\\")",
          "action": "a natural one-line to-do, how YOU'd write it for yourself (e.g. \\"Pay the Hetzner invoice\\", \\"Send Piyush the 2FA fix\\", \\"Chase Dinesh for the deck\\"). Open loops only; \\"\\" for durable facts.",
          "kind": "i_owe loops ONLY: \\"reply\\" if you can close it by just sending a message (answer a question, confirm, share a quick detail), or \\"action\\" if it needs real work first (build/fix something, pay, compile or prepare a deliverable, send a file, review). Omit for owes_me and durable facts.",
          "confidence": 0.0,
          "evidence": "the source message's text, copied VERBATIM from the transcript",
          "sourceMsg": "the [number] of the single transcript message this loop is about"
        }
      ],
      "resolvedLoops": [numbers from the OPEN LOOPS list that the NEW messages just closed],
      "chasedLoops": [{"loop": <OPEN LOOPS list number>, "sourceMsg": <transcript [N] of the follow-up message>}]
    }

    Predicates:
    - i_owe   = [ME] PERSONALLY owes a reply or deliverable, AND the ask is directed at [ME]. In a DM that's automatic. In a GROUP the message text itself must ADDRESS [ME]: an @-mention of [ME]'S OWN USERNAME (given below), or [ME]'s name used in the second person ("Pratyush, can you…"). Nothing else counts. Explicitly NOT [ME]'s loop, ever:
      * a question thrown to the room — even when it is ABOUT [ME]'s product, project, or work, and even when [ME] is the person most likely to know the answer;
      * people referring to [ME] in the THIRD person ("he built it", "ye bhai kab launch karega", "[name] will send it") — they are talking ABOUT [ME], not TO [ME];
      * an ask that @-mentions or names a DIFFERENT person — that is THAT person's job.
      When in doubt in a group, emit NOTHING. subject = the person [ME] owes it to.
    - owes_me = someone still needs to get back to the user.        subject = that person.
    - WHO ACTS decides the direction — never who benefits. A message where the SENDER commits to do something ("Will check with Deeksha", "creating this", "I'll send it tomorrow") is THEIR commitment → owes_me (subject = sender), NEVER i_owe. i_owe requires [ME] to be the actor: either the message asks [ME] to do it, or [ME] committed in [ME]'s own message ("I'll…", "lemme see", "will do"). A joint "we should / we will have to…" with no explicit owner is NOT [ME]'s task — skip it unless [ME] explicitly takes it (and if the OTHER person takes it, it's owes_me).
    - works_at / prefers / fact = durable background facts about a person (subject = that person). Emit sparingly.
    - writes_in = a fact about how the USER writes (subject = "me"). Emit rarely.

    Rules:
    - Only emit an open loop (i_owe/owes_me) when something is GENUINELY pending on someone. "ok", "thanks", "got it", banter = NO loop.
    - Be STRICT about i_owe in group/supergroup chats: jokes, reactions, side-chatter, and questions thrown to the whole room are NOT [ME]'s loops. If you can't tell that [ME] SPECIFICALLY must respond, do not emit i_owe.
    - PROVENANCE: every transcript message is numbered [N]. For EVERY fact — open loops AND durable facts alike — set "sourceMsg" to the [N] of the single message it comes from (the exact ask / request / question / commitment / statement), and copy THAT message's text verbatim into "evidence". NEVER write a placeholder like "Previous context", "previously tracked", or "[ME]: …" — always cite a real numbered message.
    - TWO NUMBERINGS, never mix them: "sourceMsg" ALWAYS uses the [N] from the transcript below (in facts AND in chasedLoops). "resolvedLoops" and chasedLoops' "loop" ALWAYS use the plain numbers (1., 2., …) from the OPEN LOOPS list. An OPEN LOOPS number is never a valid sourceMsg.
    - object must be a short noun phrase, never a sentence, so the SAME loop re-extracts identically across runs.
    - NEVER INVENT what is owed — the object must come from the message itself. If the message doesn't say WHAT is owed, do NOT emit a loop: a bare "give access", "access plz", "send it", "do the needful", "let's do it" with no stated object is too vague to be a task — skip it. (Never turn "give access" into "access to the resource", or a reaction to a shared link into a task.)
    - CLOSING LOOPS: an OPEN LOOP closes only when a NEW message from [ME] actually ADDRESSES that specific loop — answers that exact question, sends that exact thing, gives that exact update. Put its number in resolvedLoops and do NOT re-emit it. A [ME] message about something else does NOT close it — match the reply to the loop; never close on unrelated chatter.
    - NEVER RE-EMIT AN OPEN LOOP: the "facts" array is ONLY for loops that ORIGINATE in the NEW numbered messages below. The OPEN LOOPS list is context so you can CLOSE loops (resolvedLoops) — it is NOT a to-do list to copy back into "facts". If a loop is already in OPEN LOOPS and these new messages neither close it nor add a genuinely new ask, output NOTHING for it: do not re-list it, and never re-anchor an old loop onto one of these unrelated messages. Only a NEW request/commitment first appearing in these numbered messages becomes a new fact.
    - CHASED LOOPS: when a NEW message from the OTHER person follows up on / nudges something [ME] owes THEM (an "you owe" OPEN LOOP) without closing it — "any update?", "wen free tonight?", asking the same thing again — do NOT re-emit the loop; report it in "chasedLoops": {"loop": its OPEN LOOPS number, "sourceMsg": the follow-up message's transcript [N]}. This bumps the existing item to the latest ping instead of duplicating it. Only report a chase when the connection to a SPECIFIC loop is clear from the conversation (in a DM, a bare "free tonight?"/"around?" ping usually chases the latest thing [ME] owes them); if it is genuinely ambiguous WHICH loop is being chased, report nothing. A chase never targets a loop where THEY owe [ME].
    - Prefer a few high-confidence facts over many guesses. Empty arrays are perfectly fine.
    - "action" must read like a to-do you wrote yourself (imperative, natural, specific) — NEVER a template like "Owe X: Y". Keep "object" as the short stable noun phrase; "action" is the human phrasing.
    - For every i_owe loop, set "kind": "reply" when a quick message closes it, "action" when it needs work or time before you can respond. This is what separates the user's Reply queue (quick replies) from their Tasks (take work). owes_me and durable facts: omit "kind".
    - Output ONLY the JSON object.
    """

    /// The NEW messages as a NUMBERED transcript (the user message). Numbering
    /// lets the model cite each loop's source by [N] → exact provenance instead
    /// of fragile evidence-text matching. Bodies are fenced (PromptSafety): the
    /// [N] and sender labels are app-authored structure, the text inside the
    /// fence is untrusted sender data — an inbound message that embeds fake
    /// "[7] [ME]: …" lines must not be able to forge numbering, the user's
    /// voice, or a loop closure.
    ///
    /// `context` = the last few ALREADY-PROCESSED messages, unnumbered and
    /// clearly labeled: a tiny new window (one terse "wen free tonight" ping)
    /// judged blind made the model invent connections and re-emit old loops
    /// anchored on the ping. Context restores the thread without being
    /// extractable.
    static func numberedTranscript(snippets: [MessageSnippet], context: [MessageSnippet] = []) -> String {
        let numbered = snippets.enumerated()
            .map { i, s in "[\(i + 1)] \(s.senderFirstName): \(PromptSafety.fence(s.text))" }
            .joined(separator: "\n")
        guard !context.isEmpty else { return numbered }
        let contextLines = context
            .map { s in "(context) \(s.senderFirstName): \(PromptSafety.fence(s.text))" }
            .joined(separator: "\n")
        return """
        ALREADY-PROCESSED CONTEXT — for understanding the thread only. NEVER extract facts from, cite, or anchor anything on these lines; they have no [N]:
        \(contextLines)

        NEW MESSAGES (the only extractable ones):
        \(numbered)
        """
    }

    /// Context appended to the system prompt.
    static func contextBlock(
        myName: String,
        myUsername: String?,
        chatTitle: String,
        chatType: String,
        openLoops: [Fact]
    ) -> String {
        let loopList: String
        if openLoops.isEmpty {
            loopList = "none"
        } else {
            // Ask dates make "the most recent thing you owe them" computable —
            // chase/close targeting was guesswork without them.
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            loopList = openLoops.enumerated().map { i, f in
                let dir = f.predicate == .iOwe ? "you owe \(f.subjectEntity)" : "\(f.subjectEntity) owes you"
                return "\(i + 1). [\(dir)] → \(f.objectText) (asked \(fmt.string(from: f.validFrom)))"
            }.joined(separator: "\n")
        }
        // The username is what group @-mentions actually address — without it
        // the model can't tell "@rrspace07 pls finalise" is someone ELSE's job.
        let handle = (myUsername?.isEmpty == false) ? " Telegram username: @\(myUsername!) — an @-mention of any OTHER handle is NOT [ME]." : ""
        return """

        ---
        The user is [ME] (name: \(myName)).\(handle) Chat: \(chatTitle) (\(chatType)).

        OPEN LOOPS already tracked in this chat:
        \(loopList)

        The NEW messages to read follow as the transcript below.
        """
    }
}

// MARK: - Parser

enum FactExtractionParser {
    /// Every draft carries its OWN provenance: the cited [N] (or evidence-matched)
    /// message's id, text, real sender, and date. Facts with no verifiable source
    /// are dropped (precision) — nothing falls back to a shared batch message.
    static func parse(
        _ response: String,
        chatId: Int64,
        openLoops: [Fact],
        validFrom: Date,
        messages: [MessageSnippet] = []
    ) throws -> FactExtractionResult {
        guard let dto: FactExtractionDTO = try? JSONExtractor.parseJSON(response) else {
            // "Couldn't parse" must be distinguishable from "parsed, empty":
            // throwing makes the coordinator skip the cursor advance and retry
            // this window next pass, instead of silently dropping its messages.
            throw FactExtractionError.unparseableResponse
        }

        // A loop the model re-lists that is ALREADY open in this chat is a
        // RE-EMISSION, not a new ask. Dropping it keeps the ORIGINAL fact (earliest,
        // correctly anchored) and stops the model re-stapling an open loop onto an
        // unrelated later message (e.g. anchoring "send the Airbnb options" onto an
        // OTP code from two weeks later). Deliberately NOT a re-emission:
        //  - a loop this same response CLOSES (resolvedLoops) — the matching new
        //    fact is a legitimate re-ask ("thanks — now the April invoice") and
        //    must survive, or close+re-ask in one window loses the ask forever;
        //  - the same object owed by a DIFFERENT named person (Alice's deck vs
        //    Bob's deck) — distinct loops. Subjects match when equal or when
        //    either side is "me", because the observed drift is me↔counterparty
        //    on the SAME loop.
        let resolvedIndices = Set(dto.resolvedLoops ?? [])
        var seenLoops: [(key: String, subject: String)] = openLoops.enumerated()
            .filter { $0.element.predicate.isOpenLoop && !resolvedIndices.contains($0.offset + 1) }
            .map { (loopKey($0.element.predicate, $0.element.objectText), $0.element.subjectEntity.lowercased()) }
        func isReEmission(_ predicate: FactPredicate, _ object: String, _ subject: String) -> Bool {
            let key = loopKey(predicate, object)
            let subj = subject.lowercased()
            return seenLoops.contains { $0.key == key && ($0.subject == subj || $0.subject == "me" || subj == "me") }
        }

        let drafts: [FactDraft] = (dto.facts ?? []).compactMap { f in
            guard let predicate = FactPredicate(rawValue: f.predicate.lowercased()) else { return nil }
            let object = f.object.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = f.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !object.isEmpty, !subject.isEmpty else { return nil }
            if predicate.isOpenLoop, isReEmission(predicate, object, subject) { return nil }
            // The reply/action tag only applies to i_owe loops; ignore it elsewhere.
            let loopKind = predicate == .iOwe ? LoopKind(rawValue: (f.kind ?? "").lowercased()) : nil

            // Provenance: the cited [N] is primary, but never blindly — the model
            // has TWO numbering spaces in view (transcript [N] + the OPEN LOOPS
            // list), so a citation whose message is clearly UNRELATED to the
            // quoted evidence is treated as a mis-cite and re-resolved from the
            // evidence text. A fact with no verifiable source at all is dropped.
            let evidence = cleanedEvidence(f.evidence)
            let source: MessageSnippet?
            if let n = f.sourceMsg, n >= 1, n <= messages.count {
                let cited = messages[n - 1]
                if evidence.isEmpty || textsRelated(cited.text, evidence) {
                    source = cited
                } else {
                    source = matchSourceSnippet(evidence: evidence, in: messages)
                }
            } else {
                source = matchSourceSnippet(evidence: evidence, in: messages)
            }
            guard let snip = source else { return nil }
            // Register the loop identity only now — an emission that FAILED
            // provenance must not poison a valid duplicate later in the batch.
            if predicate.isOpenLoop {
                seenLoops.append((loopKey(predicate, object), subject.lowercased()))
            }
            return FactDraft(
                subjectEntity: subject,
                predicate: predicate,
                objectText: object,
                action: (f.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                loopKind: loopKind,
                objectEntity: nil,
                confidence: min(1, max(0, f.confidence ?? 0.7)),
                // The ASK's real date (the cited message), not the batch-newest —
                // ask-age ranking and "how old is this" labels depend on it.
                validFrom: snip.date ?? validFrom,
                sourceChatId: chatId,
                sourceMessageId: snip.messageId,
                sourceText: snip.text,
                senderName: subject
            )
        }

        let resolved: [String] = (dto.resolvedLoops ?? []).compactMap { n in
            let idx = n - 1
            guard openLoops.indices.contains(idx) else { return nil }
            return openLoops[idx].fingerprint
        }

        // Chases: a follow-up ping bumps the existing loop instead of duplicating
        // it. Only the OTHER side can chase ([ME]'s own message must not bump a
        // "they're waiting" date), and a loop the model also CLOSED wins as
        // closed — no point bumping a loop that just ended.
        let resolvedSet = Set(resolved)
        let chased: [ChasedLoopUpdate] = (dto.chasedLoops ?? []).compactMap { chase in
            guard let loopN = chase.loop, openLoops.indices.contains(loopN - 1),
                  let msgN = chase.sourceMsg, msgN >= 1, msgN <= messages.count else { return nil }
            let loop = openLoops[loopN - 1]
            // Direction is structural: the OTHER person's ping can only chase
            // what THEY are waiting on — an i_owe loop. An owes_me loop (what
            // they owe the user) is chased by [ME], and [ME]'s messages are
            // already excluded — so an inbound chase citing owes_me is always a
            // mis-cite (one bumped a Jun-9 owes_me onto "wen free tonight").
            guard loop.predicate == .iOwe, !resolvedSet.contains(loop.fingerprint) else { return nil }
            let snip = messages[msgN - 1]
            guard snip.senderFirstName != "[ME]" else { return nil }
            return ChasedLoopUpdate(
                fingerprint: loop.fingerprint,
                sourceMessageId: snip.messageId,
                sourceText: snip.text,
                date: snip.date ?? validFrom
            )
        }

        return FactExtractionResult(drafts: drafts, resolvedFingerprints: resolved, chasedLoops: chased)
    }

    /// Loop identity for the re-emission drop-set: predicate + the SAME canonical
    /// object normalization the store's fingerprint uses (one definition, so the
    /// parser's "same loop" can never disagree with the upsert's).
    private static func loopKey(_ predicate: FactPredicate, _ object: String) -> String {
        predicate.rawValue + "|" + ContextLayer.normalizedLoopObject(object)
    }

    /// Model-quoted evidence, cleaned for matching: fence tokens the model may
    /// have copied from the fenced transcript are stripped so comparisons run
    /// against the raw stored message text.
    private static func cleanedEvidence(_ raw: String?) -> String {
        (raw ?? "")
            .replacingOccurrences(of: "«msg»", with: "")
            .replacingOccurrences(of: "«/msg»", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Loose relatedness check between a cited message and the model's quoted
    /// evidence (case-insensitive bidirectional containment). Lenient on purpose:
    /// it only exists to catch citations that are OBVIOUSLY about a different
    /// message (numbering-space confusion), not to second-guess trims.
    private static func textsRelated(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        return x.contains(y) || y.contains(x)
    }

    /// Match a fact's evidence text back to the specific message it quotes.
    /// Case-insensitive; the substring fallback requires the CONTAINED side to be
    /// substantial (≥ 12 chars) so a filler "ok" can never become the anchor by
    /// matching inside "book the hotel".
    private static func matchSourceSnippet(evidence: String, in messages: [MessageSnippet]) -> MessageSnippet? {
        guard !evidence.isEmpty, !messages.isEmpty else { return nil }
        let evLower = evidence.lowercased()
        if let m = messages.first(where: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == evLower
        }) {
            return m
        }
        // Evidence may be trimmed to a substring (or vice-versa) — accept either
        // direction, but only meaningful spans.
        return messages.first(where: { m in
            let text = m.text.lowercased()
            guard !text.isEmpty else { return false }
            if text.contains(evLower) { return evLower.count >= 12 }
            if evLower.contains(text) { return text.count >= 12 }
            return false
        })
    }
}
