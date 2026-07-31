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
/// and tasks/reply-queue are derived from them; while OFF, fact EXTRACTION
/// stops (no AI spend) and the tasks/reply-queue views keep projecting the
/// last-known facts — they freeze rather than fall back (the pre-facts
/// pipeline was retired). Runtime kill-switch: users/support can turn it
/// off in Preferences WITHOUT a new build. Read ONCE at first access and fixed
/// for the process lifetime — a mid-session flip would race every coordinator
/// and view that branched on it at startup, so the toggle takes effect on the
/// next launch (same relaunch semantics as logout).
enum ContextLayer {
    static let enabled: Bool = {
        (UserDefaults.standard.object(forKey: AppConstants.Preferences.contextLayerEnabledKey) as? Bool) ?? true
    }()

    /// How many of the newest unprocessed messages to feed one extraction call.
    /// Measured 2026-07-23: 80 cut the AI-call count (320 → 234) and ~1 min of
    /// catch-up, but found 27% FEWER facts (137 → 100) — recall degrades over
    /// the longer transcript. Speed is not worth missed loops; 40 stays.
    static let extractionWindow = 40
    /// Don't extract chats older than this (matches the reply/triage recency).
    static let maxChatAgeSeconds: TimeInterval = 30 * 86_400
    /// Chats processed per pass (newest-active first); the cursor advances each
    /// pass so the rest are picked up on later passes.
    static let maxChatsPerPass = 40
    /// Windows crawled per chat per pass. Cold start walks forward from the
    /// 30-day boundary this many windows at a time, so a deep chat catches up
    /// over a few passes rather than being read all at once.
    static let maxWindowsPerChatPerPass = 6
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

/// For an `i_owe` open loop, whether the user can close it with a quick reply or
/// it needs real work first. This is what splits the Reply queue (just respond)
/// from Tasks (takes time). Decided by the model at extraction.
/// `nil` = not yet classified → treated as a Task, so nothing wrongly lands in
/// the reply queue. `owes_me` loops don't use this (they're always follow-ups).
enum LoopKind: String, Codable, Sendable {
    case reply    // closable by sending a message now (answer / confirm / share)
    case action   // needs a deliverable, payment, build, or chase first
}

/// WHY a loop was invalidated. Distinguishes user actions (browsable in the
/// Done tab, undoable) from automatic reply-closes — without it, Mark Done made
/// a task vanish from every tab with no history and no way back.
enum FactCloseReason: String, Codable, Sendable {
    case replied = "replied"          // auto: the loop was addressed in chat
    case userDone = "user_done"       // user clicked Mark Done
    case userIgnored = "user_ignored" // user clicked Ignore
}

extension Notification.Name {
    /// Posted after the fact store changes (loops opened / closed / cleaned) so
    /// the Tasks + Reply queue views re-project immediately instead of waiting
    /// for the next chat-update tick.
    static let contextFactsChanged = Notification.Name("contextFactsChanged")
}

/// A rolling entity summary — one row of `entity_summaries`. Bi-temporal like
/// facts: the current row has supersededAt == nil; every fold supersedes the
/// old row and inserts a fresh one, so history stays queryable.
struct EntitySummary: Identifiable, Equatable, Sendable {
    var id: Int64
    var entityKind: String        // "chat" (person/topic in later milestones)
    var entityId: Int64
    var entityTitle: String
    var summary: String
    var throughMessageId: Int64   // fold cursor: newest message folded in
    var validFrom: Date
    var supersededAt: Date?       // nil = current
}

/// A stored fact — one row of `facts`.
struct Fact: Identifiable, Equatable, Sendable {
    var id: Int64
    var subjectEntity: String
    var subjectPersonId: Int64?   // canonical Telegram user id, when resolved
    var predicate: FactPredicate
    var objectText: String
    var action: String            // model-written natural to-do phrasing (display)
    var loopKind: LoopKind? = nil // i_owe: reply vs action; nil = unclassified
    var objectEntity: String?
    var confidence: Double
    var validFrom: Date
    var invalidAt: Date?          // nil = still valid (bi-temporal)
    var closeReason: FactCloseReason? = nil // why invalidated (nil while open)
    var sourceChatId: Int64
    var sourceChatTitle: String = ""   // chat display title captured at extraction
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
    var action: String = ""             // model-written natural to-do phrasing
    var loopKind: LoopKind? = nil       // i_owe: reply vs action (set by extraction)
    var objectEntity: String?
    var confidence: Double
    var validFrom: Date
    var sourceChatId: Int64
    var sourceChatTitle: String = ""
    var sourceMessageId: Int64
    var sourceText: String
    var senderName: String

    /// Stable identity: a live fact is unique on (subject | predicate |
    /// normalized object). Re-extracting the same loop upserts; the inverse
    /// predicate or an explicit resolution invalidates it instead of dup'ing.
    /// When the subject resolved to a person id, identity keys on THAT (so
    /// "Piyush" and "Piyush Avantis" share one note); otherwise on the name.
    var fingerprint: String {
        let subjectKey = subjectPersonId.map { "p:\($0)" } ?? "n:\(subjectEntity.lowercased())"
        return "\(subjectKey)|\(predicate.rawValue)|\(ContextLayer.normalizedLoopObject(objectText))"
    }
}

extension ContextLayer {
    /// THE canonical normalization of a loop's object noun phrase — used by BOTH
    /// the store identity (fingerprint) and the parser's re-emission drop-set,
    /// so the two layers can never disagree about what "the same loop" means
    /// (a divergence let whitespace-variant re-emissions slip the parser yet
    /// collide on fingerprint, silently re-anchoring the fact's evidence).
    /// Lowercase, collapse ALL whitespace, strip one leading article.
    static func normalizedLoopObject(_ raw: String) -> String {
        var t = raw
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for article in ["the ", "a ", "an "] where t.hasPrefix(article) {
            t = String(t.dropFirst(article.count))
            break // one leading article, never a cascade ("the a cappella group")
        }
        return t
    }
}
