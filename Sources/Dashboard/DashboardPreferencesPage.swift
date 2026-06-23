import SwiftUI

struct DashboardPreferencesPage: View {
    @EnvironmentObject private var telegramService: TelegramService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var indexingProgress = IndexScheduler.shared.progress
    @StateObject private var recentSyncProgress = RecentSyncCoordinator.shared.progress
    @AppStorage(AppConstants.Preferences.includeBotsInAISearchKey) private var includeBotsInAISearch = false
    @AppStorage(AppConstants.Preferences.showPigeonFlockKey) private var showPigeonFlock = true
    @AppStorage(AppConstants.Preferences.dashboardTaskAutoExpireDaysKey)
    private var taskAutoExpireDays = AppConstants.Preferences.dashboardTaskAutoExpireDaysDefault
    @AppStorage(AppConstants.Preferences.chatOpenTargetKey)
    private var chatOpenTargetRaw: String = ChatOpenTarget.detectedDefault().rawValue

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
        .alert("Reset all local data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task { await deleteAllData() }
            }
        } message: {
            Text("This clears TDLib data, cached messages, AI usage, credentials, and your Telegram session. You'll be taken back to the welcome screen and can sign in again.")
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

    /// Refresh only meaningful when the page actually has freshness data
    /// to pull (pricing usage, indexing). Hides the button on static pages
    /// like account, reset, about.
    private var showsRefreshControl: Bool {
        switch selectedPage {
        case .ai, .indexing, .diagnostics:
            return true
        case .account, .preferences, .reset, .about:
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

    /// Diagnostics is debug-only — hidden from the user-facing rail. The
    /// underlying page is still rendered if `selectedPage` somehow lands
    /// there (defensive), but you can't navigate to it from the UI.
    private var visiblePreferencePages: [DashboardPreferencePage] {
        DashboardPreferencePage.allCases.filter { $0 != .diagnostics }
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
        case .preferences:
            return DashboardPreferenceStatusItem(
                title: "Pigeon flock",
                value: showPigeonFlock ? "On" : "Off",
                caption: showPigeonFlock ? "5 birds, drag the line to bounce" : "Plain divider under the title",
                systemImage: "slider.horizontal.3",
                tint: PidgyDashboardTheme.blue
            )
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
        case .preferences:
            preferencesPage
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
        VStack(alignment: .leading, spacing: 0) {
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

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            planSection
            // The provider/key block only matters on BYOK; on the
            // managed (Pidgy AI) plan there's nothing to configure.
            if entitlements.selectedPlan == .byok {
                aiProviderSection
            } else {
                managedAINote
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
                    Picker("", selection: $selectedAIProvider) {
                        ForEach(AIProviderConfig.ProviderType.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                if selectedAIProvider != .none {
                    PrefField(label: "API key", hint: "Stored in Keychain or the debug credential store") {
                        PrefMinInput(text: $aiApiKey, placeholder: "\(selectedAIProvider.rawValue) API key", isSecure: true, monospaced: true)
                    }
                    PrefField(label: "Model", hint: "Default: \(selectedAIProvider.defaultModel)") {
                        PrefMinInput(text: $aiModel, placeholder: selectedAIProvider.defaultModel, monospaced: true)
                    }
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
                            .disabled(isTestingConnection || selectedAIProvider == .none)
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
    private var preferencesPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection {
                PrefSectionHead(
                    title: "Quirks",
                    subtitle: "Little bits of Pidgy you can turn on or off"
                )
                PrefField(
                    label: "Pigeons on the squiggle",
                    hint: "Show the animated flock under the page title. Drag the line to bounce them; click any to shoo.",
                    right: {
                        PrefToggle(isOn: $showPigeonFlock)
                    }
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
                    label: "Auto-complete stale tasks",
                    hint: "Open AI-extracted tasks with no fresh chat activity are marked Done after this long. Re-open one from the Done filter and it stays put.",
                    right: {
                        PrefOptionMenu(
                            options: [
                                (7, "7 days"),
                                (14, "14 days"),
                                (30, "30 days"),
                                (0, "Never")
                            ],
                            selection: $taskAutoExpireDays
                        )
                    }
                )
            }

            PrefSection {
                PrefSectionHead(title: "Privacy", subtitle: "Keep the AI surface explicit")
                PrefField(
                    label: "Include bot chats",
                    hint: "Hide Telegram bots from AI search and agentic ranking when off",
                    right: {
                        PrefToggle(isOn: $includeBotsInAISearch)
                    }
                )

                // Inline note panel — accent-tinted left rail + bg-2 background.
                HStack(alignment: .top, spacing: 12) {
                    Capsule()
                        .fill(Color.Pidgy.accentFg.opacity(0.50))
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What AI sees")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.Pidgy.fg1)
                        Text("Message text, sender first names, relative timestamps, chat names, and numeric chat IDs. It does not send phone numbers, user IDs, session tokens, media files, stickers, or voice messages.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Pidgy.fg3)
                            .lineSpacing(2)
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
                if let plan = entitlements.selectedPlan,
                   let url = entitlements.checkoutURL(for: plan) {
                    PrefGhostButton(title: "Manage", systemImage: "creditcard") {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    Text("Payments coming soon")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Pidgy.fg4)
                }
            }

            // Plan switch — for trial users this just changes which plan
            // the trial (and eventual subscription) is for; the clock is
            // preserved. A live paid switch will route through the
            // payment provider once wired.
            PrefField(
                label: "Plan",
                hint: "Pidgy AI runs the model for you; Bring your own key keeps everything off our servers."
            ) {
                HStack(spacing: 8) {
                    ForEach(PidgyPlan.allCases) { plan in
                        let isCurrent = entitlements.selectedPlan == plan
                        Button {
                            entitlements.startTrial(plan: plan)
                        } label: {
                            Text("\(plan.title) · $\(plan.monthlyPriceUSD)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isCurrent ? Color.Pidgy.fg1 : Color.Pidgy.fg3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(isCurrent ? Color.Pidgy.bg4 : Color.clear)
                                        .overlay(Capsule().stroke(
                                            isCurrent ? Color.Pidgy.accentFg.opacity(0.6) : Color.Pidgy.border2
                                        ))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            licenseRow
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

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 0) {
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
        selectedAIProvider = .none
        includeBotsInAISearch = false
        showPigeonFlock = true
        usageOverview = .empty
        graphDebugSummary = .empty
        routingSnapshots = []
        setTelegramStatus(.success("Reset complete"))

        // Send the user back to the welcome screen — exactly like a fresh
        // install. AppDelegate listens for this and (re)opens the onboarding
        // window after closing the dashboard.
        NotificationCenter.default.post(name: .pidgyReplayOnboarding, object: nil)
    }

    @MainActor
    private func refreshCurrentPreferencePage() {
        switch selectedPage {
        case .account:
            loadCredentials()
            onRefreshDashboard()
        case .ai:
            loadAIConfig()
            Task { await refreshUsageOverview() }
        case .preferences:
            // Toggles are pure @AppStorage — nothing to fetch.
            break
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
        case .ai:
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
        case .ai:
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
                    .frame(width: 18)
                Text(page.rawValue)
                    .font(PidgyDashboardTheme.detailBodyFont.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : PidgyDashboardTheme.primary)
            .padding(.horizontal, 10)
            .frame(height: PidgyDashboardTheme.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg4 : Color.clear)
            )
            .contentShape(Rectangle())
            .animation(PidgyMotion.easeOutFast, value: isSelected)
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

// MARK: - V2 Preferences building blocks (matches the design system handoff)
//
// These are the Section / SectionHead / Field / MinInput / Pill / GhostBtn /
// Toggle / StatTile / HBarChart / Sparkline / Donut atoms from the design's
// Preferences.jsx, ported to SwiftUI on top of PidgyTokens. They replace the
// older DashboardPreferenceSection / Row / Metric / Note components which are
// still in the file but unused — kept around just to keep the diff focused.

private struct PrefSection<Content: View>: View {
    var topPadding: CGFloat = 24
    var bottomBorder: Bool = true
    let content: () -> Content

    init(topPadding: CGFloat = 24, bottomBorder: Bool = true, @ViewBuilder _ content: @escaping () -> Content) {
        self.topPadding = topPadding
        self.bottomBorder = bottomBorder
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.top, topPadding)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if bottomBorder {
                Rectangle()
                    .fill(Color.Pidgy.border1)
                    .frame(height: 1)
            }
        }
    }
}

private struct PrefSectionHead<Action: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Font.Pidgy.sectionTitle)
                    .tracking(-0.4)
                    .foregroundStyle(Color.Pidgy.fg1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.bottom, 18)
    }
}

extension PrefSectionHead where Action == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, action: { EmptyView() })
    }
}

/// Form field row used across the v2 Preferences design.
/// `content` renders below the label/hint pair; `right` floats trailing.
/// Pass `nil` for either to omit. Avoids generic-init ambiguity.
private struct PrefField: View {
    let label: String
    var hint: String?
    var content: AnyView?
    var right: AnyView?

    init(
        label: String,
        hint: String? = nil,
        @ViewBuilder content: () -> some View = { EmptyView() },
        @ViewBuilder right: () -> some View = { EmptyView() }
    ) {
        self.label = label
        self.hint = hint
        let body = content()
        if body is EmptyView {
            self.content = nil
        } else {
            self.content = AnyView(body)
        }
        let rightView = right()
        if rightView is EmptyView {
            self.right = nil
        } else {
            self.right = AnyView(rightView)
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Pidgy.fg1)
                if let hint, !hint.isEmpty {
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
                if let content {
                    content.padding(.top, 8)
                }
            }
            Spacer(minLength: 12)
            if let right {
                right
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.Pidgy.border1)
                .frame(height: 1)
        }
    }
}

/// Borderless input — only a 1pt bottom hairline. Bound to a String, plain
/// text or password.
private struct PrefMinInput: View {
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false
    var monospaced: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(monospaced ? Font.Pidgy.mono : .system(size: 13))
        .foregroundStyle(Color.Pidgy.fg1)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.Pidgy.border2)
                .frame(height: 1)
        }
    }
}

private struct PrefPill: View {
    enum Tone { case green, red, blue, amber, mono }
    let text: String
    var tone: Tone = .green

    private var fg: Color {
        switch tone {
        case .green: return Color.Pidgy.success
        case .red: return Color.Pidgy.danger
        case .blue: return Color.Pidgy.accentFg
        case .amber: return Color.Pidgy.warning
        case .mono: return Color.Pidgy.fg2
        }
    }

    private var bg: Color {
        switch tone {
        case .green: return Color.Pidgy.success.opacity(0.10)
        case .red: return Color.Pidgy.danger.opacity(0.12)
        case .blue: return Color.Pidgy.accentFg.opacity(0.12)
        case .amber: return Color.Pidgy.warning.opacity(0.12)
        case .mono: return .clear
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(fg).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(fg)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(bg))
    }
}

private struct PrefGhostButton: View {
    let title: String
    var systemImage: String?
    var tone: Tone = .neutral
    let action: () -> Void

    enum Tone { case neutral, danger }

    @State private var isHovering = false

    private var fg: Color {
        tone == .danger ? Color.Pidgy.danger : Color.Pidgy.fg1
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.Pidgy.bg2 : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.Pidgy.border2)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PidgyMotion.easeOutFast, value: isHovering)
    }
}

private struct PrefToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.Pidgy.accentFg : Color.Pidgy.bg3)
                    .overlay(
                        Capsule().stroke(isOn ? Color.Pidgy.accentFg : Color.Pidgy.border2)
                    )
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.30), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(PidgyMotion.easeOut, value: isOn)
    }
}

