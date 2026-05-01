import SwiftUI

enum DashboardTopicSemanticSearchMode: Sendable, Equatable {
    case search
    case catchUp
}

struct DashboardTopicSemanticSearchResult: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable {
        case message
        case task
        case reply
        case recent
    }

    let chatId: Int64
    let messageId: Int64?
    let chatTitle: String
    let title: String
    let senderName: String
    let snippet: String
    let date: Date?
    let score: Double
    let source: Source

    var id: String {
        "\(source.rawValue):\(chatId):\(messageId ?? 0):\(date?.timeIntervalSince1970 ?? 0):\(title)"
    }
}

struct DashboardEntityHighlight: Identifiable, Sendable, Equatable, Hashable {
    enum Kind: Int, Sendable {
        case topic = 0
        case chat = 1
        case person = 2
    }

    let label: String
    let normalizedLabel: String
    let chatId: Int64?
    let kind: Kind

    var id: String { normalizedLabel }
}

enum DashboardTopicSemanticSearchEngine {
    static func results(
        query: String,
        mode: DashboardTopicSemanticSearchMode,
        topicName: String,
        chatTitles: [Int64: String],
        ftsHits: [TelegramService.LocalMessageSearchHit],
        vectorHits: [TelegramService.LocalMessageSearchHit],
        recentMessages: [DashboardPersonRecentMessage],
        tasks: [DashboardTask],
        replies: [FollowUpItem],
        limit: Int
    ) -> [DashboardTopicSemanticSearchResult] {
        guard limit > 0 else { return [] }

        var merged: [String: MutableMessageResult] = [:]
        let maxFTS = ftsHits.map(\.score).max() ?? 0
        let maxVector = vectorHits.map { max(0, $0.score) }.max() ?? 0

        for hit in ftsHits {
            mergeMessage(hit, score: normalized(hit.score, maxScore: maxFTS) * 0.62, into: &merged)
        }

        for hit in vectorHits {
            mergeMessage(hit, score: normalized(max(0, hit.score), maxScore: maxVector) * 0.38, into: &merged)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = merged.values.map { item in
            DashboardTopicSemanticSearchResult(
                chatId: item.message.chatId,
                messageId: item.message.id,
                chatTitle: chatTitles[item.message.chatId] ?? item.message.chatTitle ?? "Chat \(item.message.chatId)",
                title: chatTitles[item.message.chatId] ?? item.message.chatTitle ?? "Chat \(item.message.chatId)",
                senderName: item.message.senderName ?? "Unknown",
                snippet: clipped(item.message.displayText),
                date: item.message.date,
                score: item.score + recencyBoost(item.message.date),
                source: .message
            )
        }

        results += tasks
            .filter(\.isActionableNow)
            .compactMap { task in
                guard includes(fields: [task.title, task.summary, task.suggestedAction, task.personName, task.chatTitle, task.topicName ?? ""], query: trimmedQuery, mode: mode) else {
                    return nil
                }
                let date = task.latestSourceDate ?? task.updatedAt
                return DashboardTopicSemanticSearchResult(
                    chatId: task.chatId,
                    messageId: nil,
                    chatTitle: chatTitles[task.chatId] ?? task.chatTitle,
                    title: task.title,
                    senderName: task.personName.isEmpty ? "Task" : task.personName,
                    snippet: clipped(task.suggestedAction.isEmpty ? task.summary : task.suggestedAction),
                    date: date,
                    score: 0.72 + matchBoost(fields: [task.title, task.summary, task.suggestedAction], query: trimmedQuery) + recencyBoost(date),
                    source: .task
                )
            }

        results += replies.compactMap { reply in
            let suggested = reply.suggestedAction ?? reply.lastMessage.displayText
            guard includes(fields: [reply.chat.title, suggested, reply.lastMessage.displayText, topicName], query: trimmedQuery, mode: mode) else {
                return nil
            }
            return DashboardTopicSemanticSearchResult(
                chatId: reply.chat.id,
                messageId: reply.lastMessage.id,
                chatTitle: chatTitles[reply.chat.id] ?? reply.chat.title,
                title: reply.suggestedAction ?? "Needs reply",
                senderName: reply.lastMessage.senderName ?? reply.chat.title,
                snippet: clipped(reply.lastMessage.displayText),
                date: reply.lastMessage.date,
                score: 0.76 + matchBoost(fields: [suggested, reply.lastMessage.displayText], query: trimmedQuery) + recencyBoost(reply.lastMessage.date),
                source: .reply
            )
        }

        results += recentMessages.compactMap { message in
            guard includes(fields: [message.chatTitle, message.senderName, message.text, topicName], query: trimmedQuery, mode: mode) else {
                return nil
            }
            return DashboardTopicSemanticSearchResult(
                chatId: message.chatId,
                messageId: nil,
                chatTitle: chatTitles[message.chatId] ?? message.chatTitle,
                title: message.chatTitle,
                senderName: message.senderName,
                snippet: clipped(message.text),
                date: message.date,
                score: 0.48 + matchBoost(fields: [message.chatTitle, message.senderName, message.text], query: trimmedQuery) + recencyBoost(message.date),
                source: .recent
            )
        }

        var seen = Set<String>()
        return results
            .filter { result in
                let key = "\(result.source.rawValue):\(result.chatId):\(result.messageId ?? 0):\(result.title):\(result.snippet)"
                return seen.insert(key).inserted
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    private struct MutableMessageResult {
        let message: TGMessage
        var score: Double
    }

    private static func mergeMessage(
        _ hit: TelegramService.LocalMessageSearchHit,
        score: Double,
        into merged: inout [String: MutableMessageResult]
    ) {
        let key = "\(hit.message.chatId):\(hit.message.id)"
        if var existing = merged[key] {
            existing.score += score
            merged[key] = existing
        } else {
            merged[key] = MutableMessageResult(message: hit.message, score: score)
        }
    }

    private static func normalized(_ score: Double, maxScore: Double) -> Double {
        guard maxScore > 0 else { return max(0, score) }
        return max(0, min(1, score / maxScore))
    }

    private static func includes(
        fields: [String],
        query: String,
        mode: DashboardTopicSemanticSearchMode
    ) -> Bool {
        if mode == .catchUp, query.isEmpty { return true }
        guard !query.isEmpty else { return false }
        return matchBoost(fields: fields, query: query) > 0
    }

    private static func matchBoost(fields: [String], query: String) -> Double {
        let terms = normalizedTerms(query)
        guard !terms.isEmpty else { return 0 }
        let haystack = normalize(fields.joined(separator: " "))
        let matches = terms.filter { haystack.contains($0) }.count
        guard matches > 0 else { return 0 }
        return min(0.22, Double(matches) / Double(terms.count) * 0.22)
    }

    private static func normalizedTerms(_ text: String) -> [String] {
        normalize(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recencyBoost(_ date: Date?) -> Double {
        guard let date else { return 0 }
        let ageDays = max(0, Date().timeIntervalSince(date) / 86_400)
        return max(0, 0.14 - min(0.14, ageDays * 0.01))
    }

    private static func clipped(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 180 else { return cleaned }
        return String(cleaned.prefix(177)) + "..."
    }
}
