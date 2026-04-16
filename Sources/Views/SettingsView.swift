import SwiftUI

private struct QueryRoutingDebugSnapshot: Identifiable {
    let query: String
    let spec: QuerySpec
    let runtimeIntent: QueryIntent

    var id: String { query }
}

struct SettingsView: View {
    private enum SettingsTab: Hashable {
        case credentials
        case ai
        case usage
        case debug
        case about
    }

    @EnvironmentObject var telegramService: TelegramService
    @EnvironmentObject var aiService: AIService
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var saveStatus: String?
    @State private var showDeleteConfirmation = false
    @State private var selectedTab: SettingsTab = .credentials

    // AI settings
    @State private var selectedAIProvider: AIProviderConfig.ProviderType = .none
    @State private var aiApiKey = ""
    @State private var aiModel = ""
    @State private var aiSaveStatus: String?
    @State private var isTestingConnection = false
    @State private var testConnectionResult: String?
    @State private var usageOverview: AIUsageOverview = .empty
    @State private var isLoadingUsage = false
    @State private var graphDebugSummary: GraphBuilder.DebugSummary = .empty
    @State private var isLoadingGraphDebug = false
    @State private var routingDebugQuery = "who do I need to reply to"
    @State private var routingDebugSnapshot: QueryRoutingDebugSnapshot?
    @State private var routingSampleSnapshots: [QueryRoutingDebugSnapshot] = []
    @State private var isLoadingRoutingDebug = false
    @StateObject private var indexingProgress = IndexScheduler.shared.progress
    @StateObject private var recentSyncProgress = RecentSyncCoordinator.shared.progress
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    private let routingSampleQueries: [String] = [
        "where I shared wallet address",
        "find message with contract address",
        "first dollar",
        "partnership discussions",
        "who do I need to reply to",
        "who haven't I replied to from last week",
        "stale investors",
        "summarize my chats with Akhil"
    ]

