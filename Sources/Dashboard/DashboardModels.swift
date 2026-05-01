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
            let query = TopicQuery(name: topic.name)
            let chatCount = normalizedChats.reduce(into: 0) { count, chat in
                if query.matches(chat.title) || chat.preview.map(query.matches) == true {
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

    private struct TopicQuery: Sendable {
        let normalizedName: String
        let terms: [String]

        init(name: String) {
            normalizedName = DashboardTopicMatcher.normalize(name)
            terms = normalizedName
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 3 }
        }

        func matches(_ text: String) -> Bool {
            guard !text.isEmpty, !normalizedName.isEmpty else { return false }
            if text.contains(normalizedName) { return true }
            guard terms.count > 1 else { return terms.first.map { text.contains($0) } ?? false }
            return terms.allSatisfy { text.contains($0) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            return namesOverlap(task.ownerName, name) || namesOverlap(task.personName, name)
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

        let parts = trimmed
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(normalizedOwnerName)
            .filter { $0.count >= 2 }
        aliases.formUnion(parts)

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

struct DashboardTaskCandidate: Sendable, Equatable {
    let stableFingerprint: String
    let title: String
    let summary: String
    let suggestedAction: String
    let ownerName: String
    let personName: String
    let chatId: Int64
    let chatTitle: String
    let topicName: String?
    let priority: DashboardTaskPriority
    let status: DashboardTaskStatus
    let confidence: Double
    let createdAt: Date
    let dueAt: Date?
    let sourceMessages: [DashboardTaskSourceMessage]

    func resolvingSourceMetadata(from messages: [TGMessage], myUserId: Int64) -> DashboardTaskCandidate {
        var metadataByMessageKey: [String: (date: Date, senderName: String)] = [:]
        for message in messages {
            let isMe: Bool
            if message.isOutgoing {
                isMe = true
            } else if case .user(let uid) = message.senderId, myUserId > 0 {
                isMe = uid == myUserId
            } else {
                isMe = false
            }
            let senderName = isMe ? "You" : (message.senderName ?? "Unknown")
            metadataByMessageKey["\(message.chatId):\(message.id)"] = (message.date, senderName)
        }

        let resolvedSources = sourceMessages.map { source -> DashboardTaskSourceMessage in
            guard let metadata = metadataByMessageKey["\(source.chatId):\(source.messageId)"] else {
                return source
            }
            return DashboardTaskSourceMessage(
                chatId: source.chatId,
                messageId: source.messageId,
                senderName: metadata.senderName,
                text: source.text,
                date: metadata.date
            )
        }

        return DashboardTaskCandidate(
            stableFingerprint: stableFingerprint,
            title: title,
            summary: summary,
            suggestedAction: suggestedAction,
            ownerName: ownerName,
            personName: personName,
            chatId: chatId,
            chatTitle: chatTitle,
            topicName: topicName,
            priority: priority,
            status: status,
            confidence: confidence,
            createdAt: createdAt,
            dueAt: dueAt,
            sourceMessages: resolvedSources
        )
    }
}

struct DashboardTaskTriageCandidate: Sendable, Equatable {
    let chat: TGChat
    let messages: [TGMessage]
    let openTasks: [DashboardTask]
    let openTaskEvidenceByTaskId: [Int64: [DashboardTaskSourceMessage]]
}

struct DashboardTaskTriageOpenTaskDTO: Codable, Sendable, Equatable {
    let taskId: Int64
    let title: String
    let summary: String
    let suggestedAction: String
    let ownerName: String
    let personName: String
    let latestSourceDateISO8601: String?
    let sourceMessages: [DashboardTaskSourceMessageDTO]
}

struct DashboardTaskTriageCandidateDTO: Codable, Sendable {
    let chatId: Int64
    let chatTitle: String
    let chatType: String
    let unreadCount: Int
    let memberCount: Int?
    let messages: [MessageSnippet]
    let openTasks: [DashboardTaskTriageOpenTaskDTO]
}

enum DashboardTaskTriageRoute: String, Codable, Sendable, Equatable, Hashable {
    case effortTask = "effort_task"
    case replyQueue = "reply_queue"
    case completedTask = "completed_task"
    case ignore

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).lowercased()
        switch rawValue {
        case "effort_task", "task":
            self = .effortTask
        case "reply_queue", "reply_only":
            self = .replyQueue
        case "completed_task", "complete_task", "completed", "complete", "done", "resolved":
            self = .completedTask
        default:
            self = .ignore
        }
    }
}

struct DashboardTaskTriageResultDTO: Codable, Sendable, Equatable {
    let chatId: Int64
    let route: DashboardTaskTriageRoute
    let confidence: Double
    let reason: String
    let supportingMessageIds: [Int64]
    let completedTaskIds: [Int64]

    enum CodingKeys: String, CodingKey {
        case chatId
        case route
        case confidence
        case reason
        case supportingMessageIds
        case completedTaskIds
    }

    init(
        chatId: Int64,
        route: DashboardTaskTriageRoute,
        confidence: Double,
        reason: String,
        supportingMessageIds: [Int64],
        completedTaskIds: [Int64] = []
    ) {
        self.chatId = chatId
        self.route = route
        self.confidence = confidence
        self.reason = reason
        self.supportingMessageIds = supportingMessageIds
        self.completedTaskIds = completedTaskIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try Self.decodeFlexibleInt64(container, key: .chatId)
        route = try container.decode(DashboardTaskTriageRoute.self, forKey: .route)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        supportingMessageIds = try Self.decodeFlexibleInt64Array(container, key: .supportingMessageIds)
        completedTaskIds = try Self.decodeFlexibleInt64Array(container, key: .completedTaskIds)
    }

    private static func decodeFlexibleInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64 {
        if let value = try? container.decode(Int64.self, forKey: key) {
            return value
        }
        let rawValue = try container.decode(String.self, forKey: key)
        guard let value = Int64(rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be an Int64"
            )
        }
        return value
    }

    private static func decodeFlexibleInt64Array(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [Int64] {
        if let values = try? container.decode([Int64].self, forKey: key) {
            return values
        }
        if let values = try? container.decode([String].self, forKey: key) {
            return values.compactMap(Int64.init)
        }
        return []
    }
}

struct DashboardTopicDTO: Codable, Sendable, Equatable {
    let name: String
    let rationale: String
    let score: Double
}

struct DashboardTaskDTO: Codable, Sendable, Equatable {
    let stableFingerprint: String
    let title: String
    let summary: String
    let suggestedAction: String
    let ownerName: String
    let personName: String
    let chatId: Int64
    let chatTitle: String
    let topicName: String?
    let priority: String
    let confidence: Double
    let dueAtISO8601: String?
    let sourceMessages: [DashboardTaskSourceMessageDTO]

    enum CodingKeys: String, CodingKey {
        case stableFingerprint
        case title
        case summary
        case suggestedAction
        case ownerName
        case personName
        case chatId
        case chatTitle
        case topicName
        case priority
        case confidence
        case dueAtISO8601
        case sourceMessages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stableFingerprint = try container.decode(String.self, forKey: .stableFingerprint)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        suggestedAction = try container.decodeIfPresent(String.self, forKey: .suggestedAction) ?? ""
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName) ?? "Unknown"
        personName = try container.decodeIfPresent(String.self, forKey: .personName) ?? ""
        chatId = try Self.decodeFlexibleInt64(container, key: .chatId)
        chatTitle = try container.decodeIfPresent(String.self, forKey: .chatTitle) ?? "Chat \(chatId)"
        topicName = try container.decodeIfPresent(String.self, forKey: .topicName)
        priority = try container.decodeIfPresent(String.self, forKey: .priority) ?? DashboardTaskPriority.medium.rawValue
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        dueAtISO8601 = try container.decodeIfPresent(String.self, forKey: .dueAtISO8601)
        sourceMessages = try container.decodeIfPresent([DashboardTaskSourceMessageDTO].self, forKey: .sourceMessages) ?? []
    }

    init(
        stableFingerprint: String,
        title: String,
        summary: String,
        suggestedAction: String,
        ownerName: String,
        personName: String,
        chatId: Int64,
        chatTitle: String,
        topicName: String?,
        priority: String,
        confidence: Double,
        dueAtISO8601: String?,
        sourceMessages: [DashboardTaskSourceMessageDTO]
    ) {
        self.stableFingerprint = stableFingerprint
        self.title = title
        self.summary = summary
        self.suggestedAction = suggestedAction
        self.ownerName = ownerName
        self.personName = personName
        self.chatId = chatId
        self.chatTitle = chatTitle
        self.topicName = topicName
        self.priority = priority
        self.confidence = confidence
        self.dueAtISO8601 = dueAtISO8601
        self.sourceMessages = sourceMessages
    }

    func candidate(now: Date = Date()) -> DashboardTaskCandidate {
        let priorityValue = DashboardTaskPriority(rawValue: priority.lowercased()) ?? .medium
        let parsedDueDate = dueAtISO8601.flatMap(Self.iso8601Date(from:))
        let fallbackFingerprint = Self.fingerprint(
            title: title,
            chatId: chatId,
            sourceMessages: sourceMessages
        )
        return DashboardTaskCandidate(
            stableFingerprint: stableFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackFingerprint
                : stableFingerprint,
            title: title,
            summary: summary,
            suggestedAction: suggestedAction,
            ownerName: ownerName,
            personName: personName,
            chatId: chatId,
            chatTitle: chatTitle,
            topicName: topicName,
            priority: priorityValue,
            status: .open,
            confidence: max(0, min(1, confidence)),
            createdAt: now,
            dueAt: parsedDueDate,
            sourceMessages: sourceMessages.map { $0.sourceMessage(fallbackChatId: chatId, fallbackDate: now) }
        )
    }

    private static func decodeFlexibleInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64 {
        if let numeric = try? container.decode(Int64.self, forKey: key) {
            return numeric
        }
        let raw = try container.decode(String.self, forKey: key)
        guard let numeric = Int64(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be an Int64 or numeric string"
            )
        }
        return numeric
    }

    private static func iso8601Date(from string: String) -> Date? {
        ISO8601DateFormatter.dashboard.date(from: string)
    }

    private static func fingerprint(
        title: String,
        chatId: Int64,
        sourceMessages: [DashboardTaskSourceMessageDTO]
    ) -> String {
        let messageKey = sourceMessages
            .map { "\($0.chatId ?? chatId):\($0.messageId)" }
            .joined(separator: "|")
        return "\(chatId):\(title.lowercased()):\(messageKey)"
    }
}

