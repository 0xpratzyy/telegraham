import Foundation
import TDLibKit

@MainActor
final class PatternSearchEngine {
    static let shared = PatternSearchEngine()

    private struct ParsedQuery {
        let raw: String
        let normalized: String
        let searchPhrase: String
        let prefersOutgoing: Bool
        let exactTokens: [String]
        let keywords: [String]
        let entityKinds: Set<PatternSearchResult.MatchKind>
    }

    private struct CandidateScore {
        let message: TGMessage
        let chat: TGChat?
        let chatTitle: String
        let score: Double
        let matchKind: PatternSearchResult.MatchKind
        let matchedValue: String?
        let outgoingBiasApplied: Bool
    }

    private let boilerplatePhrases = [
        "where i shared", "where did i share",
        "where i sent", "where did i send",
        "where i pasted", "where did i paste",
        "where i posted", "where did i post",
        "find message with", "find messages with",
        "show message with", "show messages with",
        "find the message", "find this link",
        "where i", "where did i", "find", "message with", "messages with"
    ]

    private let stopWords: Set<String> = [
        "where", "did", "the", "with", "this", "that", "have", "from", "into", "for",
        "sent", "shared", "paste", "pasted", "posted", "show", "find", "message", "messages",
        "chat", "chats", "my", "i", "a", "an"
    ]

