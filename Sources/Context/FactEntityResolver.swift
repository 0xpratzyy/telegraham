//
//  FactEntityResolver.swift
//  Pidgy — #48 context layer
//
//  Resolves a fact's subject (a free-text name from the model) to a canonical
//  Telegram user id — the same id the People graph keys on. This collapses name
//  variants ("Piyush" / "Piyush Avantis") into one person and lets facts join
//  the People surface. Returns nil when the subject can't be confidently tied to
//  a real person (a bare/3rd-party name, or "me"); the fact then keys on its
//  normalized name instead, so we never MIS-merge two different people.
//

import Foundation

/// A global name → Telegram-id directory, built once per pass from the whole
/// message history + every DM's title. Lets us resolve people who are only
/// MENTIONED in a chat (not senders there) and unify the same person across
/// chats — the reach the per-chat window can't give on its own.
struct FactContactDirectory: Sendable {
    let idToName: [Int64: String]
    let firstNameToIds: [String: Set<Int64>]
    let fullNameToId: [String: Int64]   // only unambiguous full names

    static let empty = FactContactDirectory(idToName: [:], firstNameToIds: [:], fullNameToId: [:])

    /// `rows` = (id, name, count) from messages; `dmContacts` = (id, title) from
    /// private chats (authoritative display names, even for silent contacts).
    static func build(
        rows: [(id: Int64, name: String, count: Int)],
        dmContacts: [(id: Int64, name: String)]
    ) -> FactContactDirectory {
        var bestName: [Int64: (name: String, score: Int)] = [:]
        var firstNameToIds: [String: Set<Int64>] = [:]
        var fullNameToIds: [String: Set<Int64>] = [:]

        func ingest(id: Int64, name: String, weight: Int) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let lower = trimmed.lowercased()
            if let cur = bestName[id] {
                if weight > cur.score || (weight == cur.score && trimmed.count > cur.name.count) {
                    bestName[id] = (trimmed, weight)
                }
            } else {
                bestName[id] = (trimmed, weight)
            }
            fullNameToIds[lower, default: []].insert(id)
            if let first = lower.split(whereSeparator: \.isWhitespace).first {
                firstNameToIds[String(first), default: []].insert(id)
            }
        }

        for r in rows { ingest(id: r.id, name: r.name, weight: r.count) }
        // A DM title is the authoritative display name for that contact.
        for c in dmContacts { ingest(id: c.id, name: c.name, weight: 1_000_000) }

        let idToName = bestName.mapValues { $0.name }
        let fullNameToId = fullNameToIds.compactMapValues { ids -> Int64? in
            ids.count == 1 ? ids.first : nil
        }
        return FactContactDirectory(idToName: idToName, firstNameToIds: firstNameToIds, fullNameToId: fullNameToId)
    }

    /// Resolve a name globally: exact (unambiguous) full name, else a globally
    /// unique first name. Nil if ambiguous or unknown.
    func resolve(_ name: String) -> (id: Int64, display: String)? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        if let id = fullNameToId[lower] { return (id, idToName[id] ?? name) }
        if let first = lower.split(whereSeparator: \.isWhitespace).first,
           let ids = firstNameToIds[String(first)], ids.count == 1, let id = ids.first {
            return (id, idToName[id] ?? name)
        }
        return nil
    }
}

enum FactEntityResolver {
    // Only "me" forms are the user — never treat a real name as self.
    private static let selfTokens: Set<String> = ["me", "myself", "self"]

    /// (personId, displayName). DETERMINISTIC, so a loop's identity is stable
    /// across passes (no fingerprint drift):
    ///   1. for an OPEN LOOP in a DM, the counterparty — only when the subject's
    ///      first name EQUALS a title token (token equality, NOT substring, so a
    ///      3rd party mentioned in a DM isn't misattributed to the counterparty);
    ///   2. the GLOBAL directory (stable across passes; covers mentioned-elsewhere
    ///      people + unifies the same person across chats);
    ///   3. otherwise unresolved — keep the model's name (keyed by name, never
    ///      merged with anyone).
    ///
    /// We intentionally do NOT match against just the current window's senders:
    /// that set changed window-to-window, so the same loop resolved differently
    /// across passes and produced duplicate live facts.
    static func resolve(
        subject: String,
        predicate: FactPredicate,
        chat: TGChat,
        myUserId: Int64,
        directory: FactContactDirectory
    ) -> (personId: Int64?, displayName: String) {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty, !selfTokens.contains(lower) else { return (nil, trimmed) }
        let subjectFirst = lower.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? lower

        // 1) Open loop in a DM → the counterparty (token-equality guard).
        if predicate.isOpenLoop, case .privateChat(let uid) = chat.chatType, uid != myUserId {
            let titleTokens = Set(chat.title.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            if titleTokens.contains(subjectFirst) {
                return (uid, chat.title.isEmpty ? trimmed : chat.title)
            }
        }

        // 2) Global directory — deterministic, so identity is stable across passes.
        if let hit = directory.resolve(trimmed) {
            return (hit.id, hit.display)
        }

        // 3) Unresolved — keep the model's name.
        return (nil, trimmed)
    }
}
