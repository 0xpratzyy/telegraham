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
        static let backgroundChatDiscoveryLimit = 100
        static let backgroundChatDiscoverySettleDelayMilliseconds: UInt64 = 700
        static let backgroundChatDiscoveryInterPassDelayMilliseconds: UInt64 = 350
        static let maxStagnantBackgroundChatDiscoveryPasses = 2
    }

    enum AI {
        static let claudeBaseURL = URL(string: "https://api.anthropic.com/v1/messages")!
        static let openAIBaseURL = URL(string: "https://api.openai.com/v1/chat/completions")!
        static let claudeAPIVersion = "2023-06-01"
        static let defaultClaudeModel = "claude-sonnet-4-20250514"
        static let defaultOpenAIModel = "gpt-5"
        /// Managed (Pidgy AI) plan model + proxy path — Gemini 3.1 Flash-Lite
        /// via the proxy's Vertex path. To switch to gpt-5, flip to "gpt-5" +
        /// "/v1/chat/completions" (proxy + Vertex auth already wired).
        static let managedModel = "google/gemini-3.1-flash-lite"
        static let managedProxyPath = "/v1/vertex/chat/completions"
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

        enum QueryPlanner {
            static let minimumPlannerConfidence = 0.72
            /// A plan may also reroute when it's clearly MORE confident
            /// than the deterministic guess it overrides — absolute
            /// cliffs discarded correct plans that hedged (summary@0.62
            /// beats topic_search@0.45 every time).
            static let relativeConfidenceMargin = 0.1
            static let lowConfidenceThreshold = 0.60
        }
    }

    enum FollowUp {
        static let replyThresholdSeconds: TimeInterval = 0          // immediate
        static let followUpThresholdSeconds: TimeInterval = 86400   // 24h
        static let staleThresholdSeconds: TimeInterval = 259200     // 3 days
        static let maxPipelineAgeSeconds: TimeInterval = 1209600    // 14 days
        static let maxGroupMembers = 50       // largest group we still route through AI
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
        /// On-device model weights (e.g. the e5 embedding model) download
        /// here, under Application Support — NOT the Hugging Face Hub's
        /// ~/Documents/huggingface default, which triggers a macOS
        /// "access your Documents folder" prompt.
        static let modelsDirectoryName = "models"
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
        static let maxConcurrentChatWorkers = 2
        // Raised from 20 → 50 so the indexing pipeline scope matches
        // the reply-queue AI's `FollowUp.maxGroupMembers = 50`. Before
        // this, supergroups in the 21–50 member range (real team /
        // project chats) were filtered out at the indexing gate, which
        // kept People + Tasks blind to ~60–80 active chats on a
        // typical Telegram account. 50 stays well under the
        // "community group" threshold (≥100 members) where messages
        // mostly aren't addressed to you.
        static let maxIndexedGroupMembers = 50
        static let minEmbeddingTextLength = 10
        static let embeddingPreviewCharacterLimit = 160
        static let embeddingBackfillBatchSize = 128

        /// Conversation-window chunking. Single chat messages are often
        /// too short to carry meaning alone ("sure, sending it
        /// tomorrow"), so retrieval also embeds sliding windows of
        /// consecutive messages with sender names prefixed. Window =
        /// up to N messages (capped by characters, since the contextual
        /// model has a token budget), advancing by N - overlap so
        /// adjacent windows share context.
        static let chunkWindowMessageCount = 8
        static let chunkWindowOverlap = 2
        static let chunkWindowMaxCharacters = 900
        /// Windows with less combined text than this are noise (a run
        /// of stickers/reactions) — skip embedding them.
        static let chunkWindowMinContentCharacters = 24
        /// How many chats get chunk-backfill attention per scheduler
        /// pass, and how many messages are loaded per chat per pass.
        static let chunkBackfillChatsPerPass = 3
        static let chunkBackfillMessagesPerChat = 300

        /// Corpus-derived stopwords: tokens in at least this share of
        /// all messages are treated as function words in term
        /// extraction, whatever language they're from. Calibrated
        /// against the live corpus: 1% catches "hai"/"bhai" and every
        /// English filler while leaving content words ("wallet" 0.7%)
        /// untouched. Refreshed by the index scheduler periodically.
        static let corpusStopWordMinDocShare = 0.01
        static let corpusStopWordRefreshPasses = 200
    }

    enum RecentSync {
        static let latestWindowPerChat = 50
        static let maxChatsPerPass = 12
        static let maxConcurrentChatFetches = 4
        static let idlePollIntervalMilliseconds: UInt64 = 2_000
        static let activePollIntervalMilliseconds: UInt64 = 500
        static let staleRefreshAgeSeconds: TimeInterval = 10 * 60
        static let recoveryRefreshChatLimit = 8
        static let recoveryRefreshCooldownSeconds: TimeInterval = 90
    }

    enum MajorChatCoverage {
        static let coverageStateVersion = 12
        static let coverageWindowDays: TimeInterval = 30
        // Pages of 50 instead of 100 — smaller per-call payload means
        // each getChatHistory call finishes faster, which reduces the
        // chance a single batch eats the entire 300s timeout window
        // while TDLib's per-chat SequenceDispatcher is under
        // backpressure. With 50/page we still hit the 3 req/s rate
        // limit cap for active chats but no single call can stall the
        // whole timeout budget.
        static let historyBatchSize = 50
        // No artificial pass cap — every major chat is in scope every pass.
        // The rate limiter (2 concurrent in-flight + 3 tokens/sec for
        // getChatHistory + separate 20/sec bucket for getChatHistoryLocal)
        // is the real backpressure; the per-pass count is just an upper
        // bound. Setting these high so we sweep the whole 176-chat pool
        // each pass instead of getting stuck cycling through 2 debt chats.
        static let maxChatsPerPass = 250
        static let recoveryMaxChatsPerPass = 250
        // Same idea for the debt pool — let every chat with debt be a
        // candidate, not just the first 48.
        static let debtCandidateLimit = 500
        static let debtHydrationLimit = 64
        static let maxBatchesPerChat = 20
        static let maxNetworkBatchesPerChat = 6
        static let minTrustedLocalCoverageMessages = 10
        static let historyFetchTimeoutSeconds: TimeInterval = 60
        // 5 minutes per network fetch attempt. We accept slow passes (a chat
        // timing out wastes 5 min) in exchange for actually completing the
        // deep-history fetches that 150s wasn't long enough for. With ~30
        // remaining failing chats, a worst-case all-timeout pass is ~2.5h —
        // tolerable for users who left the app running overnight.
        static let networkHistoryFetchTimeoutSeconds: TimeInterval = 300
        static let networkBatchSpacingMilliseconds: UInt64 = 500

        /// Adaptive page size — first attempt uses the full
        /// `historyBatchSize`; each subsequent retry halves the page
        /// until we hit a floor of 8. Smaller payloads per call mean a
        /// single batch is less likely to stall the whole timeout
        /// window when TDLib's per-chat SequenceDispatcher is backed up.
        static func adaptiveBatchSize(failureCount: Int) -> Int {
            let minBatch = 8
            let attempts = max(0, failureCount)
            let scaled = historyBatchSize >> attempts  // halves each step
            return max(minBatch, scaled)
        }

        /// Adaptive network timeout — first attempt uses
        /// `networkHistoryFetchTimeoutSeconds`; each retry doubles up
        /// to a 30-min cap. Pairs with `adaptiveBatchSize` so retries
        /// trade payload size for patience: smaller calls + longer
        /// budget gives a stuck TDLib chat the best shot at completing.
        static func adaptiveNetworkTimeoutSeconds(failureCount: Int) -> TimeInterval {
            let cap: TimeInterval = 30 * 60
            let attempts = max(0, failureCount)
            let scaled = networkHistoryFetchTimeoutSeconds * pow(2.0, Double(attempts))
            return min(cap, scaled)
        }
        static let memberCountResolutionTimeoutSeconds: TimeInterval = 3
        static let localEmptyPageRetryCount = 1
        static let localEmptyPageRetryDelayMilliseconds: UInt64 = 250
        static let incompleteLocalRetryDelaySeconds: TimeInterval = 5 * 60
        // First retry waits 3 min so TDLib's stale in-flight call from the
        // previous pass has time to drain. Retrying sooner queues the new
        // call behind the stale one in TDLib's per-chat SequenceDispatcher,
        // forcing the new call to inherit the stale call's wait.
        static let retryBackoffSeconds: [TimeInterval] = [
            3 * 60,
            10 * 60,
            45 * 60
        ]
        static let transientHistoryFailureCooldownSeconds: TimeInterval = 5 * 60
        static let idlePollIntervalMilliseconds: UInt64 = 8_000
        static let activePollIntervalMilliseconds: UInt64 = 3_000
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
            /// How many candidate chats can ENTER the summary candidate
            /// pool. Bumped from 8 — for broad "catch me up on X" queries
            /// the answer often spans 6-10 chats and the previous cap meant
            /// half of them were silently excluded before the multi-chat
            /// fan-out even saw them.
            static let supportingResultLimit = 14
            static let summaryMessageLimit = 18
            static let fallbackSnippetLimit = 3
            /// Cap on the number of chats that contribute to the AI digest.
            /// Higher than supporting candidates so we can include a wider
            /// sweep when scores are close together.
            static let multiChatCandidateLimit = 6
            /// How many messages to include from each chat in a multi-chat
            /// digest. Per-chat budget instead of one flat top-K — keeps
            /// every participating chat represented in the AI input.
            /// Bumped from 5 → 20 because the research is clear: chat
            /// meaning is positional. Isolated 5-message slices starve the
            /// model; ~20 messages around the anchor gives it
            /// conversational flow.
            static let perChatDigestMessageLimit = 20
            /// Score gap below the focus chat that still qualifies for inclusion
            /// in the multi-chat digest. Tight default for sharp queries.
            static let multiChatScoreDelta = 4.0
            /// Looser threshold for "catch me up" / "key takeaways" / "what
            /// happened" style queries — the user has explicitly asked for a
            /// broad sweep, so we let more chats through even when their
            /// scores are further from the focus.
            static let multiChatScoreDeltaCatchUp = 7.5
            static let implicitRecentRecapLookbackDays = 7
            static let implicitRecentRecapBestHitBonus = 1.2
            static let implicitRecentRecapChatActivityBonus = 0.8
            static let implicitRecentRecapMissingPenalty = 2.6
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
            static let maxRenderedWorthCheckingResults = 5
            static let maxFallbackRenderedResults = 6
            static let progressiveConfidenceThreshold = 0.72
            static let preferredFreshResultAgeSeconds: TimeInterval = 5 * 86_400
            static let minimumFreshResultsBeforeDroppingStale = 8
        }
    }

    enum Dashboard {
        static let maxTopicCount = 6
        // Bump on any change to the task-triage prompt/schema — forces a
        // one-time full rescan of all main-list chats.
        static let taskTriageContextVersion = 9
        static let taskTriageChatLimit = 48
        static let taskTriageBatchSize = 12
        static let taskExtractionMessagesPerChat = 16
        static let taskRefreshIntervalSeconds: TimeInterval = 8 * 60
        static let topicDiscoveryMessageLimit = 160
        static let defaultTaskLimit = 200
    }

    enum App {
        static let version = "1.0.0"
    }

    enum Preferences {
        static let includeBotsInAISearchKey = "includeBotsInAISearch"
        static let persistReplyQueueCandidateSnapshotsKey = "persistReplyQueueCandidateSnapshots"
        static let dashboardTaskTriageContextVersionKey = "dashboardTaskTriageContextVersion"
        static let dashboardTaskPinnedOwnersKey = "dashboardTaskPinnedOwners"
        static let didCompleteOnboardingKey = "pidgyDidCompleteOnboarding"
        /// Set of chat IDs (Int64, serialized as NSNumber array) the
        /// user has explicitly hidden from the reply queue via the
        /// row context menu's "Hide from queue" action. Filtered out
        /// of AttentionStore.followUpItems before any UI sees them.
        static let excludedFromReplyQueueKey = "pidgyExcludedFromReplyQueue"
        /// Set of chat IDs the user has ARCHIVED — removed from every
        /// dashboard pipeline (reply queue AND tasks), the same way
        /// bots are filtered. Distinct from `excludedFromReplyQueueKey`
        /// which only hides a chat from the reply queue. Managed from
        /// Preferences → Archived chats.
        static let archivedChatsKey = "pidgyArchivedChats"
        /// Toggle for the decorative pigeon flock on the home
        /// dashboard's "What to do now" squiggle. Default: on. When
        /// off, the squiggle falls back to a plain divider line.
        static let showPigeonFlockKey = "showPigeonFlock"

        /// Days of evidence silence after which an open AI-extracted
        /// task is automatically marked Done. A user re-opening such a
        /// task shields it for a full window (status_set_by_user_at).
        /// 0 = never auto-complete. Default when the key is unset: 30.
        static let dashboardTaskAutoExpireDaysKey = "dashboardTaskAutoExpireDays"
        static let dashboardTaskAutoExpireDaysDefault = 30

        /// Where "Open in chat" lands: "desktop" (tg:// deep links) or
        /// "web" (web.telegram.org). Unset = auto-detect from whether a
        /// tg:// handler is installed. See ChatOpenTarget.
        static let chatOpenTargetKey = "pidgyChatOpenTarget"

        /// Persisted subscription/trial state (Billing/Subscription).
        static let subscriptionStateKey = "pidgySubscriptionState"
    }
}
