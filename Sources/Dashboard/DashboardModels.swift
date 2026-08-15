import Foundation

enum DashboardTaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case done
    case snoozed
    case ignored

    var label: String {
        switch self {
        case .open: return "Open"
        case .done: return "Done"
        case .snoozed: return "Snoozed"
        case .ignored: return "Ignored"
        }
    }
}

enum DashboardTaskPriority: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    var label: String {
        rawValue.capitalized
    }

    var sortRank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

struct DashboardTopic: Identifiable, Sendable, Equatable, Hashable {
    let id: Int64
    let name: String
    let rationale: String
    let score: Double
    let rank: Int
    let createdAt: Date
    let updatedAt: Date
}

struct DashboardSidebarTopicSummary: Identifiable, Sendable, Equatable, Hashable {
    let id: Int64
    let name: String
    let chatCount: Int
    let rank: Int
    let isPinned: Bool
}

enum DashboardTopicMatcher {
    struct ChatSnapshot: Identifiable, Sendable, Equatable, Hashable {
        let id: Int64
        let title: String
        let preview: String?
    }

    static func sidebarItems(
        topics: [DashboardTopic],
        chats: [ChatSnapshot],
        minimumChatCount: Int = 10,
        pinnedScore: Double = 9_000,
        limit: Int = 6
    ) -> [DashboardSidebarTopicSummary] {
        let normalizedChats = chats.map { chat in
            NormalizedChat(
                id: chat.id,
                title: normalize(chat.title),
                preview: chat.preview.map(normalize)
            )
        }

        return topics.compactMap { topic -> DashboardSidebarTopicSummary? in
            let query = DashboardTopicMatchQuery(name: topic.name, rationale: topic.rationale)
            let chatCount = normalizedChats.reduce(into: 0) { count, chat in
                if query.matchesNormalized(chat.title) || chat.preview.map(query.matchesNormalized) == true {
                    count += 1
                }
            }
            let isPinned = topic.score >= pinnedScore
            guard chatCount > minimumChatCount || isPinned else { return nil }
            return DashboardSidebarTopicSummary(
                id: topic.id,
                name: topic.name,
                chatCount: chatCount,
                rank: topic.rank,
                isPinned: isPinned
            )
        }
        .sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
            if $0.chatCount != $1.chatCount { return $0.chatCount > $1.chatCount }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    private struct NormalizedChat: Sendable {
        let id: Int64
        let title: String
        let preview: String?
    }

    fileprivate static func normalize(_ text: String) -> String {
        asciiWords(in: text, padded: false)
    }

    fileprivate static func asciiWords(in text: String, padded: Bool) -> String {
        var normalized = padded ? " " : ""
        normalized.reserveCapacity(text.utf8.count + (padded ? 2 : 0))
        var needsSeparator = false

        for byte in text.lowercased().utf8 {
            let isASCIILetter = byte >= 97 && byte <= 122
            let isASCIIDigit = byte >= 48 && byte <= 57
            if isASCIILetter || isASCIIDigit {
                if needsSeparator, normalized.last != " " {
                    normalized.append(" ")
                }
                normalized.unicodeScalars.append(UnicodeScalar(byte))
                needsSeparator = false
            } else if normalized.last != " " {
                needsSeparator = true
            }
        }

        if padded, normalized.last != " " {
            normalized.append(" ")
        }
        return normalized
    }
}

/// Compiled lexical definition shared by sidebar counts and the Topics page.
/// Branded topics (for example "First Dollar support") must retain their
/// brand anchor; generic support words must never pull unrelated chats into
/// that workspace.
struct DashboardTopicMatchQuery: Sendable {
    private let normalizedName: String
    private let nameTerms: [String]
    private let descriptionTerms: [String]
    private let brandAnchor: String?

    init(name: String, rationale: String) {
        normalizedName = DashboardTopicMatcher.normalize(name)
        let compiledNameTerms = normalizedName
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 }
        nameTerms = compiledNameTerms

        let identityTerms = compiledNameTerms.filter { !Self.genericTopicTerms.contains($0) }
        brandAnchor = identityTerms.isEmpty ? nil : identityTerms.joined(separator: " ")

        let normalizedRationale = DashboardTopicMatcher.normalize(rationale)
        descriptionTerms = normalizedRationale
            .split(separator: " ")
            .map(String.init)
            .filter {
                $0.count >= 3
                    && !Self.topicStopWords.contains($0)
                    && !compiledNameTerms.contains($0)
            }
    }

    func matches(_ text: String) -> Bool {
        matchesNormalized(DashboardTopicMatcher.normalize(text))
    }

    func matchesNormalized(_ text: String) -> Bool {
        guard !text.isEmpty, !normalizedName.isEmpty else { return false }
        if text.contains(normalizedName) { return true }

        if let brandAnchor, !text.contains(brandAnchor) {
            return false
        }

        let descriptionMatches = descriptionTerms.reduce(into: 0) { count, term in
            if text.contains(term) { count += 1 }
        }

        if brandAnchor != nil {
            return descriptionMatches >= 1
        }

        if nameTerms.count > 1, nameTerms.allSatisfy({ text.contains($0) }) { return true }
        if nameTerms.count == 1, nameTerms.first.map({ text.contains($0) }) == true { return true }

        let requiredDescriptionMatches = min(2, descriptionTerms.count)
        return requiredDescriptionMatches > 0 && descriptionMatches >= requiredDescriptionMatches
    }

    private static let genericTopicTerms: Set<String> = [
        "billing", "problem", "problems", "issue", "issues", "support", "ticket", "tickets",
        "product", "feedback", "design", "review", "reviews", "partnership", "partnerships",
        "intro", "intros", "introduction", "introductions", "hiring", "candidate", "candidates",
        "travel", "booking", "bookings", "bug", "bugs", "incident", "incidents", "request",
        "requests", "update", "updates", "customer", "customers", "help"
    ]