    func search(
        query querySpec: QuerySpec,
        scope: QueryScope,
        scopedChats: [TGChat],
        telegramService: TelegramService
    ) async -> [PatternSearchResult] {
        let parsed = parse(querySpec.rawQuery)
        guard !scopedChats.isEmpty else { return [] }

        let chatsById = Dictionary(uniqueKeysWithValues: scopedChats.map { ($0.id, $0) })
        let scopedChatIds = scopedChats.map(\.id)

        var candidateByKey: [String: CandidateScore] = [:]

        if !parsed.searchPhrase.isEmpty {
            let ftsHits = await telegramService.localScoredSearch(
                query: parsed.searchPhrase,
                chatIds: scopedChatIds,
                limit: AppConstants.Search.Pattern.ftsCandidateLimit
            )

            for hit in ftsHits {
                guard let verified = verify(
                    message: hit.message,
                    chat: chatsById[hit.message.chatId],
                    parsed: parsed,
                    baseScore: hit.score
                ) else {
                    continue
                }
                merge(verified, into: &candidateByKey)
            }
        }

        let searchable = await DatabaseManager.shared.loadSearchableMessages(
            chatIds: scopedChatIds,
            limit: AppConstants.Search.Pattern.maxSearchableMessages
        )
        for record in searchable {
            let message = tgMessage(from: record, chat: chatsById[record.chatId])
            guard let verified = verify(
                message: message,
                chat: chatsById[record.chatId],
                parsed: parsed,
                baseScore: 0
            ) else {
                continue
            }
            merge(verified, into: &candidateByKey)
        }

        if !parsed.searchPhrase.isEmpty {
            let unindexedChatIds = await DatabaseManager.shared.unindexedChatIds(in: scopedChatIds)
            if !unindexedChatIds.isEmpty,
               let fallbackMessages = try? await telegramService.searchMessages(
                    query: parsed.searchPhrase,
                    limit: AppConstants.Search.Pattern.fallbackCandidateLimit,
                    chatTypeFilter: fallbackChatTypeFilter(for: scope)
               ) {
                for message in fallbackMessages where unindexedChatIds.contains(message.chatId) {
                    guard let verified = verify(
                        message: message,
                        chat: chatsById[message.chatId],
                        parsed: parsed,
                        baseScore: 0.15
                    ) else {
                        continue
                    }
                    merge(verified, into: &candidateByKey)
                }
            }
        }

        return candidateByKey.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.message.date != rhs.message.date { return lhs.message.date > rhs.message.date }
                return lhs.message.id > rhs.message.id
            }
            .prefix(AppConstants.Search.Pattern.maxRenderedResults)
            .map {
                PatternSearchResult(
                    message: $0.message,
                    chat: $0.chat,
                    chatTitle: $0.chatTitle,
                    snippet: snippet(from: $0.message.displayText),
                    score: $0.score,
                    matchKind: $0.matchKind,
                    matchedValue: $0.matchedValue,
                    outgoingBiasApplied: $0.outgoingBiasApplied
                )
            }
    }

    private func parse(_ rawQuery: String) -> ParsedQuery {
        let normalized = rawQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let prefersOutgoing = [
            "where i shared", "where did i share",
            "where i sent", "where did i send",
            "where i pasted", "where did i paste",
            "where i posted", "where did i post"
        ].contains(where: { normalized.contains($0) })

        var cleaned = normalized
        for phrase in boilerplatePhrases {
            cleaned = cleaned.replacingOccurrences(of: phrase, with: " ")
        }
        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let exactTokens = structuredTokens(in: rawQuery)
        let keywords = cleaned
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "@" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !stopWords.contains($0) }

        var entityKinds: Set<PatternSearchResult.MatchKind> = []
        if normalized.contains("wallet") || normalized.contains("contract") || normalized.contains("address") {
            entityKinds.insert(.walletAddress)
        }
        if normalized.contains("tx hash") || normalized.contains("transaction hash") {
            entityKinds.insert(.evmAddress)
        }
        if normalized.contains("url") || normalized.contains("link") {
            entityKinds.insert(.url)
        }
        if normalized.contains("domain") {
            entityKinds.insert(.domain)
        }
        if normalized.contains("handle") || normalized.contains("username") {
            entityKinds.insert(.handle)
        }
        if exactTokens.contains(where: { $0.hasPrefix("0x") }) {
            entityKinds.insert(.evmAddress)
        }
        if exactTokens.contains(where: { $0.hasPrefix("@") }) {
            entityKinds.insert(.handle)
        }
        if exactTokens.contains(where: { $0.contains("://") }) {
            entityKinds.insert(.url)
        }
        if exactTokens.contains(where: { isDomainLike($0) }) {
            entityKinds.insert(.domain)
        }
        if exactTokens.contains(where: { isLongAddressLike($0) }) {
            entityKinds.insert(.longAddress)
        }

        let searchPhrase = exactTokens.first ?? cleaned
        return ParsedQuery(
            raw: rawQuery,
            normalized: normalized,
            searchPhrase: searchPhrase,
            prefersOutgoing: prefersOutgoing,
            exactTokens: exactTokens,
            keywords: keywords,
            entityKinds: entityKinds
        )
    }

    private func structuredTokens(in rawQuery: String) -> [String] {
        let patterns = [
            #"0x[a-fA-F0-9]{8,}"#,
            #"https?://[^\s]+"#,
            #"@[A-Za-z0-9_]{3,}"#,
            #"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b"#,
            #"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b"#
        ]

        var tokens: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(rawQuery.startIndex..<rawQuery.endIndex, in: rawQuery)
            let matches = regex.matches(in: rawQuery, range: nsRange)
            for match in matches {
                guard let range = Range(match.range, in: rawQuery) else { continue }
                tokens.append(String(rawQuery[range]))
            }
        }
        return Array(NSOrderedSet(array: tokens)) as? [String] ?? tokens
    }

    private func verify(
        message: TGMessage,
        chat: TGChat?,
        parsed: ParsedQuery,
        baseScore: Double
    ) -> CandidateScore? {
        let rawText = message.textContent ?? message.displayText
        let normalizedText = rawText.lowercased()
        guard !normalizedText.isEmpty else { return nil }

        var bestMatchKind: PatternSearchResult.MatchKind?
        var matchedValue: String?
        var score = baseScore

        if parsed.prefersOutgoing {
            if message.isOutgoing {
                score += 0.35
            } else {
                score -= 0.18
            }
        }

        if !parsed.exactTokens.isEmpty {
            for token in parsed.exactTokens {
                if normalizedText.contains(token.lowercased()) {
                    bestMatchKind = classify(token: token)
                    matchedValue = token
                    score += 1.1
                    break
                }
            }
        }

        if bestMatchKind == nil,
           !parsed.searchPhrase.isEmpty,
           normalizedText.contains(parsed.searchPhrase.lowercased()) {
            bestMatchKind = .exactPhrase
            matchedValue = parsed.searchPhrase
            score += 0.9
        }

        if bestMatchKind == nil {
            for entityKind in parsed.entityKinds {
                if let match = firstMatch(for: entityKind, in: rawText) {
                    bestMatchKind = entityKind
                    matchedValue = match
                    score += 0.85
                    break
                }
            }
        }

        let keywordMatches = parsed.keywords.filter { normalizedText.contains($0) }
        if !keywordMatches.isEmpty {
            let ratio = Double(keywordMatches.count) / Double(max(1, parsed.keywords.count))
            score += min(0.45, ratio * 0.45)
            if bestMatchKind == nil {
                bestMatchKind = .literalToken
                matchedValue = keywordMatches.joined(separator: " ")
            }
        }

        guard let finalMatchKind = bestMatchKind else { return nil }

        if let chat, chat.chatType.isPrivate {
            score += 0.05
        }

        let recencySeconds = max(0, Date().timeIntervalSince(message.date))
        if recencySeconds <= 86_400 {
            score += 0.08
        } else if recencySeconds <= 7 * 86_400 {
            score += 0.04
        }

        let chatTitle = chat?.title ?? message.chatTitle ?? "Chat \(message.chatId)"
        return CandidateScore(
            message: message,
            chat: chat,
            chatTitle: chatTitle,
            score: score,
            matchKind: finalMatchKind,
            matchedValue: matchedValue,
            outgoingBiasApplied: parsed.prefersOutgoing && message.isOutgoing
        )
    }

    private func merge(_ candidate: CandidateScore, into candidates: inout [String: CandidateScore]) {
        let key = "\(candidate.message.chatId):\(candidate.message.id)"
        guard let existing = candidates[key] else {
            candidates[key] = candidate
            return
        }
        if candidate.score > existing.score {
            candidates[key] = candidate
        }
    }

    private func classify(token: String) -> PatternSearchResult.MatchKind {
        if token.hasPrefix("0x") { return .evmAddress }
        if token.hasPrefix("@") { return .handle }
        if token.contains("://") { return .url }
        if isDomainLike(token) { return .domain }
        if isLongAddressLike(token) { return .longAddress }
        return .literalToken
    }

    private func firstMatch(for kind: PatternSearchResult.MatchKind, in text: String) -> String? {
        let pattern: String
        switch kind {
        case .walletAddress:
            pattern = #"(0x[a-fA-F0-9]{8,}|\b[1-9A-HJ-NP-Za-km-z]{24,64}\b)"#
        case .evmAddress:
            pattern = #"0x[a-fA-F0-9]{8,}"#
        case .longAddress:
            pattern = #"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b"#
        case .url:
            pattern = #"https?://[^\s]+"#
        case .domain:
            pattern = #"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b"#
        case .handle:
            pattern = #"@[A-Za-z0-9_]{3,}"#
        case .exactPhrase, .literalToken:
            return nil
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func fallbackChatTypeFilter(for scope: QueryScope) -> SearchMessagesChatTypeFilter? {
        switch scope {
        case .all:
            return nil
        case .dms:
            return .searchMessagesChatTypeFilterPrivate
        case .groups:
            return .searchMessagesChatTypeFilterGroup
        }
    }

    private func tgMessage(from record: DatabaseManager.MessageRecord, chat: TGChat?) -> TGMessage {
        let senderId: TGMessage.MessageSenderId
        if let senderUserId = record.senderUserId {
            senderId = .user(senderUserId)
        } else {
            senderId = .chat(record.chatId)
        }

        let mediaType = record.mediaTypeRaw.flatMap(TGMessage.MediaType.init(rawValue:))

        return TGMessage(
            id: record.id,
            chatId: record.chatId,
            senderId: senderId,
            date: record.date,
            textContent: record.textContent,
            mediaType: mediaType,
            isOutgoing: record.isOutgoing,
            chatTitle: chat?.title,
            senderName: record.senderName
        )
    }

    private func snippet(from text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(normalized.prefix(AppConstants.Search.Pattern.snippetCharacterLimit))
    }

    private func isDomainLike(_ token: String) -> Bool {
        token.contains(".") && !token.contains("://") && !token.hasPrefix("@")
    }

    private func isLongAddressLike(_ token: String) -> Bool {
        guard token.count >= 24 else { return false }
        guard token.range(of: #"^[1-9A-HJ-NP-Za-km-z]{24,64}$"#, options: .regularExpression) != nil else {
            return false
        }
        return true
    }
}
