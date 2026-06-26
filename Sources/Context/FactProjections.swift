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
            .filter { $0.isOpen && $0.predicate.isOpenLoop }
            .map { f in
                let chatTitle = !f.sourceChatTitle.isEmpty
                    ? f.sourceChatTitle
                    : (chatTitles[f.sourceChatId] ?? "Chat \(f.sourceChatId)")
                // Prefer the model's natural phrasing; fall back to a readable
                // template only when an older fact has no action yet.
                let title: String
                let suggested: String
                let owner: String
                switch f.predicate {
                case .iOwe:
                    title = f.action.isEmpty ? "Follow up with \(f.subjectEntity) about \(f.objectText)" : f.action
                    suggested = "Reply to \(f.subjectEntity)"
                    owner = "Me"
                default: // .owesMe
                    title = f.action.isEmpty ? "Waiting on \(f.subjectEntity) for \(f.objectText)" : f.action
                    suggested = "Nudge \(f.subjectEntity)"
                    owner = f.subjectEntity
                }
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

    /// Open-loop facts → reply-queue rows. i_owe = on me, owes_me = on them.
    static func replyQueue(from facts: [Fact], chatTitles: [Int64: String]) -> [FactReplyItem] {
        facts
            .filter { $0.isOpen && $0.predicate.isOpenLoop }
            .map { f in
                FactReplyItem(
                    id: f.id,
                    chatId: f.sourceChatId,
                    chatTitle: !f.sourceChatTitle.isEmpty
                        ? f.sourceChatTitle
                        : (chatTitles[f.sourceChatId] ?? "Chat \(f.sourceChatId)"),
                    person: f.subjectEntity,
                    onMe: f.predicate == .iOwe,
                    object: f.objectText,
                    action: f.action.isEmpty ? f.objectText : f.action,
                    evidence: f.sourceText,
                    date: f.validFrom
                )
            }
            .sorted { $0.date > $1.date }
    }
}