    private static let topicStopWords: Set<String> = [
        "added", "manually", "about", "across", "include", "includes", "including",
        "related", "things", "topic", "topics", "where", "with", "from", "that",
        "this", "these", "those", "your", "their", "into", "everything"
    ]
}

struct DashboardSuggestedTopic: Sendable, Equatable, Hashable {
    let name: String
    let description: String
    let chatCount: Int
    let tintSeed: Int64
}

/// Produces broad, reusable topic suggestions from real conversation volume.
/// Individual chat titles, email subjects, channel names, and provider IDs are
/// intentionally never promoted into topic suggestions.
enum DashboardTopicSuggestionEngine {
    static func rankedSuggestions(
        chats: [DashboardTopicMatcher.ChatSnapshot],
        existingTopicNames: [String],
        minimumChatCount: Int = 5,
        limit: Int = 6
    ) -> [DashboardSuggestedTopic] {
        let existing = Set(existingTopicNames.map(normalize))
        let normalizedChats = chats.map { chat in
            Array(normalize([chat.title, chat.preview ?? ""].joined(separator: " ")).utf8)
        }

        return catalog.enumerated().compactMap { index, candidate -> DashboardSuggestedTopic? in
            guard !existing.contains(normalize(candidate.name)) else { return nil }
            let count = normalizedChats.reduce(into: 0) { result, chatText in
                if candidate.matches(chatText) { result += 1 }
            }
            guard count >= minimumChatCount else { return nil }
            return DashboardSuggestedTopic(
                name: candidate.name,
                description: candidate.description,
                chatCount: count,
                tintSeed: Int64(-10_000 - index)
            )
        }
        .sorted {
            if $0.chatCount != $1.chatCount { return $0.chatCount > $1.chatCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .prefix(limit)
        .map { $0 }
    }

    private struct Candidate: Sendable {
        let name: String
        let description: String
        /// Every group must contribute at least one matching phrase. A single
        /// group represents an OR-list; multiple groups make a focused AND.
        let normalizedPhraseGroups: [[[UInt8]]]

        init(name: String, description: String, requiredPhraseGroups: [[String]]) {
            self.name = name
            self.description = description
            normalizedPhraseGroups = requiredPhraseGroups.map { group in
                group.map { Array(DashboardTopicSuggestionEngine.normalize($0).utf8) }
            }
        }

        func matches(_ text: [UInt8]) -> Bool {
            normalizedPhraseGroups.allSatisfy { group in
                group.contains { DashboardTopicSuggestionEngine.contains($0, in: text) }
            }
        }
    }

    private static let catalog: [Candidate] = [
        Candidate(
            name: "Billing problems",
            description: "Failed or overdue payments, card declines, invoices, refunds, renewals, subscription issues, and billing support.",
            requiredPhraseGroups: [[
                "billing", "bill", "invoice", "payment", "paid", "pay", "charge", "refund",
                "renewal", "renew", "subscription", "card decline", "declined", "failed transaction",
                "overdue", "receipt", "top up", "topup"
            ]]
        ),
        Candidate(
            name: "First Dollar support",
            description: "Customer questions, bug reports, profile verification, onboarding issues, and support requests about First Dollar.",
            requiredPhraseGroups: [
                ["first dollar", "firstdollar", "first-dollar"],
                ["support", "ticket", "help", "issue", "bug", "problem", "verify", "verification", "profile", "onboard", "application", "account", "access", "review", "fix", "error", "failed"]
            ]
        ),
        Candidate(
            name: "Product feedback",
            description: "Product feedback, feature requests, user testing notes, usability issues, and requested improvements.",
            requiredPhraseGroups: [[
                "product feedback", "feature request", "user testing", "usability", "beta tester",
                "design feedback", "feedback on", "requested improvement"
            ]]
        ),
        Candidate(
            name: "Design reviews",
            description: "Design reviews and requested changes involving Figma, UI, UX, pages, screens, themes, and visual assets.",
            requiredPhraseGroups: [
                ["design", "figma", " ui ", " ux ", "page", "screen", "theme", "mockup", "storyline"],
                ["review", "feedback", "check", "approve", "change", "update", "fix", "better version"]
            ]
        ),
        Candidate(
            name: "Partnerships & intros",
            description: "Partnership discussions, introductions, collaborations, sponsorships, and follow-ups with potential partners.",
            requiredPhraseGroups: [[
                "partnership", "partner", "introduction", "intro", "collaboration", "collab",
                "sponsorship", "sponsor", "distribution connection"
            ]]
        ),
        Candidate(
            name: "Hiring & candidates",
            description: "Hiring conversations, applicants, interviews, job offers, candidate reviews, and role discussions.",
            requiredPhraseGroups: [[
                "hiring", "candidate", "applicant", "interview", "job offer", "job application", "role opening", "recruit"
            ]]
        ),
        Candidate(
            name: "Travel & bookings",
            description: "Flights, hotels, check-ins, itineraries, visas, reservations, and other travel logistics.",
            requiredPhraseGroups: [[
                "flight", "hotel", "check in", "check-in", "itinerary", "visa", "reservation", "travel", "booking"
            ]]
        ),
        Candidate(
            name: "Bugs & incidents",
            description: "Errors, outages, broken flows, failed deployments, regressions, and production incidents that need investigation.",
            requiredPhraseGroups: [[
                "bug", "error", "outage", "offline", "broken", "failed deployment", "regression", "incident", "not working"
            ]]
        )
    ]

    private static func normalize(_ text: String) -> String {
        DashboardTopicMatcher.asciiWords(in: text, padded: true)
    }

    /// The matcher operates only on normalized ASCII. A byte scan avoids
    /// Foundation's locale-aware String range machinery, which dominated the
    /// sidebar suggestion profile even after regex normalization was removed.
    private static func contains(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let lastStart = haystack.count - needle.count
        for start in 0...lastStart {
            var matched = true
            for offset in needle.indices where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }
}

struct DashboardTask: Identifiable, Sendable, Equatable, Hashable {
    let id: Int64
    let stableFingerprint: String
    let title: String
    let summary: String
    let suggestedAction: String
    let ownerName: String
    let personName: String
    let chatId: Int64
    let chatTitle: String
    let topicId: Int64?
    let topicName: String?
    let priority: DashboardTaskPriority
    let status: DashboardTaskStatus
    let confidence: Double
    let createdAt: Date
    let updatedAt: Date
    let dueAt: Date?
    let snoozedUntil: Date?
    let latestSourceDate: Date?
    /// When the user last changed this task's status by hand (done /
    /// snooze / ignore / re-open). Nil = never touched.
    let statusSetByUserAt: Date?

    /// Done or ignored — terminal unless the user re-opens.
    var isClosed: Bool {
        status == .done || status == .ignored
    }

    var isActionableNow: Bool {
        switch status {
        case .open:
            return true
        case .snoozed:
            guard let snoozedUntil else { return false }
            return snoozedUntil <= Date()
        case .done, .ignored:
            return false
        }
    }
}

/// Turns model-written task sentences into scan-friendly macOS list titles.
/// The full source text remains in `summary`/evidence; this is presentation
/// copy only, so old facts improve immediately without rewriting storage.
enum DashboardTaskTitle {
    static func compact(_ rawValue: String) -> String {
        var title = normalized(rawValue)
        guard !title.isEmpty else { return "Untitled task" }

        title = title.replacingOccurrences(
            of: #"(?i)^\[?action required\]?\s*[:\-–—]?\s*"#,
            with: "",
            options: .regularExpression
        )

        let semanticRules: [(pattern: String, replacement: String)] = [
            (
                #"(?i)^complete required action\s*:\s*(.+?)[.!]?$"#,
                "Review $1"
            ),
            (
                #"(?i)^your\s+(.+?)\s+site at\s+(\S+)\s+is about to go offline[.!]?$"#,
                "Renew $2 on $1"
            ),
            (
                #"(?i)^reactivate the\s+(.+?)\s+subscription for\s+(\S+)[.!]?$"#,
                "Renew $2 on $1"
            ),
            (
                #"(?i)^complete the\s+.+\s+for the\s+(.+?)\s+grant[.!]?$"#,
                "Complete $1 grant forms"
            ),
            (
                #"(?i)^approve the\s+(.+?)\s+transaction(?:\s+in|\s+on)\s+.+$"#,
                "Approve $1 transaction"
            ),
            (
                #"(?i)^download the affected\s+(.+?)\s+before\s+.+$"#,
                "Download expiring $1"
            ),
            (
                #"(?i)^provide (?:an?\s+)?identity document for\s+.+?\s+on\s+(?:the\s+)?(.+?)\s+dashboard[.!]?$"#,
                "Verify identity on $1"
            ),
            (
                #"(?i)^upload the\s+(?:valid\s+)?(?:unexpired\s+)?(.+?)\s+to\s+(?:the\s+)?(.+?)\s+dashboard for\s+.+$"#,
                "Upload $1 to $2"
            ),
            (
                #"(?i)^pay the invoice for\s+(.+?)\s+to\s+(.+?)[.!]?$"#,
                "Pay $2 invoice · $1"
            ),
            (
                #"(?i)^pay the\s+(.+?)\s+api invoice\s*\((.+?)\)[.!]?$"#,
                "Pay $1 invoice · $2"
            ),
            (
                #"(?i)^pay the\s+(.+?)\s+bill of\s+(.+?)(?:\s+due on\s+.+)?[.!]?$"#,
                "Pay $1 · $2"
            )
        ]

        for rule in semanticRules where title.range(of: rule.pattern, options: .regularExpression) != nil {
            title = title.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: .regularExpression
            )
            break
        }

        title = title.replacingOccurrences(
            of: #"(?i)\s+(?:in|on)\s+the\s+.+?\s+(?:mobile banking\s+)?app[.!]?$"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"(?i)\s+due on\s+.+$"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: " credit card", with: " card", options: .caseInsensitive)
        title = normalized(title)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-"))

        return bounded(title, maxWords: 9, maxCharacters: 68)
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String, maxWords: Int, maxCharacters: Int) -> String {
        var words = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
        var wasClipped = words.count > maxWords
        if wasClipped { words = Array(words.prefix(maxWords)) }
        var result = words.joined(separator: " ")

        if result.count > maxCharacters {
            let end = result.index(result.startIndex, offsetBy: maxCharacters)
            let prefix = String(result[..<end])
            result = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
            wasClipped = true
        }
        return result + (wasClipped ? "…" : "")
    }
}

struct DashboardTaskSourceMessage: Sendable, Equatable, Hashable {
    let chatId: Int64
    let messageId: Int64
    let senderName: String
    let text: String
    let date: Date
}

enum DashboardTaskOwnerFilter: Sendable, Equatable, Hashable, Identifiable {
    case mine
    case owner(String)
    case all

    var id: String {
        switch self {
        case .mine:
            return "mine"
        case .owner(let name):
            return "owner:\(DashboardTaskOwnership.normalizedOwnerName(name))"
        case .all:
            return "all"
        }
    }
}

struct DashboardTaskOwnerOption: Identifiable, Sendable, Equatable, Hashable {
    let filter: DashboardTaskOwnerFilter
    let label: String
    let count: Int

    var id: String { filter.id }
}

struct DashboardTaskOwnerSearchOption: Identifiable, Sendable, Equatable, Hashable {
    let filter: DashboardTaskOwnerFilter
    let label: String
    let count: Int
    let subtitle: String?

    var id: String { filter.id }
}

struct DashboardTaskPersonOption: Identifiable, Sendable, Equatable, Hashable {
    let name: String
    let count: Int

    var id: String { DashboardTaskOwnership.normalizedOwnerName(name) }
}

enum DashboardTaskOwnership {
    static func isMine(ownerName: String, currentUser: TGUser?) -> Bool {
        let normalizedOwner = normalizedOwnerName(ownerName)
        guard !normalizedOwner.isEmpty else { return false }
        return userOwnerAliases(for: currentUser).contains(normalizedOwner)
    }

    static func isKnownOwner(_ ownerName: String) -> Bool {
        let normalized = normalizedOwnerName(ownerName)
        return !normalized.isEmpty && !["unknown", "unclear", "none", "unassigned"].contains(normalized)
    }

    static func matches(
        ownerName: String,
        filter: DashboardTaskOwnerFilter?,
        currentUser: TGUser?
    ) -> Bool {
        guard let filter else { return true }
        switch filter {
        case .mine:
            return isMine(ownerName: ownerName, currentUser: currentUser)
        case .owner(let name):
            return normalizedOwnerName(ownerName) == normalizedOwnerName(name)
        case .all:
            return true
        }
    }

    static func matches(
        task: DashboardTask,
        filter: DashboardTaskOwnerFilter?,
        currentUser: TGUser?
    ) -> Bool {
        guard let filter else { return true }
        switch filter {
        case .mine:
            return isMine(ownerName: task.ownerName, currentUser: currentUser)
        case .owner(let name):
            // Owner chips filter strictly by ownerName. Previously we also
            // matched personName, which leaked tasks whose subject (but not
            // owner) was the selected person — e.g. "Create the campaign"
            // (owner=Me, person=Rajanshee) showed up under the "Rajanshee"
            // chip because Rajanshee was the conversational person.
            return namesOverlap(task.ownerName, name)
        case .all:
            return true
        }
    }

    static func namesOverlap(_ lhs: String, _ rhs: String) -> Bool {
        let lhsAliases = ownerAliases(for: lhs)
        let rhsAliases = ownerAliases(for: rhs)
        guard !lhsAliases.isEmpty, !rhsAliases.isEmpty else { return false }
        return !lhsAliases.isDisjoint(with: rhsAliases)
    }

    static func ownerOptions(
        for tasks: [DashboardTask],
        currentUser: TGUser?,
        limit: Int = 5
    ) -> [DashboardTaskOwnerOption] {
        guard !tasks.isEmpty else {
            return [
                DashboardTaskOwnerOption(filter: .mine, label: "Mine", count: 0),
                DashboardTaskOwnerOption(filter: .all, label: "All", count: 0)
            ]
        }

        var mineCount = 0
        var grouped: [String: (label: String, count: Int)] = [:]

        for task in tasks {
            if isMine(ownerName: task.ownerName, currentUser: currentUser) {
                mineCount += 1
                continue
            }

            guard isKnownOwner(task.ownerName) else { continue }
            let normalized = normalizedOwnerName(task.ownerName)
            let label = displayOwnerName(task.ownerName)
            let existing = grouped[normalized]
            grouped[normalized] = (label: existing?.label ?? label, count: (existing?.count ?? 0) + 1)
        }

        let otherOptions = grouped.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            .prefix(limit)
            .map { DashboardTaskOwnerOption(filter: .owner($0.label), label: $0.label, count: $0.count) }

        return [
            DashboardTaskOwnerOption(filter: .mine, label: "Mine", count: mineCount)
        ] + otherOptions + [
            DashboardTaskOwnerOption(filter: .all, label: "All", count: tasks.count)
        ]
    }

    static func normalizedOwnerName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func ownerAliases(for value: String) -> Set<String> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = normalizedOwnerName(trimmed)
        var aliases: Set<String> = []
        if !full.isEmpty {
            aliases.insert(full)
        }

        // Only include the FIRST token (first name) as a secondary alias.
        // Previously we added every token, which caused last names like
        // "Singh" to make unrelated people collide — "Rahul Singh
        // Bhadoriya" and "Rajanshee Singh" share `singh`, so the
        // "Rajanshee Singh" chip was matching all of Rahul's tasks too.
        // First-name matches still catch the common "Rajanshee" vs
        // "Rajanshee Singh" merge that the chip strip relies on.
        let tokens = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalizedOwnerName)
            .filter { $0.count >= 2 }
        if let firstToken = tokens.first, !firstToken.isEmpty {
            aliases.insert(firstToken)
        }

        return aliases
    }

    private static func displayOwnerName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown" : trimmed
    }

