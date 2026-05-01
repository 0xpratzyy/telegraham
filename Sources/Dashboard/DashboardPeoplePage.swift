import SwiftUI

struct DashboardPeoplePage: View {
    let topContacts: [RelationGraph.Node]
    let staleContacts: [RelationGraph.Node]
    let allContacts: [RelationGraph.Node]
    let tasks: [DashboardTask]
    let followUpItems: [FollowUpItem]
    @Binding var selectedPersonId: Int64?
    let onOpenTask: (DashboardTask) -> Void
    let onOpenChat: (TGChat) -> Void

    @State private var filter: DashboardPeopleLens = .needsYou
    @State private var personQuery = ""
    @State private var signalSnapshot: [DashboardPersonSignal] = []
    @State private var filteredSignalSnapshot: [DashboardPersonSignal] = []
    @State private var isBuildingSignals = false
    @State private var renderLimit = DashboardPeopleRenderWindow.defaultPageSize

    private var baseContacts: [RelationGraph.Node] {
        uniqueContacts(allContacts + topContacts + staleContacts)
    }

    private var visibleSignals: [DashboardPersonSignal] {
        filteredSignalSnapshot
    }

    private var selectedSignal: DashboardPersonSignal? {
        selectedPersonId.flatMap { id in signalSnapshot.first(where: { $0.contact.entityId == id }) }
    }

    private var renderedSignals: [DashboardPersonSignal] {
        renderWindow.visibleSignals(from: visibleSignals)
    }

    private var renderWindow: DashboardPeopleRenderWindow {
        DashboardPeopleRenderWindow(
            pageSize: DashboardPeopleRenderWindow.defaultPageSize,
            loadedCount: renderLimit
        )
    }

    private var hasMoreSignals: Bool {
        !renderWindow.hasLoadedAll(totalCount: visibleSignals.count)
    }

    private var peopleInputSignature: String {
        let contactIds = baseContacts.prefix(50).map(\.entityId).map(String.init).joined(separator: ",")
        let staleIds = staleContacts.prefix(50).map(\.entityId).map(String.init).joined(separator: ",")
        let taskVersion = tasks
            .map { "\($0.id):\($0.status.rawValue):\($0.updatedAt.timeIntervalSince1970):\($0.snoozedUntil?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: "|")
        let replyVersion = followUpItems
            .map { "\($0.chat.id):\($0.category.rawValue):\($0.lastMessage.id)" }
            .joined(separator: "|")
        return "\(baseContacts.count)#\(contactIds)#\(staleIds)#\(taskVersion)#\(replyVersion)"
    }

    var body: some View {
        Group {
            if let selectedSignal {
                HStack(spacing: 0) {
                    peopleList
                        .frame(width: 340)

                    DashboardPersonDetail(
                        contact: selectedSignal.contact,
                        signal: selectedSignal,
                        tasks: tasksForSelectedContact,
                        followUpItems: repliesForSelectedContact,
                        onOpenTask: onOpenTask,
                        onOpenChat: onOpenChat,
                        onClose: { selectedPersonId = nil }
                    )
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        centeredHeader
                        peopleRows
                    }
                    .frame(maxWidth: PidgyDashboardTheme.pageMaxWidth, alignment: .leading)
                    .padding(.top, PidgyDashboardTheme.pageTopPadding)
                    .padding(.horizontal, PidgyDashboardTheme.pageHorizontalPadding)
                    .padding(.bottom, PidgyDashboardTheme.pageBottomPadding)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: peopleInputSignature) {
            await rebuildSignals()
        }
        .onChange(of: filter) {
            resetRenderLimit()
            applyPeopleFilter()
        }
        .onChange(of: personQuery) {
            resetRenderLimit()
            applyPeopleFilter()
        }
    }

    private var peopleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactFilterBar
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PidgyDashboardTheme.rule.opacity(0.7))
                    .frame(height: 1)
            }

