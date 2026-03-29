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
            static let maxAdaptiveRounds = 4
            static let confidentTopAverageThreshold = 0.72
            static let initialMessagesPerChat = 8
            static let topUpAdditionalMessages = 4
            static let maxMessagesPerChat = 12
            static let maxLowConfidenceTopUps = 2
            static let lowConfidenceThreshold = 0.60
            static let dateProbeStep = 12
            static let maxDateProbeMessagesPerChat = 80
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
        static let messagesPerChat = 10       // initial batch for AI categorization
        static let progressiveFetchStep = 5   // fetch only a small older slice when confidence is low
        static let maxMessagesForAIClassification = 20
        static let maxAIConcurrency = 5       // parallel AI calls
    }

    enum Cache {
        static let maxUserCacheSize = 500
        static let maxChatCacheSize = 200
        static let maxCachedMessagesPerChat = 50
    }

    enum App {
        static let version = "1.0.0"
    }

    enum Preferences {
        static let includeBotsInAISearchKey = "includeBotsInAISearch"
    }
}