/// Compact value picker for preference rows — a borderless Menu
/// rendered as a small bordered chip, visually paired with PrefToggle.
private struct PrefOptionMenu: View {
    let options: [(value: Int, label: String)]
    @Binding var selection: Int

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? "\(selection) days"
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.Pidgy.fg1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.Pidgy.bg3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.Pidgy.border2)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Stat tile: small dot + uppercase eyebrow / display value / hint.
/// No card chrome — sits in a grid with an inset divider on top.
private struct PrefStatTile: View {
    enum Dot { case blue, green, amber, red }
    let eyebrow: String
    let value: String
    var hint: String?
    var dot: Dot = .blue
    var hasTopBorder: Bool = true

    private var dotColor: Color {
        switch dot {
        case .blue: return Color.Pidgy.accentFg
        case .green: return Color.Pidgy.success
        case .amber: return Color.Pidgy.warning
        case .red: return Color.Pidgy.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 5, height: 5)
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.85)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Pidgy.fg3)
            }
            Text(value)
                .font(Font.Pidgy.statValue)
                .tracking(-0.4)
                .foregroundStyle(Color.Pidgy.fg1)
                .lineLimit(1)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Pidgy.fg3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            if hasTopBorder {
                Rectangle().fill(Color.Pidgy.border1).frame(height: 1)
            }
        }
    }
}

