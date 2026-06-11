import SwiftUI

struct DashboardTasksPage: View {
    let tasks: [DashboardTask]
    let evidenceByTaskId: [Int64: [DashboardTaskSourceMessage]]
    let ownerPeople: [RelationGraph.Node]
    let currentUser: TGUser?
    let isRefreshing: Bool
    let aiConfigured: Bool
    @Binding var selectedTaskId: Int64?
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void

    @State private var statusFilter: DashboardStatusFilter = .open
    @State private var selectedOwnerFilter: DashboardTaskOwnerFilter = .mine
    @State private var isOwnerPickerPresented = false
    @State private var ownerSearchQuery = ""
    @State private var cachedSearchBase: [DashboardTaskOwnerSearchOption] = []
    @State private var liveSearchHits: [DashboardTaskOwnerSearchOption] = []
    @State private var liveSearchTask: Task<Void, Never>?
    @StateObject private var pinsStore = DashboardOwnerPinsStore.shared

    private var filteredTasks: [DashboardTask] {
        DashboardTaskListFilters.filteredTasks(
            tasksForSelectedStatus,
            status: nil,
            ownerFilter: selectedOwnerFilter,
            currentUser: currentUser
        )
    }

    private var selectedTask: DashboardTask? {
        selectedTaskId.flatMap { id in tasks.first { $0.id == id } }
    }

    // Chips shown in the strip: always "For me", then anything the user has
    // pinned via the "+" picker. Counts come from the currently-visible tasks.
    private var ownerOptions: [DashboardTaskOwnerOption] {
        let pinned = DashboardTaskListFilters.pinnedOwnerChips(
            pinnedNames: pinsStore.pinnedNames,
            tasks: tasksForSelectedStatus,
            currentUser: currentUser
        )

        // If the user has the chip strip filtered to a specific owner that
        // isn't pinned (e.g. they tapped a result in the picker without
        // pinning), surface a transient chip so the active filter is visible.
        guard !pinned.contains(where: { $0.filter.id == selectedOwnerFilter.id }),
              case .owner(let selectedOwner) = selectedOwnerFilter
        else {
            return pinned
        }

        let selectedCount = DashboardTaskListFilters.count(
            tasksForSelectedStatus,
            status: nil,
            ownerFilter: selectedOwnerFilter,
            currentUser: currentUser
        )
        return pinned + [
            DashboardTaskOwnerOption(
                filter: selectedOwnerFilter,
                label: selectedOwner,
                count: selectedCount
            )
        ]
    }

    // Computing the full search candidate list iterates every task × every
    // person in the People directory and builds normalized alias sets — on
    // a typical account that's 100–500 ms of work and used to run on every
    // popover render (and every keystroke), which made the "+" button feel
    // janky. We now compute the unfiltered base list off the main actor when
    // inputs change, cache it, and filter in-memory by the search query.
    //
    // For queries we ALSO hit the SQLite-backed RelationGraph directly via
    // `searchContacts(query:)`, because the cache only holds people the
    // dashboard loaded up-front (top 200 + stale + grouped) plus task-derived
    // owners. Anyone with a low interaction_score (e.g. an old contact you
    // haven't messaged in months) wouldn't be in either set, so we union the
    // SQL hits in to make the picker behave like an actual address-book
    // search.
    private var ownerSearchOptions: [DashboardTaskOwnerSearchOption] {
        let normalizedQuery = DashboardTaskOwnership.normalizedOwnerName(ownerSearchQuery)
        if normalizedQuery.isEmpty {
            return Array(cachedSearchBase.prefix(40))
        }
        let cacheHits = cachedSearchBase.filter { option in
            DashboardTaskOwnership
                .normalizedOwnerName(option.label)
                .contains(normalizedQuery)
        }
        guard !liveSearchHits.isEmpty else { return cacheHits }

        // Merge — cache hits first (they have task counts / archived
        // subtitles), then live SQL hits we haven't already shown.
        var seen = Set(cacheHits.map { DashboardTaskOwnership.normalizedOwnerName($0.label) })
        var merged = cacheHits
        for hit in liveSearchHits {
            let normalized = DashboardTaskOwnership.normalizedOwnerName(hit.label)
            if seen.insert(normalized).inserted {
                merged.append(hit)
            }
        }
        return merged
    }