    private static func userOwnerAliases(for user: TGUser?) -> Set<String> {
        var aliases: Set<String> = [
            "me",
            "myself",
            "you"
        ]

        guard let user else { return aliases }

        for value in [user.firstName, user.lastName, user.displayName] {
            let normalized = normalizedOwnerName(value)
            if !normalized.isEmpty {
                aliases.insert(normalized)
            }
        }

        if let username = user.username {
            let normalized = normalizedOwnerName(username)
            if !normalized.isEmpty {
                aliases.insert(normalized)
            }
        }

        return aliases
    }
}

enum DashboardTaskPeople {
    static func personOptions(
        for tasks: [DashboardTask],
        minimumCount: Int = 2,
        limit: Int = 8
    ) -> [DashboardTaskPersonOption] {
        var grouped: [String: (label: String, count: Int)] = [:]

        for task in tasks {
            let name = task.personName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let normalized = DashboardTaskOwnership.normalizedOwnerName(name)
            guard !normalized.isEmpty && normalized != "unknown" else { continue }

            let existing = grouped[normalized]
            grouped[normalized] = (label: existing?.label ?? name, count: (existing?.count ?? 0) + 1)
        }

        return grouped.values
            .filter { $0.count >= minimumCount }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            .prefix(limit)
            .map { DashboardTaskPersonOption(name: $0.label, count: $0.count) }
    }
}

