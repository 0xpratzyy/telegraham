import Foundation

enum DashboardPreferencePage: String, CaseIterable, Identifiable, Hashable {
    case account = "Account"
    case ai = "AI"
    case pricing = "Pricing"
    case indexing = "Indexing"
    case diagnostics = "Diagnostics"
    case reset = "Reset"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .account:
            return "person.crop.circle"
        case .ai:
            return "sparkles"
        case .pricing:
            return "chart.bar.xaxis"
        case .indexing:
            return "externaldrive.connected.to.line.below"
        case .diagnostics:
            return "waveform.path.ecg"
        case .reset:
            return "trash"
        case .about:
            return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .account:
            return "Telegram connection and credentials"
        case .ai:
            return "Provider, model, and privacy"
        case .pricing:
            return "AI usage, tokens, and cost"
        case .indexing:
            return "Search freshness and local coverage"
        case .diagnostics:
            return "Graph health and query routing"
        case .reset:
            return "Local data cleanup"
        case .about:
            return "App identity and shortcuts"
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
    static let routingSampleQueries: [String] = [
        "where I shared wallet address",
        "find message with contract address",
        "first dollar",
        "partnership discussions",
        "who do I need to reply to",
        "who haven't I replied to from last week",
        "stale investors",
        "summarize my chats with Akhil"
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
        .aiModel
    ]

    static let userDefaultsKeysToDelete: [String] = [
        AppConstants.Preferences.includeBotsInAISearchKey,
        AppConstants.Preferences.dashboardTaskTriageContextVersionKey
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
        for key in PreferencesResetPlan.credentialKeysToDelete {
            try? KeychainManager.delete(for: key)
        }
        for key in PreferencesResetPlan.userDefaultsKeysToDelete {
            userDefaults.removeObject(forKey: key)
        }

        let pidgyDataDir = PreferencesResetPlan.defaultPidgyDataDirectory(fileManager: fileManager)

        TaskIndexCoordinator.shared.stop()
        await RecentSyncCoordinator.shared.stop()
        await IndexScheduler.shared.stop()
        telegramService.stop()
        await MessageCacheService.shared.invalidateAllLocalData()
        await AIUsageStore.shared.invalidateAll()
        await DatabaseManager.shared.close()

        if let pidgyDataDir {
            try? fileManager.removeItem(at: pidgyDataDir)
        }

        telegramService.authState = .uninitialized
        telegramService.chats = []
        telegramService.currentUser = nil
        telegramService.isLoading = false
        telegramService.errorMessage = nil
        aiService.clearConfigurationState()
    }
}