    // Snapshot key used to rebuild the cache only when the inputs that
    // actually drive the search results change.
    private var searchSnapshotKey: Int {
        var hasher = Hasher()
        hasher.combine(tasks.count)
        hasher.combine(tasks.first?.id)
        hasher.combine(tasks.last?.id)
        hasher.combine(ownerPeople.count)
        hasher.combine(ownerPeople.first?.entityId)
        hasher.combine(ownerPeople.last?.entityId)
        hasher.combine(currentUser?.id)
        hasher.combine(pinsStore.pinnedNames)
        return hasher.finalize()
    }

    private var shouldShowTaskSkeleton: Bool {
        tasks.isEmpty && isRefreshing
    }

    private var tasksForSelectedStatus: [DashboardTask] {
        DashboardTaskListFilters.tasksForStatusFilter(tasks, statusFilter: statusFilter)
    }

    private var selectedProfileName: String? {
        if case .owner(let name) = selectedOwnerFilter {
            return name
        }
        return nil
    }

    private var openCount: Int { statusCount(.open) }
    private var doneCount: Int { statusCount(.done) }
    private var allCount: Int {
        DashboardTaskListFilters.count(
            DashboardTaskListFilters.tasksForStatusFilter(tasks, statusFilter: .all),
            status: nil,
            ownerFilter: selectedOwnerFilter,
            currentUser: currentUser
        )
    }

    var body: some View {
        Group {
            if let selectedTask {
                HStack(spacing: 0) {
                    compactList
                        .frame(minWidth: 500)

                    DashboardTaskDetail(
                        task: selectedTask,
                        evidence: evidenceByTaskId[selectedTask.id] ?? [],
                        isRefreshing: isRefreshing,
                        onUpdateStatus: onUpdateStatus,
                        onOpenChat: onOpenChat,
                        onClose: { selectedTaskId = nil }
                    )
                    .frame(width: 420)
                }
            } else {
                centeredList
            }
        }
        .task(id: searchSnapshotKey) {
            await refreshSearchCandidates()
        }
        .onChange(of: ownerSearchQuery) { _, newValue in
            scheduleLiveSearch(query: newValue)
        }
        .onChange(of: isOwnerPickerPresented) { _, presented in
            if !presented {
                ownerSearchQuery = ""
                liveSearchHits = []
                liveSearchTask?.cancel()
            }
        }
    }

