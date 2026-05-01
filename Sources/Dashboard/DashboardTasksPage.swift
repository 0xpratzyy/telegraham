import SwiftUI

struct DashboardTasksPage: View {
    let tasks: [DashboardTask]
    let evidenceByTaskId: [Int64: [DashboardTaskSourceMessage]]
    let ownerPeople: [RelationGraph.Node]
    let currentUser: TGUser?
    let isRefreshing: Bool
    let aiConfigured: Bool
    @Binding var selectedTaskId: Int64?
    let onRefresh: () -> Void
    let onUpdateStatus: (DashboardTask, DashboardTaskStatus, Date?) -> Void
    let onOpenChat: (Int64) -> Void

    @State private var statusFilter: DashboardStatusFilter = .open
    @State private var selectedOwnerFilter: DashboardTaskOwnerFilter = .mine
    @State private var isOwnerPickerPresented = false
    @State private var ownerSearchQuery = ""

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

    private var baseOwnerOptions: [DashboardTaskOwnerOption] {
        DashboardTaskListFilters.ownerChips(
            for: tasksForSelectedStatus,
            currentUser: currentUser
        )
    }

    private var ownerOptions: [DashboardTaskOwnerOption] {
        let options = baseOwnerOptions
        guard !options.contains(where: { $0.filter.id == selectedOwnerFilter.id }),
              case .owner(let selectedOwner) = selectedOwnerFilter
        else {
            return options
        }

        let selectedCount = DashboardTaskListFilters.count(
            tasksForSelectedStatus,
            status: nil,
            ownerFilter: selectedOwnerFilter,
            currentUser: currentUser
        )
        return options + [
            DashboardTaskOwnerOption(
                filter: selectedOwnerFilter,
                label: selectedOwner,
                count: selectedCount
            )
        ]
    }

    private var ownerSearchOptions: [DashboardTaskOwnerSearchOption] {
        DashboardTaskListFilters.ownerSearchOptions(
            visibleOptions: ownerOptions,
            allTasks: tasks,
            people: ownerPeople,
            currentUser: currentUser,
            query: ownerSearchQuery
        )
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
        if let selectedTask {
            HStack(spacing: 0) {
                compactList
                    .frame(minWidth: 500)

                DashboardTaskDetail(
                    task: selectedTask,
                    evidence: evidenceByTaskId[selectedTask.id] ?? [],
                    isRefreshing: isRefreshing,
                    onRefresh: onRefresh,
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(aiConfigured ? "\(filteredTasks.count) matching tasks" : "Connect AI to extract tasks")
                    .font(PidgyDashboardTheme.pageSubtitleFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    .font(PidgyDashboardTheme.metadataMediumFont)
                    .frame(height: 30)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PidgyDashboardTheme.primary)
            .background(DashboardCapsuleBackground())
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
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(PidgyDashboardTheme.captionMediumFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                TextField("Search owner", text: $ownerSearchQuery)
                    .font(PidgyDashboardTheme.metadataFont)
                    .textFieldStyle(.plain)
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(DashboardCapsuleBackground())

            ScrollView {
                LazyVStack(spacing: 2) {
                    if ownerSearchOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ownerSearchQuery.isEmpty ? "No other owners yet" : "No owner found")
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
                                selectedOwnerFilter = option.filter
                                ownerSearchQuery = ""
                                isOwnerPickerPresented = false
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

    private var taskRows: some View {
        VStack(spacing: 0) {
            if shouldShowTaskSkeleton {
                DashboardSkeletonRows(count: selectedTask == nil ? 9 : 7)
                    .padding(.top, 6)
            } else if filteredTasks.isEmpty {
                DashboardEmptyState(
                    systemImage: aiConfigured ? "tray" : "sparkles",
                    title: aiConfigured
                        ? selectedProfileName.map { "No tasks for \($0)" } ?? "No tasks match"
                        : "AI task extraction is off",
                    subtitle: aiConfigured
                        ? (selectedProfileName == nil ? "Change a filter or refresh after recent sync catches up." : "Try Open, Done, or another profile.")
                        : "Connect an AI provider in Settings to populate this page."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
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
                }
            }
        }
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
}
