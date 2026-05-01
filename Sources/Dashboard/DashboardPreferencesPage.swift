import SwiftUI

struct DashboardPreferencesPage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var indexingProgress = IndexScheduler.shared.progress
    @StateObject private var recentSyncProgress = RecentSyncCoordinator.shared.progress
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false

    let onBackToDashboard: () -> Void
    let onRefreshDashboard: () -> Void
    let onRefreshUsage: () -> Void

    @State private var selectedPage: DashboardPreferencePage = .account
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var telegramStatus: DashboardPreferenceStatus?
    @State private var selectedAIProvider: AIProviderConfig.ProviderType = .none
    @State private var aiApiKey = ""
    @State private var aiModel = ""
    @State private var aiStatus: DashboardPreferenceStatus?
    @State private var isTestingConnection = false
    @State private var testConnectionStatus: DashboardPreferenceStatus?
    @State private var usageOverview: AIUsageOverview = .empty
    @State private var isLoadingUsage = false
    @State private var graphDebugSummary: GraphBuilder.DebugSummary = .empty
    @State private var isLoadingDiagnostics = false
    @State private var routingDebugQuery = "who do I need to reply to"
    @State private var routingSnapshots: [QueryRoutingDebugSnapshot] = []
    @State private var isLoadingRoutingDebug = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            preferencesTopBar

            HStack(spacing: 0) {
                preferencesRail

                Rectangle()
                    .fill(PidgyDashboardTheme.rule)
                    .frame(width: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        preferencesStatusStrip
                        selectedPreferencePage
                    }
                    .frame(maxWidth: 1040, alignment: .leading)
                    .padding(.horizontal, 38)
                    .padding(.top, 28)
                    .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
                }
            }
        }
        .background(PidgyDashboardTheme.paper)
        .onAppear {
            loadCredentials()
            loadAIConfig()
        }
        .task(id: selectedPage) {
            await refreshDataIfNeeded(for: selectedPage)
        }
        .onChange(of: selectedAIProvider) { oldValue, newValue in
            guard oldValue != newValue else { return }
            loadAIFields(for: newValue)
            aiStatus = nil
            testConnectionStatus = nil
        }
        .onChange(of: includeBotsInAISearch) {
            telegramService.scheduleBotMetadataWarm(
                for: telegramService.visibleChats,
                includeBots: includeBotsInAISearch
            )
            Task {
                await TaskIndexCoordinator.shared.setBotInclusion(
                    includeBotsInAISearch,
                    telegramService: telegramService
                )
            }
        }
        .alert("Delete all local data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteAllData() }
            }
        } message: {
            Text("This removes TDLib data, cached messages, AI usage, credentials, and your Telegram session. You will need to connect again.")
        }
    }

    private var preferencesTopBar: some View {
        HStack(spacing: 14) {
            Button(action: onBackToDashboard) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.left")
                    Text("Dashboard")
                }
                .font(PidgyDashboardTheme.metadataMediumFont)
                .frame(height: 30)
                .padding(.horizontal, 11)
                .background(DashboardCapsuleBackground())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)

            PidgyMascotMark(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Preferences")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text("· \(selectedPage.rawValue)")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
                Text(selectedPage.subtitle)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: refreshCurrentPreferencePage) {
                HStack(spacing: 7) {
                    if isCurrentPageRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isCurrentPageRefreshing ? "Refreshing" : "Refresh")
                }
                .font(PidgyDashboardTheme.metadataMediumFont)
                .frame(height: 30)
                .padding(.horizontal, 12)
                .background(DashboardCapsuleBackground())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .background(PidgyDashboardTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }

    private var preferencesRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("CONTROL CENTER")
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.8)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Text("Setup, cost, and local health")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)

            VStack(spacing: 3) {
                ForEach(DashboardPreferencePage.allCases) { page in
                    DashboardPreferenceSidebarButton(
                        page: page,
                        isSelected: selectedPage == page
                    ) {
                        selectedPage = page
                    }
                }
            }
            .padding(.horizontal, 11)

            Spacer()

            DashboardPreferenceSidebarSummary(
                title: aiService.isConfigured ? aiService.providerType.rawValue : "No provider",
                subtitle: pricingSummarySubtitle,
                systemImage: aiService.isConfigured ? "checkmark.seal" : "exclamationmark.triangle",
                tint: aiService.isConfigured ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .frame(width: 258)
        .frame(maxHeight: .infinity)
        .background(PidgyDashboardTheme.sidebar)
    }

    private var preferencesStatusStrip: some View {
        DashboardPreferenceControlMosaic(
            page: selectedPage,
            primary: primaryStatusItem,
            items: preferenceStatusItems
        )
    }

    private var primaryStatusItem: DashboardPreferenceStatusItem {
        switch selectedPage {
        case .account:
            return preferenceStatusItems[0]
        case .ai:
            return preferenceStatusItems[1]
        case .pricing:
            return preferenceStatusItems[2]
        case .indexing:
            return preferenceStatusItems[3]
        case .diagnostics:
            return DashboardPreferenceStatusItem(
                title: "Graph",
                value: graphDebugSummary.isComplete ? "Complete" : "Building",
                caption: graphDebugSummary.isComplete ? "\(integerString(graphDebugSummary.nodeCounts.reduce(0) { $0 + $1.count })) nodes" : "Open Diagnostics to load",
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: graphDebugSummary.isComplete ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
            )
        case .reset:
            return DashboardPreferenceStatusItem(
                title: "Local reset",
                value: "Manual",
                caption: "Deletes only this Mac's Pidgy data",
                systemImage: "trash",
                tint: PidgyDashboardTheme.red
            )
        case .about:
            return DashboardPreferenceStatusItem(
                title: "Pidgy",
                value: AppConstants.App.version,
                caption: PidgyBranding.dashboardTagline,
                systemImage: "info.circle",
                tint: PidgyDashboardTheme.blue
            )
        }
    }

    private var preferenceStatusItems: [DashboardPreferenceStatusItem] {
        [
            DashboardPreferenceStatusItem(
                title: "Telegram",
                value: authStateDescription,
                caption: telegramService.currentUser?.displayName ?? "No local account",
                systemImage: "paperplane",
                tint: telegramService.authState == .ready ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
            ),
            DashboardPreferenceStatusItem(
                title: "AI provider",
                value: aiService.isConfigured ? aiService.providerType.rawValue : "Not set",
                caption: aiService.isConfigured ? "Ready for dashboard actions" : "Open AI to configure",
                systemImage: "sparkles",
                tint: aiService.isConfigured ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
            ),
            DashboardPreferenceStatusItem(
                title: "30d spend",
                value: usageOverview.hasUsage ? currencyString(usageOverview.last30Days.estimatedCostUSD) : "--",
                caption: usageOverview.hasUsage ? "\(integerString(usageOverview.last30Days.requestCount)) requests" : "Open Pricing to load",
                systemImage: "chart.bar.xaxis",
                tint: PidgyDashboardTheme.blue
            ),
            DashboardPreferenceStatusItem(
                title: "Sync",
                value: recentSyncStatusLabel,
                caption: recentSyncStatusCaption,
                systemImage: "arrow.triangle.2.circlepath",
                tint: recentSyncProgress.activeRefreshes > 0 ? PidgyDashboardTheme.blue : PidgyDashboardTheme.green
            )
        ]
    }

    @ViewBuilder
    private var selectedPreferencePage: some View {
        switch selectedPage {
        case .account:
            accountPage
        case .ai:
            aiPage
        case .pricing:
            pricingPage
        case .indexing:
            indexingPage
        case .diagnostics:
            diagnosticsPage
        case .reset:
            resetPage
        case .about:
            aboutPage
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(title: "Telegram", subtitle: "Connection and local account", systemImage: "paperplane") {
                DashboardPreferenceRow(title: "Status", subtitle: "TDLib connection state") {
                    DashboardStatusPill(
                        text: authStateDescription,
                        tint: telegramService.authState == .ready ? PidgyDashboardTheme.green : PidgyDashboardTheme.secondary
                    )
                }

                if let user = telegramService.currentUser {
                    DashboardPreferenceRow(title: "Account", subtitle: user.displayName) {
                        DashboardPreferenceDangerButton(title: "Log out", systemImage: "rectangle.portrait.and.arrow.right") {
                            Task { try? await telegramService.logOut() }
                        }
                    }
                }

                LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                    DashboardPreferenceInputBlock(
                        title: "API ID",
                        subtitle: "Your Telegram developer app ID",
                        placeholder: "123456",
                        text: $apiId
                    )

                    DashboardPreferenceInputBlock(
                        title: "API Hash",
                        subtitle: "Stored locally through the credential manager",
                        placeholder: "Telegram API hash",
                        text: $apiHash,
                        isSecure: true
                    )
                }
                .padding(.vertical, 8)

                DashboardPreferenceRow(title: "Credentials", subtitle: "Save locally and start Telegram if possible") {
                    HStack(spacing: 10) {
                        if let telegramStatus {
                            DashboardPreferenceInlineStatus(status: telegramStatus)
                        }
                        DashboardPreferenceButton(title: "Save", systemImage: "checkmark", action: saveCredentials)
                    }
                }

                Link("Get credentials from my.telegram.org", destination: URL(string: "https://my.telegram.org")!)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.brand)
                    .padding(.top, 2)
            }

            DashboardPreferenceSection(title: "Account health", subtitle: "What the rest of the app can see", systemImage: "person.text.rectangle") {
                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Visible chats",
                        value: integerString(telegramService.visibleChats.count),
                        caption: "Loaded in the current session",
                        tint: PidgyDashboardTheme.blue
                    )
                    DashboardPreferenceMetric(
                        title: "Sync state",
                        value: recentSyncStatusLabel,
                        caption: recentSyncStatusCaption,
                        tint: recentSyncProgress.activeRefreshes > 0 ? PidgyDashboardTheme.blue : PidgyDashboardTheme.green
                    )
                }
            }
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(title: "Provider", subtitle: "Used for reply queue, tasks, summaries, and semantic search", systemImage: "sparkles") {
                DashboardPreferenceRow(title: "Provider", subtitle: aiService.isConfigured ? "Configured as \(aiService.providerType.rawValue)" : "Required for AI dashboard features") {
                    Picker("", selection: $selectedAIProvider) {
                        ForEach(AIProviderConfig.ProviderType.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                }

                if selectedAIProvider != .none {
                    LazyVGrid(columns: formColumns, alignment: .leading, spacing: 14) {
                        DashboardPreferenceInputBlock(
                            title: "API key",
                            subtitle: "Stored in Keychain or the debug credential store",
                            placeholder: "\(selectedAIProvider.rawValue) API key",
                            text: $aiApiKey,
                            isSecure: true
                        )

                        DashboardPreferenceInputBlock(
                            title: "Model",
                            subtitle: "Default: \(selectedAIProvider.defaultModel)",
                            placeholder: selectedAIProvider.defaultModel,
                            text: $aiModel
                        )
                    }
                    .padding(.vertical, 8)
                }

                DashboardPreferenceRow(title: "Provider config", subtitle: "Save before testing a connection") {
                    HStack(spacing: 10) {
                        if let aiStatus {
                            DashboardPreferenceInlineStatus(status: aiStatus)
                        }
                        DashboardPreferenceButton(title: "Save", systemImage: "checkmark", action: saveAIConfig)
                    }
                }

                DashboardPreferenceRow(title: "Connection test", subtitle: "Sends a tiny provider health check") {
                    HStack(spacing: 10) {
                        if isTestingConnection {
                            ProgressView()
                                .controlSize(.small)
                        }
                        if let testConnectionStatus {
                            DashboardPreferenceInlineStatus(status: testConnectionStatus)
                        }
                        DashboardPreferenceButton(title: "Test", systemImage: "bolt.horizontal", action: {
                            Task { await testConnection() }
                        })
                        .disabled(isTestingConnection || selectedAIProvider == .none)
                    }
                }
            }

            DashboardPreferenceSection(title: "Privacy", subtitle: "Keep the AI surface explicit", systemImage: "hand.raised") {
                DashboardPreferenceRow(title: "Include bot chats", subtitle: "Hide Telegram bots from AI search and agentic ranking when off") {
                    Toggle("", isOn: $includeBotsInAISearch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                DashboardPreferenceNote(
                    title: "What AI sees",
                    text: "Message text, sender first names, relative timestamps, chat names, and numeric chat IDs. It does not send phone numbers, user IDs, session tokens, media files, stickers, or voice messages."
                )
            }
        }
    }

    private var pricingPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(title: "Cost overview", subtitle: "Last 30 days and lifetime usage", systemImage: "dollarsign.circle") {
                if isLoadingUsage && !usageOverview.hasUsage {
                    DashboardSkeletonRows(count: 4, showAvatar: false, showTimestamp: false)
                } else {
                    DashboardPricingBarGraph(rows: pricingBarRows)

                    LazyVGrid(columns: metricColumns, spacing: 12) {
                        DashboardPreferenceMetric(
                            title: "30d cost",
                            value: currencyString(usageOverview.last30Days.estimatedCostUSD),
                            caption: "\(integerString(usageOverview.last30Days.requestCount)) successful requests",
                            tint: PidgyDashboardTheme.blue
                        )
                        DashboardPreferenceMetric(
                            title: "30d tokens",
                            value: compactNumberString(usageOverview.last30Days.inputTokens + usageOverview.last30Days.outputTokens),
                            caption: "Input and output tokens",
                            tint: PidgyDashboardTheme.green
                        )
                        DashboardPreferenceMetric(
                            title: "Lifetime cost",
                            value: currencyString(usageOverview.lifetime.estimatedCostUSD),
                            caption: "\(integerString(usageOverview.lifetime.requestCount)) total requests",
                            tint: PidgyDashboardTheme.blue
                        )
                        DashboardPreferenceMetric(
                            title: "Unpriced",
                            value: integerString(usageOverview.last30Days.unpricedRequestCount + usageOverview.last30Days.unmeteredRequestCount),
                            caption: "Requests excluded from USD totals",
                            tint: PidgyDashboardTheme.yellow
                        )
                    }
                }

                DashboardPreferenceRow(title: "Usage data", subtitle: "Refresh provider-reported usage totals") {
                    HStack(spacing: 10) {
                        if isLoadingUsage {
                            ProgressView()
                                .controlSize(.small)
                        }
                        DashboardPreferenceButton(title: "Refresh", systemImage: "arrow.clockwise") {
                            Task { await refreshUsageOverview() }
                        }
                    }
                }
            }

            DashboardPreferenceBreakdownSection(
                title: "By feature",
                rows: usageOverview.byFeature30Days,
                costLabel: { costLabel(for: $0) },
                integerString: integerString,
                compactNumberString: compactNumberString
            )

            DashboardPreferenceBreakdownSection(
                title: "By model",
                rows: usageOverview.byModel30Days,
                costLabel: { costLabel(for: $0) },
                integerString: integerString,
                compactNumberString: compactNumberString
            )

            if usageOverview.last30Days.unpricedRequestCount > 0 || usageOverview.last30Days.unmeteredRequestCount > 0 {
                DashboardPreferenceNote(
                    title: "Pricing notes",
                    text: "Some successful requests did not include usage metadata or used a model without local pricing, so they are excluded from the USD estimate."
                )
            }
        }
    }

    private var indexingPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(title: "Indexing", subtitle: "Freshness and local search coverage", systemImage: "externaldrive.connected.to.line.below") {
                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Search-ready",
                        value: "\(integerString(indexingProgress.indexed)) / \(integerString(indexingProgress.total))",
                        caption: "Loaded chats deep-indexed",
                        tint: indexingProgress.total > 0 && indexingProgress.indexed >= indexingProgress.total ? PidgyDashboardTheme.green : PidgyDashboardTheme.blue
                    )
                    DashboardPreferenceMetric(
                        title: "Pending",
                        value: integerString(indexingProgress.pendingChats),
                        caption: "Chats waiting on deep index",
                        tint: indexingProgress.pendingChats == 0 ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
                    )
                    DashboardPreferenceMetric(
                        title: "Workers",
                        value: indexingWorkerLabel,
                        caption: indexingWorkerCaption,
                        tint: indexingWorkerTint
                    )
                    DashboardPreferenceMetric(
                        title: "ETA",
                        value: deepIndexETALabel,
                        caption: deepIndexETACaption,
                        tint: deepIndexETATint
                    )
                }

                DashboardPreferenceRow(title: "Refresh dashboard caches", subtitle: "Reload local task/topic state after a provider or bot-filter change") {
                    DashboardPreferenceButton(title: "Refresh", systemImage: "arrow.clockwise", action: onRefreshUsage)
                }
            }

            DashboardPreferenceSection(title: "Recent sync", subtitle: "The live window that feeds search and task context", systemImage: "arrow.triangle.2.circlepath") {
                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Status",
                        value: recentSyncStatusLabel,
                        caption: recentSyncStatusCaption,
                        tint: recentSyncProgress.activeRefreshes > 0 ? PidgyDashboardTheme.blue : PidgyDashboardTheme.green
                    )
                    DashboardPreferenceMetric(
                        title: "Stale visible",
                        value: "\(integerString(recentSyncProgress.staleVisibleChats)) / \(integerString(recentSyncProgress.totalVisibleChats))",
                        caption: "Visible chats needing refresh",
                        tint: recentSyncProgress.staleVisibleChats == 0 ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
                    )
                    DashboardPreferenceMetric(
                        title: "Last sync",
                        value: recentSyncProgress.lastSyncAt.map(relativeTimeString) ?? "No refresh",
                        caption: recentSyncProgress.lastSyncedChat ?? "Most recently refreshed visible chat",
                        tint: PidgyDashboardTheme.blue
                    )
                    DashboardPreferenceMetric(
                        title: "This session",
                        value: "\(integerString(recentSyncProgress.sessionRefreshedChats)) chats",
                        caption: "\(compactNumberString(recentSyncProgress.sessionRefreshedMessages)) messages refreshed",
                        tint: PidgyDashboardTheme.green
                    )
                }
            }
        }
    }

    private var diagnosticsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            queryRoutingSection

            DashboardPreferenceSection(title: "Graph health", subtitle: "Relation graph and search pipeline diagnostics", systemImage: "point.3.connected.trianglepath.dotted") {
                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Graph build",
                        value: graphDebugSummary.isComplete ? "Complete" : "\(integerString(graphDebugSummary.processedChats)) / \(integerString(graphDebugSummary.totalChats))",
                        caption: "Relation graph contacts",
                        tint: graphDebugSummary.isComplete ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
                    )
                    DashboardPreferenceMetric(
                        title: "Completion",
                        value: percentString(graphDebugSummary.completionFraction),
                        caption: "Based on startup graph progress",
                        tint: PidgyDashboardTheme.green
                    )
                    DashboardPreferenceMetric(
                        title: "Nodes",
                        value: integerString(graphDebugSummary.nodeCounts.reduce(0) { $0 + $1.count }),
                        caption: "Total graph entities",
                        tint: PidgyDashboardTheme.blue
                    )
                    DashboardPreferenceMetric(
                        title: "Edges",
                        value: integerString(graphDebugSummary.edgeCounts.reduce(0) { $0 + $1.count }),
                        caption: "DM and shared-group relationships",
                        tint: PidgyDashboardTheme.green
                    )
                }

                DashboardPreferenceRow(title: "Diagnostics", subtitle: "Refresh graph summary and query routes") {
                    HStack(spacing: 10) {
                        if isLoadingDiagnostics || isLoadingRoutingDebug {
                            ProgressView()
                                .controlSize(.small)
                        }
                        DashboardPreferenceButton(title: "Refresh", systemImage: "arrow.clockwise") {
                            Task {
                                await refreshDiagnostics()
                                await refreshRoutingDebug()
                            }
                        }
                        DashboardPreferenceButton(title: "Rebuild graph", systemImage: "hammer") {
                            Task { await refreshDiagnostics(rebuild: true) }
                        }
                    }
                }
            }

            DashboardGraphBreakdownSection(title: "Nodes by type", rows: graphDebugSummary.nodeCounts, integerString: integerString)
            DashboardGraphBreakdownSection(title: "Edges by type", rows: graphDebugSummary.edgeCounts, integerString: integerString)
        }
    }

    private var resetPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(title: "Local reset", subtitle: "Destructive cleanup for this Mac only", systemImage: "trash", isDanger: true) {
                DashboardPreferenceNote(
                    title: "What gets deleted",
                    text: "TDLib data, SQLite cache, AI usage, saved providers, credentials, and all local dashboard state. Telegram cloud data is not deleted."
                )

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Credentials",
                        value: integerString(PreferencesResetPlan.credentialKeysToDelete.count),
                        caption: "Credential slots cleared",
                        tint: PidgyDashboardTheme.red
                    )
                    DashboardPreferenceMetric(
                        title: "Defaults",
                        value: integerString(PreferencesResetPlan.userDefaultsKeysToDelete.count),
                        caption: "Preference keys reset",
                        tint: PidgyDashboardTheme.yellow
                    )
                }

                DashboardPreferenceRow(title: "Delete all local data", subtitle: "You will need to authenticate again") {
                    DashboardPreferenceDangerButton(title: "Delete", systemImage: "trash") {
                        showDeleteConfirmation = true
                    }
                }
            }
        }
    }

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            DashboardPreferenceSection(
                title: "Pidgy",
                subtitle: PidgyBranding.dashboardTagline,
                systemImage: "bolt.circle",
                assetImage: PidgyBranding.logoAssetName
            ) {
                DashboardPreferenceAboutHero()

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    DashboardPreferenceMetric(
                        title: "Version",
                        value: AppConstants.App.version,
                        caption: "Local build metadata",
                        tint: PidgyDashboardTheme.blue
                    )
                    DashboardPreferenceMetric(
                        title: "Hotkey",
                        value: "Cmd Shift T",
                        caption: "Open the quick launcher",
                        tint: PidgyDashboardTheme.blue
                    )
                }

                DashboardPreferenceNote(
                    title: "Local-first posture",
                    text: "Pidgy reads Telegram data locally, stores credentials locally, and uses your configured AI provider only when an AI feature needs it."
                )
            }
        }
    }

    private var queryRoutingSection: some View {
        DashboardPreferenceSection(title: "Query routing", subtitle: "See which engine a search will hit", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .foregroundStyle(PidgyDashboardTheme.brand)
                        .frame(width: 32, height: 34)
                        .background(PidgyDashboardTheme.brand.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    TextField("Try a query", text: $routingDebugQuery)
                        .textFieldStyle(.plain)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(PidgyDashboardTheme.deep)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                        .onSubmit {
                            Task { await refreshRoutingDebug() }
                        }

                    if isLoadingRoutingDebug {
                        ProgressView()
                            .controlSize(.small)
                    }

                    DashboardPreferenceButton(title: "Route", systemImage: "arrow.right") {
                        Task { await refreshRoutingDebug() }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    if routingSnapshots.isEmpty && isLoadingRoutingDebug {
                        DashboardSkeletonRows(count: 3, showAvatar: false, showTimestamp: false)
                    } else {
                        ForEach(routingSnapshots) { snapshot in
                            DashboardRoutingDebugCard(snapshot: snapshot) {
                                routingDebugQuery = snapshot.query
                                Task { await refreshRoutingDebug() }
                            }
                        }
                    }
                }
            }
        }
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 190), spacing: 12)
        ]
    }

    private var formColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 260), spacing: 14)
        ]
    }

    private var pricingBarRows: [DashboardPricingBarRow] {
        let rows = usageOverview.byFeature30Days
            .filter { $0.metrics.requestCount > 0 }
            .prefix(7)
            .map {
                DashboardPricingBarRow(
                    id: $0.id,
                    title: $0.title,
                    value: max($0.metrics.estimatedCostUSD, 0),
                    requests: $0.metrics.requestCount,
                    tint: tint(for: $0.id)
                )
            }

        if rows.isEmpty && usageOverview.last30Days.requestCount > 0 {
            return [
                DashboardPricingBarRow(
                    id: "all",
                    title: "All usage",
                    value: usageOverview.last30Days.estimatedCostUSD,
                    requests: usageOverview.last30Days.requestCount,
                    tint: PidgyDashboardTheme.blue
                )
            ]
        }

        return Array(rows)
    }

    private var pricingSummarySubtitle: String {
        if usageOverview.hasUsage {
            return "\(currencyString(usageOverview.last30Days.estimatedCostUSD)) in 30d"
        }
        return "No tracked usage yet"
    }

    private func loadCredentials() {
        apiId = (try? KeychainManager.retrieve(for: .apiId)) ?? ""
        apiHash = (try? KeychainManager.retrieve(for: .apiHash)) ?? ""
    }

    private func saveCredentials() {
        let trimmedId = apiId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedHash.isEmpty else {
            setTelegramStatus(.error("Missing credentials"))
            return
        }

        do {
            try KeychainManager.save(trimmedId, for: .apiId)
            try KeychainManager.save(trimmedHash, for: .apiHash)
            apiId = trimmedId
            apiHash = trimmedHash
            if let id = Int(trimmedId) {
                telegramService.start(apiId: id, apiHash: trimmedHash)
            }
            setTelegramStatus(.success("Saved"))
        } catch {
            setTelegramStatus(.error(error.localizedDescription))
        }
    }

    private func loadAIConfig() {
        selectedAIProvider = aiService.providerType
        loadAIFields(for: selectedAIProvider)
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

    private func saveAIConfig() {
        let trimmedKey = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if selectedAIProvider != .none && trimmedKey.isEmpty {
            setAIStatus(.error("API key required"))
            return
        }

        aiApiKey = trimmedKey
        aiModel = trimmedModel
        aiService.configure(
            type: selectedAIProvider,
            apiKey: selectedAIProvider == .none ? "" : trimmedKey,
            model: trimmedModel.isEmpty ? nil : trimmedModel
        )
        setAIStatus(.success("Saved"))
    }

    private func testConnection() async {
        isTestingConnection = true
        testConnectionStatus = nil
        defer { isTestingConnection = false }

        saveAIConfig()
        guard selectedAIProvider != .none else {
            testConnectionStatus = .error("No provider")
            return
        }

        do {
            let success = try await aiService.testConnection()
            testConnectionStatus = success ? .success("Connected") : .error("Failed")
        } catch {
            testConnectionStatus = .error(error.localizedDescription)
        }
    }

    @MainActor
    private func deleteAllData() async {
        await PreferencesResetService().deleteAllLocalData(
            telegramService: telegramService,
            aiService: aiService
        )

        apiId = ""
        apiHash = ""
        aiApiKey = ""
        aiModel = ""
        selectedAIProvider = .none
        includeBotsInAISearch = false
        usageOverview = .empty
        graphDebugSummary = .empty
        routingSnapshots = []
        setTelegramStatus(.success("Deleted"))
    }

    @MainActor
    private func refreshCurrentPreferencePage() {
        switch selectedPage {
        case .account:
            loadCredentials()
            onRefreshDashboard()
        case .ai:
            loadAIConfig()
        case .pricing:
            Task { await refreshUsageOverview() }
        case .indexing:
            onRefreshUsage()
        case .diagnostics:
            Task {
                await refreshDiagnostics()
                await refreshRoutingDebug()
            }
        case .reset, .about:
            loadCredentials()
            loadAIConfig()
            onRefreshDashboard()
        }
    }

    @MainActor
    private func refreshDataIfNeeded(for page: DashboardPreferencePage) async {
        switch page {
        case .pricing:
            await refreshUsageOverview()
        case .diagnostics:
            await refreshDiagnostics()
            await refreshRoutingDebug()
        default:
            break
        }
    }

    @MainActor
    private func refreshUsageOverview() async {
        guard !isLoadingUsage else { return }
        isLoadingUsage = true
        usageOverview = await aiService.loadUsageOverview()
        isLoadingUsage = false
    }

    @MainActor
    private func refreshDiagnostics(rebuild: Bool = false) async {
        guard !isLoadingDiagnostics else { return }
        isLoadingDiagnostics = true
        if rebuild {
            await GraphBuilder.shared.refresh(using: telegramService)
        }
        graphDebugSummary = await GraphBuilder.shared.debugSummary()
        isLoadingDiagnostics = false
    }

    @MainActor
    private func refreshRoutingDebug() async {
        guard !isLoadingRoutingDebug else { return }
        isLoadingRoutingDebug = true
        routingSnapshots = await DashboardDiagnosticsService.routingSnapshots(
            query: routingDebugQuery,
            aiService: aiService
        )
        isLoadingRoutingDebug = false
    }

    private func setTelegramStatus(_ status: DashboardPreferenceStatus) {
        telegramStatus = status
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            telegramStatus = nil
        }
    }

    private func setAIStatus(_ status: DashboardPreferenceStatus) {
        aiStatus = status
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            aiStatus = nil
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch selectedPage {
        case .pricing:
            return isLoadingUsage
        case .diagnostics:
            return isLoadingDiagnostics || isLoadingRoutingDebug
        default:
            return false
        }
    }

    private var authStateDescription: String {
        switch telegramService.authState {
        case .uninitialized: return "Not initialized"
        case .waitingForParameters: return "Configuring"
        case .waitingForPhoneNumber: return "Waiting for phone"
        case .waitingForQrCode: return "Scan QR"
        case .waitingForCode: return "Waiting for code"
        case .waitingForPassword: return "Waiting for password"
        case .ready: return "Connected"
        case .loggingOut: return "Logging out"
        case .closing: return "Closing"
        case .closed: return "Disconnected"
        }
    }

    private var recentSyncStatusLabel: String {
        if recentSyncProgress.activeRefreshes > 0 { return "Refreshing" }
        if recentSyncProgress.isRefreshQueued { return "Queued" }
        if recentSyncProgress.totalVisibleChats > 0 && recentSyncProgress.staleVisibleChats == 0 { return "Fresh" }
        return "Watching"
    }

    private var recentSyncStatusCaption: String {
        if recentSyncProgress.activeRefreshes > 0 { return "Pulling recent windows now" }
        if recentSyncProgress.isRefreshQueued { return "Refresh queued" }
        if recentSyncProgress.totalVisibleChats > 0 && recentSyncProgress.staleVisibleChats == 0 { return "Visible chats are fresh" }
        return "Monitoring visible chats"
    }

    private var indexingWorkerLabel: String {
        if indexingProgress.isPaused { return "Yielding" }
        if indexingProgress.activeWorkers > 0 { return "\(indexingProgress.activeWorkers)" }
        if indexingProgress.pendingChats == 0 && indexingProgress.total > 0 { return "Idle" }
        return "Waiting"
    }

    private var indexingWorkerCaption: String {
        if indexingProgress.isPaused { return "Deep index yields while you actively search" }
        if indexingProgress.activeWorkers > 0 { return "Concurrent deep-index workers live now" }
        if indexingProgress.pendingChats == 0 && indexingProgress.total > 0 { return "No pending loaded chats left" }
        return "Workers are ready for the next backlog pass"
    }

    private var indexingWorkerTint: Color {
        if indexingProgress.isPaused { return PidgyDashboardTheme.yellow }
        if indexingProgress.activeWorkers > 0 { return PidgyDashboardTheme.blue }
        return indexingProgress.pendingChats == 0 ? PidgyDashboardTheme.green : PidgyDashboardTheme.secondary
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
        guard let etaSeconds = deepIndexETASeconds else { return "Estimating" }
        return durationString(etaSeconds)
    }

    private var deepIndexETACaption: String {
        guard indexingProgress.pendingChats > 0 else {
            return "Loaded main-list backlog is covered"
        }
        guard let sessionStartedAt = indexingProgress.sessionStartedAt else {
            return "Waiting for this session to establish a pace"
        }
        let elapsed = Date().timeIntervalSince(sessionStartedAt)
        guard indexingProgress.sessionCompletedChats > 0, elapsed >= 60 else {
            return "Needs more completed-chat data"
        }
        return "Estimated from \(integerString(indexingProgress.sessionCompletedChats)) completed chats"
    }

    private var deepIndexETATint: Color {
        if indexingProgress.pendingChats == 0 { return PidgyDashboardTheme.green }
        if deepIndexETASeconds != nil { return PidgyDashboardTheme.blue }
        return PidgyDashboardTheme.yellow
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
        DateFormatting.compactRelativeTime(from: date)
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "<1m"
        }
        if seconds < 3_600 {
            return "\(Int((seconds / 60).rounded()))m"
        }
        return "\(Int((seconds / 3_600).rounded()))h"
    }

    private func tint(for id: String) -> Color {
        PidgyDashboardTheme.topicTint(Int64(abs(id.hashValue % 997)))
    }
}