    private var centeredList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                filterBar
                    .padding(.bottom, 10)
                taskRows
            }
            .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
            .padding(.top, PidgyDashboardTheme.pageTopPadding)
            .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
            .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
            .frame(maxWidth: .infinity)
        }
    }

    private var compactList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks")
                    .font(PidgyDashboardTheme.titleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Spacer()
                Text("\(filteredTasks.count) shown")
                    .font(PidgyDashboardTheme.metadataFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 12)

            filterBar
                .padding(.horizontal, 28)
                .padding(.bottom, 10)

            ScrollView {
                taskRows
                    .padding(.horizontal, 14)
                    .padding(.bottom, 28)
            }
        }
        .background(PidgyDashboardTheme.paper)
    }

    private var header: some View {
        // Page-internal Refresh button removed — the global top-bar
        // Refresh (with the "Updated Xm ago" stamp) is the only entry
        // point now. Single-button refresh model per UX spec.
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .tracking(-0.6)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(aiConfigured ? "\(filteredTasks.count) matching tasks" : "Connect AI to extract tasks")
                    .font(PidgyDashboardTheme.pageSubtitleFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 14)
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DashboardStatusSegments(
                    selection: $statusFilter,
                    openCount: openCount,
                    doneCount: doneCount,
                    allCount: allCount
                )
            }

            ownerChips
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ownerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ownerOptions) { option in
                    Button {
                        selectedOwnerFilter = option.filter
                    } label: {
                        HStack(spacing: 6) {
                            Text(option.label)
                            Text("\(option.count)")
                                .foregroundStyle(isOwnerSelected(option) ? PidgyDashboardTheme.secondary : PidgyDashboardTheme.tertiary)
                        }
                        .font(PidgyDashboardTheme.metadataMediumFont)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .foregroundStyle(isOwnerSelected(option) ? PidgyDashboardTheme.primary : PidgyDashboardTheme.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isOwnerSelected(option) ? Color.Pidgy.bg4 : PidgyDashboardTheme.raised.opacity(0.55))
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if case .owner(let name) = option.filter {
                            Button(role: .destructive) {
                                removePinned(name: name)
                            } label: {
                                Label("Remove from filter", systemImage: "minus.circle")
                            }
                        }
                    }
                }

                Button {
                    isOwnerPickerPresented.toggle()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PidgyDashboardTheme.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(PidgyDashboardTheme.raised.opacity(0.55))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(PidgyDashboardTheme.rule)
                        )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isOwnerPickerPresented, arrowEdge: .bottom) {
                    ownerPickerPopover
                }
            }
        }
    }

    private var ownerPickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSearchField(
                placeholder: "Add a person to filter",
                text: $ownerSearchQuery,
                size: .compact
            )

            ScrollView {
                LazyVStack(spacing: 2) {
                    if ownerSearchOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ownerSearchQuery.isEmpty ? "No suggestions yet" : "No matches")
                                .font(PidgyDashboardTheme.metadataMediumFont)
                                .foregroundStyle(PidgyDashboardTheme.primary)
                            Text(ownerSearchQuery.isEmpty ? "Try after People finishes loading." : "Try another name from your Telegram contacts.")
                                .font(PidgyDashboardTheme.captionFont)
                                .foregroundStyle(PidgyDashboardTheme.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14)
                    } else {
                        ForEach(ownerSearchOptions) { option in
                            Button {
                                pinAndSelect(option: option)
                            } label: {
                                HStack(spacing: 9) {
                                    DashboardInitialsAvatar(label: option.label, size: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(option.label)
                                            .font(PidgyDashboardTheme.metadataMediumFont)
                                            .foregroundStyle(PidgyDashboardTheme.primary)
                                            .lineLimit(1)
                                        if let subtitle = option.subtitle, !subtitle.isEmpty {
                                            Text(subtitle)
                                                .font(PidgyDashboardTheme.captionFont)
                                                .foregroundStyle(PidgyDashboardTheme.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if option.count > 0 {
                                        Text("\(option.count)")
                                            .font(PidgyDashboardTheme.monoCaptionFont)
                                            .foregroundStyle(PidgyDashboardTheme.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(PidgyDashboardTheme.raised.opacity(0.001))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(12)
        .frame(width: 300)
        .background(PidgyDashboardTheme.paper)
    }

    // Pick the most specific reason the filtered list is empty. If the
    // user has actively chosen an owner/profile chip, that's the answer
    // — even when AI is off — otherwise selecting "Rajanshee Singh 0"
    // silently shows "AI task extraction is off" while other owners
    // have plenty of tasks, which looks like the whole feature is
    // broken.
    private func emptyStateContent() -> (image: String, title: String, subtitle: String) {
        if let profileName = selectedProfileName {
            return (
                "tray",
                "No tasks for \(profileName)",
                aiConfigured
                    ? "Try Open, Done, or another profile."
                    : "Connect an AI provider in Settings to surface more."
            )
        }
        if aiConfigured {
            return (
                "tray",
                "No tasks match",
                "Change a filter or refresh after recent sync catches up."
            )
        }
        return (
            "sparkles",
            "AI task extraction is off",
            "Connect an AI provider in Settings to populate this page."
        )
    }

    private var emptyStateView: some View {
        let content = emptyStateContent()
        return DashboardEmptyState(
            systemImage: content.image,
            title: content.title,
            subtitle: content.subtitle
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private var taskRows: some View {
        VStack(spacing: 0) {
            if shouldShowTaskSkeleton {
                DashboardSkeletonRows(count: selectedTask == nil ? 9 : 7)
                    .padding(.top, 6)
            } else if filteredTasks.isEmpty {
                emptyStateView
            } else {
                ForEach(filteredTasks) { task in
                    Button {
                        selectedTaskId = task.id
                    } label: {
                        DashboardTaskRow(
                            task: task,
                            isSelected: selectedTaskId == task.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // Bad extraction (wrong owner, not a task,
                        // duplicate…) → feedback sheet with the task
                        // context as a removable attachment, plus a
                        // local eval fixture. See FlaggedAnswerFixture.
                        Button("Flag this task…", systemImage: "flag") {
                            flagTask(task)
                        }
                    }
                }
            }
        }
    }

    private func flagTask(_ task: DashboardTask) {
        FlaggedAnswerFixture
            .task(task, evidence: evidenceByTaskId[task.id] ?? [])
            .submitToFeedbackSheet()
    }

    private func statusCount(_ status: DashboardTaskStatus) -> Int {
        DashboardTaskListFilters.count(
            tasks,
            status: status,
            ownerFilter: selectedOwnerFilter,
            currentUser: currentUser
        )
    }

    private func isOwnerSelected(_ option: DashboardTaskOwnerOption) -> Bool {
        selectedOwnerFilter.id == option.filter.id
    }

    private func pinAndSelect(option: DashboardTaskOwnerSearchOption) {
        if case .owner(let name) = option.filter {
            pinsStore.pin(name)
        }
        selectedOwnerFilter = option.filter
        ownerSearchQuery = ""
        isOwnerPickerPresented = false
    }

    private func removePinned(name: String) {
        pinsStore.unpin(name)
        if case .owner(let selected) = selectedOwnerFilter,
           DashboardTaskOwnership.normalizedOwnerName(selected) ==
            DashboardTaskOwnership.normalizedOwnerName(name) {
            selectedOwnerFilter = .mine
        }
    }

    private func scheduleLiveSearch(query: String) {
        liveSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            liveSearchHits = []
            return
        }
        let visibleSnapshot = ownerOptions
        let user = currentUser
        liveSearchTask = Task { @MainActor in
            // Tiny debounce so we don't fire SQL on every keystroke.
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }

            let nodes = await RelationGraph.shared.searchContacts(query: trimmed, limit: 80)
            if Task.isCancelled { return }

            let visibleIds = Set(visibleSnapshot.map(\.id))
            let mineAliases = Set(visibleSnapshot
                .compactMap { option -> String? in
                    if case .mine = option.filter { return option.label } else { return nil }
                })

            liveSearchHits = nodes.compactMap { node -> DashboardTaskOwnerSearchOption? in
                let display = node.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let username = node.username?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = [display, username].compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }.first
                guard let label else { return nil }
                guard DashboardTaskOwnership.isKnownOwner(label) else { return nil }
                guard !DashboardTaskOwnership.isMine(ownerName: label, currentUser: user) else { return nil }
                guard !mineAliases.contains(where: { $0 == label }) else { return nil }
                guard !visibleIds.contains(DashboardTaskOwnerFilter.owner(label).id) else { return nil }

                let subtitle = username.flatMap { username -> String? in
                    guard !username.isEmpty, username != display else { return nil }
                    return "@\(username)"
                }
                return DashboardTaskOwnerSearchOption(
                    filter: .owner(label),
                    label: label,
                    count: 0,
                    subtitle: subtitle
                )
            }
        }
    }

    private func refreshSearchCandidates() async {
        let visibleOptions = ownerOptions
        let allTasks = tasks
        let people = ownerPeople
        let user = currentUser

        let computed = await Task.detached(priority: .userInitiated) {
            DashboardTaskListFilters.ownerSearchOptions(
                visibleOptions: visibleOptions,
                allTasks: allTasks,
                people: people,
                currentUser: user,
                query: "",
                limit: .max
            )
        }.value

        guard !Task.isCancelled else { return }
        cachedSearchBase = computed
    }
}
