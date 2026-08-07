import AppKit
import Foundation

/// Settings navigation, organised by what the user is trying to do.
///
/// The previous eight pages were named after the implementation — "Indexing",
/// "Diagnostics", "Preferences" — and the consequences showed. Nobody opens
/// settings wanting to "configure indexing"; they want to know whether their
/// data is current. And "Preferences" inside Preferences had become the
/// leftover bucket: a third of the whole file, with a cosmetic animation
/// toggle sitting next to the memory-engine kill switch.
///
/// Five pages now, each answering one question:
///   Connections — which message sources are connected?
///   Plan & AI — what am I on, and what is it costing?
///   Memory    — what does Pidgy read and remember about me?
///   Data      — is it current, and how do I start over?
///   About     — what is this, and who else can I bring?
///
/// `diagnostics` survives for the graph/routing inspector but is no longer a
/// peer of these: it is developer tooling and is hidden outside DEBUG.
enum DashboardPreferencePage: String, CaseIterable, Identifiable, Hashable {
    case account = "Connections"
    case plan = "Plan & AI"
    case memory = "Memory"
    case data = "Data"
    case about = "About"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    /// What the sidebar offers. Diagnostics is a debug build only — shipping
    /// a "Rebuild graph" button and node/edge breakdowns to end users puts an
    /// inspector in a consumer surface.
    static var visibleCases: [DashboardPreferencePage] {
        #if DEBUG
        return allCases
        #else
        return allCases.filter { $0 != .diagnostics }
        #endif
    }

    var systemImage: String {
        switch self {
        case .account:
            return "link"
        case .plan:
            return "sparkles"
        case .memory:
            return "brain"
        case .data:
            return "externaldrive.connected.to.line.below"
        case .about:
            return "info.circle"
        case .diagnostics:
            return "waveform.path.ecg"
        }
    }

    var subtitle: String {
        switch self {
        case .account:
            return "Telegram, Gmail, Slack, and WhatsApp imports"
        case .plan:
            return "Your plan, AI provider, and what it costs"
        case .memory:
            return "What Pidgy reads, remembers, and sends to AI"
        case .data:
            return "Freshness, coverage, and starting over"
        case .about:
            return "App, privacy, and invites"
        case .diagnostics:
            return "Graph health and query routing"
        }
    }
}

struct QueryRoutingDebugSnapshot: Identifiable {
    let query: String
    let spec: QuerySpec
    let runtimeIntent: QueryIntent

    var id: String { query }
}

enum DashboardDiagnosticsService {
    /// Probes for the routing table — one per query family, so the
    /// diagnostics page shows which engine each shape hits.
    ///
    /// Deliberately free of real names and real projects: this page ships to
    /// every install, and it used to carry a developer's contact ("summarize
    /// my chats with Akhil") and company ("first dollar"), which read as
    /// another user's data leaking into the UI. The routing only cares about
    /// the SHAPE of the query, so a placeholder name probes it identically.
    static let routingSampleQueries: [String] = [
        "where I shared wallet address",
        "find message with contract address",
        "pricing",
        "partnership discussions",
        "who do I need to reply to",
        "who haven't I replied to from last week",
        "stale investors",
        "summarize my chats with Alex"
    ]

    @MainActor
    static func routingSnapshots(
        query: String,
        aiService: AIService,
        now: Date = Date(),
        timezone: TimeZone = .current
    ) async -> [QueryRoutingDebugSnapshot] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshots: [QueryRoutingDebugSnapshot] = []

        if !trimmedQuery.isEmpty {
            snapshots.append(
                await routingSnapshot(
                    query: trimmedQuery,
                    aiService: aiService,
                    now: now,
                    timezone: timezone
                )
            )
        }

        for sampleQuery in routingSampleQueries where sampleQuery != trimmedQuery {
            snapshots.append(
                await routingSnapshot(
                    query: sampleQuery,
                    aiService: aiService,
                    now: now,
                    timezone: timezone
                )
            )
        }

        return snapshots
    }

    @MainActor
    static func routingSnapshot(
        query: String,
        aiService: AIService,
        now: Date = Date(),
        timezone: TimeZone = .current
    ) async -> QueryRoutingDebugSnapshot {
        let spec = QueryInterpreter().parse(
            query: query,
            now: now,
            timezone: timezone,
            activeFilter: .all
        )
        let runtimeIntent = await aiService.queryRouter.route(
            query: query,
            querySpec: spec,
            activeFilter: spec.scope,
            timezone: timezone,
            now: now
        )

        return QueryRoutingDebugSnapshot(
            query: query,
            spec: spec,
            runtimeIntent: runtimeIntent
        )
    }
}

enum PreferencesResetPlan {
    static let credentialKeysToDelete: [KeychainManager.Key] = [
        .apiId,
        .apiHash,
        .aiProviderType,
        .aiApiKeyOpenAI,
        .aiApiKeyClaude,
        .aiModelOpenAI,
        .aiModelClaude,
        .aiApiKey,
        .aiModel,
        .gmailAccessToken,
        .gmailRefreshToken,
        .gmailTokenExpiry,
        .gmailAccountEmail,
        .gmailAccounts,
        .slackAccessToken,
        .slackRefreshToken,
        .slackTeamId,
        .slackTeamName,
        .slackAuthedUserId,
        .slackTokenExpiry
    ]

