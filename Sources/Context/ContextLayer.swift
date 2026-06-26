//
//  ContextLayer.swift
//  Pidgy — #48 context layer
//
//  One queryable, time-aware fact store. Tasks + reply queue become VIEWS over
//  the open-loop facts (i_owe / owes_me) instead of re-extracting from raw
//  message windows every pass. A fact is a triplet with provenance and a
//  bi-temporal validity window — invalidate old facts, never overwrite.
//

import Foundation

/// Master switch for the context-layer pipeline. While ON, facts are extracted
/// and tasks/reply-queue are derived from them; while OFF the app runs the
/// existing re-extraction pipeline unchanged. ON for review builds; the whole
/// feature lives behind this so it's clean to keep or scrap.
enum ContextLayer {
    static let enabled = true

    /// How many of the newest unprocessed messages to feed one extraction call.
    static let extractionWindow = 40
    /// Don't extract chats older than this (matches the reply/triage recency).
    static let maxChatAgeSeconds: TimeInterval = 30 * 86_400
    /// Chats processed per pass (newest-active first); the cursor advances each
    /// pass so the rest are picked up on later passes.
    static let maxChatsPerPass = 40
    /// Windows crawled per chat per pass. Cold start walks forward from the
    /// 30-day boundary this many windows at a time, so a deep chat catches up
    /// over a few passes rather than being read all at once.
    static let maxWindowsPerChatPerPass = 3
}

/// The predicate vocabulary. Starts tiny — the open-loop predicates that power
/// tasks + reply queue — and grows (works_at / prefers / writes_in) for the
/// later people / voice / topic views.
enum FactPredicate: String, Codable, CaseIterable, Sendable {
    case iOwe = "i_owe"          // the user owes them (a reply / a deliverable)
    case owesMe = "owes_me"      // they owe the user
    case worksAt = "works_at"
    case prefers = "prefers"
    case writesIn = "writes_in"  // voice facts about the user
    case fact = "fact"           // generic durable fact

    /// The open-loop predicates that ARE tasks / reply-queue items.
    static let openLoops: [FactPredicate] = [.iOwe, .owesMe]
    var isOpenLoop: Bool { Self.openLoops.contains(self) }
}

/// A stored fact — one row of `facts`.
struct Fact: Identifiable, Equatable, Sendable {
    var id: Int64
    var subjectEntity: String
    var subjectPersonId: Int64?   // canonical Telegram user id, when resolved
    var predicate: FactPredicate
    var objectText: String
    var objectEntity: String?
    var confidence: Double
    var validFrom: Date
    var invalidAt: Date?          // nil = still valid (bi-temporal)
    var sourceChatId: Int64
    var sourceMessageId: Int64
    var sourceText: String
    var senderName: String
    var fingerprint: String
    var createdAt: Date
    var updatedAt: Date

    var isOpen: Bool { invalidAt == nil }
}

/// A fact about to be written (no id/timestamps yet) — what extraction produces.
struct FactDraft: Equatable, Sendable {
    var subjectEntity: String
    var subjectPersonId: Int64? = nil   // set by the entity resolver post-extraction
    var predicate: FactPredicate
    var objectText: String
    var objectEntity: String?
    var confidence: Double
    var validFrom: Date
    var sourceChatId: Int64
    var sourceMessageId: Int64
    var sourceText: String
    var senderName: String

    /// Stable identity: a live fact is unique on (subject | predicate |
    /// normalized object). Re-extracting the same loop upserts; the inverse
    /// predicate or an explicit resolution invalidates it instead of dup'ing.
    /// When the subject resolved to a person id, identity keys on THAT (so
    /// "Piyush" and "Piyush Avantis" share one note); otherwise on the name.
    var fingerprint: String {
        let obj = objectText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let subjectKey = subjectPersonId.map { "p:\($0)" } ?? "n:\(subjectEntity.lowercased())"
        return "\(subjectKey)|\(predicate.rawValue)|\(obj)"
    }
}