private enum DashboardPreferenceStatus: Equatable {
    case success(String)
    case error(String)

    var text: String {
        switch self {
        case .success(let text), .error(let text):
            return text
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return PidgyDashboardTheme.green
        case .error:
            return PidgyDashboardTheme.red
        }
    }
}

private struct DashboardPreferenceStatusItem: Identifiable {
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    let tint: Color

    var id: String { title }
}

private struct DashboardPreferenceControlMosaic: View {
    let page: DashboardPreferencePage
    let primary: DashboardPreferenceStatusItem
    let items: [DashboardPreferenceStatusItem]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DashboardPreferenceFocusCard(page: page, item: primary)
                .frame(minWidth: 360, maxWidth: .infinity)

            VStack(spacing: 10) {
                ForEach(items.filter { $0.id != primary.id }.prefix(3)) { item in
                    DashboardPreferenceMiniStatusCard(item: item)
                }
            }
            .frame(width: 310)
        }
    }
}

private struct DashboardPreferenceFocusCard: View {
    let page: DashboardPreferencePage
    let item: DashboardPreferenceStatusItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.brand)
                    .frame(width: 42, height: 42)
                    .background(PidgyDashboardTheme.brand.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(page.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text(page.subtitle)
                        .font(PidgyDashboardTheme.detailBodyFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                DashboardLiveStatusDot(tint: item.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.uppercased())
                        .font(PidgyDashboardTheme.captionMediumFont)
                        .tracking(0.7)
                        .foregroundStyle(PidgyDashboardTheme.tertiary)
                    Text(item.value)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(1)
                    Text(item.caption)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .background(PidgyDashboardTheme.deep)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .padding(16)
        .frame(minHeight: 156, alignment: .topLeading)
        .background(PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardPreferenceMiniStatusCard: View {
    let item: DashboardPreferenceStatusItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(item.tint)
                .frame(width: 30, height: 30)
                .background(item.tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title.uppercased())
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .tracking(0.6)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                Text(item.value)
                    .font(PidgyDashboardTheme.rowEmphasisFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text(item.caption)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(minHeight: 45)
        .background(PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardLiveStatusDot: View {
    let tint: Color
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 18, height: 18)
                .scaleEffect(isPulsing ? 1.45 : 0.85)
                .opacity(isPulsing ? 0 : 1)
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 22, height: 22)
        .onAppear { isPulsing = true }
        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false), value: isPulsing)
    }
}

private struct DashboardPreferenceSidebarButton: View {
    let page: DashboardPreferencePage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(isSelected ? PidgyDashboardTheme.brand : PidgyDashboardTheme.secondary)
                    .frame(width: 24, height: 24)
                    .background(isSelected ? PidgyDashboardTheme.brand.opacity(0.14) : PidgyDashboardTheme.raised.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.rawValue)
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .lineLimit(1)
                    Text(page.subtitle)
                        .font(PidgyDashboardTheme.captionFont)
                        .foregroundStyle(isSelected ? PidgyDashboardTheme.brand.opacity(0.78) : PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? PidgyDashboardTheme.brand : PidgyDashboardTheme.primary)
            .padding(.horizontal, 9)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? PidgyDashboardTheme.brand.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardPreferencePressStyle())
    }
}