enum DashboardTaskListFilters {
    static func tasksForStatusFilter(
        _ tasks: [DashboardTask],
        statusFilter: DashboardStatusFilter
    ) -> [DashboardTask] {
        switch statusFilter {
        case .all:
            return tasks.filter { $0.status != .ignored }
        case .open:
            return tasks.filter { $0.status == .open }
        case .snoozed:
            return tasks.filter { $0.status == .snoozed }
        case .done:
            return tasks.filter { $0.status == .done }
        case .ignored:
            return tasks.filter { $0.status == .ignored }
        }
    }

    static func filteredTasks(
        _ tasks: [DashboardTask],
        status: DashboardTaskStatus?,
        ownerFilter: DashboardTaskOwnerFilter,
        currentUser: TGUser?
    ) -> [DashboardTask] {
        DashboardTaskFilter.apply(
            tasks,
            status: status,
            ownerFilter: ownerFilter,
            currentUser: currentUser
        )
    }

    static func count(
        _ tasks: [DashboardTask],
        status: DashboardTaskStatus?,
        ownerFilter: DashboardTaskOwnerFilter,
        currentUser: TGUser?
    ) -> Int {
        filteredTasks(
            tasks,
            status: status,
            ownerFilter: ownerFilter,
            currentUser: currentUser
        ).count
    }

