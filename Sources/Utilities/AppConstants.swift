import Foundation

/// Centralized constants for the TGSearch app.
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
        static let actionItemChatCount = 50
        static let actionItemPerChat = 15
    }

    enum AI {
        static let claudeBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
        static let openAIBaseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        static let claudeAPIVersion = "2023-06-01"
        static let defaultClaudeModel = "claude-sonnet-4-20250514"
        static let defaultOpenAIModel = "gpt-4o-mini"
        static let followUpClaudeModel = "claude-3-5-haiku-20241022"
        static let followUpOpenAIModel = "gpt-4o-mini"
        static let maxResponseTokens = 4096
        static let maxTokenBudgetChars = 16000
        static let requestTimeoutSeconds: TimeInterval = 90
    }

    enum FollowUp {
        static let replyThresholdSeconds: TimeInterval = 0          // immediate
        static let followUpThresholdSeconds: TimeInterval = 86400   // 24h
        static let staleThresholdSeconds: TimeInterval = 259200     // 3 days
        static let maxPipelineAgeSeconds: TimeInterval = 2592000    // 30 days — older = dead, not pipeline
        static let maxGroupMembers = 20       // skip groups with KNOWN count > this
        static let maxGroupUnread = 10        // skip groups with > this many unread (community signal)
        static let maxAISuggestions = 15
        static let messagesPerChat = 8
    }

    enum Cache {
        static let maxUserCacheSize = 500
        static let maxChatCacheSize = 200
    }

    enum App {
        static let version = "1.0.0"
    }
}