private struct DashboardPreferenceSidebarSummary: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PidgyDashboardTheme.rule)
        )
    }
}

private struct DashboardPreferenceSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var assetImage: String? = nil
    var isDanger = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                sectionIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text(subtitle)
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(16)
        .background(isDanger ? PidgyDashboardTheme.red.opacity(0.075) : PidgyDashboardTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isDanger ? PidgyDashboardTheme.red.opacity(0.24) : PidgyDashboardTheme.rule)
        )
    }

    @ViewBuilder
    private var sectionIcon: some View {
        if let assetImage {
            Image(assetImage)
                .resizable()
                .scaledToFill()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: systemImage)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(isDanger ? PidgyDashboardTheme.red : PidgyDashboardTheme.brand)
                .frame(width: 22, height: 22)
                .background((isDanger ? PidgyDashboardTheme.red : PidgyDashboardTheme.brand).opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct DashboardPreferenceRow<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(subtitle)
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 24)

            trailing
        }
        .frame(minHeight: 46)
        .padding(.vertical, 6)
    }
}

private struct DashboardPreferenceFieldRow: View {
    let title: String
    let subtitle: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        DashboardPreferenceRow(title: title, subtitle: subtitle) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(PidgyDashboardTheme.detailBodyFont)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .padding(.horizontal, 12)
            .frame(width: 340, height: 34)
            .background(PidgyDashboardTheme.deep)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
        }
    }
}