    static func ownerChips(
        for tasks: [DashboardTask],
        currentUser: TGUser?,
        limit: Int = 10
    ) -> [DashboardTaskOwnerOption] {
        DashboardTaskOwnership.ownerOptions(
            for: tasks,
            currentUser: currentUser,
            limit: limit
        )
        .compactMap { option in
            switch option.filter {
            case .mine:
                return DashboardTaskOwnerOption(
                    filter: option.filter,
                    label: "For me",
                    count: option.count
                )
            case .owner:
                return option
            case .all:
                return nil
            }
        }
    }

    /// Build the chip strip for the Tasks page: always "For me" first, then a
    /// chip for every owner the user has explicitly pinned (with the current
    /// matching-task count). Unlike ``ownerChips(for:currentUser:limit:)``,
    /// this never auto-derives a chip from current task data — chips only
    /// appear here once the user adds them via the "+" picker, so the strip
    /// stays stable across syncs and refreshes.
    static func pinnedOwnerChips(
        pinnedNames: [String],
        tasks: [DashboardTask],
        currentUser: TGUser?
    ) -> [DashboardTaskOwnerOption] {
        let mineCount = count(
            tasks,
            status: nil,
            ownerFilter: .mine,
            currentUser: currentUser
        )
        let anyoneCount = count(
            tasks,
            status: nil,
            ownerFilter: .all,
            currentUser: currentUser
        )

        var seen: Set<String> = []
        // "Anyone" only adds value when Pidgy actually extracted work owned
        // by somebody else. If both sets are identical, showing both chips
        // creates two controls that do the same thing.
        var chips: [DashboardTaskOwnerOption] = [
            DashboardTaskOwnerOption(filter: .mine, label: "For me", count: mineCount)
        ]
        if anyoneCount > mineCount {
            chips.append(DashboardTaskOwnerOption(filter: .all, label: "Anyone", count: anyoneCount))
        }

        for rawName in pinnedNames {
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = DashboardTaskOwnership.normalizedOwnerName(trimmed)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let chipCount = count(
                tasks,
                status: nil,
                ownerFilter: .owner(trimmed),
                currentUser: currentUser
            )
            chips.append(
                DashboardTaskOwnerOption(
                    filter: .owner(trimmed),
                    label: trimmed,
                    count: chipCount
                )
            )
        }

        return chips
    }

    static func ownerAddOptions(
        visibleOptions: [DashboardTaskOwnerOption],
        allTasks: [DashboardTask],
        currentUser: TGUser?,
        limit: Int = 30
    ) -> [DashboardTaskOwnerOption] {
        let visibleIds = Set(visibleOptions.map(\.id))
        return ownerChips(
            for: allTasks,
            currentUser: currentUser,
            limit: limit
        )
        .filter { option in
            guard !visibleIds.contains(option.id) else { return false }
            if case .mine = option.filter { return false }
            return true
        }
    }

