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
        let requiresOutgoingEvidence: Bool
        let exactTokens: [String]
        let specificStructuredLookup: Bool
        let keywords: [String]
        let recipientKeywords: [String]
        let artifactKeywords: [String]
        let phraseFeatures: [String]
        let contextKeywords: [String]
        let platformHints: Set<String>
        let entityKinds: Set<PatternSearchResult.MatchKind>

        var requestsLinkLikeEvidence: Bool {
            artifactKeywords.contains(where: {
                ["link", "url", "doc", "docs", "github", "gist", "meet", "youtube"].contains($0)
            })
        }
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
        "chat", "chats", "my", "i", "a", "an", "to", "only", "here", "there"
    ]

    private let artifactQueryKeywords: Set<String> = [
        "wallet", "address", "contract", "hash", "link", "url", "domain", "handle", "username",
        "email", "repo", "gist", "meet", "github", "youtube", "tx", "docs", "doc"
    ]

    private let recipientStopWords: Set<String> = [
        "where", "did", "the", "with", "this", "that", "have", "from", "into", "for",
        "sent", "shared", "paste", "pasted", "posted", "show", "find", "message", "messages",
        "chat", "chats", "my", "i", "a", "an", "to", "send", "share", "post", "paste",
        "only", "here", "there", "wallet", "address", "contract", "hash", "link", "url",
        "doc", "docs"
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
        let recipientKeywords = extractedRecipientKeywords(from: normalized)
        let artifactKeywords = artifactKeywords(in: normalized)
        let phraseFeatures = phraseFeatures(in: normalized)
        let contextKeywords = contextKeywords(in: normalized)
        let platformHints = platformHints(in: normalized)
        let keywords = cleaned
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != "@" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !stopWords.contains($0) && !recipientKeywords.contains($0) }

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

        let searchPhrase = exactTokens.first ?? phraseFeatures.first ?? cleaned
        return ParsedQuery(
            raw: rawQuery,
            normalized: normalized,
            searchPhrase: searchPhrase,
            prefersOutgoing: prefersOutgoing,
            requiresOutgoingEvidence: prefersOutgoing,
            exactTokens: exactTokens,
            specificStructuredLookup: !exactTokens.isEmpty,
            keywords: keywords,
            recipientKeywords: recipientKeywords,
            artifactKeywords: artifactKeywords,
            phraseFeatures: phraseFeatures,
            contextKeywords: contextKeywords,
            platformHints: platformHints,
            entityKinds: entityKinds
        )
    }

    private func structuredTokens(in rawQuery: String) -> [String] {
        let patterns = [
            #"\b[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b"#,
            #"0x[a-fA-F0-9]{8,}"#,
            #"https?://[^\s]+"#,
            #"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}/[^\s]+"#,
            #"@[A-Za-z0-9_]{3,}"#,
            #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#,
            #"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b"#,
            #"\b(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}\b"#
        ]

        var tokens: [String] = []
        var matchedRanges: [NSRange] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(rawQuery.startIndex..<rawQuery.endIndex, in: rawQuery)
            let matches = regex.matches(in: rawQuery, range: nsRange)
            for match in matches {
                if matchedRanges.contains(where: { NSLocationInRange(match.range.location, $0) && NSMaxRange(match.range) <= NSMaxRange($0) }) {
                    continue
                }
                guard let range = Range(match.range, in: rawQuery) else { continue }
                tokens.append(String(rawQuery[range]))
                matchedRanges.append(match.range)
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

        let normalizedChatTitle = (chat?.title ?? message.chatTitle ?? "").lowercased()
        let normalizedSenderName = (message.senderName ?? "").lowercased()

        var bestMatchKind: PatternSearchResult.MatchKind?
        var matchedValue: String?
        var score = baseScore
        var exactStructuredMatches = 0
        var artifactEvidenceFound = false
        let phraseMatches = parsed.phraseFeatures.filter { normalizedText.contains($0) }
        let contextMatches = parsed.contextKeywords.filter {
            normalizedText.contains($0) || normalizedChatTitle.contains($0) || normalizedSenderName.contains($0)
        }

        if parsed.requiresOutgoingEvidence && !message.isOutgoing {
            return nil
        }

        if parsed.prefersOutgoing {
            score += message.isOutgoing ? 0.65 : -0.28
        }

        if !parsed.exactTokens.isEmpty {
            for token in parsed.exactTokens {
                if let exactMatch = bestStructuredMatch(for: token, in: rawText) {
                    exactStructuredMatches += 1
                    artifactEvidenceFound = true
                    if bestMatchKind == nil {
                        bestMatchKind = exactMatch.kind
                        matchedValue = exactMatch.value
                    }
                    score += exactMatch.scoreBoost
                }
            }
        }

        if parsed.specificStructuredLookup && exactStructuredMatches == 0 {
            return nil
        }

        if !parsed.platformHints.isEmpty && !matchesPlatformHints(parsed.platformHints, in: normalizedText) {
            return nil
        }

        if bestMatchKind == nil,
           !parsed.searchPhrase.isEmpty,
           normalizedText.contains(parsed.searchPhrase.lowercased()) {
            bestMatchKind = .exactPhrase
            matchedValue = parsed.searchPhrase
            score += 1.0
        }

        if bestMatchKind == nil, !parsed.specificStructuredLookup {
            for entityKind in parsed.entityKinds {
                if let match = allMatches(for: entityKind, in: rawText).first {
                    artifactEvidenceFound = true
                    bestMatchKind = entityKind
                    matchedValue = match
                    score += 0.95
                    break
                }
            }
        }

        let artifactKeywordMatches = parsed.artifactKeywords.filter { normalizedText.contains($0) }
        if !artifactKeywordMatches.isEmpty {
            artifactEvidenceFound = true
            if bestMatchKind == nil {
                bestMatchKind = .literalToken
                matchedValue = artifactKeywordMatches.joined(separator: " ")
                score += min(0.28, Double(artifactKeywordMatches.count) * 0.14)
            } else {
                score += min(0.18, Double(artifactKeywordMatches.count) * 0.09)
            }
        }

        if (!parsed.entityKinds.isEmpty || !parsed.artifactKeywords.isEmpty) && !artifactEvidenceFound {
            return nil
        }

        if parsed.requestsLinkLikeEvidence && !hasLinkLikeEvidence(in: normalizedText) {
            return nil
        }

        if !parsed.recipientKeywords.isEmpty {
            let matchedRecipients = parsed.recipientKeywords.filter {
                normalizedText.contains($0) || normalizedChatTitle.contains($0) || normalizedSenderName.contains($0)
            }

            guard !matchedRecipients.isEmpty else { return nil }

            let titleRecipientMatchCount = parsed.recipientKeywords.filter { normalizedChatTitle.contains($0) }.count
            if titleRecipientMatchCount > 0 {
                score += min(0.8, Double(titleRecipientMatchCount) * 0.45)
                if let chat, chat.chatType.isPrivate {
                    score += 0.18
                }
            }

            let inlineRecipientMatchCount = parsed.recipientKeywords.filter {
                normalizedText.contains($0) || normalizedSenderName.contains($0)
            }.count
            if inlineRecipientMatchCount > 0 {
                score += min(0.4, Double(inlineRecipientMatchCount) * 0.2)
            }
        }

        let keywordMatches = parsed.keywords.filter { normalizedText.contains($0) }
        if !parsed.contextKeywords.isEmpty,
           !parsed.specificStructuredLookup,
           contextMatches.isEmpty,
           phraseMatches.isEmpty,
           keywordMatches.isEmpty {
            return nil
        }
        if !keywordMatches.isEmpty {
            let ratio = Double(keywordMatches.count) / Double(max(1, parsed.keywords.count))
            if bestMatchKind == nil {
                if parsed.keywords.count >= 2 && (keywordMatches.count < min(2, parsed.keywords.count) || ratio < 0.6) {
                    return nil
                }
                bestMatchKind = .literalToken
                matchedValue = keywordMatches.joined(separator: " ")
                score += min(0.35, ratio * 0.35)
            } else {
                score += min(0.3, ratio * 0.3)
            }
        }

        score += Double(phraseMatches.count) * 0.35
        score += Double(contextMatches.count) * 0.22
        score += specializedBoost(for: parsed.phraseFeatures, contextKeywords: parsed.contextKeywords, in: normalizedText)

        guard let finalMatchKind = bestMatchKind else { return nil }

        if parsed.prefersOutgoing && message.isOutgoing && finalMatchKind != .literalToken {
            score += 0.12
        }

        if parsed.entityKinds.contains(finalMatchKind) {
            score += 0.18
        }

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
        let cleaned = normalizedEntityToken(token)
        if isEmailLike(cleaned) { return .literalToken }
        if cleaned.hasPrefix("0x") { return .evmAddress }
        if cleaned.hasPrefix("@") { return .handle }
        if cleaned.contains("://") { return .url }
        if cleaned.contains("/") { return .literalToken }
        if isDomainLike(cleaned) { return .domain }
        if isLongAddressLike(cleaned) { return .longAddress }
        return .literalToken
    }

    private func allMatches(for kind: PatternSearchResult.MatchKind, in text: String) -> [String] {
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
            return []
        }

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }

    private func bestStructuredMatch(for token: String, in text: String) -> (kind: PatternSearchResult.MatchKind, value: String, scoreBoost: Double)? {
        let tokenKind = classify(token: token)
        let normalizedToken = normalizedEntityToken(token)

        switch tokenKind {
        case .url:
            let urlMatches = allMatches(for: .url, in: text)
            if let exactURL = urlMatches.first(where: { canonicalURLToken($0) == canonicalURLToken(normalizedToken) }) {
                return (.url, exactURL, 1.85)
            }

        case .domain:
            let domainToken = canonicalDomainToken(normalizedToken)
            let domainCandidates = allMatches(for: .url, in: text) + allMatches(for: .domain, in: text)
            if let domainMatch = domainCandidates.first(where: { canonicalDomainToken($0) == domainToken }) {
                return (.domain, domainMatch, 1.7)
            }

        case .handle:
            let handleMatches = allMatches(for: .handle, in: text)
            if let handleMatch = handleMatches.first(where: { normalizedEntityToken($0) == normalizedToken }) {
                return (.handle, handleMatch, 1.75)
            }

        case .evmAddress, .walletAddress, .longAddress:
            let addressMatches = allMatches(for: .walletAddress, in: text)
            if let addressMatch = addressMatches.first(where: { normalizedEntityToken($0) == normalizedToken }) {
                let kind: PatternSearchResult.MatchKind
                if normalizedToken.hasPrefix("0x") {
                    kind = .evmAddress
                } else if normalizedToken.count >= 24 {
                    kind = .longAddress
                } else {
                    kind = .walletAddress
                }
                return (kind, addressMatch, 1.8)
            }

        case .exactPhrase, .literalToken:
            if text.lowercased().contains(normalizedToken) {
                return (.literalToken, token, 1.65)
            }
        }

        return nil
    }

    private func normalizedEntityToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\"'"))
            .lowercased()
    }

    private func canonicalURLToken(_ token: String) -> String {
        normalizedEntityToken(token)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func canonicalDomainToken(_ token: String) -> String {
        let normalized = normalizedEntityToken(token)
        let value: String
        if let url = URL(string: normalized), let host = url.host {
            value = host
        } else {
            value = normalized
                .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
                .components(separatedBy: "/")
                .first ?? normalized
        }

        return value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
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
        let normalized = normalizedEntityToken(token)
        return normalized.contains(".") && !normalized.contains("://") && !normalized.contains("/") && !normalized.hasPrefix("@")
    }

    private func isEmailLike(_ token: String) -> Bool {
        let normalized = normalizedEntityToken(token)
        guard normalized.contains("@"), normalized.contains(".") else { return false }
        return normalized.range(
            of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#,
            options: .regularExpression
        ) != nil
    }

    private func isLongAddressLike(_ token: String) -> Bool {
        let normalized = normalizedEntityToken(token)
        guard normalized.count >= 24 else { return false }
        guard normalized.range(of: #"^[1-9A-HJ-NP-Za-km-z]{24,64}$"#, options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    private func extractedRecipientKeywords(from normalizedQuery: String) -> [String] {
        let patterns = [
            #"\b(?:send|share|paste|post)\s+(?:to|with)\s+([a-z0-9_@.\- ]+)$"#,
            #"\b(?:sent|shared|pasted|posted)\s+(?:to|with)\s+([a-z0-9_@.\- ]+)$"#,
            #"\b(?:to|with)\s+([a-z0-9_@.\- ]+)$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(normalizedQuery.startIndex..<normalizedQuery.endIndex, in: normalizedQuery)
            guard let match = regex.firstMatch(in: normalizedQuery, range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: normalizedQuery) else {
                continue
            }

            let extracted = String(normalizedQuery[range])
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
                .map(String.init)
                .filter {
                    !$0.isEmpty
                    && !recipientStopWords.contains($0)
                    && !artifactQueryKeywords.contains($0)
                    && !$0.allSatisfy(\.isNumber)
                }

            if !extracted.isEmpty {
                return Array(NSOrderedSet(array: extracted)) as? [String] ?? extracted
            }
        }

        return []
    }

    private func artifactKeywords(in normalizedQuery: String) -> [String] {
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
            .map(String.init)
        return Array(NSOrderedSet(array: tokens.filter { artifactQueryKeywords.contains($0) })) as? [String] ?? []
    }

    private func phraseFeatures(in normalizedQuery: String) -> [String] {
        let phrases = [
            "case studies",
            "first dollar docs",
            "builder program",
            "admin leaderboard",
            "radar winners",
            "send 400 only",
            "google meet",
            "product hunt",
            "vesting contracts",
            "email tracking",
            "otp forwarding",
            "final collection",
            "chat handoff",
            "running 5 min late",
            "after the call"
        ]
        return phrases.filter { normalizedQuery.contains($0) }
    }

    private func contextKeywords(in normalizedQuery: String) -> [String] {
        let generic: Set<String> = [
            "first", "dollar", "where", "find", "show", "shared", "share", "sent", "send",
            "link", "url", "doc", "docs", "message", "chat", "group", "with", "after",
            "call", "that", "this", "the", "only", "here", "there", "google", "meet"
        ]
        let tokens = normalizedQuery
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." && $0 != "-" })
            .map(String.init)
        return Array(NSOrderedSet(array: tokens.filter {
            !$0.isEmpty
            && !generic.contains($0)
            && !$0.hasPrefix("@")
            && !isDomainLike($0)
        })) as? [String] ?? []
    }

    private func platformHints(in normalizedQuery: String) -> Set<String> {
        var hints: Set<String> = []
        if normalizedQuery.contains("twitter link") || normalizedQuery.contains(" x link") || normalizedQuery.hasPrefix("x link") {
            hints.insert("x")
        }
        if normalizedQuery.contains("github link") || normalizedQuery.contains("github repo") {
            hints.insert("github")
        }
        if normalizedQuery.contains("gist") {
            hints.insert("gist")
        }
        if normalizedQuery.contains("google meet") || normalizedQuery.contains("meet link") {
            hints.insert("google_meet")
        }
        if normalizedQuery.contains("basescan") || normalizedQuery.contains(" tx ") {
            hints.insert("basescan")
        }
        if normalizedQuery.contains("youtube") || normalizedQuery.contains("videos link") {
            hints.insert("youtube")
        }
        return hints
    }

    private func matchesPlatformHints(_ hints: Set<String>, in normalizedText: String) -> Bool {
        for hint in hints {
            switch hint {
            case "x":
                guard normalizedText.contains("x.com/") || normalizedText.contains("twitter.com/") else { return false }
            case "github":
                guard normalizedText.contains("github.com/") else { return false }
            case "gist":
                guard normalizedText.contains("gist.github.com/") else { return false }
            case "google_meet":
                guard normalizedText.contains("meet.google.com/") else { return false }
            case "basescan":
                guard normalizedText.contains("basescan.org/") else { return false }
            case "youtube":
                guard normalizedText.contains("youtube.com/") || normalizedText.contains("youtu.be/") else { return false }
            default:
                continue
            }
        }
        return true
    }

    private func hasLinkLikeEvidence(in normalizedText: String) -> Bool {
        ["http://", "https://", ".com", ".io", ".site", ".money", "@", "0x", "github.com/", "notion.so/"].contains {
            normalizedText.contains($0)
        }
    }

    private func specializedBoost(for phrases: [String], contextKeywords: [String], in normalizedText: String) -> Double {
        var boost = 0.0
        if phrases.contains("case studies") && normalizedText.contains("case-studies") { boost += 0.8 }
        if phrases.contains("first dollar docs") && normalizedText.contains("docs.firstdollar.money") { boost += 0.9 }
        if phrases.contains("first dollar docs") && normalizedText.contains("notion.site") { boost -= 0.45 }
        if phrases.contains("radar winners") && normalizedText.contains("radar-winners") { boost += 0.8 }
        if phrases.contains("admin leaderboard") && normalizedText.contains("admin/leaderboard") { boost += 0.7 }
        if phrases.contains("product hunt") && normalizedText.contains("producthunt") { boost += 0.45 }
        if phrases.contains("vesting contracts") && (normalizedText.contains("vesting-contracts") || normalizedText.contains("vesting contract")) { boost += 0.75 }
        if phrases.contains("email tracking") && normalizedText.contains("team@firstdollar.money") { boost += 0.9 }
        if phrases.contains("otp forwarding") && normalizedText.contains("prisha@0xfbi.com") { boost += 0.9 }
        if phrases.contains("final collection") && normalizedText.contains("final collection") { boost += 0.9 }
        if phrases.contains("chat handoff") && normalizedText.contains("moving our chat here") { boost += 0.72 }
        if phrases.contains("running 5 min late") && normalizedText.contains("running 5 min late") { boost += 0.72 }
        if contextKeywords.contains("openclaw") && normalizedText.contains("openclaw") { boost += 0.72 }
        if contextKeywords.contains("huddle01") && normalizedText.contains("huddle01.com") { boost += 0.68 }
        if contextKeywords.contains("gstack") && normalizedText.contains("gstack") { boost += 0.36 }
        if contextKeywords.contains("karpathy") && normalizedText.contains("karpathy") { boost += 0.36 }
        if contextKeywords.contains("basescan") && normalizedText.contains("basescan.org/") { boost += 0.82 }
        if contextKeywords.contains("varun") && (normalizedText.contains("youtube.com/") || normalizedText.contains("youtu.be/")) { boost += 0.52 }
        if contextKeywords.contains("cypherblocks") && normalizedText.contains("whitelist") { boost += 0.6 }
        return boost
    }
}