    var body: some View {
        TabView(selection: $selectedTab) {
            credentialsTab
                .tag(SettingsTab.credentials)
                .tabItem {
                    Label("Credentials", systemImage: "key")
                }

            aiTab
                .tag(SettingsTab.ai)
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }

            usageTab
                .tag(SettingsTab.usage)
                .tabItem {
                    Label("Usage", systemImage: "chart.bar.xaxis")
                }

            debugTab
                .tag(SettingsTab.debug)
                .tabItem {
                    Label("Debug", systemImage: "wrench.and.screwdriver")
                }

            aboutTab
                .tag(SettingsTab.about)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            loadCredentials()
            loadAIConfig()
            Task { await refreshUsageOverview() }
            Task { await refreshGraphDebugSummary() }
            Task { await refreshRoutingDebug() }
        }
        .onChange(of: selectedTab) { _, newValue in
            switch newValue {
            case .usage:
                Task { await refreshUsageOverview() }
            case .debug:
                Task { await refreshGraphDebugSummary() }
                Task { await refreshRoutingDebug() }
            default:
                break
            }
        }
    }

    // MARK: - Credentials Tab

    private var credentialsTab: some View {
        Form {
            Section {
                TextField("API ID", text: $apiId)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Hash", text: $apiHash)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Credentials") {
                        saveCredentials()
                    }

                    if let status = saveStatus {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(status.contains("Error") ? .red : .green)
                    }
                }

                Link("Get credentials from my.telegram.org",
                     destination: URL(string: "https://my.telegram.org")!)
                    .font(.system(size: 12))
            } header: {
                Text("Telegram API Credentials")
            } footer: {
                Text("Each user must generate their own credentials. Never use someone else's API credentials.")
                    .font(.system(size: 11))
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        StatusDot(isConnected: telegramService.authState == .ready)
                        Text(authStateDescription)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

                if telegramService.authState == .ready {
                    if let user = telegramService.currentUser {
                        HStack {
                            Text("Account")
                            Spacer()
                            Text(user.displayName)
                                .foregroundColor(.secondary)
                        }
                    }

                    Button("Log Out") {
                        Task {
                            try? await telegramService.logOut()
                        }
                    }
                    .foregroundColor(.red)
                }
            } header: {
                Text("Account")
            }

            Section {
                Button("Delete All Local Data") {
                    showDeleteConfirmation = true
                }
                .foregroundColor(.red)
            } header: {
                Text("Data")
            } footer: {
                Text("Removes TDLib database, credentials, and all local data. You'll need to re-authenticate.")
                    .font(.system(size: 11))
            }
        }
        .formStyle(.grouped)
        .alert("Delete All Data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will remove all local data including your Telegram session. You will need to re-authenticate.")
        }
    }

    // MARK: - AI Tab

    private var aiTab: some View {
        Form {
                Section {
                    Picker("Provider", selection: $selectedAIProvider) {
                        Text("None").tag(AIProviderConfig.ProviderType.none)
                        Text("Claude (Anthropic)").tag(AIProviderConfig.ProviderType.claude)
                        Text("OpenAI").tag(AIProviderConfig.ProviderType.openai)
                    }
                    .onChange(of: selectedAIProvider) { oldValue, newValue in
                        guard oldValue != newValue else { return }
                        loadAIFields(for: newValue)
                        aiSaveStatus = nil
                        testConnectionResult = nil
                    }

                    if selectedAIProvider != .none {
                        SecureField("API Key", text: $aiApiKey)
                            .textFieldStyle(.roundedBorder)

                    TextField("Model (optional, uses default if empty)", text: $aiModel)
                        .textFieldStyle(.roundedBorder)

                    Text("Default: \(selectedAIProvider.defaultModel)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack {
                        Button("Save AI Settings") {
                            saveAIConfig()
                        }

                        if let status = aiSaveStatus {
                            Text(status)
                                .font(.system(size: 12))
                                .foregroundColor(status.contains("Error") ? .red : .green)
                        }
                    }

                    HStack {
                        Button("Test Connection") {
                            Task { await testConnection() }
                        }
                        .disabled(isTestingConnection || aiApiKey.isEmpty)

                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let result = testConnectionResult {
                            Text(result)
                                .font(.system(size: 12))
                                .foregroundColor(result.contains("✓") ? .green : .red)
                        }
                    }
                }
            } header: {
                Text("AI Provider")
            } footer: {
                Text("Your own API key is used. No data is stored on any server beyond what the AI provider processes.")
                    .font(.system(size: 11))
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(aiService.isConfigured ? .green : .secondary)
                            .frame(width: 8, height: 8)
                        Text(aiService.isConfigured ? "Configured (\(aiService.providerType.rawValue))" : "Not configured")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }

            } header: {
                Text("Privacy")
            } footer: {
                Text("AI features send message text, sender first names, relative timestamps, chat names, and numeric chat IDs. No phone numbers, user IDs, or media files are ever sent.")
                    .font(.system(size: 11))
            }

            Section {
                Toggle("Include Bot Chats In AI Search", isOn: $includeBotsInAISearch)
                Text("Turn this off to hide Telegram bots like BotFather from AI search and agentic ranking.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } header: {
                Text("AI Search Preferences")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What data is sent to AI:")
                        .font(.system(size: 12, weight: .semibold))
                    Text("- Message text (plaintext)")
                        .font(.system(size: 11))
                    Text("- Sender first name")
                        .font(.system(size: 11))
                    Text("- Relative timestamp (e.g. \"2h ago\")")
                        .font(.system(size: 11))
                    Text("- Numeric chat ID")
                        .font(.system(size: 11))
                    Text("- Chat name")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("What is never sent:")
                        .font(.system(size: 12, weight: .semibold))
                    Text("- Phone numbers, user IDs, session tokens")
                        .font(.system(size: 11))
                    Text("- Media files, stickers, voice messages")
                        .font(.system(size: 11))
                    Text("- Last names, full chat histories")
                        .font(.system(size: 11))
                }
                .foregroundColor(.secondary)
            } header: {
                Text("Privacy Details")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Usage Tab

    private var usageTab: some View {
        ZStack {
            if !usageOverview.hasUsage && isLoadingUsage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading AI usage...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if !usageOverview.hasUsage {
                VStack(spacing: 14) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text("No AI usage yet")
                        .font(.system(size: 18, weight: .semibold))

                    Text("Successful AI calls will show up here with provider-reported tokens and estimated USD cost.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button("Refresh") {
                        Task { await refreshUsageOverview() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI Cost & Usage")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Last 30 Days is the default lens. Lifetime totals are shown below.")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if isLoadingUsage {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button("Refresh") {
                                Task { await refreshUsageOverview() }
                            }
                            .buttonStyle(.bordered)
                        }

                        LazyVGrid(columns: usageGridColumns, spacing: 12) {
                            usageMetricCard(
                                title: "Last 30 Days Cost",
                                value: currencyString(usageOverview.last30Days.estimatedCostUSD),
                                caption: "Estimated cost (USD)",
                                accent: .orange
                            )
                            usageMetricCard(
                                title: "Last 30 Days Requests",
                                value: integerString(usageOverview.last30Days.requestCount),
                                caption: "Successful AI calls",
                                accent: .blue
                            )
                            usageMetricCard(
                                title: "Last 30 Days Input",
                                value: compactNumberString(usageOverview.last30Days.inputTokens),
                                caption: "Provider-reported input tokens",
                                accent: .green
                            )
                            usageMetricCard(
                                title: "Last 30 Days Output",
                                value: compactNumberString(usageOverview.last30Days.outputTokens),
                                caption: "Provider-reported output tokens",
                                accent: .purple
                            )
                        }

                        usageMetricCard(
                            title: "Lifetime Cost",
                            value: currencyString(usageOverview.lifetime.estimatedCostUSD),
                            caption: "Estimated cost (USD) across all tracked usage",
                            accent: .pink
                        )

                        if usageOverview.last30Days.unpricedRequestCount > 0 || usageOverview.last30Days.unmeteredRequestCount > 0 {
                            usageInfoCard
                        }

                        usageBreakdownSection(
                            title: "By Feature (30d)",
                            rows: usageOverview.byFeature30Days
                        )

                        usageBreakdownSection(
                            title: "By Model (30d)",
                            rows: usageOverview.byModel30Days
                        )
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Debug Tab

    private var debugTab: some View {
        ZStack {
            if !graphDebugSummary.hasData && isLoadingGraphDebug {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading graph debug info...")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else if !graphDebugSummary.hasData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(spacing: 14) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundColor(.secondary)

                            Text("No graph data yet")
                                .font(.system(size: 18, weight: .semibold))

                            Text("Once the graph builder runs, node counts, edge counts, and top contacts will appear here.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)

                            Button("Refresh") {
                                Task { await refreshGraphDebugSummary(rebuild: true) }
                            }
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)

                        routingDebugSection
                    }
                    .padding(16)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Graph Debug")
                                    .font(.system(size: 18, weight: .semibold))
                                Text(graphDebugStatusLine)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if isLoadingGraphDebug {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Button("Refresh") {
                                Task { await refreshGraphDebugSummary(rebuild: true) }
                            }
                            .buttonStyle(.bordered)
                        }

                        LazyVGrid(columns: usageGridColumns, spacing: 12) {
                            usageMetricCard(
                                title: "Recent Sync",
                                value: recentSyncStatusLabel,
                                caption: recentSyncStatusCaption,
                                accent: recentSyncStatusAccent
                            )
                            usageMetricCard(
                                title: "Stale Visible Chats",
                                value: recentSyncStaleLabel,
                                caption: "Visible chats still waiting on a fresh local window",
                                accent: recentSyncProgress.staleVisibleChats == 0 ? .green : .orange
                            )
                            usageMetricCard(
                                title: "Last Recent Sync",
                                value: recentSyncLastLabel,
                                caption: recentSyncLastCaption,
                                accent: .cyan
                            )
                            usageMetricCard(
                                title: "Recent Sync Session",
                                value: recentSyncSessionLabel,
                                caption: recentSyncSessionCaption,
                                accent: .mint
                            )
                        }

                        LazyVGrid(columns: usageGridColumns, spacing: 12) {
                            usageMetricCard(
                                title: "Search-Ready Chats",
                                value: "\(integerString(indexingProgress.indexed)) / \(integerString(indexingProgress.total))",
                                caption: "Loaded main-list chats fully deep-indexed for local search",
                                accent: indexingProgress.total > 0 && indexingProgress.indexed >= indexingProgress.total ? .green : .orange
                            )
                            usageMetricCard(
                                title: "Pending Deep Index",
                                value: integerString(indexingProgress.pendingChats),
                                caption: "Loaded main-list chats still missing deep local history",
                                accent: indexingProgress.pendingChats == 0 ? .green : .orange
                            )
                            usageMetricCard(
                                title: "Active Workers",
                                value: indexingWorkerLabel,
                                caption: indexingWorkerCaption,
                                accent: indexingWorkerAccent
                            )
                            usageMetricCard(
                                title: "Indexer Focus",
                                value: indexingCurrentChatLabel,
                                caption: "Current or last deep-index target",
                                accent: .teal
                            )
                        }

                        LazyVGrid(columns: usageGridColumns, spacing: 12) {
                            usageMetricCard(
                                title: "Last Index Progress",
                                value: lastIndexProgressLabel,
                                caption: lastIndexProgressCaption,
                                accent: lastIndexProgressAccent
                            )
                            usageMetricCard(
                                title: "Deep Index ETA",
                                value: deepIndexETALabel,
                                caption: deepIndexETACaption,
                                accent: deepIndexETAAccent
                            )
                            usageMetricCard(
                                title: "Indexed This Session",
                                value: compactNumberString(indexingProgress.sessionIndexedMessages),
                                caption: "Durable history messages written this run",
                                accent: .blue
                            )
                            usageMetricCard(
                                title: "Chats Completed",
                                value: integerString(indexingProgress.sessionCompletedChats),
                                caption: "Chats that reached full search-ready coverage",
                                accent: .purple
                            )
                            usageMetricCard(
                                title: "Index Coverage",
                                value: percentString(indexingCoverageFraction),
                                caption: "Indexable chats ready for local search",
                                accent: .mint
                            )
                        }

                        LazyVGrid(columns: usageGridColumns, spacing: 12) {
                            usageMetricCard(
                                title: "Chats Processed",
                                value: "\(integerString(graphDebugSummary.processedChats)) / \(integerString(graphDebugSummary.totalChats))",
                                caption: graphDebugSummary.isComplete ? "Graph build complete" : "Startup graph build progress",
                                accent: graphDebugSummary.isComplete ? .green : .orange
                            )
                            usageMetricCard(
                                title: "Node Rows",
                                value: integerString(graphDebugSummary.nodeCounts.reduce(0) { $0 + $1.count }),
                                caption: "Total entities in relation graph",
                                accent: .blue
                            )
                            usageMetricCard(
                                title: "Edge Rows",
                                value: integerString(graphDebugSummary.edgeCounts.reduce(0) { $0 + $1.count }),
                                caption: "DM and shared-group relationships",
                                accent: .purple
                            )
                            usageMetricCard(
                                title: "Completion",
                                value: percentString(graphDebugSummary.completionFraction),
                                caption: "Based on startup graph builder progress",
                                accent: .pink
                            )
                        }

                        debugBreakdownSection(title: "Nodes By Type", rows: graphDebugSummary.nodeCounts)
                        debugBreakdownSection(title: "Edges By Type", rows: graphDebugSummary.edgeCounts)
                        debugTopContactsSection
                        routingDebugSection
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Pidgy")
                .font(.system(size: 20, weight: .bold, design: .monospaced))

            Text("Version \(AppConstants.App.version)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("AI-Powered Telegram Search")
                .font(.system(size: 14))
                .foregroundColor(.secondary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 4) {
                Text("Read-only access. Your data stays on your machine.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Global Hotkey: ⌘ + ⇧ + T")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func loadCredentials() {
        apiId = (try? KeychainManager.retrieve(for: .apiId)) ?? ""
        apiHash = (try? KeychainManager.retrieve(for: .apiHash)) ?? ""
    }

    private func saveCredentials() {
        do {
            try KeychainManager.save(apiId, for: .apiId)
            try KeychainManager.save(apiHash, for: .apiHash)
            saveStatus = "Saved"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                saveStatus = nil
            }
        } catch {
            saveStatus = "Error: \(error.localizedDescription)"
        }
    }

    private func loadAIConfig() {
        selectedAIProvider = aiService.providerType
        loadAIFields(for: selectedAIProvider)
    }

    private func saveAIConfig() {
        let trimmedKey = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey: String

        if selectedAIProvider == .none {
            resolvedKey = ""
        } else if !trimmedKey.isEmpty {
            resolvedKey = trimmedKey
            aiApiKey = trimmedKey
        } else {
            aiSaveStatus = "Error: API key required"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                aiSaveStatus = nil
            }
            return
        }

        aiService.configure(type: selectedAIProvider, apiKey: resolvedKey, model: aiModel.isEmpty ? nil : aiModel)
        aiSaveStatus = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            aiSaveStatus = nil
        }
    }

    private func loadAIFields(for provider: AIProviderConfig.ProviderType) {
        guard provider != .none else {
            aiApiKey = ""
            aiModel = ""
            return
        }

        if let persisted = aiService.persistedConfiguration(for: provider) {
            aiApiKey = persisted.apiKey
            aiModel = persisted.model == provider.defaultModel ? "" : persisted.model
        } else {
            aiApiKey = ""
            aiModel = ""
        }
    }

    private func testConnection() async {
        isTestingConnection = true
        testConnectionResult = nil
        defer { isTestingConnection = false }

        // Save config first to ensure provider is up to date
        saveAIConfig()

        do {
            let success = try await aiService.testConnection()
            testConnectionResult = success ? "✓ Connection successful" : "✗ Test failed"
        } catch {
            testConnectionResult = "✗ \(error.localizedDescription)"
        }

        // Clear result after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            testConnectionResult = nil
        }
    }

    private func deleteAllData() {
        try? KeychainManager.delete(for: .apiId)
        try? KeychainManager.delete(for: .apiHash)
        try? KeychainManager.delete(for: .aiProviderType)
        try? KeychainManager.delete(for: .aiApiKeyOpenAI)
        try? KeychainManager.delete(for: .aiApiKeyClaude)
        try? KeychainManager.delete(for: .aiModelOpenAI)
        try? KeychainManager.delete(for: .aiModelClaude)
        try? KeychainManager.delete(for: .aiApiKey)
        try? KeychainManager.delete(for: .aiModel)
        UserDefaults.standard.removeObject(forKey: AppConstants.Preferences.includeBotsInAISearchKey)

        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let pidgyDataDir = appSupportDir?.appendingPathComponent("Pidgy", isDirectory: true)

        let cacheResetGroup = DispatchGroup()
        cacheResetGroup.enter()
        Task.detached {
            await MessageCacheService.shared.invalidateAllLocalData()
            await AIUsageStore.shared.invalidateAll()
            await DatabaseManager.shared.close()
            cacheResetGroup.leave()
        }
        _ = cacheResetGroup.wait(timeout: .now() + 2)

        if let pidgyDataDir {
            try? FileManager.default.removeItem(at: pidgyDataDir)
        }

        telegramService.stop()
        telegramService.authState = .uninitialized
        telegramService.chats = []
        telegramService.currentUser = nil
        telegramService.isLoading = false
        telegramService.errorMessage = nil
        aiService.clearConfigurationState()

        apiId = ""
        apiHash = ""
        aiApiKey = ""
        aiModel = ""
        selectedAIProvider = .none
        includeBotsInAISearch = false
        aiSaveStatus = nil
        testConnectionResult = nil
        usageOverview = .empty
        saveStatus = "All data deleted"
    }

    @MainActor
    private func refreshUsageOverview() async {
        guard !isLoadingUsage else { return }
        isLoadingUsage = true
        usageOverview = await aiService.loadUsageOverview()
        isLoadingUsage = false
    }

    @MainActor
    private func refreshGraphDebugSummary(rebuild: Bool = false) async {
        guard !isLoadingGraphDebug else { return }
        isLoadingGraphDebug = true
        if rebuild {
            await GraphBuilder.shared.refresh(using: telegramService)
        }
        graphDebugSummary = await GraphBuilder.shared.debugSummary()
        isLoadingGraphDebug = false
    }

    @MainActor
    private func refreshRoutingDebug() async {
        guard !isLoadingRoutingDebug else { return }
        isLoadingRoutingDebug = true

        let interpreter = QueryInterpreter()
        let now = Date()
        let timezone = TimeZone.current

        let trimmedQuery = routingDebugQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let spec = interpreter.parse(
                query: trimmedQuery,
                now: now,
                timezone: timezone,
                activeFilter: .all
            )
            let runtimeIntent = await aiService.queryRouter.route(
                query: trimmedQuery,
                querySpec: spec,
                activeFilter: spec.scope,
                timezone: timezone,
                now: now
            )
            routingDebugSnapshot = QueryRoutingDebugSnapshot(
                query: trimmedQuery,
                spec: spec,
                runtimeIntent: runtimeIntent
            )
        } else {
            routingDebugSnapshot = nil
        }

        var samples: [QueryRoutingDebugSnapshot] = []
        for query in routingSampleQueries {
            let spec = interpreter.parse(
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
            samples.append(
                QueryRoutingDebugSnapshot(
                    query: query,
                    spec: spec,
                    runtimeIntent: runtimeIntent
                )
            )
        }
        routingSampleSnapshots = samples
        isLoadingRoutingDebug = false
    }

    private var authStateDescription: String {
        switch telegramService.authState {
        case .uninitialized: return "Not initialized"
        case .waitingForParameters: return "Configuring..."
        case .waitingForPhoneNumber: return "Waiting for phone"
        case .waitingForQrCode: return "Scan QR code"
        case .waitingForCode: return "Waiting for code"
        case .waitingForPassword: return "Waiting for password"
        case .ready: return "Connected"
        case .loggingOut: return "Logging out..."
        case .closing: return "Closing..."
        case .closed: return "Disconnected"
        }
    }

    private var usageGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var graphDebugStatusLine: String {
        let progress = "\(integerString(graphDebugSummary.processedChats)) / \(integerString(graphDebugSummary.totalChats)) chats"
        if let lastUpdatedAt = graphDebugSummary.lastUpdatedAt {
            return "\(progress) • Last update \(DateFormatting.compactRelativeTime(from: lastUpdatedAt))"
        }
        return progress
    }

    private var indexingCoverageFraction: Double {
        guard indexingProgress.total > 0 else { return 0 }
        return min(max(Double(indexingProgress.indexed) / Double(indexingProgress.total), 0), 1)
    }

    private var indexingCurrentChatLabel: String {
        if let currentChat = indexingProgress.currentChat, !currentChat.isEmpty {
            return currentChat
        }
        if let lastIndexedChat = indexingProgress.lastIndexedChat, !lastIndexedChat.isEmpty {
            return lastIndexedChat
        }
        if indexingProgress.isPaused {
            return "Search active"
        }
        if indexingProgress.total > 0 && indexingProgress.indexed >= indexingProgress.total {
            return "Up to date"
        }
        return "Waiting"
    }

    private var indexingWorkerLabel: String {
        if indexingProgress.isPaused {
            return "Yielding"
        }
        if indexingProgress.activeWorkers > 0 {
            return "\(indexingProgress.activeWorkers)"
        }
        if indexingProgress.pendingChats == 0 && indexingProgress.total > 0 {
            return "Idle"
        }
        return "Waiting"
    }

    private var indexingWorkerCaption: String {
        if indexingProgress.isPaused {
            return "Deep index yields while you actively search"
        }
        if indexingProgress.activeWorkers > 0 {
            return "Concurrent deep-index workers live now"
        }
        if indexingProgress.pendingChats == 0 && indexingProgress.total > 0 {
            return "No pending loaded main-list chats left to deep-index"
        }
        return "Workers are ready for the next loaded-chat backlog pass"
    }

    private var indexingWorkerAccent: Color {
        if indexingProgress.isPaused {
            return .orange
        }
        if indexingProgress.activeWorkers > 0 {
            return .blue
        }
        return indexingProgress.pendingChats == 0 ? .green : .secondary
    }

    private var lastIndexProgressLabel: String {
        if indexingProgress.lastBatchMessageCount > 0 {
            return "\(compactNumberString(indexingProgress.lastBatchMessageCount)) msgs"
        }
        if indexingProgress.lastBackfillCount > 0 {
            return "\(compactNumberString(indexingProgress.lastBackfillCount)) emb"
        }
        if let lastIndexedAt = indexingProgress.lastIndexedAt {
            return relativeTimeString(lastIndexedAt)
        }
        return "No batches yet"
    }

    private var lastIndexProgressCaption: String {
        let subject = indexingProgress.lastIndexedChat ?? "Deep index"
        if let lastIndexedAt = indexingProgress.lastIndexedAt {
            return "\(subject) moved \(relativeTimeString(lastIndexedAt))"
        }
        if indexingProgress.pendingChats > 0 {
            return "Waiting for the first loaded-chat deep-index batch"
        }
        return "All currently loaded main-list chats are covered"
    }

    private var lastIndexProgressAccent: Color {
        if indexingProgress.lastIndexedAt != nil {
            return .green
        }
        return indexingProgress.pendingChats > 0 ? .orange : .secondary
    }

    private var deepIndexETASeconds: TimeInterval? {
        guard indexingProgress.pendingChats > 0 else { return 0 }
        guard let sessionStartedAt = indexingProgress.sessionStartedAt else { return nil }
        guard indexingProgress.sessionCompletedChats > 0 else { return nil }

        let elapsed = Date().timeIntervalSince(sessionStartedAt)
        guard elapsed >= 60 else { return nil }

        let chatsPerSecond = Double(indexingProgress.sessionCompletedChats) / elapsed
        guard chatsPerSecond > 0 else { return nil }

        return Double(indexingProgress.pendingChats) / chatsPerSecond
    }

    private var deepIndexETALabel: String {
        guard indexingProgress.pendingChats > 0 else { return "Done" }
        guard let etaSeconds = deepIndexETASeconds else { return "Estimating…" }
        return durationString(etaSeconds)
    }

    private var deepIndexETACaption: String {
        guard indexingProgress.pendingChats > 0 else {
            return "Loaded main-list backlog is fully covered right now"
        }
        guard let sessionStartedAt = indexingProgress.sessionStartedAt else {
            return "Waiting for this session to establish a pace"
        }
        let elapsed = Date().timeIntervalSince(sessionStartedAt)
        guard indexingProgress.sessionCompletedChats > 0, elapsed >= 60 else {
            return "Need a bit more completed-chat data before the estimate settles"
        }
        return "Estimated from \(integerString(indexingProgress.sessionCompletedChats)) completed chats this run"
    }

    private var deepIndexETAAccent: Color {
        if indexingProgress.pendingChats == 0 {
            return .green
        }
        if deepIndexETASeconds != nil {
            return .indigo
        }
        return .orange
    }

    private var recentSyncStatusLabel: String {
        if recentSyncProgress.activeRefreshes > 0 {
            return "Refreshing"
        }
        if recentSyncProgress.isRefreshQueued {
            return "Queued"
        }
        if recentSyncProgress.totalVisibleChats > 0 && recentSyncProgress.staleVisibleChats == 0 {
            return "Fresh"
        }
        return "Watching"
    }

    private var recentSyncStatusCaption: String {
        if recentSyncProgress.activeRefreshes > 0 {
            return "Recent windows are being pulled into SQLite now"
        }
        if recentSyncProgress.isRefreshQueued {
            return "A startup, foreground, or priority refresh is queued"
        }
        if recentSyncProgress.totalVisibleChats > 0 && recentSyncProgress.staleVisibleChats == 0 {
            return "Visible chats are locally fresh for launcher search"
        }
        return "Monitoring visible chats for freshness drift"
    }

    private var recentSyncStatusAccent: Color {
        if recentSyncProgress.activeRefreshes > 0 {
            return .blue
        }
        if recentSyncProgress.isRefreshQueued {
            return .orange
        }
        if recentSyncProgress.totalVisibleChats > 0 && recentSyncProgress.staleVisibleChats == 0 {
            return .green
        }
        return .secondary
    }

    private var recentSyncStaleLabel: String {
        "\(integerString(recentSyncProgress.staleVisibleChats)) / \(integerString(recentSyncProgress.totalVisibleChats))"
    }

    private var recentSyncLastLabel: String {
        guard let lastSyncAt = recentSyncProgress.lastSyncAt else { return "No refresh yet" }
        return relativeTimeString(lastSyncAt)
    }

    private var recentSyncLastCaption: String {
        if let lastSyncedChat = recentSyncProgress.lastSyncedChat, !lastSyncedChat.isEmpty {
            return lastSyncedChat
        }
        return "Most recently refreshed visible chat"
    }

    private var recentSyncSessionLabel: String {
        "\(integerString(recentSyncProgress.sessionRefreshedChats)) chats"
    }

    private var recentSyncSessionCaption: String {
        let messageSummary = "\(compactNumberString(recentSyncProgress.sessionRefreshedMessages)) msgs"
        if recentSyncProgress.prioritizedChats > 0 {
            return "\(messageSummary) • \(integerString(recentSyncProgress.prioritizedChats)) priority"
        }
        return "\(messageSummary) this session"
    }

    private var usageInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pricing notes")
                .font(.system(size: 12, weight: .semibold))

            if usageOverview.last30Days.unpricedRequestCount > 0 {
                Text("\(integerString(usageOverview.last30Days.unpricedRequestCount)) metered request(s) used a model without local pricing and were excluded from USD totals.")
                    .font(.system(size: 12))
            }

            if usageOverview.last30Days.unmeteredRequestCount > 0 {
                Text("\(integerString(usageOverview.last30Days.unmeteredRequestCount)) successful request(s) returned no provider usage object and were excluded from token and cost totals.")
                    .font(.system(size: 12))
            }
        }
        .foregroundColor(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func usageMetricCard(
        title: String,
        value: String,
        caption: String,
        accent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(accent.opacity(0.18))
                .frame(width: 30, height: 6)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(caption)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
    }

    private func usageBreakdownSection(title: String, rows: [AIUsageBreakdownRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            if rows.isEmpty {
                Text("No tracked usage in this window.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(rows) { row in
                    usageBreakdownRow(row)

                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func usageBreakdownRow(_ row: AIUsageBreakdownRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))

                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(costLabel(for: row.metrics))
                    .font(.system(size: 13, weight: .semibold))

                Text("\(integerString(row.metrics.requestCount)) req • \(compactNumberString(row.metrics.inputTokens + row.metrics.outputTokens)) tok")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func debugBreakdownSection(title: String, rows: [GraphBuilder.DebugCountRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            if rows.isEmpty {
                Text("No rows yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(integerString(row.count))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }

                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var debugTopContactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Contacts")
                .font(.system(size: 13, weight: .semibold))

            if graphDebugSummary.topContacts.isEmpty {
                Text("No contact scores yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(graphDebugSummary.topContacts) { contact in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.displayName)
                                .font(.system(size: 13, weight: .medium))

                            Text(contact.category.capitalized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(String(format: "%.1f", contact.interactionScore))
                                .font(.system(size: 13, weight: .semibold))

                            Text(contact.lastInteractionAt.map(DateFormatting.compactRelativeTime(from:)) ?? "No activity")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    if contact.id != graphDebugSummary.topContacts.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var routingDebugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Query Routing Debug")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Use this to verify which query family and engine a search will hit.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isLoadingRoutingDebug {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Refresh") {
                    Task { await refreshRoutingDebug() }
                }
                .buttonStyle(.bordered)
            }

            TextField("Try a query", text: $routingDebugQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await refreshRoutingDebug() }
                }

            if let snapshot = routingDebugSnapshot {
                routingDebugCard(snapshot, title: "Live Query")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Sample Queries")
                    .font(.system(size: 12, weight: .semibold))

                ForEach(routingSampleSnapshots) { snapshot in
                    routingDebugCard(snapshot, title: nil)

                    if snapshot.id != routingSampleSnapshots.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func routingDebugCard(_ snapshot: QueryRoutingDebugSnapshot, title: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(snapshot.query)
                .font(.system(size: 13, weight: .medium))

            VStack(alignment: .leading, spacing: 4) {
                routingDebugLine("Family", snapshot.spec.family.rawValue)
                routingDebugLine("Preferred Engine", snapshot.spec.preferredEngine.rawValue)
                routingDebugLine("Runtime Route", snapshot.runtimeIntent.rawValue)
                routingDebugLine("Mode", snapshot.spec.mode.rawValue)
                routingDebugLine("Scope", snapshot.spec.scope.rawValue)
                routingDebugLine("Reply Constraint", snapshot.spec.replyConstraint.rawValue)
                routingDebugLine("Confidence", String(format: "%.2f", snapshot.spec.parseConfidence))
                if !snapshot.spec.unsupportedFragments.isEmpty {
                    routingDebugLine("Unsupported", snapshot.spec.unsupportedFragments.joined(separator: " • "))
                }
            }

            HStack {
                Spacer()
                Button("Use Query") {
                    routingDebugQuery = snapshot.query
                    Task { await refreshRoutingDebug() }
                }
                .buttonStyle(.link)
            }
        }
    }

    private func routingDebugLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func costLabel(for metrics: AIUsageMetrics) -> String {
        if metrics.estimatedCostUSD > 0 || (metrics.unpricedRequestCount == 0 && metrics.unmeteredRequestCount == 0) {
            return currencyString(metrics.estimatedCostUSD)
        }

        if metrics.unpricedRequestCount > 0 {
            return "Unpriced"
        }

        return "Unmetered"
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        formatter.minimumFractionDigits = value < 10 && value > 0 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }

    private func integerString(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compactNumberString(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0", with: "")
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000).replacingOccurrences(of: ".0", with: "")
        }
        return integerString(value)
    }

    private func percentString(_ value: Double) -> String {
        let normalized = min(max(value, 0), 1)
        return "\(Int((normalized * 100).rounded()))%"
    }

    private func relativeTimeString(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }

        if minutes > 0 {
            return "\(minutes)m"
        }

        return "<1m"
    }
}
