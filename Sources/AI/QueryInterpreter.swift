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
            "have not responded"
        ]
        let inferredReplyIntent =
            containsAny(replySignals, in: normalized)
            || regexMatches(#"\bhaven'?t\b.*\brepl(?:y|ied)\b"#, in: normalized)
            || regexMatches(#"\bwho\b.*\brepl(?:y|ied)\b"#, in: normalized)
            || regexMatches(#"\brespond(?:ed|ing)?\b"#, in: normalized) && normalized.contains("who")
        let replyConstraint: ReplyConstraint = inferredReplyIntent ? .pipelineOnMeOnly : .none

        let timeRange = parseTimeRange(in: normalized, now: now, timezone: timezone)
        if containsAny(["before ", "after ", "between ", "except "], in: normalized) {
            unsupportedFragments.append("Advanced time operators are not fully supported yet.")
        }

        let agenticSignals = [
            "intro",
            "connect",
            "warm",
            "lead",
            "reply",
            "replied",
            "respond",
            "follow up",
            "follow-up",
            "who should i",
            "who do i",
            "waiting on me"
        ]
        let mode: QueryIntent =
            (replyConstraint != .none || timeRange != nil || scopeWasExplicit || containsAny(agenticSignals, in: normalized))
            ? .agenticSearch
            : .semanticSearch

        var confidence = 0.45
        if mode == .agenticSearch { confidence += 0.15 }
        if scopeWasExplicit { confidence += 0.15 }
        if replyConstraint != .none { confidence += 0.20 }
        if timeRange != nil { confidence += 0.20 }
        confidence -= Double(unsupportedFragments.count) * 0.12
        confidence = min(0.99, max(0.05, confidence))

        return QuerySpec(
            rawQuery: query,
            mode: mode,
            scope: scope,
            scopeWasExplicit: scopeWasExplicit,
            replyConstraint: replyConstraint,
            timeRange: timeRange,
            parseConfidence: confidence,
            unsupportedFragments: Array(Set(unsupportedFragments)).sorted()
        )
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