// MARK: - Charts

private struct PrefBarRow: Identifiable {
    let id: String
    let label: String
    let value: Double
    let right: String
    let sub: String
    let color: Color
}

private struct PrefHBarChart: View {
    let rows: [PrefBarRow]
    var max: Double {
        Swift.max(rows.map(\.value).max() ?? 1, 0.0001)
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(rows) { row in
                let pct = row.value / max
                HStack(spacing: 14) {
                    Text(row.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Pidgy.fg2)
                        .lineLimit(1)
                        .frame(width: 160, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.Pidgy.bg3)
                                .frame(height: 8)
                            Capsule()
                                .fill(row.color)
                                .frame(width: max == 0 ? 0 : proxy.size.width * pct, height: 8)
                        }
                    }
                    .frame(height: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(row.right)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Pidgy.fg1)
                            .monospacedDigit()
                        Text(row.sub)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.Pidgy.fg4)
                            .monospacedDigit()
                    }
                    .frame(width: 90, alignment: .trailing)
                }
            }
        }
    }
}

private struct PrefSparkline: View {
    let data: [Double]
    var color: Color = Color.Pidgy.accentFg
    var height: CGFloat = 56
    var fill: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let pad: CGFloat = 4
            let drawableWidth = width - pad * 2
            let drawableHeight = height - pad * 2
            let maxValue = data.max() ?? 1
            let minValue = data.min() ?? 0
            let range = Swift.max(maxValue - minValue, 0.0001)

