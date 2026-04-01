import SwiftUI

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
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

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
        }
        .onChange(of: selectedTab) { _, newValue in
            switch newValue {
            case .usage:
                Task { await refreshUsageOverview() }
            case .debug:
                Task { await refreshGraphDebugSummary() }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
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
        aiApiKey = (try? KeychainManager.retrieve(for: .aiApiKey)) ?? ""
        aiModel = (try? KeychainManager.retrieve(for: .aiModel)) ?? ""
    }

    private func saveAIConfig() {
        aiService.configure(type: selectedAIProvider, apiKey: aiApiKey, model: aiModel.isEmpty ? nil : aiModel)
        aiSaveStatus = "Saved"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            aiSaveStatus = nil
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
}