    static func ownerSearchOptions(
        visibleOptions: [DashboardTaskOwnerOption],
        allTasks: [DashboardTask],
        people: [RelationGraph.Node],
        currentUser: TGUser?,
        query: String,
        limit: Int = 40
    ) -> [DashboardTaskOwnerSearchOption] {
        let visibleIds = Set(visibleOptions.map(\.id))
        let normalizedQuery = DashboardTaskOwnership.normalizedOwnerName(query)
        let activeTasks = tasksForStatusFilter(allTasks, statusFilter: .all)
        var archivedCounts: [String: Int] = [:]
        var options: [String: (label: String, count: Int, subtitle: String?, score: Double)] = [:]

        for task in allTasks {
            guard DashboardTaskOwnership.isKnownOwner(task.ownerName),
                  !DashboardTaskOwnership.isMine(ownerName: task.ownerName, currentUser: currentUser)
            else { continue }

            let normalized = DashboardTaskOwnership.normalizedOwnerName(task.ownerName)
            if task.status == .ignored {
                archivedCounts[normalized, default: 0] += 1
            }
        }

        for task in activeTasks {
            let profileNames = [task.personName, task.ownerName]
            for name in profileNames {
                guard DashboardTaskOwnership.isKnownOwner(name),
                      !DashboardTaskOwnership.isMine(ownerName: name, currentUser: currentUser)
                else { continue }

                let count = profileTaskCount(
                    in: activeTasks,
                    name: name,
                    currentUser: currentUser
                )
                addOwnerSearchOption(
                    name: name,
                    count: count,
                    subtitle: DashboardTaskOwnership.namesOverlap(task.ownerName, name) ? "Assigned owner" : "Related tasks",
                    score: 20_000 + Double(count) * 100,
                    visibleIds: visibleIds,
                    normalizedQuery: normalizedQuery,
                    currentUser: currentUser,
                    into: &options
                )
            }
        }

        for task in allTasks where task.status == .ignored {
            let normalized = DashboardTaskOwnership.normalizedOwnerName(task.ownerName)
            guard DashboardTaskOwnership.isKnownOwner(task.ownerName),
                  !DashboardTaskOwnership.isMine(ownerName: task.ownerName, currentUser: currentUser)
            else { continue }

            let activeCount = profileTaskCount(
                in: activeTasks,
                name: task.ownerName,
                currentUser: currentUser
            )
            guard activeCount == 0 else { continue }

            addOwnerSearchOption(
                name: task.ownerName,
                count: 0,
                subtitle: "\(archivedCounts[normalized, default: 0]) archived",
                score: 10_000 + Double(archivedCounts[normalized, default: 0]),
                visibleIds: visibleIds,
                normalizedQuery: normalizedQuery,
                currentUser: currentUser,
                into: &options
            )
        }

        for person in people {
            let displayName = person.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = person.username?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = [displayName, username].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first
            guard let name else { continue }

            let subtitle = username.flatMap { username -> String? in
                guard !username.isEmpty, username != displayName else { return nil }
                return "@\(username)"
            }

            addOwnerSearchOption(
                name: name,
                count: profileTaskCount(
                    in: activeTasks,
                    name: name,
                    currentUser: currentUser
                ),
                subtitle: subtitle,
                score: person.interactionScore,
                visibleIds: visibleIds,
                normalizedQuery: normalizedQuery,
                currentUser: currentUser,
                into: &options
            )
        }

        return options.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            .prefix(limit)
            .map {
                DashboardTaskOwnerSearchOption(
                    filter: .owner($0.label),
                    label: $0.label,
                    count: $0.count,
                    subtitle: $0.subtitle
            )
        }
    }

    private static func profileTaskCount(
        in tasks: [DashboardTask],
        name: String,
        currentUser: TGUser?
    ) -> Int {
        tasks.filter {
            DashboardTaskOwnership.matches(
                task: $0,
                filter: .owner(name),
                currentUser: currentUser
            )
        }.count
    }

    private static func addOwnerSearchOption(
        name: String,
        count: Int,
        subtitle: String?,
        score: Double,
        visibleIds: Set<String>,
        normalizedQuery: String,
        currentUser: TGUser?,
        into options: inout [String: (label: String, count: Int, subtitle: String?, score: Double)]
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DashboardTaskOwnership.isKnownOwner(trimmed),
              !DashboardTaskOwnership.isMine(ownerName: trimmed, currentUser: currentUser)
        else { return }

        let normalized = DashboardTaskOwnership.normalizedOwnerName(trimmed)
        guard !normalized.isEmpty,
              !visibleIds.contains(DashboardTaskOwnerFilter.owner(trimmed).id),
              normalizedQuery.isEmpty || normalized.contains(normalizedQuery)
        else { return }

        let existingKey = options.keys.first { key in
            guard let option = options[key] else { return false }
            return DashboardTaskOwnership.namesOverlap(option.label, trimmed)
        }

        if let existingKey, let existing = options[existingKey] {
            let preferredLabel = existing.label.count >= trimmed.count ? existing.label : trimmed
            options[existingKey] = (
                label: preferredLabel,
                count: max(existing.count, count),
                subtitle: existing.subtitle ?? subtitle,
                score: max(existing.score, score)
            )
        } else {
            options[normalized] = (
                label: trimmed,
                count: count,
                subtitle: subtitle,
                score: score
            )
        }
    }
}

enum DashboardTaskFilter {
    static func sortByRecentActivity(_ tasks: [DashboardTask]) -> [DashboardTask] {
        tasks.sorted { lhs, rhs in
            let lhsDate = lhs.latestSourceDate ?? lhs.updatedAt
            let rhsDate = rhs.latestSourceDate ?? rhs.updatedAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.id > rhs.id
        }
    }

    static func excludingChatIds(
        _ tasks: [DashboardTask],
        _ excludedChatIds: Set<Int64>
    ) -> [DashboardTask] {
        guard !excludedChatIds.isEmpty else { return tasks }
        return tasks.filter { !excludedChatIds.contains($0.chatId) }
    }

    static func apply(
        _ tasks: [DashboardTask],
        status: DashboardTaskStatus? = nil,
        ownerFilter: DashboardTaskOwnerFilter? = nil,
        currentUser: TGUser? = nil,
        topicId: Int64? = nil,
        chatId: Int64? = nil,
        personQuery: String = ""
    ) -> [DashboardTask] {
        let normalizedPerson = personQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return sortByRecentActivity(tasks.filter { task in
            if let status, task.status != status {
                return false
            }
            if !DashboardTaskOwnership.matches(
                task: task,
                filter: ownerFilter,
                currentUser: currentUser
            ) {
                return false
            }
            if let topicId, task.topicId != topicId {
                return false
            }
            if let chatId, task.chatId != chatId {
                return false
            }
            if !normalizedPerson.isEmpty {
                let person = task.personName.lowercased()
                let owner = task.ownerName.lowercased()
                let chat = task.chatTitle.lowercased()
                return person.contains(normalizedPerson)
                    || owner.contains(normalizedPerson)
                    || chat.contains(normalizedPerson)
            }
            return true
        })
    }
}