            ScrollView {
                peopleRows
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }
        }
        .background(PidgyDashboardTheme.paper)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PidgyDashboardTheme.rule)
                .frame(width: 1)
        }
    }

    private var centeredHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("People")
                    .font(PidgyDashboardTheme.pageTitleFont)
                    .foregroundStyle(PidgyDashboardTheme.primary)
                Text(isBuildingSignals ? "loading relationships" : "\(visibleSignals.count) relationships")
                    .font(PidgyDashboardTheme.pageSubtitleFont)
                    .foregroundStyle(PidgyDashboardTheme.secondary)
                Spacer()
            }

            HStack(spacing: 12) {
                DashboardPeopleTabs(
                    selection: $filter,
                    needsCount: needsCount,
                    keyCount: keyCount,
                    coldCount: coldCount,
                    recentCount: recentCount,
                    allCount: signalSnapshot.count
                )

                Spacer(minLength: 12)

                personSearchField
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 22)
    }

    private var compactFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardPeopleTabs(
                selection: $filter,
                needsCount: needsCount,
                keyCount: keyCount,
                coldCount: coldCount,
                recentCount: recentCount,
                allCount: signalSnapshot.count
            )
            personSearchField
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var personSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(PidgyDashboardTheme.captionMediumFont)
                .foregroundStyle(PidgyDashboardTheme.secondary)
            TextField("Search people", text: $personQuery)
                .font(PidgyDashboardTheme.metadataFont)
                .textFieldStyle(.plain)
        }
        .frame(width: 160, height: 28)
        .padding(.horizontal, 9)
        .background(DashboardCapsuleBackground())
    }

    private var peopleRows: some View {
        LazyVStack(spacing: 0) {
            if isBuildingSignals && signalSnapshot.isEmpty {
                DashboardSkeletonRows(count: 10, showTimestamp: false)
                    .padding(.top, 6)
            } else if visibleSignals.isEmpty {
                DashboardEmptyState(
                    systemImage: "person.2",
                    title: "No people here yet",
                    subtitle: "People context appears after recent chats are indexed."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 36)
            } else {
                ForEach(renderedSignals) { signal in
                    Button {
                        selectedPersonId = signal.contact.entityId
                    } label: {
                        DashboardPersonRow(
                            signal: signal,
                            isSelected: selectedPersonId == signal.contact.entityId
                        )
                    }
                    .buttonStyle(.plain)
                }

                if hasMoreSignals {
                    DashboardSkeletonRows(count: 2, showTimestamp: false)
                        .padding(.vertical, 6)
                    .onAppear(perform: loadMoreSignals)
                }
            }
        }
    }

    private var tasksForSelectedContact: [DashboardTask] {
        guard let selectedSignal else { return [] }
        return tasks(for: selectedSignal.contact)
    }

    private var repliesForSelectedContact: [FollowUpItem] {
        guard let selectedSignal else { return [] }
        return replies(for: selectedSignal.contact)
    }

    private var needsCount: Int {
        signalSnapshot.filter(\.needsAttention).count
    }

    private var keyCount: Int {
        signalSnapshot.count
    }

    private var coldCount: Int {
        signalSnapshot.filter(\.stale).count
    }

    private var recentCount: Int {
        signalSnapshot.filter { $0.latestActivityAt != nil }.count
    }

    private func tasks(for contact: RelationGraph.Node) -> [DashboardTask] {
        return tasks.filter { task in
            task.isActionableNow
                && (
                    matches(contact, text: task.personName)
                        || matches(contact, text: task.ownerName)
                        || matches(contact, text: task.chatTitle)
                )
        }
    }

    private func replies(for contact: RelationGraph.Node) -> [FollowUpItem] {
        followUpItems.filter { item in
            guard item.category == .onMe else { return false }
            switch item.chat.chatType {
            case .privateChat(let userId):
                if userId == contact.entityId { return true }
            default:
                break
            }
            return matches(contact, text: item.chat.title)
                || matches(contact, text: item.lastMessage.senderName)
        }
    }

    private func uniqueContacts(_ contacts: [RelationGraph.Node]) -> [RelationGraph.Node] {
        var seen = Set<Int64>()
        return contacts.filter { seen.insert($0.entityId).inserted }
    }

    private func matches(_ contact: RelationGraph.Node, text: String?) -> Bool {
        guard let text else { return false }
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedText.isEmpty else { return false }
        return searchTerms(for: contact).contains { term in
            normalizedText == term || (term.count >= 3 && normalizedText.contains(term))
        }
    }

    private func searchTerms(for contact: RelationGraph.Node) -> [String] {
        var terms: [String] = []
        for value in [contact.bestDisplayName, contact.displayName, contact.username] {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else { continue }
            terms.append(trimmed)
            if let first = trimmed.split(separator: " ").first, first.count >= 3 {
                terms.append(String(first))
            }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    private func resetRenderLimit() {
        renderLimit = DashboardPeopleRenderWindow.defaultPageSize
    }

    private func loadMoreSignals() {
        renderLimit = renderWindow.nextLoadedCount(totalCount: visibleSignals.count)
    }

    private func applyPeopleFilter() {
        filteredSignalSnapshot = filteredPeopleSignals(from: signalSnapshot)
    }

    private func filteredPeopleSignals(from signals: [DashboardPersonSignal]) -> [DashboardPersonSignal] {
        let lensSignals = DashboardPeopleDirectory.filtered(signals, lens: filter)
        let query = personQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return lensSignals
        }
        return lensSignals.filter { signal in
            let contact = signal.contact
            return contact.bestDisplayName.lowercased().contains(query)
                || (contact.username?.lowercased().contains(query) ?? false)
                || contact.category.lowercased().contains(query)
        }
    }

    private func rebuildSignals() async {
        let contacts = baseContacts
        let tasks = tasks
        let followUpItems = followUpItems
        let staleContactIds = Set(staleContacts.map(\.entityId))

        isBuildingSignals = true
        resetRenderLimit()

        let builtSignals = await Task.detached(priority: .userInitiated) {
            DashboardPeopleDirectory.buildSignals(
                contacts: contacts,
                tasks: tasks,
                followUpItems: followUpItems,
                staleContactIds: staleContactIds
            )
        }.value

        guard !Task.isCancelled else { return }
        signalSnapshot = builtSignals
        filteredSignalSnapshot = filteredPeopleSignals(from: builtSignals)
        if let selectedPersonId, !builtSignals.contains(where: { $0.contact.entityId == selectedPersonId }) {
            self.selectedPersonId = nil
        }
        isBuildingSignals = false
    }
}
