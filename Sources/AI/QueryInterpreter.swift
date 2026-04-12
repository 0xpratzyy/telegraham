import Foundation

protocol QueryInterpreting {
    func parse(query: String, now: Date, timezone: TimeZone, activeFilter: QueryScope) -> QuerySpec
}

final class QueryInterpreter: QueryInterpreting {
    private let monthNames: [String: Int] = [
        "jan": 1, "january": 1,
        "feb": 2, "february": 2,
        "mar": 3, "march": 3,
        "apr": 4, "april": 4,
        "may": 5,
        "jun": 6, "june": 6,
        "jul": 7, "july": 7,
        "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10,
        "nov": 11, "november": 11,
        "dec": 12, "december": 12
    ]

    func parse(query: String, now: Date, timezone: TimeZone = .current, activeFilter: QueryScope = .all) -> QuerySpec {
        let normalized = normalize(query)
        guard !normalized.isEmpty else {
            return QuerySpec(
                rawQuery: query,
                mode: .semanticSearch,
                family: .topicSearch,
                preferredEngine: .semanticRetrieval,
                scope: activeFilter,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.95,
                unsupportedFragments: []
            )
        }

        var unsupportedFragments: [String] = []

        // Scope parsing: query words override selected tab scope.
        let dmSignals = [
            "only dms", "only dm", "dm only", "dms only", "in dms", "in dm", "just dms", "just dm"
        ]
        let groupSignals = [
            "only groups", "group only", "groups only", "in groups", "just groups"
        ]

        let hasDMScope = containsAny(dmSignals, in: normalized)
        let hasGroupScope = containsAny(groupSignals, in: normalized)

        var scope = activeFilter
        var scopeWasExplicit = false
        if hasDMScope && hasGroupScope {
            unsupportedFragments.append("Conflicting scope terms (DMs and groups).")
        } else if hasDMScope {
            scope = .dms
            scopeWasExplicit = true
        } else if hasGroupScope {
            scope = .groups
            scopeWasExplicit = true
        }

        // Reply intent for current milestone: pipeline-only interpretation.
        let replySignals = [
            "haven't replied",
            "havent replied",
            "have not replied",
            "didn't reply",
            "didnt reply",
            "did not reply",
            "need to reply",
            "have to reply",
            "who should i reply",
            "who do i have to reply",
            "waiting on me",
            "haven't responded",
            "have not responded",
            "need my reply",
            "need my response",
            "needs my response",
            "needs my reply",
            "pending my reply",
            "pending my response",
            "owe a reply",
            "owe reply",
            "owe a response",
            "still on me",
            "follow-up from me",
            "follow up from me",
            "pending follow-up",
            "pending follow up",
            "pending follow-ups",
            "pending follow ups",
            "need response from me",
            "supposed to respond",
            "waiting on my reply",
            "open dms that need a reply",
            "open dms that need my reply",
            "responsible for answering",
            "promise to get back to",
            "promised to get back to",
            "what is on me"
        ]
        let replyPatterns = [
            #"\bneed(?:s)?\b.*\b(my|a)\s+(reply|response)\b"#,
            #"\b(pending|owe|owed)\b.*\b(reply|response)\b"#,
            #"\bfollow[\s-]?up\b.*\bfrom me\b"#,
            #"\b(still|what(?:'s| is)?)\b.*\bon me\b"#,
            #"\bowe\b.*\brepl(?:y|ies)\b"#,
            #"\brespond\b.*\bto\b"#,
            #"\bresponsible\b.*\b(answering|responding)\b"#,
            #"\bpromis(?:e|ed)\b.*\bget back\b"#,
            #"\bwaiting\b.*\bmy reply\b"#,
            #"\bopen dms?\b.*\bneed(?:s)?\b.*\breply\b"#
        ]
        let inferredReplyIntent =
            containsAny(replySignals, in: normalized)
            || regexMatches(#"\bhaven'?t\b.*\brepl(?:y|ied)\b"#, in: normalized)
            || regexMatches(#"\bwho\b.*\brepl(?:y|ied)\b"#, in: normalized)
            || regexMatches(#"\brespond(?:ed|ing)?\b"#, in: normalized) && normalized.contains("who")
            || regexMatchesAny(replyPatterns, in: normalized)
        let replyConstraint: ReplyConstraint = inferredReplyIntent ? .pipelineOnMeOnly : .none

        let timeRange = parseTimeRange(in: normalized, now: now, timezone: timezone)
        if containsAny(["before ", "after ", "between ", "except "], in: normalized) {
            unsupportedFragments.append("Advanced time operators are not fully supported yet.")
        }

        let family = inferFamily(
            normalized: normalized,
            replyConstraint: replyConstraint
        )
        let preferredEngine = preferredEngine(for: family)
        let mode = runtimeMode(
            for: family,
            preferredEngine: preferredEngine
        )

        var confidence = 0.45
        if mode == .agenticSearch { confidence += 0.15 }
        if scopeWasExplicit { confidence += 0.15 }
        if replyConstraint != .none { confidence += 0.20 }
        if timeRange != nil { confidence += 0.20 }
        if family == .exactLookup { confidence += 0.10 }
        if family == .summary || family == .relationship { confidence += 0.08 }
        confidence -= Double(unsupportedFragments.count) * 0.12
        confidence = min(0.99, max(0.05, confidence))

        return QuerySpec(
            rawQuery: query,
            mode: mode,
            family: family,
            preferredEngine: preferredEngine,
            scope: scope,
            scopeWasExplicit: scopeWasExplicit,
            replyConstraint: replyConstraint,
            timeRange: timeRange,
            parseConfidence: confidence,
            unsupportedFragments: Array(Set(unsupportedFragments)).sorted()
        )
    }

    private func inferFamily(normalized: String, replyConstraint: ReplyConstraint) -> QueryFamily {
        let crmOverridePatterns = [
            #"\bcontacts?\b.*\bhaven'?t replied\b.*\bin a while\b"#,
            #"\bwho\b.*\bhaven'?t replied\b.*\bin a while\b"#
        ]
        if regexMatchesAny(crmOverridePatterns, in: normalized) {
            return .relationship
        }

        if replyConstraint == .pipelineOnMeOnly {
            return .replyQueue
        }

        let summarySignals = [
            "summarize", "summary", "summarise", "recap",
            "what did we decide", "what happened", "what did i discuss",
            "what have we discussed", "latest context", "catch me up",
            "key takeaways", "takeaways from"
        ]
        if containsAny(summarySignals, in: normalized) {
            return .summary
        }

        let crmSignals = [
            "stale", "inactive", "most active", "top contacts", "top people",
            "warm leads", "investors", "builders", "vendors",
            "friends", "acquaintance", "who do i talk to most",
            "warmest contacts", "strongest investor relationships", "best leads",
            "relationship strength", "relationship with", "warm but not active",
            "talked to most this month", "top contacts by relationship",
            "state of my relationship"
        ]
        let crmPatterns = [
            #"\bwho are my warmest contacts\b"#,
            #"\bwhich people have i talked to most\b"#,
            #"\bstrongest\b.*\brelationships\b"#,
            #"\bbest leads\b.*\bnetwork\b"#,
            #"\brelationships?\b.*\bwarm\b.*\bnot active\b"#,
            #"\bstate of my relationship\b"#,
            #"\btop people\b.*\brelationship strength\b"#
        ]
        if containsAny(crmSignals, in: normalized) || regexMatchesAny(crmPatterns, in: normalized) {
            return .relationship
        }

        let exactLookupSignals = [
            "where did i share", "where i shared", "where did i send", "where i sent",
            "where did i paste", "where i pasted", "find message with", "find messages with",
            "show messages with", "show message with", "which chat has", "find the message",
            "find this link", "find this url", "where did i post", "where i posted"
        ]
        let exactEntitySignals = [
            "wallet address", "contract address", "tx hash", "transaction hash",
            "email address", "telegram username", "twitter handle", "discord handle",
            "link", "url", "domain", "ca ", "contract"
        ]
        let artifactSignals = [
            "wallet", "address", "contract", "hash", "link", "url", "domain", "handle", "username"
        ]
        let transferLookupSignals = [
            "i sent", "i shared", "i pasted", "i posted",
            "sent to", "shared to", "shared with", "posted to", "pasted to",
            "find", "show", "where"
        ]
        let hasStructuredToken = regexMatches(#"\b0x[a-f0-9]{6,}\b"#, in: normalized)
            || regexMatches(#"\b[1-9A-HJ-NP-Za-km-z]{24,64}\b"#, in: normalized)
            || regexMatches(#"https?://"#, in: normalized)
            || regexMatches(#"@[a-z0-9_]{3,}"#, in: normalized)
            || regexMatches(#"\b[a-z0-9-]+\.(?:com|io|co|ai|org|net|app|dev|xyz|gg|finance|me|so|money|site)\b"#, in: normalized)
        let hasArtifactTransferIntent =
            containsAny(artifactSignals, in: normalized) && containsAny(transferLookupSignals, in: normalized)

        if containsAny(exactLookupSignals, in: normalized)
            || containsAny(exactEntitySignals, in: normalized)
            || hasStructuredToken
            || hasArtifactTransferIntent {
            return .exactLookup
        }

        return .topicSearch
    }

    private func preferredEngine(for family: QueryFamily) -> QueryEngine {
        switch family {
        case .exactLookup:
            return .messageLookup
        case .topicSearch:
            return .semanticRetrieval
        case .replyQueue:
            return .replyTriage
        case .relationship:
            return .graphCRM
        case .summary:
            return .summarize
        }
    }

    private func runtimeMode(for family: QueryFamily, preferredEngine: QueryEngine) -> QueryIntent {
        switch preferredEngine {
        case .messageLookup:
            return .messageSearch
        case .semanticRetrieval:
            return .semanticSearch
        case .summarize:
            return .summarySearch
        case .replyTriage:
            return .agenticSearch
        case .graphCRM:
            return .unsupported
        }
    }

    private func normalize(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }

    private func containsAny(_ phrases: [String], in text: String) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private func regexMatchesAny(_ patterns: [String], in text: String) -> Bool {
        patterns.contains { regexMatches($0, in: text) }
    }

    private func parseTimeRange(in normalized: String, now: Date, timezone: TimeZone) -> TimeRangeConstraint? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        func dayRange(for date: Date, label: String) -> TimeRangeConstraint? {
            let start = calendar.startOfDay(for: date)
            guard let end = calendar.date(byAdding: .second, value: 86_399, to: start) else { return nil }
            return TimeRangeConstraint(startDate: start, endDate: end, label: label)
        }

        if normalized.contains("today") {
            return dayRange(for: now, label: "Today")
        }

        if normalized.contains("yesterday"),
           let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            return dayRange(for: yesterday, label: "Yesterday")
        }

        if normalized.contains("this week"),
           let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) {
            return TimeRangeConstraint(startDate: weekInterval.start, endDate: now, label: "This Week")
        }

        // Natural language "last week" is interpreted as rolling 7 days for better operator recall.
        // Use "previous calendar week" if strict calendar-week semantics are needed.
        if normalized.contains("last week") || normalized.contains("past week") {
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return nil }
            return TimeRangeConstraint(startDate: start, endDate: now, label: "Last Week")
        }

        if normalized.contains("previous calendar week"),
           let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           let lastWeekDate = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
           let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastWeekDate),
           let end = calendar.date(byAdding: .second, value: -1, to: lastWeek.end) {
            return TimeRangeConstraint(startDate: lastWeek.start, endDate: end, label: "Prev Cal Week")
        }

        if normalized.contains("this month"),
           let monthInterval = calendar.dateInterval(of: .month, for: now) {
            return TimeRangeConstraint(startDate: monthInterval.start, endDate: now, label: "This Month")
        }

        if normalized.contains("last month"),
           let thisMonth = calendar.dateInterval(of: .month, for: now),
           let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: thisMonth.start),
           let lastMonth = calendar.dateInterval(of: .month, for: lastMonthDate),
           let end = calendar.date(byAdding: .second, value: -1, to: lastMonth.end) {
            return TimeRangeConstraint(startDate: lastMonth.start, endDate: end, label: "Last Month")
        }

        let monthPattern =
            #"\b(?:in\s+)?(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\s+(\d{4}))?\b"#
        guard let regex = try? NSRegularExpression(pattern: monthPattern, options: []) else { return nil }
        let nsRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: nsRange),
              let monthRange = Range(match.range(at: 1), in: normalized) else {
            return nil
        }

        let monthToken = String(normalized[monthRange])
        guard let month = monthNames[monthToken] else { return nil }

        let year: Int
        if let yearRange = Range(match.range(at: 2), in: normalized),
           let parsedYear = Int(String(normalized[yearRange])) {
            year = parsedYear
        } else {
            let currentYear = calendar.component(.year, from: now)
            let currentMonth = calendar.component(.month, from: now)
            year = month <= currentMonth ? currentYear : (currentYear - 1)
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = timezone

        guard let start = calendar.date(from: components),
              let monthEndExclusive = calendar.date(byAdding: .month, value: 1, to: start),
              let end = calendar.date(byAdding: .second, value: -1, to: monthEndExclusive) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.timeZone = timezone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM yyyy"
        let label = formatter.string(from: start)

        return TimeRangeConstraint(startDate: start, endDate: end, label: label)
    }
}