enum DashboardPeopleLens: String, CaseIterable, Identifiable, Sendable {
    case needsYou
    case keyPeople
    case goingCold
    case recent
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .needsYou:
            return "Needs you"
        case .keyPeople:
            return "Key people"
        case .goingCold:
            return "Going cold"
        case .recent:
            return "Recent"
        case .all:
            return "All"
        }
    }
}

struct DashboardPersonSignal: Identifiable, Sendable, Equatable, Hashable {
    let contact: RelationGraph.Node
    let openReplyCount: Int
    let openTaskCount: Int
    let stale: Bool
    let latestActivityAt: Date?

    var id: Int64 { contact.entityId }
    var needsAttention: Bool { openReplyCount > 0 || openTaskCount > 0 }
}

struct DashboardPeopleRenderWindow: Sendable, Equatable {
    static let defaultPageSize = 80

    let pageSize: Int
    let loadedCount: Int

    func visibleSignals(from signals: [DashboardPersonSignal]) -> [DashboardPersonSignal] {
        Array(signals.prefix(max(0, loadedCount)))
    }

    func hasLoadedAll(totalCount: Int) -> Bool {
        loadedCount >= totalCount
    }

    func nextLoadedCount(totalCount: Int) -> Int {
        min(totalCount, loadedCount + pageSize)
    }
}

enum DashboardPeopleDirectory {
    static func buildSignals(
        contacts: [RelationGraph.Node],
        tasks: [DashboardTask],
        followUpItems: [FollowUpItem],
        staleContactIds: Set<Int64>,
        now: Date = Date()
    ) -> [DashboardPersonSignal] {
        // Nameless nodes are unusable rows AND poison the name-based matching
        // below (an "Unknown" contact matches every "Unknown"-owner task).
        let uniqueContacts = uniqueContacts(contacts).filter(\.hasResolvedName)
        let matchers = uniqueContacts.map { ContactMatcher(contact: $0, terms: searchTerms(for: $0)) }
        var replyCounts: [Int64: Int] = [:]
        var taskCounts: [Int64: Int] = [:]

        for task in tasks where task.isActionableNow {
            let fields = [task.personName, task.ownerName, task.chatTitle]
            for matcher in matchers where matches(matcher, fields: fields) {
                taskCounts[matcher.contact.entityId, default: 0] += 1
            }
        }

        for item in followUpItems where item.category == .onMe {
            switch item.chat.chatType {
            case .privateChat(let userId):
                replyCounts[userId, default: 0] += 1
                continue
            default:
                break
            }

            let fields = [item.chat.title, item.lastMessage.senderName ?? ""]
            for matcher in matchers where matches(matcher, fields: fields) {
                replyCounts[matcher.contact.entityId, default: 0] += 1
            }
        }

        return buildSignals(
            contacts: uniqueContacts,
            replyCountsByPersonId: replyCounts,
            taskCountsByPersonId: taskCounts,
            staleContactIds: staleContactIds,
            now: now
        )
    }

    static func buildSignals(
        contacts: [RelationGraph.Node],
        replyCountsByPersonId: [Int64: Int],
        taskCountsByPersonId: [Int64: Int],
        staleContactIds: Set<Int64>,
        now: Date = Date()
    ) -> [DashboardPersonSignal] {
        let uniqueContacts = contacts.reduce(into: [Int64: RelationGraph.Node]()) { byId, contact in
            guard byId[contact.entityId] == nil else { return }
            byId[contact.entityId] = contact
        }

        return uniqueContacts.values.map { contact in
            DashboardPersonSignal(
                contact: contact,
                openReplyCount: replyCountsByPersonId[contact.entityId] ?? 0,
                openTaskCount: taskCountsByPersonId[contact.entityId] ?? 0,
                stale: staleContactIds.contains(contact.entityId),
                latestActivityAt: contact.lastInteractionAt ?? contact.firstSeenAt
            )
        }
        .sorted(by: sortKeyPeople)
    }

    static func filtered(
        _ signals: [DashboardPersonSignal],
        lens: DashboardPeopleLens
    ) -> [DashboardPersonSignal] {
        switch lens {
        case .needsYou:
            return signals
                .filter(\.needsAttention)
                .sorted(by: sortNeedsAttention)
        case .keyPeople:
            return signals.sorted(by: sortKeyPeople)
        case .goingCold:
            return signals
                .filter(\.stale)
                .sorted(by: sortGoingCold)
        case .recent:
            return signals
                .filter { $0.latestActivityAt != nil }
                .sorted(by: sortRecent)
        case .all:
            return signals.sorted {
                $0.contact.bestDisplayName.localizedCaseInsensitiveCompare($1.contact.bestDisplayName) == .orderedAscending
            }
        }
    }

    private static func sortNeedsAttention(_ lhs: DashboardPersonSignal, _ rhs: DashboardPersonSignal) -> Bool {
        let lhsWork = lhs.openReplyCount + lhs.openTaskCount
        let rhsWork = rhs.openReplyCount + rhs.openTaskCount
        if lhsWork != rhsWork {
            return lhsWork > rhsWork
        }
        return sortRecent(lhs, rhs)
    }

