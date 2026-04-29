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

    func resolvingSourceDates(from messages: [TGMessage]) -> DashboardTaskCandidate {
        var dateByMessageKey: [String: Date] = [:]
        for message in messages {
            dateByMessageKey["\(message.chatId):\(message.id)"] = message.date
        }

        let resolvedSources = sourceMessages.map { source -> DashboardTaskSourceMessage in
            guard let date = dateByMessageKey["\(source.chatId):\(source.messageId)"] else {
                return source
            }
            return DashboardTaskSourceMessage(
                chatId: source.chatId,
                messageId: source.messageId,
                senderName: source.senderName,
                text: source.text,
                date: date
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
}

struct DashboardTaskTriageCandidateDTO: Codable, Sendable {
    let chatId: Int64
    let chatTitle: String
    let chatType: String
    let unreadCount: Int
    let memberCount: Int?
    let messages: [MessageSnippet]
}

enum DashboardTaskTriageRoute: String, Codable, Sendable, Equatable, Hashable {
    case effortTask = "effort_task"
    case replyQueue = "reply_queue"
    case ignore

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).lowercased()
        switch rawValue {
        case "effort_task", "task":
            self = .effortTask
        case "reply_queue", "reply_only":
            self = .replyQueue
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

    enum CodingKeys: String, CodingKey {
        case chatId
        case route
        case confidence
        case reason
        case supportingMessageIds
    }

    init(
        chatId: Int64,
        route: DashboardTaskTriageRoute,
        confidence: Double,
        reason: String,
        supportingMessageIds: [Int64]
    ) {
        self.chatId = chatId
        self.route = route
        self.confidence = confidence
        self.reason = reason
        self.supportingMessageIds = supportingMessageIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatId = try Self.decodeFlexibleInt64(container, key: .chatId)
        route = try container.decode(DashboardTaskTriageRoute.self, forKey: .route)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        supportingMessageIds = try Self.decodeFlexibleInt64Array(container, key: .supportingMessageIds)
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
        ownerName = try container.decodeIfPresent(String.self, forKey: .ownerName) ?? "Me"
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
            if let topicId, task.topicId != topicId {
                return false
            }
            if let chatId, task.chatId != chatId {
                return false
            }
            if !normalizedPerson.isEmpty {
                let person = task.personName.lowercased()
                let chat = task.chatTitle.lowercased()
                return person.contains(normalizedPerson) || chat.contains(normalizedPerson)
            }
            return true
        })
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