private struct DashboardPreferenceInputBlock: View {
    let title: String
    let subtitle: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(subtitle)
                    .font(PidgyDashboardTheme.captionFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(2)
            }

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(PidgyDashboardTheme.detailBodyFont)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(PidgyDashboardTheme.deep)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PidgyDashboardTheme.rule)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardPreferencePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DashboardPreferenceButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(DashboardCapsuleBackground())
        }
        .buttonStyle(DashboardPreferencePressStyle())
    }
}

private struct DashboardPreferenceDangerButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(PidgyDashboardTheme.red)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(PidgyDashboardTheme.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(PidgyDashboardTheme.red.opacity(0.25))
            )
        }
        .buttonStyle(DashboardPreferencePressStyle())
    }
}

private struct DashboardPreferenceInlineStatus: View {
    let status: DashboardPreferenceStatus

    var body: some View {
        Text(status.text)
            .font(PidgyDashboardTheme.metadataMediumFont)
            .foregroundStyle(status.tint)
            .lineLimit(1)
    }
}

private struct DashboardStatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(PidgyDashboardTheme.metadataMediumFont)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(tint.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.24)))
    }
}

private struct DashboardPreferenceNote: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
            Text(text)
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DashboardPreferenceMetric: View {
    let title: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(PidgyDashboardTheme.captionMediumFont)
                .tracking(0.7)
                .foregroundStyle(PidgyDashboardTheme.tertiary)
            Text(value)
                .font(PidgyDashboardTheme.rowEmphasisFont)
                .foregroundStyle(PidgyDashboardTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(caption)
                .font(PidgyDashboardTheme.metadataFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .padding(12)
        }
    }
}

