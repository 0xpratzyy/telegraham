import Foundation

struct AgenticDebugExclusionBucket: Identifiable, Codable {
    let reason: String
    var count: Int = 0
    var sampleChats: [String] = []

    var id: String { reason }
}

struct AgenticDebugWaveTiming: Identifiable, Codable {
    let wave: Int
    let chatCount: Int
    let localPrepMs: Int
    let aiMs: Int
    let provisionalCount: Int

    var id: Int { wave }
}

struct AgenticDebugBatchTiming: Identifiable, Codable {
    let label: String
    let size: Int
    let durationMs: Int
    let resultCount: Int

    var id: String { label }
}

struct AgenticDebugInfo: Codable {
    var scopedChats: Int
    var maxScanChats: Int
    var providerName: String = ""
    var providerModel: String = ""
    var eligiblePrivateChats: Int = 0
    var eligibleGroupChats: Int = 0
    var cappedPrivateChats: Int = 0
    var cappedGroupChats: Int = 0
    var scannedChats: Int = 0
    var inRangeChats: Int = 0
    var replyOwedChats: Int = 0
    var matchedChats: Int = 0
    var matchedPrivateChats: Int = 0
    var matchedGroupChats: Int = 0
    var candidatesSentToAI: Int = 0
    var aiReturned: Int = 0
    var rankedBeforeValidation: Int = 0
    var droppedByValidation: Int = 0
    var finalCount: Int = 0
    var finalPrivateChats: Int = 0
    var finalGroupChats: Int = 0
    var totalDurationMs: Int = 0
    var candidateCollectionMs: Int = 0
    var prioritizationMs: Int = 0
    var localPrepMs: Int = 0
    var aiMs: Int = 0
    var needMoreMs: Int = 0
    var finalizationMs: Int = 0
    var memoryHitChats: Int = 0
    var sqliteHitChats: Int = 0
    var emptyLocalChats: Int = 0
    var aiBatchCount: Int = 0
    var needMoreCount: Int = 0
    var stopReason: String = "unknown"
    var exclusionBuckets: [AgenticDebugExclusionBucket] = []
    var waveTimings: [AgenticDebugWaveTiming] = []
    var batchTimings: [AgenticDebugBatchTiming] = []

    mutating func recordExclusion(_ reason: String, chatTitle: String) {
        if let index = exclusionBuckets.firstIndex(where: { $0.reason == reason }) {
            exclusionBuckets[index].count += 1
            if exclusionBuckets[index].sampleChats.count < 3,
               !exclusionBuckets[index].sampleChats.contains(chatTitle) {
                exclusionBuckets[index].sampleChats.append(chatTitle)
            }
        } else {
            exclusionBuckets.append(
                AgenticDebugExclusionBucket(
                    reason: reason,
                    count: 1,
                    sampleChats: chatTitle.isEmpty ? [] : [chatTitle]
                )
            )
        }
    }
}

struct AgenticDebugChatAudit: Identifiable, Codable {
    let chatId: Int64
    let chatTitle: String
    let chatType: String
    var scanned: Bool = false
    var inRange: Bool = false
    var messageCount: Int = 0
    var pipelineCategory: String = ""
    var replyOwed: Bool = false
    var strictReplySignal: Bool = false
    var effectiveGroupReplySignal: Bool = false
    var prefilterExclusionReason: String?
    var sentToAI: Bool = false
    var aiScore: Int?
    var aiWarmth: String?
    var aiReplyability: String?
    var aiConfidence: Double?
    var aiReason: String?
    var supportingMessageIds: [Int64] = []
    var validationFailureReason: String?
    var finalIncluded: Bool = false

    var id: Int64 { chatId }
}

struct PersistedAgenticDebugSnapshot: Codable {
    let query: String
    let querySpec: QuerySpec?
    let capturedAt: Date
    let debug: AgenticDebugInfo
    let chatAudits: [AgenticDebugChatAudit]
}