    static let userDefaultsKeysToDelete: [String] = [
        AppConstants.Preferences.includeBotsInAISearchKey,
        AppConstants.Preferences.dashboardTaskPinnedOwnersKey,
        AppConstants.Preferences.didCompleteOnboardingKey,
        AppConstants.Preferences.showPigeonFlockKey,
        AppConstants.Preferences.chatOpenTargetKey,
        AppConstants.Preferences.subscriptionStateKey,
        // Privacy opt-in — deleting it returns the install to the opt-OUT
        // default (identity never rides crash reports without a fresh
        // explicit enable).
        AppConstants.Preferences.diagnosticsIdentityEnabledKey,
        // Invite cache — server state (keyed on the surviving install id)
        // is the source of truth; a re-onboard redeems idempotently and
        // gets the same codes back.
        AppConstants.Preferences.inviteRegisteredKey,
        AppConstants.Preferences.inviteCodesCacheKey,
        AppConstants.Preferences.inviteReferralsKey,
        // Raw strings: keys written by retired pipelines — still swept so
        // old installs reset cleanly.
        "dashboardTaskTriageContextVersion",
        "dashboardTaskAutoExpireDays"
    ]

    static func pidgyDataDirectory(in applicationSupportDirectory: URL?) -> URL? {
        applicationSupportDirectory?.appendingPathComponent("Pidgy", isDirectory: true)
    }

    static func defaultPidgyDataDirectory(fileManager: FileManager = .default) -> URL? {
        pidgyDataDirectory(
            in: fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
    }
}

@MainActor
struct PreferencesResetService {
    var fileManager: FileManager = .default
    var userDefaults: UserDefaults = .standard

    func deleteAllLocalData(
        telegramService: TelegramService,
        aiService: AIService
    ) async {
        // Synchronous, fast: keychain + UserDefaults clears.
        for key in PreferencesResetPlan.credentialKeysToDelete {
            try? KeychainManager.delete(for: key)
        }
        for key in PreferencesResetPlan.userDefaultsKeysToDelete {
            userDefaults.removeObject(forKey: key)
        }

        let pidgyDataDir = PreferencesResetPlan.defaultPidgyDataDirectory(fileManager: fileManager)

        // Stop everything independently in parallel — each `stop()` waits on
        // its own queue / TDLib roundtrip, and they don't depend on each
        // other. Doing them serially used to add multiple seconds of
        // perceived delay before the file removal could even start.
        TaskIndexCoordinator.shared.stop()
        // The fact-extraction crawl (and its OCR pass) is a WRITER — it must
        // stop AND DRAIN before the DB below is closed and deleted, or a
        // suspended pass resumes mid-wipe and writes into / reopens the
        // dying handle. stop() awaits the in-flight pass (bounded ~5s).
        await FactExtractionCoordinator.shared.stop()
        // Cancel the GraphBuilder background loop owned by AppDelegate.
        // It's a Task.detached `while !Task.isCancelled` cycle —
        // without this explicit cancel, the next 2-minute tick would
        // rebuild relation-graph nodes onto the freshly-reset DB.
        // Audit P1 finding; verified in code review.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.cancelGraphBuildLoop()
        }
        // Latch the debug trace recorder BEFORE the directory delete below —
        // its fire-and-forget tasks would otherwise recreate the freshly
        // wiped Pidgy dir with raw chat prompts inside.
        await LocalAITraceRecorder.shared.stop()
        async let recentStop: Void = RecentSyncCoordinator.shared.stop()
        async let coverageStop: Void = MajorChatCoverageCoordinator.shared.stop()
        async let scheduleStop: Void = IndexScheduler.shared.stop()
        async let cacheInvalidate: Void = MessageCacheService.shared.invalidateAllLocalData()
        async let usageInvalidate: Void = AIUsageStore.shared.invalidateAll()
        _ = await (recentStop, coverageStop, scheduleStop, cacheInvalidate, usageInvalidate)

        // Close TDLib + the SQLite handle BEFORE removing the data dir, so
        // the OS isn't trying to delete files that are still open.
        telegramService.stop()
        await DatabaseManager.shared.close()

        // The TDLib database can be hundreds of MB. Hop the recursive
        // remove off the main actor so the SwiftUI alert can dismiss and
        // the progress UI stays responsive while the disk does its thing.
        if let pidgyDataDir {
            await Task.detached(priority: .userInitiated) {
                try? FileManager.default.removeItem(at: pidgyDataDir)
            }.value
        }

        telegramService.authState = .uninitialized
        telegramService.chats = []
        telegramService.currentUser = nil
        telegramService.isLoading = false
        telegramService.errorMessage = nil
        aiService.clearConfigurationState()
    }
}