    private static func sortKeyPeople(_ lhs: DashboardPersonSignal, _ rhs: DashboardPersonSignal) -> Bool {
        if lhs.contact.interactionScore != rhs.contact.interactionScore {
            return lhs.contact.interactionScore > rhs.contact.interactionScore
        }
        return sortRecent(lhs, rhs)
    }

    private static func sortGoingCold(_ lhs: DashboardPersonSignal, _ rhs: DashboardPersonSignal) -> Bool {
        let lhsDate = lhs.latestActivityAt ?? .distantPast
        let rhsDate = rhs.latestActivityAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        return sortKeyPeople(lhs, rhs)
    }

    private static func sortRecent(_ lhs: DashboardPersonSignal, _ rhs: DashboardPersonSignal) -> Bool {
        let lhsDate = lhs.latestActivityAt ?? .distantPast
        let rhsDate = rhs.latestActivityAt ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }
        return lhs.contact.bestDisplayName.localizedCaseInsensitiveCompare(rhs.contact.bestDisplayName) == .orderedAscending
    }

    private struct ContactMatcher {
        let contact: RelationGraph.Node
        let terms: [String]
    }

    private static func uniqueContacts(_ contacts: [RelationGraph.Node]) -> [RelationGraph.Node] {
        var seen = Set<Int64>()
        return contacts.filter { seen.insert($0.entityId).inserted }
    }

    private static func matches(_ matcher: ContactMatcher, fields: [String]) -> Bool {
        fields.contains { field in
            let normalizedField = field.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedField.isEmpty else { return false }
            return matcher.terms.contains { term in
                normalizedField == term || (term.count >= 3 && normalizedField.contains(term))
            }
        }
    }

    private static func searchTerms(for contact: RelationGraph.Node) -> [String] {
        var terms: [String] = []
        for value in [contact.bestDisplayName, contact.displayName, contact.username] {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            terms.append(trimmed)
            if let first = trimmed.split(separator: " ").first, first.count >= 3 {
                terms.append(String(first))
            }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }
}

struct DashboardPersonRecentMessage: Identifiable, Sendable, Equatable, Hashable {
    let chatId: Int64
    let chatTitle: String
    let senderName: String
    let text: String
    let date: Date
    let isOutgoing: Bool

    var id: String { "\(chatId):\(date.timeIntervalSince1970):\(senderName):\(text)" }
}

struct DashboardPersonContextSummary: Sendable, Equatable {
    let headline: String
    let detail: String
    let recentChatCount: Int
    let snippets: [DashboardPersonRecentMessage]

    static func make(
        contact: RelationGraph.Node,
        openTaskCount: Int,
        openReplyCount: Int,
        messages: [DashboardPersonRecentMessage],
        now: Date = Date()
    ) -> DashboardPersonContextSummary {
        let sortedMessages = messages.sorted {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            return $0.chatTitle.localizedCaseInsensitiveCompare($1.chatTitle) == .orderedAscending
        }
        let uniqueChatCount = Set(sortedMessages.map(\.chatId)).count
        let openParts = [
            openReplyCount == 1 ? "1 reply" : "\(openReplyCount) replies",
            openTaskCount == 1 ? "1 task" : "\(openTaskCount) tasks"
        ]

        let headline: String
        if openReplyCount + openTaskCount > 0 {
            headline = "\(contact.bestDisplayName) has \(openParts.joined(separator: " and ")) open."
        } else if let lastInteractionAt = contact.lastInteractionAt {
            let stamp = compactRelativeTime(from: lastInteractionAt, now: now)
            // Beyond a week the stamp is an ABSOLUTE date ("Apr 9") — "ago"
            // only reads right after a relative one ("3d").
            let suffix = stamp.first?.isNumber == true && !stamp.contains(" ") ? " ago" : ""
            headline = "No open work. Last touched \(stamp)\(suffix)."
        } else {
            headline = "No open work or recent touch recorded."
        }

        let detail: String
        if uniqueChatCount > 0 {
            var latestByChat: [Int64: DashboardPersonRecentMessage] = [:]
            for message in sortedMessages where latestByChat[message.chatId] == nil {
                latestByChat[message.chatId] = message
            }
            let context = latestByChat.values
                .sorted {
                    if $0.date != $1.date { return $0.date > $1.date }
                    return $0.chatTitle.localizedCaseInsensitiveCompare($1.chatTitle) == .orderedAscending
                }
                .prefix(2)
                .map { "\($0.chatTitle): \(clipped($0.text, maxLength: 90))" }
                .joined(separator: " ")
            detail = "Recent context across \(uniqueChatCount) chat\(uniqueChatCount == 1 ? "" : "s"): \(context)"
        } else {
            detail = "No indexed message snippets found for this person yet."
        }

        return DashboardPersonContextSummary(
            headline: headline,
            detail: detail,
            recentChatCount: uniqueChatCount,
            snippets: Array(sortedMessages.prefix(6))
        )
    }

    private static func compactRelativeTime(from date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        return DateFormatting.dashboardListTimestamp(from: date, now: now)
    }

    private static func clipped(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return "\(text.prefix(maxLength - 3))..."
    }
}

extension ISO8601DateFormatter {
    static let dashboard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension RelationGraph.Node {
    var bestDisplayName: String {
        displayName?.isEmpty == false ? displayName! : (username ?? "Unknown")
    }

    /// True when we actually know who this is. Contacts without any name are
    /// noise in People lists — a row reading "Unknown" identifies nobody, and
    /// its name-based task matching latches onto other "Unknown"-owner rows.
    /// (GraphBuilder bakes the literal "Unknown" into unnamed nodes.)
    var hasResolvedName: Bool {
        let name = bestDisplayName
        return name != "Unknown" && !name.hasPrefix("User ")
    }
}
