import Foundation

/// Centralized constants for the Pidgy app.
enum AppConstants {
    enum Panel {
        static let width: CGFloat = 640
        static let height: CGFloat = 480
        static let topOffsetRatio: CGFloat = 0.12
    }

    enum RateLimit {
        static let maxTokens: Double = 10
        static let refillRate: Double = 5
        static let defaultMethod = "default"
        static let userPriorityPollIntervalMilliseconds: UInt64 = 60
        static let backgroundPriorityPollIntervalMilliseconds: UInt64 = 120
        static let floodWaitBackoffMultiplier = 1.2
    }

    enum Fetch {
        static let chatListLimit = 100
        static let chatHistoryLimit = 50
        static let searchLimit = 50
    }

    enum AI {
        static let claudeBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
        static let openAIBaseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        static let claudeAPIVersion = "2023-06-01"
        static let defaultClaudeModel = "claude-sonnet-4-20250514"
        static let defaultOpenAIModel = "gpt-5-mini"
        static let replyQueueOpenAIModel = "gpt-5.4-mini"
        static let followUpClaudeModel = "claude-3-5-haiku-20241022"
        static let followUpOpenAIModel = "gpt-5-mini"
        static let maxResponseTokens = 4096
        static let maxTokenBudgetChars = 16000
        static let requestTimeoutSeconds: TimeInterval = 90

        enum AgenticSearch {
            static let maxCandidateChats = 12
            static let retrievalBatchCount = 3
            static let retrievalBatchSize = 10
            static let initialScanChats = 12
            static let adaptiveExpansionStep = 8
            static let maxAdaptiveScanChats = 48
            static let maxAdaptiveRounds = 5
            static let replyQueueMinimumScanChats = 32
            static let replyQueueMinimumFinalResults = 5
            static let replyQueuePrivateMaxAgeSeconds: TimeInterval = 45 * 86_400
            static let confidentTopAverageThreshold = 0.72
            static let initialMessagesPerChat = 8
            static let topUpAdditionalMessages = 4
            static let maxMessagesPerChat = 12
            static let maxLowConfidenceTopUps = 2
            static let lowConfidenceThreshold = 0.60
            static let dateProbeStep = 12
            static let maxDateProbeMessagesPerChat = 80
        }

        enum SemanticSearch {
            static let ftsTopMessages = 50
            static let vectorTopMessages = 50
            static let fallbackTopMessages = 40
            static let maxLocalChatsForRerank = 20
            static let maxRenderedSemanticResults = 24
            static let messagePreviewCharacterLimit = 180
            static let highRelevanceThreshold = 0.72
            static let mediumRelevanceThreshold = 0.40
            static let ftsWeight = 0.6
            static let vectorWeight = 0.4
            static let titleWeight = 0.45
            static let fallbackWeight = 0.35
            static let exactTitleBoost = 0.18
            static let titleHistoryBonus = 0.08
            static let titleOnlyPenalty = 0.18
            static let dmBonus = 0.10
            static let smallGroupBonus = 0.04
            static let largeGroupPenalty = 0.08
        }
    }

    enum FollowUp {
        static let replyThresholdSeconds: TimeInterval = 0          // immediate
        static let followUpThresholdSeconds: TimeInterval = 86400   // 24h
        static let staleThresholdSeconds: TimeInterval = 259200     // 3 days
        static let maxPipelineAgeSeconds: TimeInterval = 1209600    // 14 days
        static let maxGroupMembers = 20       // skip groups with KNOWN count > this
        static let maxGroupUnread = 10        // skip groups with > this many unread (community signal)
        static let maxAISuggestions = 15
        static let messagesPerChat = 10       // first pass window
        static let progressiveFetchStep = 5   // chunk size while expanding older history
        static let maxMessagesForAIClassification = 30 // one retry max: 10 -> 30
        static let maxAIConcurrency = 5       // parallel AI calls
    }

    enum Cache {
        static let maxUserCacheSize = 500
        static let maxChatCacheSize = 200
        static let maxCachedMessagesPerChat = 50
    }

    enum Storage {
        static let appSupportFolderName = "Pidgy"
        static let databaseFileName = "pidgy.db"
        static let messageCacheDirectoryName = "message_cache"
        static let pipelineCacheDirectoryName = "pipeline_cache"
    }

    enum Graph {
        static let buildProgressChatId: Int64 = -1
        static let selfEntityType = "self"
        static let userEntityType = "user"
        static let groupEntityType = "group"
        static let channelEntityType = "channel"
        static let dmEdgeType = "dm"
        static let sharedGroupEdgeType = "shared_group"
        static let defaultCategory = "uncategorized"
        static let automaticCategorySource = "auto"
        static let manualCategorySource = "manual"
        static let groupParticipantLimit = 50
        static let scoreRecentWindowDays: TimeInterval = 7
        static let scoreMonthlyWindowDays: TimeInterval = 30
        static let directMessageBonus = 5.0
        static let unreadBonus = 2.0
        static let startupReadinessPollMilliseconds: UInt64 = 300
        static let startupReadinessTimeoutSeconds: TimeInterval = 8
    }

    enum Indexing {
        static let batchSize = 50
        static let interBatchDelayMilliseconds: UInt64 = 200
        static let idlePollIntervalMilliseconds: UInt64 = 1500
        static let pausedPollIntervalMilliseconds: UInt64 = 350
        static let maxPrioritizedChats = 32
        static let maxIndexedGroupMembers = 20
        static let minEmbeddingTextLength = 10
        static let embeddingPreviewCharacterLimit = 160
        static let embeddingBackfillBatchSize = 128
        static let embeddingBackfillEveryIndexedChats = 8
    }

    enum Search {
        enum Pattern {
            static let maxSearchableMessages = 12_000
            static let ftsCandidateLimit = 160
            static let fallbackCandidateLimit = 40
            static let maxRenderedResults = 30
            static let snippetCharacterLimit = 220
        }

        enum Summary {
            static let localChatLimit = 12
            static let supportingResultLimit = 8
            static let summaryMessageLimit = 18
            static let fallbackSnippetLimit = 3
        }

        enum ReplyQueue {
            static let aiBatchSize = 12
            static let scanWaveSize = 48
            static let maxScannedChats = 48
            static let minimumConfidentResultsForEarlyStop = 5
            static let stableGrowthThreshold = 1
            static let minimumWaveCountBeforeEarlyStop = 1
            static let initialPrivateMessagesPerChat = 6
            static let initialGroupMessagesPerChat = 4
            static let additionalMessagesForNeedMore = 8
            static let maxMessagesPerChat = 16
            static let maxRenderedResults = 15
            static let maxFallbackRenderedResults = 6
            static let progressiveConfidenceThreshold = 0.72
            static let preferredFreshResultAgeSeconds: TimeInterval = 5 * 86_400
            static let minimumFreshResultsBeforeDroppingStale = 8
        }
    }

    enum App {
        static let version = "1.0.0"
    }

    enum Preferences {
        static let includeBotsInAISearchKey = "includeBotsInAISearch"
    }
}
