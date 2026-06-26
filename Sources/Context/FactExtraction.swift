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
    let confidence: Double?
    let evidence: String?

    enum CodingKeys: String, CodingKey { case subject, predicate, object, action, confidence, evidence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        predicate = (try? c.decode(String.self, forKey: .predicate)) ?? ""
        object = (try? c.decode(String.self, forKey: .object)) ?? ""
        action = try? c.decodeIfPresent(String.self, forKey: .action)
        confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
        evidence = try? c.decodeIfPresent(String.self, forKey: .evidence)
    }
}

struct FactExtractionDTO: Codable {
    let facts: [FactDTO]?
    let resolvedLoops: [Int]?

    enum CodingKeys: String, CodingKey { case facts, resolvedLoops }

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
    }
}

/// What the coordinator applies to the store: new facts + loops to close.
struct FactExtractionResult: Sendable {
    var drafts: [FactDraft]
    var resolvedFingerprints: [String]
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
          "confidence": 0.0,
          "evidence": "the exact message text it came from"
        }
      ],
      "resolvedLoops": [numbers from the OPEN LOOPS list that the NEW messages just closed]
    }

    Predicates:
    - i_owe   = the user ([ME]) still needs to reply or deliver something. subject = the person they owe it to.
    - owes_me = someone still needs to get back to the user.        subject = that person.
    - works_at / prefers / fact = durable background facts about a person (subject = that person). Emit sparingly.
    - writes_in = a fact about how the USER writes (subject = "me"). Emit rarely.

    Rules:
    - Only emit an open loop (i_owe/owes_me) when something is GENUINELY pending on someone. "ok", "thanks", "got it", banter = NO loop.
    - object must be a short noun phrase, never a sentence, so the SAME loop re-extracts identically across runs.
    - If a NEW message closes a tracked OPEN LOOP, put that loop's NUMBER in resolvedLoops and do NOT re-emit it as a fact.
    - Prefer a few high-confidence facts over many guesses. Empty arrays are perfectly fine.
    - "action" must read like a to-do you wrote yourself (imperative, natural, specific) — NEVER a template like "Owe X: Y". Keep "object" as the short stable noun phrase; "action" is the human phrasing.
    - Output ONLY the JSON object.
    """

    /// Context appended to the system prompt (the transcript itself is rendered
    /// by `summarize` as the user message).
    static func contextBlock(
        myName: String,
        chatTitle: String,
        chatType: String,
        openLoops: [Fact]
    ) -> String {
        let loopList: String
        if openLoops.isEmpty {
            loopList = "none"
        } else {
            loopList = openLoops.enumerated().map { i, f in
                let dir = f.predicate == .iOwe ? "you owe \(f.subjectEntity)" : "\(f.subjectEntity) owes you"
                return "\(i + 1). [\(dir)] → \(f.objectText)"
            }.joined(separator: "\n")
        }
        return """

        ---
        The user is [ME] (name: \(myName)). Chat: \(chatTitle) (\(chatType)).

        OPEN LOOPS already tracked in this chat:
        \(loopList)

        The NEW messages to read follow as the transcript below.
        """
    }
}

// MARK: - Parser

enum FactExtractionParser {
    /// All facts in a batch share the batch's newest message as their source
    /// (the `evidence` text carries the real provenance shown to the user).
    static func parse(
        _ response: String,
        chatId: Int64,
        openLoops: [Fact],
        sourceMessageId: Int64,
        validFrom: Date
    ) throws -> FactExtractionResult {
        guard let dto: FactExtractionDTO = try? JSONExtractor.parseJSON(response) else {
            // "Couldn't parse" must be distinguishable from "parsed, empty":
            // throwing makes the coordinator skip the cursor advance and retry
            // this window next pass, instead of silently dropping its messages.
            throw FactExtractionError.unparseableResponse
        }

        let drafts: [FactDraft] = (dto.facts ?? []).compactMap { f in
            guard let predicate = FactPredicate(rawValue: f.predicate.lowercased()) else { return nil }
            let object = f.object.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = f.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !object.isEmpty, !subject.isEmpty else { return nil }
            return FactDraft(
                subjectEntity: subject,
                predicate: predicate,
                objectText: object,
                action: (f.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                objectEntity: nil,
                confidence: min(1, max(0, f.confidence ?? 0.7)),
                validFrom: validFrom,
                sourceChatId: chatId,
                sourceMessageId: sourceMessageId,
                sourceText: f.evidence ?? "",
                senderName: subject
            )
        }

        let resolved: [String] = (dto.resolvedLoops ?? []).compactMap { n in
            let idx = n - 1
            guard openLoops.indices.contains(idx) else { return nil }
            return openLoops[idx].fingerprint
        }

        return FactExtractionResult(drafts: drafts, resolvedFingerprints: resolved)
    }
}
