import SwiftUI
import UniformTypeIdentifiers

struct DashboardPreferencesPage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var indexingProgress = IndexScheduler.shared.progress
    @StateObject private var recentSyncProgress = RecentSyncCoordinator.shared.progress
    @StateObject private var integrationConnections = IntegrationConnectionStore.shared
    @ObservedObject private var slack = SlackConnectionManager.shared
    @ObservedObject private var gmail = GmailConnectionManager.shared
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false
    @AppStorage(AppConstants.Preferences.showPigeonFlockKey) private var showPigeonFlock = true
    @AppStorage(AppConstants.Preferences.contextLayerEnabledKey) private var contextLayerEnabled = true
    // Opt-in (matches PidgyTelemetry.sanctionedUser's default): identity
    // only rides crash reports when the user turned this on themselves.
    @AppStorage(AppConstants.Preferences.diagnosticsIdentityEnabledKey) private var diagnosticsIdentityEnabled = false
    @AppStorage(AppConstants.Preferences.chatOpenTargetKey)
    private var chatOpenTargetRaw: String = ChatOpenTarget.detectedDefault().rawValue

    let onBackToDashboard: () -> Void
    let onRefreshDashboard: () -> Void
    let onRefreshUsage: () -> Void

    @State private var selectedPage: DashboardPreferencePage = .account
    @ObservedObject private var inviteService = InviteService.shared
    @State private var grandfatherCode = ""
    @State private var grandfatherError: String?
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var telegramStatus: DashboardPreferenceStatus?
    @State private var whatsAppOwnerName = ""
    @State private var showWhatsAppImporter = false
    @State private var selectedAIProvider: AIProviderConfig.ProviderType = .none
    @State private var selectedBYOKProvider: BYOKProvider = .openAI
    @State private var aiApiKey = ""
    @State private var aiModel = ""
    @State private var aiBaseURL = ""
    @State private var aiStatus: DashboardPreferenceStatus?
    @State private var isTestingConnection = false
    @State private var testConnectionStatus: DashboardPreferenceStatus?
    @State private var usageOverview: AIUsageOverview = .empty
    /// Live counts for the Memory page headline (facts / open loops / chats
    /// read). Loaded when the page opens; nil until then so tiles render 0
    /// rather than stale numbers.
    @State private var memoryStats: (total: Int, openLoops: Int, resolved: Int, chats: Int)?
    @State private var memoryLastPassAt: Date?
    @State private var isLoadingUsage = false
    @State private var dailyRangeDays = 14
    @State private var hoveredDay: Date?
    @State private var graphDebugSummary: GraphBuilder.DebugSummary = .empty
    @State private var isLoadingDiagnostics = false
    @State private var routingDebugQuery = "who do I need to reply to"
    @State private var routingSnapshots: [QueryRoutingDebugSnapshot] = []
    @State private var isLoadingRoutingDebug = false
    @State private var showDeleteConfirmation = false
    @State private var isResetting = false
    @StateObject private var archivedChatsStore = ArchivedChatsStore.shared
    @ObservedObject private var entitlements = EntitlementStore.shared
    @State private var licenseKeyInput = ""
    @State private var isActivatingLicense = false
    @State private var licenseError: String?
    /// Resolved chats for the archived-chats list, keyed by chat id.
    /// Stores the full TGChat (not just the title) so each row can
    /// render the chat's avatar + DM/group shape. Populated on
    /// appear / when the set changes.
    @State private var archivedChats: [Int64: TGChat] = [:]
    // Voice profile (context layer) — editable in the Preferences page.
    @State private var voiceProfileText = ""
    @State private var voiceProfileLoaded = false
    @State private var isRegeneratingVoice = false
    @State private var voiceStatus: DashboardPreferenceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back-to-Dashboard pill chip in the top-left corner.
            HStack {
                Button(action: onBackToDashboard) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("Dashboard")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Color.Pidgy.fg2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule().stroke(Color.Pidgy.border2)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 12)

            HStack(spacing: 0) {
                preferencesRail

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        selectedPreferencePage
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(.horizontal, 64)
                    .padding(.top, 32)
                    .padding(.bottom, 80)
                }
                .id(selectedPage)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
            .animation(PidgyMotion.easeOut, value: selectedPage)
        }
        .background(Color.Pidgy.bg0)
        .onAppear {
            loadCredentials()
            loadAIConfig()
        }
        .task {
            await integrationConnections.load()
        }
        .task(id: selectedPage) {
            await refreshDataIfNeeded(for: selectedPage)
        }
        .onChange(of: selectedBYOKProvider) { oldValue, newValue in
            guard oldValue != newValue else { return }
            selectedAIProvider = newValue.providerType
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
        .alert("Reset all local data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await deleteAllData() }
            }
        } message: {
            Text("This clears TDLib data, cached messages, AI usage, credentials, and your Telegram session. You'll be taken back to the welcome screen and can sign in again.")
        }
        .fileImporter(
            isPresented: $showWhatsAppImporter,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                let owner = whatsAppOwnerName.trimmingCharacters(in: .whitespacesAndNewlines)
                await integrationConnections.importWhatsApp(
                    url: url,
                    ownerName: owner.isEmpty ? nil : owner
                )
            }
        }
    }

    private var preferencesTopBar: some View {
        HStack(spacing: 14) {
            Button(action: onBackToDashboard) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Dashboard")
                }
                .font(PidgyDashboardTheme.metadataMediumFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if showsRefreshControl {
                Button(action: refreshCurrentPreferencePage) {
                    HStack(spacing: 6) {
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
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
        .background(PidgyDashboardTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(height: 1)
        }
    }

    /// Refresh only appears where the page has something live to re-pull —
    /// usage and cost, sync coverage, the graph inspector, and About (which
    /// now carries invite codes). Account and Memory are settings you set,
    /// not readings you refresh.
    private var showsRefreshControl: Bool {
        switch selectedPage {
        case .plan, .data, .diagnostics, .about:
            return true
        case .account, .memory:
            return false
        }
    }

    private var preferencesRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visiblePreferencePages) { page in
                PrefRailRow(
                    page: page,
                    isSelected: selectedPage == page
                ) {
                    selectedPage = page
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 24)
        .frame(width: 220, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// The rail. `visibleCases` already drops Diagnostics outside DEBUG; the
    /// page still renders if `selectedPage` somehow lands there, it just
    /// isn't reachable by clicking.
    ///
    /// Invites is no longer its own page — it lives inside About, so a build
    /// that can't reach the invite server simply omits that section rather
    /// than a whole nav entry.
    private var visiblePreferencePages: [DashboardPreferencePage] {
        DashboardPreferencePage.visibleCases
    }

    /// Invites only render on builds that can reach the invite server (a
    /// bundled proxy), or on an install already registered with one.
    private var showsInviteSection: Bool {
        InviteService.gateRequired || inviteService.isRegistered
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
        case .plan:
            return preferenceStatusItems[1]
        case .memory:
            // The kill switch, not the animation toggle. The old Preferences
            // page led with "Pigeon flock" — a cosmetic setting as the
            // headline for the page that also holds whether Pidgy builds a
            // memory of your chats at all.
            return DashboardPreferenceStatusItem(
                title: "Memory engine",
                value: contextLayerEnabled ? "On" : "Off",
                caption: contextLayerEnabled
                    ? "Reading chats into tasks, replies, and answers"
                    : "Frozen — existing memory kept, nothing new extracted",
                systemImage: "brain",
                tint: contextLayerEnabled ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
            )
        case .data:
            return preferenceStatusItems[3]
        case .diagnostics:
            return DashboardPreferenceStatusItem(
                title: "Graph",
                value: graphDebugSummary.isComplete ? "Complete" : "Building",
                caption: graphDebugSummary.isComplete ? "\(integerString(graphDebugSummary.nodeCounts.reduce(0) { $0 + $1.count })) nodes" : "Open Diagnostics to load",
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: graphDebugSummary.isComplete ? PidgyDashboardTheme.green : PidgyDashboardTheme.yellow
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
        case .plan:
            planPage
        case .memory:
            memoryPage
        case .data:
            dataPage
        case .about:
            aboutPage
        case .diagnostics:
            diagnosticsPage
        }
    }

    /// Plan, provider, and cost — everything about what you're paying for and
    /// what the AI is spending. Was "AI & Plan" plus the cost/usage sections
    /// that had drifted into the old Preferences bucket.
    @ViewBuilder
    private var planPage: some View {
        aiPage
    }

    /// What Pidgy reads, remembers, and sends to a model.
    ///
    /// This is the page the old structure never had, and the reason the
    /// rethink was worth doing: the memory kill switch, the bots toggle, the
    /// "what AI sees" disclosure, archived chats, and voice style were spread
    /// across three pages even though they answer one question. A user
    /// deciding how much of their Telegram to hand over should not have to
    /// find that answer in four places.
    @ViewBuilder
    private var memoryPage: some View {
        preferencesPage
    }

    /// Freshness, coverage, and starting over — the old Indexing and Reset
    /// pages. "Is my data current" and "wipe it and re-pull" are the same
    /// concern from opposite ends, and splitting them meant the reset button
    /// lived nowhere near the state it resets.
    @ViewBuilder
    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            // The first crawl is the one time this page is opened in
            // confusion rather than curiosity — surfaces look empty and the
            // user wants to know why. Say so here, plainly, while it runs.
            if FactExtractionCoordinator.shared.isCrawling {
                HStack(alignment: .center, spacing: 12) {
                    PidgyLoader(size: 17)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reading your chats")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.Pidgy.fg1)
                        Text("Tasks and replies fill in as each chat is read — a first full read takes a few minutes.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Pidgy.fg3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.Pidgy.border1)
                        )
                )
            }
            indexingPage
            resetPage
        }
    }

    /// Invite codes + referral standing. Registered installs see their
    /// codes (click-to-copy) and referral count; a pre-invite-era install
    /// ("grandfathered") can redeem a code here post-onboarding to join
    /// the referral program — same server flow as the onboarding gate.
    private var invitesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(topPadding: 0) {
                PrefSectionHead(
                    title: "Invites",
                    subtitle: "Pidgy grows one friend at a time — each code lets one person in"
                ) {
                    if inviteService.isRegistered {
                        PrefPill(
                            text: "\(inviteService.referrals) joined",
                            tone: inviteService.referrals > 0 ? .green : .mono
                        )
                    }
                }

                if inviteService.isRegistered {
                    if inviteService.codes.isEmpty {
                        Text("Fetching your codes…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.Pidgy.fg3)
                    } else {
                        // Flow the chips in rows of 3 — bonus codes from
                        // referrals grow this list past the initial 3.
                        let rows = inviteService.codes.chunked(into: 3)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                HStack(spacing: 8) {
                                    ForEach(row) { code in
                                        InviteCodeChip(code: code)
                                    }
                                }
                            }
                        }
                        Text("Every friend who joins earns you 2 more codes — and free Pro time when plans launch.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Pidgy.fg4)
                            .padding(.top, 12)
                    }
                } else {
                    PrefField(
                        label: "Join the referral program",
                        hint: "You onboarded before invites existed — redeem any invite code once to get your own 3 codes to share.",
                        content: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    PrefMinInput(
                                        text: $grandfatherCode,
                                        placeholder: "PIDGY-ABC123",
                                        monospaced: true
                                    )
                                    .frame(maxWidth: 180)
                                    Button(inviteService.isRedeeming ? "Checking…" : "Redeem") {
                                        redeemGrandfatherCode()
                                    }
                                    .buttonStyle(.pidgyPress)
                                    .disabled(
                                        grandfatherCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            || inviteService.isRedeeming
                                    )
                                }
                                if let grandfatherError {
                                    Text(grandfatherError)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.Pidgy.danger)
                                }
                            }
                        }
                    )
                }
            }
        }
    }

    private func redeemGrandfatherCode() {
        let candidate = grandfatherCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        grandfatherError = nil
        Task { @MainActor in
            do {
                try await InviteService.shared.redeem(code: candidate)
                grandfatherCode = ""
            } catch let error as InviteService.RedeemError {
                grandfatherError = error.errorDescription
            } catch {
                grandfatherError = InviteService.RedeemError.network.errorDescription
            }
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(topPadding: 0) {
                PrefSectionHead(
                    title: "Message sources",
                    subtitle: "One memory and workflow layer — source apps stay the system of record"
                ) {
                    PrefPill(
                        text: "\(connectedIntegrationCount) active",
                        tone: connectedIntegrationCount > 0 ? .green : .mono
                    )
                }

                Text("Gmail and Slack start read-only. Pidgy stores normalized copies locally and opens the original app for actions; it does not send messages from these connections.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Pidgy.fg3)
                    .lineSpacing(3)

                gmailConnectionRow

                slackConnectionRow

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        integrationIcon(.whatsapp)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("WhatsApp export")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.Pidgy.fg1)
                            Text("Manual chat exports only — no personal-account automation")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.Pidgy.fg3)
                        }
                        Spacer()
                        if integrationAccount(for: .whatsapp) != nil {
                            PrefPill(text: "Imported", tone: .green)
                        }
                    }

                    HStack(spacing: 10) {
                        PrefMinInput(
                            text: $whatsAppOwnerName,
                            placeholder: "Your display name in the export"
                        )
                        PrefGhostButton(title: "Import .txt", systemImage: "square.and.arrow.down") {
                            showWhatsAppImporter = true
                        }
                        .disabled(integrationConnections.activity[.whatsapp] == .syncing)
                    }
                    if let status = integrationConnections.statusMessage[.whatsapp] {
                        integrationStatusText(status)
                    }
                }
                .padding(.top, 18)
            }

            PrefSection(topPadding: 0) {
                PrefSectionHead(
                    title: "Telegram",
                    subtitle: "Connection and local account"
                ) {
                    PrefPill(text: authStateDescription, tone: telegramService.authState == .ready ? .green : .amber)
                }

                if let user = telegramService.currentUser {
                    PrefField(
                        label: "Account",
                        hint: user.displayName,
                        right: {
                            PrefGhostButton(title: "Log out", systemImage: "rectangle.portrait.and.arrow.right", tone: .danger) {
                                NotificationCenter.default.post(name: .pidgyLogOut, object: nil)
                            }
                        }
                    )
                }

                PrefField(label: "API ID", hint: "Your Telegram developer app ID") {
                    PrefMinInput(text: $apiId, placeholder: "123456", monospaced: true)
                }

                PrefField(label: "API Hash", hint: "Stored locally through the credential manager") {
                    PrefMinInput(text: $apiHash, placeholder: "Telegram API hash", isSecure: true, monospaced: true)
                }

                PrefField(
                    label: "Credentials",
                    hint: "Save locally and start Telegram if possible",
                    right: {
                        HStack(spacing: 10) {
                            if let telegramStatus {
                                DashboardPreferenceInlineStatus(status: telegramStatus)
                            }
                            PrefGhostButton(title: "Save", systemImage: "checkmark", action: saveCredentials)
                        }
                    }
                )

                Link(destination: URL(string: "https://my.telegram.org")!) {
                    Text("Get credentials from my.telegram.org →")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Pidgy.accentFg)
                }
                .padding(.top, 8)
            }

            PrefSection(bottomBorder: false) {
                PrefSectionHead(title: "Account health", subtitle: "What the rest of the app can see")
                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Visible chats",
                        value: integerString(telegramService.visibleChats.count),
                        hint: "Loaded in the current session",
                        dot: .blue
                    )
                    PrefStatTile(
                        eyebrow: "Sync state",
                        value: recentSyncStatusLabel,
                        hint: recentSyncStatusCaption,
                        dot: recentSyncProgress.activeRefreshes > 0 ? .blue : .green
                    )
                    PrefStatTile(
                        eyebrow: "Last refresh",
                        value: recentSyncProgress.lastSyncAt.map(relativeTimeString) ?? "—",
                        hint: "Most recently refreshed visible chat",
                        dot: .green
                    )
                }
            }
        }
    }

    private var connectedIntegrationCount: Int {
        var sources = integrationConnections.connectedSources
        if gmailIsConnected { sources.insert(.gmail) }
        if case .connected = slack.state { sources.insert(.slack) }
        if telegramService.authState == .ready { sources.insert(.telegram) }
        return sources.count
    }

    private var gmailConnectionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                integrationIcon(.gmail)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gmail")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Text(gmailStatusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .lineLimit(2)
                }
                Spacer()
                PrefPill(text: gmailIsConnected ? "Connected" : "Not connected", tone: gmailIsConnected ? .green : .mono)
            }
            HStack(spacing: 10) {
                switch gmail.state {
                case .connecting, .syncing(_):
                    ProgressView().controlSize(.small)
                case .connected(_):
                    PrefGhostButton(title: "Read now", systemImage: "arrow.clockwise") { Task { await gmail.sync() } }
                    PrefGhostButton(title: "Remove", systemImage: "xmark", tone: .danger) { gmail.disconnect() }
                case .disconnected, .failed, .unavailable:
                    PrefGhostButton(title: "Connect Gmail", systemImage: "link") {
                        Task { await gmail.connect() }
                    }
                    .disabled(gmail.state == .unavailable)
                }
            }
        }
        .padding(.top, 18)
    }

    private var gmailIsConnected: Bool {
        switch gmail.state {
        case .connected, .syncing: return true
        default: return false
        }
    }

    private var gmailStatusText: String {
        switch gmail.state {
        case .unavailable: return "Gmail isn't configured in this build yet"
        case .disconnected: return "Threads and senders via read-only Google OAuth"
        case .connecting: return "Finish signing in in your browser…"
        case .connected(let detail), .syncing(let detail), .failed(let detail): return detail
        }
    }

    private var slackConnectionRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                integrationIcon(.slack)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Slack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Text(slackStatusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .lineLimit(2)
                }
                Spacer()
                PrefPill(text: slackIsConnected ? "Connected" : "Not connected", tone: slackIsConnected ? .green : .mono)
            }

            HStack(spacing: 10) {
                if slack.state == .connecting {
                    ProgressView().controlSize(.small)
                } else if slackIsConnected {
                    PrefGhostButton(title: "Remove", systemImage: "xmark", tone: .danger) { slack.disconnect() }
                } else if slack.state != .unavailable {
                    PrefGhostButton(title: "Connect Slack", systemImage: "link") {
                        Task { await slack.connect() }
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    private var slackIsConnected: Bool {
        if case .connected = slack.state { return true }
        return false
    }

    private var slackStatusText: String {
        switch slack.state {
        case .unavailable: return "Slack OAuth is not configured in this build"
        case .disconnected: return "Channels, DMs, and threads via read-only OAuth"
        case .connecting: return "Finish signing in in your browser…"
        case .connected(let workspace): return workspace
        case .failed(let message): return message
        }
    }

    private func integrationAccount(for source: IntegrationSource) -> SourceAccount? {
        integrationConnections.accounts.first { $0.source == source }
    }

    @ViewBuilder
    private func integrationSourceRow(
        source: IntegrationSource,
        subtitle: String,
        credential: Binding<String>,
        placeholder: String,
        connect: @escaping () -> Void
    ) -> some View {
        let account = integrationAccount(for: source)
        let activity = integrationConnections.activity[source] ?? .idle
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                integrationIcon(source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    Text(account?.displayName ?? subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .lineLimit(1)
                }
                Spacer()
                PrefPill(
                    text: account != nil || integrationConnections.hasCredential(for: source) ? "Connected" : "Not connected",
                    tone: account != nil || integrationConnections.hasCredential(for: source) ? .green : .mono
                )
            }

            HStack(spacing: 10) {
                PrefMinInput(text: credential, placeholder: placeholder, isSecure: true, monospaced: true)
                PrefGhostButton(
                    title: activity == .connecting ? "Checking…" : "Connect",
                    systemImage: "link",
                    action: connect
                )
                .disabled(activity != .idle || credential.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                PrefGhostButton(
                    title: activity == .syncing ? "Reading…" : "Read now",
                    systemImage: "arrow.clockwise"
                ) {
                    Task { await integrationConnections.sync(source: source) }
                }
                .disabled(activity != .idle || !integrationConnections.hasCredential(for: source))
                if integrationConnections.hasCredential(for: source) {
                    PrefGhostButton(title: "Remove", systemImage: "xmark", tone: .danger) {
                        integrationConnections.disconnect(source: source)
                    }
                    .help("Remove the credential; already imported local data remains")
                }
            }

            if let status = integrationConnections.statusMessage[source] {
                integrationStatusText(status)
            }
        }
        .padding(.top, 18)
    }

    private func integrationIcon(_ source: IntegrationSource) -> some View {
        Image(systemName: source.systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.Pidgy.fg2)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.Pidgy.bg2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.Pidgy.border1)
                    )
            )
    }

    private func integrationStatusText(_ status: String) -> some View {
        Text(status)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.Pidgy.fg3)
            .lineLimit(2)
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if BillingGate.showBillingUI {
                planSection
                // The provider/key block only matters on BYOK; on the
                // managed (Pidgy AI) plan there's nothing to configure.
                if entitlements.selectedPlan == .byok {
                    aiProviderSection
                } else {
                    managedAINote
                }
            } else {
                // Pre-cutover: no plan/billing UI yet. AI runs on the bundled
                // key/proxy by default, and anyone who wants their own key still
                // configures it right here — exactly the 1.0.14 behaviour.
                aiProviderSection
            }
            usageSection
        }
    }

    private var managedAINote: some View {
        PrefSection {
            PrefSectionHead(
                title: "AI provider",
                subtitle: "How AI features are powered"
            )
            PrefField(
                label: "Managed by Pidgy",
                hint: "On the Pidgy AI plan we run the model for you — nothing to set up. Switch to Bring your own key under Your plan to use your own provider."
            )
        }
    }

    private var aiProviderSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection {
                PrefSectionHead(
                    title: "Provider",
                    subtitle: "Your key, used for reply queue, tasks, summaries, and semantic search"
                ) {
                    Picker("", selection: $selectedBYOKProvider) {
                        ForEach(BYOKProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                PrefField(label: "API key", hint: "Stored in Keychain — goes straight to \(selectedBYOKProvider.displayName), never through Pidgy") {
                    PrefMinInput(text: $aiApiKey, placeholder: "\(selectedBYOKProvider.displayName) API key", isSecure: true, monospaced: true)
                }
                if selectedBYOKProvider.requiresCustomBaseURL {
                    PrefField(label: "Base URL", hint: "OpenAI-compatible chat-completions endpoint") {
                        PrefMinInput(text: $aiBaseURL, placeholder: "https://host/v1/chat/completions", monospaced: true)
                    }
                }
                PrefField(label: "Model", hint: selectedBYOKProvider.defaultModel.isEmpty ? "Enter the model id" : "Default: \(selectedBYOKProvider.defaultModel)") {
                    PrefMinInput(text: $aiModel, placeholder: selectedBYOKProvider.defaultModel.isEmpty ? "model id" : selectedBYOKProvider.defaultModel, monospaced: true)
                }

                PrefField(
                    label: "Provider config",
                    hint: "Save before testing a connection",
                    right: {
                        HStack(spacing: 10) {
                            if let aiStatus {
                                DashboardPreferenceInlineStatus(status: aiStatus)
                            }
                            PrefGhostButton(title: "Save", systemImage: "checkmark", action: saveAIConfig)
                        }
                    }
                )

                PrefField(
                    label: "Connection test",
                    hint: "Sends a tiny provider health check",
                    right: {
                        HStack(spacing: 10) {
                            if isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let testConnectionStatus {
                                DashboardPreferenceInlineStatus(status: testConnectionStatus)
                            }
                            PrefGhostButton(title: "Test", systemImage: "bolt") {
                                Task { await testConnection() }
                            }
                            .disabled(isTestingConnection || aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                )
            }

        }
    }

    /// "Preferences" page — collects the small toggleable bits of
    /// Pidgy that don't fit cleanly under Account / AI / etc:
    ///
    /// 1. **Pigeons** — the decorative animated flock on the home
    ///    dashboard's "What to do now" squiggle.
    /// 2. **Include bot chats** — moved here from the AI page's
    ///    Privacy section. Bot chats are mostly a noise-suppression
    ///    surface choice, so it groups well with the pigeon toggle
    ///    under "tweaks the user opts into."
    ///
    /// The "What AI sees" disclosure travels with the bot-chats
    /// toggle since the two are related (toggling bots changes what
    /// goes to AI, the disclosure explains what AI receives in
    /// general).
    /// "Last read 4m ago" for the Chats-read tile — the freshness half of
    /// the headline. Says "not started yet" instead of a dash on a fresh
    /// install, because an empty memory with no explanation reads as broken.
    private var memoryLastReadLabel: String {
        if let at = memoryLastPassAt {
            return "Last read \(relativeTimeString(at))"
        }
        return FactExtractionCoordinator.shared.isCrawling
            ? "First read in progress…"
            : "Not started yet"
    }

    /// The Memory page. Order is deliberate: the page leads with what the
    /// memory IS — live counts of what Pidgy has read and remembered, with
    /// the kill switch beside them — because "what does this app know about
    /// me" is the question that brings a user here. Controls that shape the
    /// memory (bots, privacy disclosure) follow; cosmetics come last. The
    /// old page led with the pigeon-animation toggle.
    private var preferencesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection {
                PrefSectionHead(
                    title: "Memory",
                    subtitle: "What Pidgy has read and remembered from your chats"
                )
                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Facts",
                        value: integerString(memoryStats?.total ?? 0),
                        hint: "Commitments, asks, and durable notes",
                        dot: .blue
                    )
                    PrefStatTile(
                        eyebrow: "Open loops",
                        value: integerString(memoryStats?.openLoops ?? 0),
                        hint: "Feed the Reply queue and Tasks",
                        dot: .amber
                    )
                    PrefStatTile(
                        eyebrow: "Chats read",
                        value: integerString(memoryStats?.chats ?? 0),
                        hint: memoryLastReadLabel,
                        dot: .green
                    )
                }
                PrefField(
                    label: "Memory engine (beta)",
                    hint: "Turn off to pause reading (no AI usage). Tasks, the Reply queue, and Ask Pidgy freeze at their last-known state. Takes effect after you quit and reopen Pidgy.",
                    right: {
                        PrefToggle(isOn: $contextLayerEnabled)
                    }
                )
            }

            PrefSection {
                PrefSectionHead(title: "Privacy", subtitle: "What leaves this Mac, and what never does")
                PrefField(
                    label: "Include bot chats",
                    hint: "Off keeps bots out of memory entirely — their stored facts are removed and no AI is spent reading them. Turning on takes effect on the next read, not instantly.",
                    right: {
                        PrefToggle(isOn: $includeBotsInAISearch)
                    }
                )
                PrefField(
                    label: "Identify my crash reports",
                    hint: "Attach your Telegram @username to diagnostics so we can reach out when something breaks on your machine. Off = reports stay anonymous.",
                    right: {
                        PrefToggle(isOn: $diagnosticsIdentityEnabled)
                    }
                )

                // The disclosure that earns the page its trust: a checklist,
                // not a paragraph — sent vs never-sent should be scannable.
                HStack(alignment: .top, spacing: 12) {
                    Capsule()
                        .fill(Color.Pidgy.accentFg.opacity(0.50))
                        .frame(width: 4)
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sent to your AI provider")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.Pidgy.fg1)
                            ForEach(["Message text", "Sender first names", "Relative timestamps", "Chat names + numeric ids"], id: \.self) { item in
                                Text("✓ " + item)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.Pidgy.fg3)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Never sent")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Color.Pidgy.fg1)
                            ForEach(["Phone numbers", "User ids + session tokens", "Media, stickers, voice"], id: \.self) { item in
                                Text("✗ " + item)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.Pidgy.fg3)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.Pidgy.border1)
                        )
                )
                .padding(.top, 14)
            }

            PrefSection {
                PrefSectionHead(
                    title: "Quirks",
                    subtitle: "Little bits of Pidgy you can turn on or off"
                )
                PrefField(
                    label: "Open chats in",
                    hint: "Where \"Open in chat\" takes you. Telegram Web works even without the Telegram app installed.",
                    right: {
                        PrefOptionMenu(
                            options: [(0, "Telegram Desktop"), (1, "Telegram Web")],
                            selection: Binding(
                                get: { chatOpenTargetRaw == ChatOpenTarget.web.rawValue ? 1 : 0 },
                                set: { chatOpenTargetRaw = ($0 == 1 ? ChatOpenTarget.web : ChatOpenTarget.desktop).rawValue }
                            )
                        )
                    }
                )
                PrefField(
                    label: "Pigeons on the squiggle",
                    hint: "Show the animated flock under the page title. Drag the line to bounce them; click any to shoo.",
                    right: {
                        PrefToggle(isOn: $showPigeonFlock)
                    }
                )
            }

            voiceSection

            // Archived chats live at the very bottom — it's a
            // management list the user only visits occasionally, not
            // a daily setting.
            archivedChatsSection
        }
    }

    /// "Your voice" — the context layer's writing-style profile. Pidgy
    /// builds it from the user's own sent messages and injects it into
    /// reply drafts so suggestions sound like them. Shown here so the
    /// user can read exactly what's stored (style only, no private
    /// content), hand-edit it, regenerate it, or open the underlying
    /// markdown file.
    @ViewBuilder
    private var voiceSection: some View {
        PrefSection(bottomBorder: !archivedChatsStore.ids.isEmpty) {
            PrefSectionHead(
                title: "Your voice",
                subtitle: "Drafts are written in your style. Built from your sent messages — edit freely."
            ) {
                PrefPill(
                    text: voiceProfileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not built" : "Active",
                    tone: voiceProfileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .mono : .green
                )
            }

            TextEditor(text: $voiceProfileText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.Pidgy.fg2)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160, maxHeight: 320)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg2)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.Pidgy.border1))
                )
                .overlay(alignment: .topLeading) {
                    if voiceProfileText.isEmpty {
                        Text(aiService.isConfigured
                             ? "Not built yet — send a few messages, then hit Regenerate."
                             : "Configure an AI provider to build your voice profile.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Pidgy.fg4)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 20)
                            .allowsHitTesting(false)
                    }
                }

            Text("Style only — tone, length, and language. No private message content is stored here.")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Pidgy.fg3)
                .padding(.top, 8)

            HStack(spacing: 10) {
                if isRegeneratingVoice {
                    ProgressView().controlSize(.small)
                }
                if let voiceStatus {
                    DashboardPreferenceInlineStatus(status: voiceStatus)
                }
                Spacer()
                PrefGhostButton(title: "Reveal file", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([VoiceProfileService.shared.profileFileURL])
                }
                PrefGhostButton(title: isRegeneratingVoice ? "Regenerating…" : "Regenerate", systemImage: "sparkles") {
                    regenerateVoiceProfile()
                }
                .disabled(isRegeneratingVoice || !aiService.isConfigured)
                PrefGhostButton(title: "Save", systemImage: "checkmark") {
                    saveVoiceProfile()
                }
                .disabled(isRegeneratingVoice)
            }
            .padding(.top, 14)
        }
        .task { await loadVoiceProfileIfNeeded() }
    }

    private func loadVoiceProfileIfNeeded() async {
        guard !voiceProfileLoaded else { return }
        voiceProfileText = await VoiceProfileService.shared.currentProfile() ?? ""
        voiceProfileLoaded = true
    }

    private func saveVoiceProfile() {
        let text = voiceProfileText
        voiceStatus = nil
        Task {
            await VoiceProfileService.shared.saveProfile(text)
            voiceStatus = .success("Saved")
        }
    }

    private func regenerateVoiceProfile() {
        guard !isRegeneratingVoice, aiService.isConfigured else { return }
        isRegeneratingVoice = true
        voiceStatus = nil
        let service = aiService
        Task {
            await VoiceProfileService.shared.generate(aiService: service)
            voiceProfileText = await VoiceProfileService.shared.currentProfile() ?? voiceProfileText
            isRegeneratingVoice = false
            voiceStatus = voiceProfileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .error("Not enough sent messages yet")
                : .success("Updated")
        }
    }

    /// Archived chats — chats the user removed from every pipeline
    /// (reply queue + tasks) via the row's "Archive chat" action.
    /// Lists them with an Unarchive button. Hidden entirely when
    /// nothing is archived so the section doesn't add noise.
    @ViewBuilder
    private var archivedChatsSection: some View {
        let archivedIds = Array(archivedChatsStore.ids).sorted()
        if !archivedIds.isEmpty {
            PrefSection(bottomBorder: false) {
                PrefSectionHead(
                    title: "Archived chats",
                    subtitle: "Removed from the reply queue and tasks. Unarchive to bring them back."
                ) {
                    PrefPill(text: "\(archivedIds.count)", tone: .mono)
                }

                VStack(spacing: 0) {
                    ForEach(archivedIds, id: \.self) { chatId in
                        HStack(spacing: 11) {
                            DashboardTelegramAvatar(
                                chat: archivedChats[chatId],
                                fallbackTitle: archivedChats[chatId]?.title ?? "Chat",
                                size: 30
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(archivedChats[chatId]?.title ?? "Chat \(chatId)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.Pidgy.fg1)
                                    .lineLimit(1)
                                Text(archivedChatKindLabel(for: chatId))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.Pidgy.fg3)
                            }
                            Spacer(minLength: 12)
                            PrefGhostButton(title: "Unarchive", systemImage: "tray.and.arrow.up") {
                                archivedChatsStore.unarchive(chatId)
                                // Bring the chat back into the
                                // pipelines on the next refresh.
                                onRefreshDashboard()
                            }
                        }
                        .padding(.vertical, 8)
                        if chatId != archivedIds.last {
                            Divider().overlay(Color.Pidgy.border1)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .task(id: archivedChatsStore.ids) {
                await resolveArchivedChats()
            }
        }
    }

    private func archivedChatKindLabel(for chatId: Int64) -> String {
        guard let chat = archivedChats[chatId] else { return "" }
        return chat.chatType.isOneOnOne ? "Direct message" : "Group"
    }

    private func resolveArchivedChats() async {
        for chatId in archivedChatsStore.ids where archivedChats[chatId] == nil {
            if let chat = try? await telegramService.getChat(id: chatId) {
                archivedChats[chatId] = chat
            }
        }
    }

    private var planStatusLine: (title: String, detail: String) {
        switch entitlements.status {
        case .none:
            return ("No plan yet", "Pick a plan to start your free trial.")
        case let .trial(daysLeft, plan):
            let unit = daysLeft == 1 ? "day" : "days"
            return ("Free trial · \(plan.title)", "\(daysLeft) \(unit) left, then $\(plan.monthlyPriceUSD)/mo.")
        case let .active(plan):
            return ("\(plan.title) · active", "$\(plan.monthlyPriceUSD)/mo subscription.")
        case let .expired(plan):
            return ("Trial ended", "Subscribe to \(plan.title) ($\(plan.monthlyPriceUSD)/mo) to keep AI features.")
        }
    }

    private var planSection: some View {
        PrefSection(topPadding: 0) {
            PrefSectionHead(
                title: "Your plan",
                subtitle: "Subscription, trial, and how AI is powered"
            )

            PrefField(label: planStatusLine.title, hint: planStatusLine.detail) {
                planActionButton
            }

            // Plan (BYOK vs Pidgy AI) is determined by the subscription — NOT a
            // local toggle, which would desync from what Dodo actually bills.
            // Shown read-only here; changing it goes through Manage subscription.
            PrefField(
                label: "Plan",
                hint: planChangeHint
            ) {
                if let plan = entitlements.selectedPlan {
                    Text("\(plan.title) · $\(plan.monthlyPriceUSD)/mo")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.Pidgy.fg2)
                } else {
                    // First-time pick for an existing user who never chose one.
                    // Not a toggle: it disappears once a plan is set, and after
                    // that, switching only happens through Manage subscription.
                    HStack(spacing: 8) {
                        ForEach(PidgyPlan.allCases) { plan in
                            Button {
                                entitlements.startTrial(plan: plan)
                            } label: {
                                Text("\(plan.title) · $\(plan.monthlyPriceUSD)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.Pidgy.fg2)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().stroke(Color.Pidgy.border2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            licenseRow
        }
    }

    private var planChangeHint: String {
        switch entitlements.status {
        case .none:
            return "Choose a plan to start your free trial."
        case .active:
            return "\(entitlements.selectedPlan?.tagline ?? ""). To switch, use Manage subscription above."
        default:
            return entitlements.selectedPlan?.tagline ?? "Chosen when you set up Pidgy."
        }
    }

    /// One contextual billing action — never a plan toggle. Trial/expired →
    /// subscribe via Dodo checkout; active → manage (upgrade/downgrade/cancel)
    /// via the Dodo customer portal.
    @ViewBuilder
    private var planActionButton: some View {
        switch entitlements.status {
        case .active:
            if let url = entitlements.manageSubscriptionURL {
                PrefGhostButton(title: "Manage subscription", systemImage: "creditcard") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                Text("Manage from your Dodo email")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
        case .trial, .expired:
            if let plan = entitlements.selectedPlan, let url = entitlements.checkoutURL(for: plan) {
                PrefGhostButton(title: "Subscribe", systemImage: "creditcard") {
                    NSWorkspace.shared.open(url)
                }
            } else {
                Text("Payments coming soon")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Pidgy.fg4)
            }
        case .none:
            Text("Choose a plan during setup")
                .font(.system(size: 11))
                .foregroundStyle(Color.Pidgy.fg4)
        }
    }

    @ViewBuilder
    private var licenseRow: some View {
        if case .active = entitlements.status, entitlements.hasLicenseKey {
            PrefField(
                label: "License",
                hint: "This device is activated. Deactivate to free the slot for another Mac."
            ) {
                PrefGhostButton(title: "Deactivate", systemImage: "minus.circle") {
                    Task { await entitlements.removeLicense() }
                }
            }
        } else {
            PrefField(
                label: "Have a license key?",
                hint: licenseError ?? "Paste the key Dodo emailed after you subscribed."
            ) {
                HStack(spacing: 8) {
                    PrefMinInput(text: $licenseKeyInput, placeholder: "PIDGY-XXXX-…", isSecure: false, monospaced: true)
                        .frame(width: 200)
                    PrefGhostButton(title: isActivatingLicense ? "…" : "Activate", systemImage: "key") {
                        activateLicense()
                    }
                }
            }
        }
    }

    private func activateLicense() {
        let key = licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isActivatingLicense else { return }
        isActivatingLicense = true
        licenseError = nil
        let deviceName = Host.current().localizedName ?? "Mac"
        Task { @MainActor in
            do {
                try await entitlements.activateLicense(key, deviceName: deviceName)
                licenseKeyInput = ""
            } catch {
                licenseError = (error as? LocalizedError)?.errorDescription ?? "Couldn't activate that key."
            }
            isActivatingLicense = false
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Cost overview ── 3-column grid: 30d cost (sparkline) / tokens / lifetime (donut)
            PrefSection(topPadding: 24) {
                PrefSectionHead(
                    title: "Cost overview",
                    subtitle: "Last 30 days · estimated USD from provider-reported usage"
                )

                HStack(alignment: .top, spacing: 0) {
                    pricingOverviewColumn(
                        eyebrow: "30D Cost",
                        value: currencyString(usageOverview.last30Days.estimatedCostUSD),
                        hint: "\(integerString(usageOverview.last30Days.requestCount)) successful requests"
                    ) {
                        PrefSparkline(data: pricingTrendData, color: Color.Pidgy.accentFg)
                            .padding(.top, 10)
                    }
                    .padding(.trailing, 20)

                    Rectangle().fill(Color.Pidgy.border1).frame(width: 1)

                    pricingOverviewColumn(
                        eyebrow: "30D Tokens",
                        value: compactNumberString(totalTokens30d),
                        hint: "Input and output combined"
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            tokenSplitBar
                            HStack {
                                Text("Input \(compactNumberString(usageOverview.last30Days.inputTokens))")
                                Spacer()
                                Text("Output \(compactNumberString(usageOverview.last30Days.outputTokens))")
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.Pidgy.fg3)
                        }
                        .padding(.top, 14)
                    }
                    .padding(.horizontal, 20)

                    Rectangle().fill(Color.Pidgy.border1).frame(width: 1)

                    pricingOverviewColumn(
                        eyebrow: "Lifetime",
                        value: currencyString(usageOverview.lifetime.estimatedCostUSD),
                        hint: "\(integerString(usageOverview.lifetime.requestCount)) total requests"
                    ) {
                        PrefDonut(
                            progress: lifetimeCapProgress,
                            label: lifetimeCapLabel,
                            sub: "of $50 monthly cap",
                            color: Color.Pidgy.success
                        )
                        .padding(.top, 10)
                    }
                    .padding(.leading, 20)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 18)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.Pidgy.border1).frame(height: 1)
                }
            }

            // ── Day by day ── per-day cost vs a derived daily budget
            PrefSection {
                PrefSectionHead(
                    title: "Day by day",
                    subtitle: "Cost per day · budget ~\(currencyString(dailyBudgetUSD))/day"
                ) {
                    dailyRangeChips
                }
                if dailyUsagePoints.allSatisfy({ $0.metrics.estimatedCostUSD == 0 }) {
                    Text("No tracked usage in the last \(dailyRangeDays) days yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 8)
                } else {
                    dailyBudgetChart
                        .padding(.top, 10)
                }
            }

            // ── By feature ── horizontal bar chart
            PrefSection {
                PrefSectionHead(title: "By feature", subtitle: "Last 30 days")
                if pricingFeatureRows.isEmpty {
                    Text("No tracked usage in the last 30 days yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                        .padding(.vertical, 8)
                } else {
                    PrefHBarChart(rows: pricingFeatureRows)
                        .padding(.top, 4)
                }
            }

            // ── Usage data refresh ──
            PrefSection(bottomBorder: false) {
                PrefSectionHead(
                    title: "Usage data",
                    subtitle: "Refresh provider-reported usage totals"
                ) {
                    PrefGhostButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await refreshUsageOverview() }
                    }
                }
            }
        }
    }

    // ── Pricing helpers (drive the new charts) ─────────────────────────────

    /// 3-column cell wrapper used inside the cost overview grid.
    @ViewBuilder
    private func pricingOverviewColumn<Body: View>(
        eyebrow: String,
        value: String,
        hint: String,
        @ViewBuilder content: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(eyebrow)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.85)
                .textCase(.uppercase)
                .foregroundStyle(Color.Pidgy.fg3)
            Text(value)
                .font(Font.Pidgy.pageTitle)
                .tracking(-0.6)
                .foregroundStyle(Color.Pidgy.fg1)
                .lineLimit(1)
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Pidgy.fg3)
            content()
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalTokens30d: Int {
        usageOverview.last30Days.inputTokens + usageOverview.last30Days.outputTokens
    }

    /// Split bar used inside the 30D Tokens column to show input vs output share.
    private var tokenSplitBar: some View {
        let total = max(totalTokens30d, 1)
        let inputFraction = Double(usageOverview.last30Days.inputTokens) / Double(total)
        return GeometryReader { proxy in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.Pidgy.accentFg)
                    .frame(width: max(0, proxy.size.width * CGFloat(inputFraction)), height: 8)
                Rectangle()
                    .fill(Color.Pidgy.avPurple)
                    .frame(height: 8)
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private static let monthlyCapUSD: Double = 50

    /// Even daily allowance derived from the monthly cap (~$1.67 on a $50 cap).
    private var dailyBudgetUSD: Double { Self.monthlyCapUSD / 30 }

    private var lifetimeCapProgress: Double {
        let cap = Self.monthlyCapUSD
        guard cap > 0 else { return 0 }
        return min(1, max(0, usageOverview.lifetime.estimatedCostUSD / cap))
    }

    private var lifetimeCapLabel: String {
        "\(Int((lifetimeCapProgress * 100).rounded()))%"
    }

    /// Trailing N days (oldest → newest) for the day-by-day bar chart, where N
    /// is the selected date-range filter.
    private var dailyUsagePoints: [DailyUsagePoint] {
        Array(usageOverview.daily30Days.suffix(dailyRangeDays))
    }

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func dayLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.dayLabelFormatter.string(from: date)
    }

    /// Date-range filter chips (7 / 14 / 30 days) for the section header.
    private var dailyRangeChips: some View {
        HStack(spacing: 4) {
            ForEach([7, 14, 30], id: \.self) { days in
                let selected = dailyRangeDays == days
                Text("\(days)D")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.Pidgy.accentFg : Color.Pidgy.fg3)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Color.Pidgy.accentFg.opacity(0.16) : Color.clear))
                    .contentShape(Capsule())
                    .onTapGesture { dailyRangeDays = days }
            }
        }
    }

    /// Vertical per-day cost bars over the selected range, scaled against the
    /// busier of the peak day or the daily budget, with a dashed budget line
    /// and over-budget days flagged amber.
    private var dailyBudgetChart: some View {
        let days = dailyUsagePoints
        let maxCost = days.map(\.metrics.estimatedCostUSD).max() ?? 0
        let scaleMax = Swift.max(maxCost, dailyBudgetUSD) * 1.15
        let chartHeight: CGFloat = 140
        let spacing: CGFloat = days.count <= 7 ? 7 : (days.count <= 14 ? 4 : 2)
        return VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(days) { point in
                        let cost = point.metrics.estimatedCostUSD
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(cost > dailyBudgetUSD ? Color.Pidgy.warning : Color.Pidgy.accentFg)
                                .opacity(hoveredDay == nil || hoveredDay == point.dayStart ? 1 : 0.4)
                                .frame(height: Swift.max(cost > 0 ? 3 : 0, chartHeight * CGFloat(cost / scaleMax)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if hoveredDay == point.dayStart {
                                dailyTooltip(point)
                                    .fixedSize()
                                    .offset(y: -8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onHover { hovering in
                            if hovering { hoveredDay = point.dayStart }
                            else if hoveredDay == point.dayStart { hoveredDay = nil }
                        }
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
                // Daily budget threshold line (value is in the section subtitle).
                Rectangle()
                    .fill(Color.Pidgy.fg3.opacity(0.5))
                    .frame(height: 1)
                    .padding(.bottom, chartHeight * CGFloat(dailyBudgetUSD / scaleMax))
            }
            .frame(height: chartHeight, alignment: .bottom)
            // x-axis: oldest · middle · newest
            HStack(spacing: 0) {
                Text(dayLabel(days.first?.dayStart))
                Spacer()
                if days.count >= 5 {
                    Text(dayLabel(days[days.count / 2].dayStart))
                    Spacer()
                }
                Text(dayLabel(days.last?.dayStart))
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.Pidgy.fg3)
        }
    }

    /// Hover tooltip card: the day and its $/day cost (amber when over budget).
    private func dailyTooltip(_ point: DailyUsagePoint) -> some View {
        let cost = point.metrics.estimatedCostUSD
        return HStack(spacing: 6) {
            Text(dayLabel(point.dayStart))
                .foregroundStyle(Color.Pidgy.fg3)
            Text("\(currencyString(cost))/day")
                .fontWeight(.semibold)
                .foregroundStyle(cost > dailyBudgetUSD ? Color.Pidgy.warning : Color.Pidgy.fg1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.Pidgy.bg4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.Pidgy.border3, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }

    /// Real per-day cost series (oldest → newest) driving the 30D cost
    /// sparkline — now backed by stored daily aggregates instead of a
    /// synthetic curve. Flat zero line when there's no usage yet.
    private var pricingTrendData: [Double] {
        let costs = usageOverview.daily30Days.map(\.metrics.estimatedCostUSD)
        return costs.contains(where: { $0 > 0 }) ? costs : Array(repeating: 0, count: 30)
    }

    private var pricingFeatureRows: [PrefBarRow] {
        let palette: [Color] = [
            Color.Pidgy.accentFg,
            Color.Pidgy.fg3,
            Color.Pidgy.avPurple,
            Color.Pidgy.success,
            Color.Pidgy.warning,
            Color.Pidgy.avPink,
            Color.Pidgy.avBlue
        ]
        let rows = usageOverview.byFeature30Days
            .filter { $0.metrics.requestCount > 0 }
            .prefix(7)
            .enumerated()
            .map { idx, breakdown in
                PrefBarRow(
                    id: breakdown.id,
                    label: breakdown.title,
                    value: max(breakdown.metrics.estimatedCostUSD, 0),
                    right: currencyString(breakdown.metrics.estimatedCostUSD),
                    sub: "\(integerString(breakdown.metrics.requestCount)) req",
                    color: palette[idx % palette.count]
                )
            }
        return Array(rows)
    }

    private var indexingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(topPadding: 0) {
                PrefSectionHead(
                    title: "Indexing",
                    subtitle: "Freshness and local search coverage"
                ) {
                    PrefPill(text: indexingPillText, tone: indexingPillTone)
                }
                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Search-ready",
                        value: "\(integerString(indexingProgress.indexed)) / \(integerString(indexingProgress.total))",
                        hint: "Loaded chats deep-indexed",
                        dot: .blue
                    )
                    PrefStatTile(
                        eyebrow: "Pending",
                        value: integerString(indexingProgress.pendingChats),
                        hint: "Chats waiting on deep index",
                        dot: indexingProgress.pendingChats == 0 ? .green : .amber
                    )
                    PrefStatTile(
                        eyebrow: "Workers",
                        value: indexingWorkerLabel,
                        hint: indexingWorkerCaption,
                        dot: .amber
                    )
                }
            }

            PrefSection(bottomBorder: false) {
                PrefSectionHead(
                    title: "Recent sync",
                    subtitle: "The live window that feeds search and task context"
                )
                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Status",
                        value: recentSyncStatusLabel,
                        hint: recentSyncStatusCaption,
                        dot: recentSyncProgress.activeRefreshes > 0 ? .blue : .green
                    )
                    PrefStatTile(
                        eyebrow: "Stale",
                        value: "\(integerString(recentSyncProgress.staleVisibleChats)) / \(integerString(recentSyncProgress.totalVisibleChats))",
                        hint: "Visible chats needing refresh",
                        dot: recentSyncProgress.staleVisibleChats == 0 ? .green : .amber
                    )
                    PrefStatTile(
                        eyebrow: "Last sync",
                        value: recentSyncProgress.lastSyncAt.map(relativeTimeString) ?? "No refresh",
                        hint: recentSyncProgress.lastSyncedChat ?? "Most recently refreshed visible chat",
                        dot: .blue
                    )
                }

                // Session activity card with sparkline.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("This session")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.Pidgy.fg1)
                        Spacer()
                        Text("\(compactNumberString(recentSyncProgress.sessionRefreshedMessages)) messages refreshed")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Pidgy.fg3)
                            .monospacedDigit()
                    }
                    PrefSparkline(
                        data: sessionActivityTrend,
                        color: Color.Pidgy.success,
                        height: 48,
                        fill: true
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.bg2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.Pidgy.border1)
                        )
                )
                .padding(.top, 18)

                HStack {
                    Spacer()
                    PrefGhostButton(title: "Refresh dashboard caches", systemImage: "arrow.clockwise", action: onRefreshUsage)
                }
                .padding(.top, 14)
            }
        }
    }

    /// Synthesizes a 20-point session-activity trend line. We don't yet store
    /// the per-tick history, so we draw a gentle ramp toward the current
    /// session's refreshed message count — gives a real-feeling chart shape
    /// without inventing data we don't have.
    private var sessionActivityTrend: [Double] {
        let total = max(Double(recentSyncProgress.sessionRefreshedMessages), 1)
        return (0..<20).map { i in
            let progress = Double(i) / 19
            return total * pow(progress, 1.4)
        }
    }

    private var indexingPillText: String {
        if indexingProgress.total > 0 && indexingProgress.indexed >= indexingProgress.total {
            return "Done"
        }
        return indexingProgress.pendingChats > 0 ? "Indexing" : "Idle"
    }

    private var indexingPillTone: PrefPill.Tone {
        if indexingProgress.total > 0 && indexingProgress.indexed >= indexingProgress.total {
            return .green
        }
        return .blue
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
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(topPadding: 0, bottomBorder: false) {
                PrefSectionHead(title: "Local reset", subtitle: "Destructive cleanup for this Mac only")

                // Tinted warning panel — danger color at 4% bg + 18% border.
                VStack(alignment: .leading, spacing: 4) {
                    Text("What gets reset")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.Pidgy.fg1)
                    (
                        Text("TDLib data, SQLite cache, AI usage, saved providers, credentials, and all local dashboard state. ")
                            .foregroundColor(Color.Pidgy.fg3)
                        + Text("Telegram cloud data is not affected.")
                            .foregroundColor(Color.Pidgy.fg2)
                    )
                    .font(.system(size: 12))
                    .lineSpacing(2)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Pidgy.danger.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.Pidgy.danger.opacity(0.18))
                        )
                )

                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Credentials",
                        value: integerString(PreferencesResetPlan.credentialKeysToDelete.count),
                        hint: "Credential slots cleared",
                        dot: .red
                    )
                    PrefStatTile(
                        eyebrow: "Defaults",
                        value: integerString(PreferencesResetPlan.userDefaultsKeysToDelete.count),
                        hint: "Preference keys reset",
                        dot: .amber
                    )
                }
                .padding(.top, 4)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset all local data")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Pidgy.fg1)
                        Text(isResetting
                             ? "Stopping background work and clearing local files…"
                             : "You'll go back to the welcome screen and sign in again")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Pidgy.fg3)
                    }
                    Spacer(minLength: 12)
                    if isResetting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.Pidgy.danger)
                            Text("Resetting…")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.Pidgy.fg2)
                        }
                    } else {
                        PrefGhostButton(title: "Reset", systemImage: "arrow.counterclockwise", tone: .danger) {
                            showDeleteConfirmation = true
                        }
                    }
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.Pidgy.border1)
                        .frame(height: 1)
                }
            }
        }
    }

    /// App identity, privacy, and invites.
    ///
    /// Invites moved here from their own nav entry: three codes to hand out
    /// is not a settings *category*, and on builds without an invite server
    /// the page was hidden entirely — a nav item that sometimes isn't there
    /// is worse than a section that sometimes isn't there.
    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsInviteSection {
                invitesPage
            }
            PrefSection(topPadding: 0) {
                HStack(alignment: .center, spacing: 18) {
                    PidgyMascotMark(size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PidgyBranding.appName)
                            .font(Font.Pidgy.pageTitle)
                            .tracking(-0.6)
                            .foregroundStyle(Color.Pidgy.fg1)
                        Text("Local-first Telegram command center for replies, tasks, people, topics, and search.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.Pidgy.fg3)
                    }
                }
            }

            PrefSection {
                HStack(alignment: .top, spacing: 24) {
                    PrefStatTile(
                        eyebrow: "Version",
                        value: AppConstants.App.version,
                        hint: "Local build metadata",
                        dot: .blue
                    )
                    PrefStatTile(
                        eyebrow: "Build",
                        value: BundledSecrets.buildCommitSHA,
                        hint: "Reference this in bug reports",
                        dot: .blue
                    )
                    PrefStatTile(
                        eyebrow: "Hotkey",
                        value: "⌘ ⇧ T",
                        hint: "Open the quick launcher",
                        dot: .blue
                    )
                }
            }

            PrefSection {
                PrefSectionHead(title: "Local-first posture")
                Text("Pidgy reads Telegram data locally, stores credentials locally, and uses your configured AI provider only when an AI feature needs it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Pidgy.fg2)
                    .lineSpacing(3)
                    .frame(maxWidth: 640, alignment: .leading)
            }

            PrefSection(bottomBorder: false) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Replay onboarding")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.Pidgy.fg1)
                        Text("Walk through the welcome, tour, and connection screens again.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Pidgy.fg3)
                    }
                    Spacer(minLength: 12)
                    PrefGhostButton(title: "Replay", systemImage: "arrow.counterclockwise") {
                        NotificationCenter.default.post(name: .pidgyReplayOnboarding, object: nil)
                    }
                }
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
        let persisted = aiService.persistedConfiguration(for: aiService.providerType)
        // Re-select the preset row from the persisted (type, base URL).
        selectedBYOKProvider = BYOKProvider.infer(
            providerType: aiService.providerType,
            baseURL: persisted?.baseURL
        )
        loadAIFields(for: selectedBYOKProvider)
    }

    private func loadAIFields(for preset: BYOKProvider) {
        if let persisted = aiService.persistedConfiguration(for: preset.providerType) {
            aiApiKey = persisted.apiKey
            // Leave the model field blank when it's just the default (the
            // placeholder shows it); only surface an explicitly-chosen model.
            aiModel = persisted.model == preset.defaultModel ? "" : persisted.model
            aiBaseURL = preset.requiresCustomBaseURL ? (persisted.baseURL?.absoluteString ?? "") : ""
        } else {
            aiApiKey = ""
            aiModel = ""
            aiBaseURL = ""
        }
    }

    private func saveAIConfig() {
        let preset = selectedBYOKProvider
        let trimmedKey = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            setAIStatus(.error("API key required"))
            return
        }

        // Resolve the OpenAI-compatible endpoint: custom → user field (must be
        // an https URL); a named preset → its built-in base URL; Anthropic →
        // nil (the native client owns its endpoint).
        var endpoint: URL?
        if preset.providerType == .openai {
            if preset.requiresCustomBaseURL {
                guard let url = URL(string: trimmedBaseURL), url.scheme?.hasPrefix("http") == true else {
                    setAIStatus(.error("Enter a valid base URL (https://…/chat/completions)"))
                    return
                }
                endpoint = url
            } else {
                endpoint = preset.defaultBaseURL
            }
        }

        aiApiKey = trimmedKey
        aiModel = trimmedModel
        aiBaseURL = trimmedBaseURL
        selectedAIProvider = preset.providerType
        aiService.configure(
            type: preset.providerType,
            apiKey: trimmedKey,
            model: trimmedModel.isEmpty ? preset.defaultModel : trimmedModel,
            openAIEndpointURL: endpoint
        )
        setAIStatus(.success("Saved"))
    }

    private func testConnection() async {
        isTestingConnection = true
        testConnectionStatus = nil
        defer { isTestingConnection = false }

        saveAIConfig()
        guard aiService.isConfigured else {
            testConnectionStatus = .error("Save a valid key first")
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
        guard !isResetting else { return }
        isResetting = true
        defer { isResetting = false }

        await PreferencesResetService().deleteAllLocalData(
            telegramService: telegramService,
            aiService: aiService
        )

        apiId = ""
        apiHash = ""
        aiApiKey = ""
        aiModel = ""
        aiBaseURL = ""
        selectedAIProvider = .none
        selectedBYOKProvider = .openAI
        includeBotsInAISearch = false
        showPigeonFlock = true
        contextLayerEnabled = true
        // Privacy default, NOT a feature default: identity on crash reports
        // is opt-in, and a reset must never silently re-enable it.
        diagnosticsIdentityEnabled = false
        usageOverview = .empty
        graphDebugSummary = .empty
        routingSnapshots = []
        setTelegramStatus(.success("Reset complete"))

        // Data is wiped (including the onboarding-complete flag) — relaunch into
        // a fresh process, exactly like logout. We must NOT re-onboard in-process:
        // deleteAllLocalData() already called TelegramService.stop(), so TDLib is
        // closed, and re-driving auth on a closed/stale client makes TDLib reject
        // setAuthenticationPhoneNumber as "unexpected". A clean process brings
        // TDLib up in authorizationStateWaitPhoneNumber, and the cleared flag
        // drops the user straight onto the welcome screen — a true fresh install.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.relaunchIntoFreshProcess()
        }
    }

    @MainActor
    private func refreshCurrentPreferencePage() {
        switch selectedPage {
        case .account:
            loadCredentials()
            onRefreshDashboard()
        case .plan:
            loadAIConfig()
            Task { await refreshUsageOverview() }
        case .memory:
            // Toggles are pure @AppStorage — nothing to fetch.
            break
        case .data:
            onRefreshUsage()
            onRefreshDashboard()
        case .diagnostics:
            Task {
                await refreshDiagnostics()
                await refreshRoutingDebug()
            }
        case .about:
            Task { await InviteService.shared.refreshStatus() }
        }
    }

    @MainActor
    private func refreshDataIfNeeded(for page: DashboardPreferencePage) async {
        switch page {
        case .memory:
            memoryStats = await DatabaseManager.shared.factStoreStats()
            memoryLastPassAt = FactExtractionCoordinator.shared.lastPassAt
        case .plan:
            await refreshUsageOverview()
        case .about:
            await InviteService.shared.refreshStatus()
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
        case .plan:
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

}
