//
//  FactProjections.swift
//  Pidgy — #48 context layer
//
//  Tasks + reply queue as VIEWS over the open-loop facts (i_owe / owes_me).
//  Nothing is re-extracted here — these are pure, cheap projections of the
//  fact store. A task closes exactly when its underlying fact is invalidated,
//  so there's no separate task lifecycle to keep in sync.
//

import Foundation

/// A reply-queue row derived from one open-loop fact. Lightweight (the real
/// FollowUpItem is UI-coupled and needs live TGChat/TGMessage objects); this is
/// the data the reply surface needs, sourced purely from facts.
struct FactReplyItem: Identifiable, Sendable {
    let id: Int64            // fact id
    let chatId: Int64
    let chatTitle: String
    let person: String
    let onMe: Bool           // true = the user owes a reply; false = waiting on them
    let object: String
    let action: String       // natural phrasing for display
    let evidence: String
    let date: Date
}

enum FactProjection {
    /// Open-loop facts → DashboardTasks (the existing task shape, so this is a
    /// drop-in for the live Tasks surface once the approach is blessed).
    static func tasks(from facts: [Fact], chatTitles: [Int64: String]) -> [DashboardTask] {
        facts
            .filter { f in
                // Tasks = work/effort items only: i_owe loops that need an action,
                // not a quick reply. Replies AND waiting-on-them (owes_me) live in
                // the reply queue — task is task, reply is reply (split on effort).
                f.isOpen && f.predicate == .iOwe && f.loopKind != .reply
            }
            .map { f in
                let chatTitle = !f.sourceChatTitle.isEmpty
                    ? f.sourceChatTitle
                    : (chatTitles[f.sourceChatId] ?? "Chat \(f.sourceChatId)")
                // Prefer the model's natural phrasing; fall back to a readable
                // template only when an older fact has no action yet.
                // All tasks are i_owe work-items now. The title IS the action
                // ("Pay the Hetzner invoice") — no redundant "Reply to X" hint.
                let rawTitle = f.action.isEmpty ? "Follow up with \(f.subjectEntity) about \(f.objectText)" : f.action
                let title = DashboardTaskTitle.compact(rawTitle)
                let suggested = ""
                let owner = "Me"
                let priority: DashboardTaskPriority = f.confidence >= 0.8 ? .high : (f.confidence >= 0.5 ? .medium : .low)
                return DashboardTask(
                    id: f.id,
                    stableFingerprint: f.fingerprint,
                    title: title,
                    summary: f.sourceText.isEmpty ? title : f.sourceText,
                    suggestedAction: suggested,
                    ownerName: owner,
                    personName: f.subjectEntity,
                    chatId: f.sourceChatId,
                    chatTitle: chatTitle,
                    topicId: nil,
                    topicName: nil,
                    priority: priority,
                    status: .open,
                    confidence: f.confidence,
                    createdAt: f.createdAt,
                    updatedAt: f.updatedAt,
                    dueAt: nil,
                    snoozedUntil: nil,
                    latestSourceDate: f.validFrom,
                    statusSetByUserAt: nil
                )
            }
            .sorted { ($0.latestSourceDate ?? .distantPast) > ($1.latestSourceDate ?? .distantPast) }
    }

    /// THE reply-queue lane routing — single definition consumed by BOTH the
    /// live surface (AttentionStore) and the inspector, so they can never
    /// disagree: freshest i_owe .reply per chat → ON ME (quick reply owed by
    /// the user); freshest owes_me per chat → ON THEM (waiting on them).
    /// i_owe .action / unclassified are Tasks — the split is on effort.
    static func replyLanes(from facts: [Fact]) -> (onMe: [Int64: Fact], onThem: [Int64: Fact]) {
        (
            onMe: freshestPerChat(facts.filter { $0.isOpen && $0.predicate == .iOwe && $0.loopKind == .reply }),
            onThem: freshestPerChat(facts.filter { $0.isOpen && $0.predicate == .owesMe })
        )
    }

    private static func freshestPerChat(_ facts: [Fact]) -> [Int64: Fact] {
        var byChat: [Int64: Fact] = [:]
        for f in facts where (byChat[f.sourceChatId].map { $0.validFrom < f.validFrom } ?? true) {
            byChat[f.sourceChatId] = f
        }
        return byChat
    }

    /// Open-loop facts → reply-queue rows (both lanes, mirroring the live
    /// surface exactly — the inspector renders this to debug the real queue).
    static func replyQueue(from facts: [Fact], chatTitles: [Int64: String]) -> [FactReplyItem] {
        let lanes = replyLanes(from: facts)
        let all = lanes.onMe.values.map { ($0, true) } + lanes.onThem.values.map { ($0, false) }
        return all
            .map { f, onMe in
                FactReplyItem(
                    id: f.id,
                    chatId: f.sourceChatId,
                    chatTitle: !f.sourceChatTitle.isEmpty
                        ? f.sourceChatTitle
                        : (chatTitles[f.sourceChatId] ?? "Chat \(f.sourceChatId)"),
                    person: f.subjectEntity,
                    onMe: onMe,
                    object: f.objectText,
                    action: f.action.isEmpty ? f.objectText : f.action,
                    evidence: f.sourceText,
                    date: f.validFrom
                )
            }
            .sorted { $0.date > $1.date }
    }

    /// USER-closed loops → Done/Ignored task rows, so the Tasks page's status
    /// tabs have history and an accidental Mark Done is one click to undo.
    static func closedTasks(from facts: [Fact], chatTitles: [Int64: String]) -> [DashboardTask] {
        facts
            .filter { $0.closeReason == .userDone || $0.closeReason == .userIgnored }
            .map { f in
                let chatTitle = !f.sourceChatTitle.isEmpty
                    ? f.sourceChatTitle
                    : (chatTitles[f.sourceChatId] ?? "Chat \(f.sourceChatId)")
                let rawTitle = f.action.isEmpty ? "Follow up with \(f.subjectEntity) about \(f.objectText)" : f.action
                let title = DashboardTaskTitle.compact(rawTitle)
                return DashboardTask(
                    id: f.id,
                    stableFingerprint: f.fingerprint,
                    title: title,
                    summary: f.sourceText.isEmpty ? title : f.sourceText,
                    suggestedAction: "",
                    ownerName: "Me",
                    personName: f.subjectEntity,
                    chatId: f.sourceChatId,
                    chatTitle: chatTitle,
                    topicId: nil,
                    topicName: nil,
                    priority: f.confidence >= 0.8 ? .high : (f.confidence >= 0.5 ? .medium : .low),
                    status: f.closeReason == .userIgnored ? .ignored : .done,
                    confidence: f.confidence,
                    createdAt: f.createdAt,
                    updatedAt: f.updatedAt,
                    dueAt: nil,
                    snoozedUntil: nil,
                    latestSourceDate: f.validFrom,
                    statusSetByUserAt: f.invalidAt
                )
            }
            .sorted { ($0.statusSetByUserAt ?? .distantPast) > ($1.statusSetByUserAt ?? .distantPast) }
    }
}