            let points: [CGPoint] = data.enumerated().map { idx, value in
                let denom = Swift.max(data.count - 1, 1)
                let x = pad + drawableWidth * CGFloat(idx) / CGFloat(denom)
                let y = pad + drawableHeight * (1 - CGFloat((value - minValue) / range))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                if fill, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: height - pad))
                        for point in points {
                            path.addLine(to: point)
                        }
                        path.addLine(to: CGPoint(x: last.x, y: height - pad))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(0.12))
                }
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(color)
                        .frame(width: 5, height: 5)
                        .position(last)
                }
            }
        }
        .frame(height: height)
    }
}

private struct PrefDonut: View {
    /// 0..1 fraction filled.
    let progress: Double
    let label: String
    var sub: String?
    var color: Color = Color.Pidgy.success
    var size: CGFloat = 92
    var lineWidth: CGFloat = 6

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.Pidgy.bg3, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: size, height: size)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Font.Pidgy.statValue)
                    .tracking(-0.4)
                    .foregroundStyle(Color.Pidgy.fg1)
                if let sub, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Pidgy.fg3)
                }
            }
        }
    }
}

/// Sidebar nav row for the v2 Preferences design — flat, icon + label, with
/// hover that lifts color from fg-3 to fg-1, and selected state that uses
/// the bg-2 fill from the design.
private struct PrefRailRow: View {
    let page: DashboardPreferencePage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var fg: Color {
        if isSelected {
            return Color.Pidgy.fg1
        }
        return isHovering ? Color.Pidgy.fg1 : Color.Pidgy.fg3
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 13))
                    .frame(width: 16)
                Text(page.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.Pidgy.bg2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PidgyMotion.easeOutFast, value: isHovering)
        .animation(PidgyMotion.easeOutFast, value: isSelected)
    }
}