struct DashboardTaskSourceMessageDTO: Codable, Sendable, Equatable {
    let chatId: Int64?
    let messageId: Int64
    let senderName: String
    let text: String
    let dateISO8601: String?

    enum CodingKeys: String, CodingKey {
        case chatId
        case messageId
        case senderName
        case text
        case dateISO8601
    }

    init(
        chatId: Int64?,
        messageId: Int64,
        senderName: String,
        text: String,
        dateISO8601: String?
    ) {
        self.chatId = chatId
        self.messageId = messageId
        self.senderName = senderName
        self.text = text
        self.dateISO8601 = dateISO8601
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try Self.decodeOptionalFlexibleInt64(container, key: .chatId)
        messageId = try Self.decodeFlexibleInt64(container, key: .messageId)
        senderName = try container.decodeIfPresent(String.self, forKey: .senderName) ?? "Unknown"
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        dateISO8601 = try container.decodeIfPresent(String.self, forKey: .dateISO8601)
    }

    func sourceMessage(fallbackChatId: Int64, fallbackDate: Date) -> DashboardTaskSourceMessage {
        DashboardTaskSourceMessage(
            chatId: chatId ?? fallbackChatId,
            messageId: messageId,
            senderName: senderName,
            text: text,
            date: dateISO8601.flatMap { ISO8601DateFormatter.dashboard.date(from: $0) } ?? fallbackDate
        )
    }

    private static func decodeOptionalFlexibleInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64? {
        if !container.contains(key) {
            return nil
        }
        if let numeric = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return numeric
        }
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let numeric = Int64(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be an Int64 or numeric string"
            )
        }
        return numeric
    }

    private static func decodeFlexibleInt64(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Int64 {
        if let numeric = try? container.decode(Int64.self, forKey: key) {
            return numeric
        }
        let raw = try container.decode(String.self, forKey: key)
        guard let numeric = Int64(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be an Int64 or numeric string"
            )
        }
        return numeric
    }
}

struct DashboardTopicsEnvelope: Codable {
    let topics: [DashboardTopicDTO]
}

enum DashboardTopicParser {
    static func parse(_ response: String) throws -> [DashboardTopicDTO] {
        if let envelope: DashboardTopicsEnvelope = try? JSONExtractor.parseJSON(response) {
            return envelope.topics
        }
        let bareArray: [DashboardTopicDTO] = try JSONExtractor.parseJSON(response)
        return bareArray
    }
}

struct DashboardTasksEnvelope: Codable {
    let tasks: [DashboardTaskDTO]
}

struct DashboardTaskTriageEnvelope: Codable {
    let decisions: [DashboardTaskTriageResultDTO]
}

enum DashboardTaskTriageParser {
    static func parse(_ response: String) throws -> [DashboardTaskTriageResultDTO] {
        if let envelope: DashboardTaskTriageEnvelope = try? JSONExtractor.parseJSON(response) {
            return envelope.decisions
        }
        return try JSONExtractor.parseJSON(response)
    }
}

enum DashboardTaskParser {
    static func parse(_ response: String) throws -> [DashboardTaskCandidate] {
        let dtos: [DashboardTaskDTO]
        if let envelope: DashboardTasksEnvelope = try? JSONExtractor.parseJSON(response) {
            dtos = envelope.tasks
        } else {
            dtos = try JSONExtractor.parseJSON(response)
        }
        let now = Date()
        return dtos.map { $0.candidate(now: now) }
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
        let uniqueContacts = uniqueContacts(contacts)
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
            headline = "No open work. Last touched \(compactRelativeTime(from: lastInteractionAt, now: now)) ago."
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

enum DashboardTaskRefreshPolicy {
    static func shouldScan(
        latestMessageId: Int64?,
        syncedLatestMessageId: Int64?,
        forceRescan: Bool = false
    ) -> Bool {
        guard let latestMessageId, latestMessageId > 0 else { return false }
        if forceRescan { return true }
        guard let syncedLatestMessageId else { return true }
        return latestMessageId > syncedLatestMessageId
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
}