private struct DashboardPricingBarRow: Identifiable {
    let id: String
    let title: String
    let value: Double
    let requests: Int
    let tint: Color
}

private struct DashboardPricingBarGraph: View {
    let rows: [DashboardPricingBarRow]

    private var maxValue: Double {
        max(rows.map(\.value).max() ?? 0, 0.0001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("30d cost by feature")
                        .font(PidgyDashboardTheme.rowEmphasisFont)
                        .foregroundStyle(PidgyDashboardTheme.primary)
                    Text("Estimated USD from provider-reported usage")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                }

                Spacer()
            }

            if rows.isEmpty {
                DashboardPreferenceNote(
                    title: "No usage yet",
                    text: "Successful AI requests will appear here with provider-reported tokens and estimated cost."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        HStack(spacing: 14) {
                            Text(row.title)
                                .font(PidgyDashboardTheme.metadataMediumFont)
                                .foregroundStyle(PidgyDashboardTheme.primary)
                                .lineLimit(1)
                                .frame(width: 155, alignment: .leading)

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(PidgyDashboardTheme.raised)
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [row.tint.opacity(0.96), row.tint.opacity(0.55)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(6, proxy.size.width * CGFloat(row.value / maxValue)))
                                }
                            }
                            .frame(height: 18)

                            VStack(alignment: .trailing, spacing: 1) {
                                Text(currencyString(row.value))
                                    .font(PidgyDashboardTheme.metadataMediumFont)
                                    .foregroundStyle(PidgyDashboardTheme.primary)
                                    .lineLimit(1)
                                Text("\(row.requests) req")
                                    .font(PidgyDashboardTheme.captionFont)
                                    .foregroundStyle(PidgyDashboardTheme.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 82, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func currencyString(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        formatter.minimumFractionDigits = value < 10 && value > 0 ? 2 : 0
        return formatter.string(from: NSNumber(value: value)) ?? "$0"
    }
}

private struct DashboardPreferenceAboutHero: View {
    var body: some View {
        HStack(spacing: 16) {
            PidgyMascotMark(size: 74)

            VStack(alignment: .leading, spacing: 5) {
                Text(PidgyBranding.appName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PidgyDashboardTheme.primary)
                    .lineLimit(1)
                Text(PidgyBranding.dashboardTagline)
                    .font(PidgyDashboardTheme.detailBodyFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .lineLimit(1)
                Text("Local-first Telegram command center for replies, tasks, people, topics, and search.")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct DashboardPreferenceBreakdownSection: View {
    let title: String
    let rows: [AIUsageBreakdownRow]
    let costLabel: (AIUsageMetrics) -> String
    let integerString: (Int) -> String
    let compactNumberString: (Int) -> String

    var body: some View {
        DashboardPreferenceSection(title: title, subtitle: "Last 30 days", systemImage: "list.bullet.rectangle") {
            if rows.isEmpty {
                Text("No tracked usage in this window.")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                                .foregroundStyle(PidgyDashboardTheme.primary)
                            if let subtitle = row.subtitle {
                                Text(subtitle)
                                    .font(PidgyDashboardTheme.metadataFont)
                                    .foregroundStyle(PidgyDashboardTheme.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(costLabel(row.metrics))
                                .font(PidgyDashboardTheme.metadataMediumFont)
                                .foregroundStyle(PidgyDashboardTheme.primary)
                            Text("\(integerString(row.metrics.requestCount)) req - \(compactNumberString(row.metrics.inputTokens + row.metrics.outputTokens)) tok")
                                .font(PidgyDashboardTheme.captionFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                        }
                    }
                    .padding(.vertical, 8)

                    if row.id != rows.last?.id {
                        Rectangle()
                            .fill(PidgyDashboardTheme.rule)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct DashboardGraphBreakdownSection: View {
    let title: String
    let rows: [GraphBuilder.DebugCountRow]
    let integerString: (Int) -> String

    var body: some View {
        DashboardPreferenceSection(title: title, subtitle: "Current graph store", systemImage: "list.bullet") {
            if rows.isEmpty {
                Text("No rows yet.")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label)
                            .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                            .foregroundStyle(PidgyDashboardTheme.primary)
                        Spacer()
                        Text(integerString(row.count))
                            .font(PidgyDashboardTheme.metadataMediumFont)
                            .foregroundStyle(PidgyDashboardTheme.secondary)
                    }
                    .padding(.vertical, 8)

                    if row.id != rows.last?.id {
                        Rectangle()
                            .fill(PidgyDashboardTheme.rule)
                            .frame(height: 1)
                    }
                }
            }
        }
    }
}

private struct DashboardRoutingDebugCard: View {
    let snapshot: QueryRoutingDebugSnapshot
    let onUseQuery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.query)
                        .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .lineLimit(2)
                    Text("\(snapshot.spec.family.rawValue) -> \(snapshot.runtimeIntent.rawValue)")
                        .font(PidgyDashboardTheme.metadataFont)
                        .foregroundStyle(PidgyDashboardTheme.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Use") {
                    onUseQuery()
                }
                .buttonStyle(.plain)
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.brand)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                routingLine("Engine", snapshot.spec.preferredEngine.rawValue)
                routingLine("Mode", snapshot.spec.mode.rawValue)
                routingLine("Scope", snapshot.spec.scope.rawValue)
                routingLine("Reply", snapshot.spec.replyConstraint.rawValue)
                routingLine("Confidence", String(format: "%.2f", snapshot.spec.parseConfidence))
                if !snapshot.spec.unsupportedFragments.isEmpty {
                    routingLine("Unsupported", snapshot.spec.unsupportedFragments.joined(separator: ", "))
                }
            }
        }
        .padding(12)
        .background(PidgyDashboardTheme.deep)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func routingLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(PidgyDashboardTheme.captionMediumFont)
                .foregroundStyle(PidgyDashboardTheme.tertiary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(PidgyDashboardTheme.captionFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
