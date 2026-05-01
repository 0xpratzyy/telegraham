import XCTest
import GRDB
@testable import Pidgy

final class PidgyCoreTests: XCTestCase {
    private var tempCredentialDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        KeychainManager.configureForTesting(storageDirectoryOverride: tempDirectory)
        tempCredentialDirectory = tempDirectory
    }

    override func tearDown() async throws {
        await MessageCacheService.shared.resetInMemoryCachesForTesting()
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: nil,
            appSupportDirectoryOverride: nil
        )
        KeychainManager.configureForTesting(storageDirectoryOverride: nil)
        if let tempCredentialDirectory {
            try? FileManager.default.removeItem(at: tempCredentialDirectory)
            self.tempCredentialDirectory = nil
        }
        try await super.tearDown()
    }

    func testPidgyDesignSystemBridgeUsesBundledFontsAndSharedTokens() {
        XCTAssertEqual(PidgyFontRegistrar.fontsSubdirectory, "Fonts")
        XCTAssertEqual(
            PidgyFontRegistrar.bundledFontFilenames,
            [
                "Inter[opsz,wght].ttf",
                "Newsreader[opsz,wght].ttf",
                "JetBrainsMono[wght].ttf"
            ]
        )
        XCTAssertEqual(PidgyDashboardTheme.pageHorizontalPadding, PidgySpace.s8)
        XCTAssertEqual(PidgyDashboardTheme.rowHorizontalPadding, PidgySpace.s3)
        XCTAssertEqual(PidgyDashboardTheme.selectedRowCornerRadius, PidgyRadius.md)
    }

    func testDurableHistorySurvivesLiveUpdateAndDelete() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 42
            let olderMessages = [
                makeRecord(id: 101, chatId: chatId, text: "oldest message", daysAgo: 8),
                makeRecord(id: 102, chatId: chatId, text: "mid message", daysAgo: 7),
                makeRecord(id: 103, chatId: chatId, text: "newest indexed", daysAgo: 6)
            ]

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: olderMessages,
                preferredOldestMessageId: olderMessages.first?.id,
                isSearchReady: true
            )

            let recentMessage = makeRecord(id: 201, chatId: chatId, text: "fresh live message", daysAgo: 0)
            await DatabaseManager.shared.upsertLiveMessages(chatId: chatId, messages: [recentMessage])

            let afterLive = await DatabaseManager.shared.loadMessages(chatId: chatId, limit: 10)
            XCTAssertEqual(Set(afterLive.map(\.id)), Set([101, 102, 103, 201]))

            let syncStateAfterLive = await DatabaseManager.shared.loadSyncState(chatId: chatId)
            XCTAssertEqual(syncStateAfterLive?.lastIndexedMessageId, 101)
            XCTAssertEqual(syncStateAfterLive?.isSearchReady, true)

            let recentSyncStateAfterLive = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(recentSyncStateAfterLive?.latestSyncedMessageId, 201)

            await DatabaseManager.shared.deleteMessages(chatId: chatId, messageIds: [201])

            let afterDelete = await DatabaseManager.shared.loadMessages(chatId: chatId, limit: 10)
            XCTAssertEqual(Set(afterDelete.map(\.id)), Set([101, 102, 103]))

            let syncStateAfterDelete = await DatabaseManager.shared.loadSyncState(chatId: chatId)
            XCTAssertEqual(syncStateAfterDelete?.isSearchReady, true)

            let recentSyncStateAfterDelete = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(recentSyncStateAfterDelete?.latestSyncedMessageId, 103)
        }
    }

    func testRecentSyncStateDoesNotResetDeepIndexReadiness() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 84
            let indexedMessages = [
                makeRecord(id: 301, chatId: chatId, text: "older indexed", daysAgo: 4),
                makeRecord(id: 302, chatId: chatId, text: "latest indexed", daysAgo: 3)
            ]

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: indexedMessages,
                preferredOldestMessageId: 301,
                isSearchReady: true
            )

            let initialSyncState = await DatabaseManager.shared.loadSyncState(chatId: chatId)
            XCTAssertEqual(initialSyncState?.lastIndexedMessageId, 301)
            XCTAssertEqual(initialSyncState?.isSearchReady, true)

            let recentMessage = makeTGMessage(
                id: 401,
                chatId: chatId,
                text: "latest recent sync write",
                date: Date()
            )
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: [recentMessage], append: false)

            let syncStateAfterRecentWrite = await DatabaseManager.shared.loadSyncState(chatId: chatId)
            XCTAssertEqual(syncStateAfterRecentWrite?.lastIndexedMessageId, 301)
            XCTAssertEqual(syncStateAfterRecentWrite?.isSearchReady, true)

            let recentSyncState = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(recentSyncState?.latestSyncedMessageId, 401)
        }
    }

    func testOlderHistoryAppendDoesNotMoveRecentSyncStateBackward() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 85
            let recentMessage = makeTGMessage(
                id: 501,
                chatId: chatId,
                text: "latest recent sync write",
                date: Date()
            )
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: [recentMessage], append: false)

            let initialRecentSyncState = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(initialRecentSyncState?.latestSyncedMessageId, recentMessage.id)

            let olderMessage = makeTGMessage(
                id: 401,
                chatId: chatId,
                text: "older history expansion",
                date: Date().addingTimeInterval(-2 * 86_400)
            )
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: [olderMessage], append: true)

            let recentSyncStateAfterAppend = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(recentSyncStateAfterAppend?.latestSyncedMessageId, recentMessage.id)
        }
    }

    func testReupsertingMessagePreservesExistingEmbedding() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 86
            let message = makeRecord(
                id: 601,
                chatId: chatId,
                text: "durable searchable message",
                daysAgo: 0
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [message],
                preferredOldestMessageId: message.id,
                isSearchReady: true
            )
            try await VectorStore.shared.storeBatchThrowing([
                VectorStore.EmbeddingRecord(
                    messageId: message.id,
                    chatId: chatId,
                    vector: [0.1, 0.2, 0.3],
                    textPreview: message.textContent ?? ""
                )
            ])

            await DatabaseManager.shared.upsertLiveMessages(chatId: chatId, messages: [message])

            let count = try await embeddingCount(chatId: chatId, messageId: message.id)
            XCTAssertEqual(count, 1)
        }
    }

    func testDashboardTopicDiscoveryCapsAndPreservesStableLabels() async throws {
        try await withTempDatabase { _ in
            var discovered = (1...8).map { index in
                DashboardTopicDTO(
                    name: "Topic \(index)",
                    rationale: "Observed in chat \(index)",
                    score: Double(10 - index)
                )
            }
            discovered[1] = DashboardTopicDTO(
                name: "Airdrops",
                rationale: "Generic campaign bucket",
                score: 99
            )

            let firstPass = await DatabaseManager.shared.upsertDashboardTopics(discovered)
            XCTAssertEqual(firstPass.map(\.name), ["Airdrops", "Topic 1", "Topic 3", "Topic 4", "Topic 5", "Topic 6"])

            let secondPass = await DatabaseManager.shared.upsertDashboardTopics([
                DashboardTopicDTO(name: "Topic 1", rationale: "Newer rationale", score: 42),
                DashboardTopicDTO(name: "Inner Circle", rationale: "High-signal relationship topic", score: 41)
            ])
            let reloaded = await DatabaseManager.shared.loadDashboardTopics()

            XCTAssertEqual(secondPass.first(where: { $0.name == "Topic 1" })?.id, firstPass.first { $0.name == "Topic 1" }?.id)
            XCTAssertTrue(reloaded.contains { $0.name == "Topic 1" })
            XCTAssertEqual(Array(reloaded.prefix(2).map(\.name)), ["Topic 1", "Inner Circle"])
            XCTAssertLessThan((reloaded.firstIndex { $0.name == "Inner Circle" } ?? Int.max), (reloaded.firstIndex { $0.name == "Airdrops" } ?? Int.max))
            XCTAssertLessThanOrEqual(reloaded.count, AppConstants.Dashboard.maxTopicCount)
        }
    }

    func testManualDashboardTopicStaysPinnedAcrossDiscoveryRefresh() async throws {
        try await withTempDatabase { _ in
            let manual = await DatabaseManager.shared.addDashboardTopic(
                name: "FBI",
                rationale: "Manual workspace"
            )
            XCTAssertEqual(manual?.name, "FBI")

            _ = await DatabaseManager.shared.upsertDashboardTopics([
                DashboardTopicDTO(name: "First Dollar", rationale: "Company workspace", score: 92),
                DashboardTopicDTO(name: "Inner Circle", rationale: "Community workspace", score: 91)
            ])

            let reloaded = await DatabaseManager.shared.loadDashboardTopics()
            XCTAssertEqual(reloaded.first?.name, "FBI")
            XCTAssertTrue(reloaded.contains { $0.name == "First Dollar" })
            XCTAssertTrue(reloaded.contains { $0.name == "Inner Circle" })
        }
    }

    func testDashboardTaskUpsertPreservesManualStateAndChatScopedEvidence() async throws {
        try await withTempDatabase { _ in
            let topic = await DatabaseManager.shared.upsertDashboardTopics([
                DashboardTopicDTO(name: "First Dollar", rationale: "Revenue work", score: 1)
            ]).first
            let now = Date()

            let firstCandidate = DashboardTaskCandidate(
                stableFingerprint: "first-dollar:contract-review",
                title: "Review the contract diff",
                summary: "Akhil asked for a contract review before Friday.",
                suggestedAction: "Reply after checking the diff",
                ownerName: "Me",
                personName: "Akhil",
                chatId: 10,
                chatTitle: "Akhil",
                topicName: topic?.name,
                priority: .high,
                status: .open,
                confidence: 0.88,
                createdAt: now,
                dueAt: nil,
                sourceMessages: [
                    DashboardTaskSourceMessage(
                        chatId: 10,
                        messageId: 501,
                        senderName: "Akhil",
                        text: "Can you review the contract diff?",
                        date: now
                    )
                ]
            )

            let inserted = await DatabaseManager.shared.upsertDashboardTasks([firstCandidate])
            XCTAssertEqual(inserted.count, 1)
            let taskId = try XCTUnwrap(inserted.first?.id)

            await DatabaseManager.shared.updateDashboardTaskStatus(taskId: taskId, status: .done)

            let refreshedCandidate = DashboardTaskCandidate(
                stableFingerprint: "first-dollar:contract-review",
                title: "Review the contract diff today",
                summary: "Akhil nudged the contract review.",
                suggestedAction: "Send reviewed notes",
                ownerName: "Me",
                personName: "Akhil",
                chatId: 10,
                chatTitle: "Akhil",
                topicName: topic?.name,
                priority: .medium,
                status: .open,
                confidence: 0.92,
                createdAt: now.addingTimeInterval(60),
                dueAt: nil,
                sourceMessages: firstCandidate.sourceMessages
            )

            let refreshed = await DatabaseManager.shared.upsertDashboardTasks([refreshedCandidate])
            XCTAssertEqual(refreshed.first?.id, taskId)
            XCTAssertEqual(refreshed.first?.status, .done)
            XCTAssertEqual(refreshed.first?.title, "Review the contract diff today")

            let secondChatCandidate = DashboardTaskCandidate(
                stableFingerprint: "inner-circle:call-notes",
                title: "Send call notes",
                summary: "Priya asked for call notes.",
                suggestedAction: "Share notes in the thread",
                ownerName: "Me",
                personName: "Priya",
                chatId: 11,
                chatTitle: "Priya",
                topicName: "Inner Circle",
                priority: .low,
                status: .open,
                confidence: 0.71,
                createdAt: now,
                dueAt: nil,
                sourceMessages: [
                    DashboardTaskSourceMessage(
                        chatId: 11,
                        messageId: 501,
                        senderName: "Priya",
                        text: "Can you send the call notes?",
                        date: now
                    )
                ]
            )

            _ = await DatabaseManager.shared.upsertDashboardTasks([secondChatCandidate])
            let allTasks = await DatabaseManager.shared.loadDashboardTasks()
            let allEvidence = await DatabaseManager.shared.loadDashboardTaskEvidence(taskIds: allTasks.map(\.id))

            XCTAssertEqual(allTasks.count, 2)
            XCTAssertTrue(allEvidence.values.flatMap { $0 }.contains { $0.chatId == 10 && $0.messageId == 501 })
            XCTAssertTrue(allEvidence.values.flatMap { $0 }.contains { $0.chatId == 11 && $0.messageId == 501 })
        }
    }

    func testDashboardTaskFilterMatchesStatusTopicChatAndPerson() {
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "Review grant ask",
                status: .open,
                topicId: 10,
                topicName: "First Dollar",
                chatId: 100,
                personName: "Akhil"
            ),
            DashboardTask.mock(
                id: 2,
                title: "Send intro",
                status: .done,
                topicId: 11,
                topicName: "Inner Circle",
                chatId: 101,
                personName: "Priya"
            )
        ]

        let filtered = DashboardTaskFilter.apply(
            tasks,
            status: .open,
            topicId: 10,
            chatId: 100,
            personQuery: "akh"
        )

        XCTAssertEqual(filtered.map(\.id), [1])
    }

    func testDashboardTaskFilterBuildsOwnerChipsAndFiltersAssignedWork() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "Send pitch deck",
                status: .open,
                topicId: 10,
                topicName: "First Dollar",
                chatId: 100,
                personName: "Rahul",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 2,
                title: "Post rev-share announcement",
                status: .open,
                topicId: 10,
                topicName: "Based Games",
                chatId: 101,
                personName: "Rajanshee",
                ownerName: "Rajanshee"
            ),
            DashboardTask.mock(
                id: 3,
                title: "Share campaign plans",
                status: .open,
                topicId: 10,
                topicName: "Based Games",
                chatId: 102,
                personName: "Rajanshee",
                ownerName: "Rajanshee"
            )
        ]

        let mine = DashboardTaskFilter.apply(
            tasks,
            status: .open,
            ownerFilter: .mine,
            currentUser: currentUser
        )
        XCTAssertEqual(mine.map(\.id), [1])

        let rajanshee = DashboardTaskFilter.apply(
            tasks,
            status: .open,
            ownerFilter: .owner("Rajanshee"),
            currentUser: currentUser
        )
        XCTAssertEqual(rajanshee.map(\.id), [3, 2])

        let options = DashboardTaskOwnership.ownerOptions(
            for: tasks,
            currentUser: currentUser
        )
        XCTAssertEqual(options.map(\.label), ["Mine", "Rajanshee", "All"])
        XCTAssertEqual(options.map(\.count), [1, 2, 3])
    }

    func testDashboardTaskListFiltersUseOwnerNameForChipsAndCounts() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "Send pitch deck",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 100,
                personName: "Rajanshee",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 2,
                title: "Post announcement",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 101,
                personName: "Rajanshee",
                ownerName: "Rajanshee"
            ),
            DashboardTask.mock(
                id: 3,
                title: "Share campaign plans",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 102,
                personName: "Pratyush",
                ownerName: "Rajanshee"
            ),
            DashboardTask.mock(
                id: 4,
                title: "Closed work",
                status: .done,
                topicId: nil,
                topicName: nil,
                chatId: 103,
                personName: "Rajanshee",
                ownerName: "Me"
            )
        ]

        let forMeOpen = DashboardTaskListFilters.filteredTasks(
            tasks,
            status: .open,
            ownerFilter: .mine,
            currentUser: currentUser
        )
        XCTAssertEqual(forMeOpen.map(\.id), [1])

        let rajansheeOpen = DashboardTaskListFilters.filteredTasks(
            tasks,
            status: .open,
            ownerFilter: .owner("Rajanshee"),
            currentUser: currentUser
        )
        XCTAssertEqual(rajansheeOpen.map(\.id), [3, 2, 1])

        let chips = DashboardTaskListFilters.ownerChips(
            for: tasks.filter { $0.status == .open },
            currentUser: currentUser
        )
        XCTAssertEqual(chips.map(\.label), ["For me", "Rajanshee"])
        XCTAssertEqual(chips.map(\.count), [1, 2])
    }

    func testDashboardTaskAllFilterExcludesIgnoredArchiveRows() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(id: 1, title: "Open me", status: .open, topicId: nil, topicName: nil, chatId: 1, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 2, title: "Done me", status: .done, topicId: nil, topicName: nil, chatId: 2, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 3, title: "Ignored me", status: .ignored, topicId: nil, topicName: nil, chatId: 3, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 4, title: "Open Rajanshee", status: .open, topicId: nil, topicName: nil, chatId: 4, personName: "Rajanshee", ownerName: "Rajanshee")
        ]

        let visibleAll = DashboardTaskListFilters.tasksForStatusFilter(tasks, statusFilter: .all)
        XCTAssertEqual(visibleAll.map(\.id), [1, 2, 4])

        let forMeAll = DashboardTaskListFilters.filteredTasks(
            visibleAll,
            status: nil,
            ownerFilter: .mine,
            currentUser: currentUser
        )
        XCTAssertEqual(forMeAll.map(\.id), [2, 1])

        let chips = DashboardTaskListFilters.ownerChips(
            for: visibleAll,
            currentUser: currentUser
        )
        XCTAssertEqual(chips.map(\.label), ["For me", "Rajanshee"])
        XCTAssertEqual(chips.map(\.count), [2, 1])
    }

    func testDashboardTaskOwnerAddOptionsIncludeKnownHiddenOwners() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(id: 1, title: "Open me", status: .open, topicId: nil, topicName: nil, chatId: 1, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 2, title: "Done me", status: .done, topicId: nil, topicName: nil, chatId: 2, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 3, title: "Archived Rajanshee", status: .ignored, topicId: nil, topicName: nil, chatId: 3, personName: "Rajanshee", ownerName: "Rajanshee Singh"),
            DashboardTask.mock(id: 4, title: "Archived Rajanshee 2", status: .ignored, topicId: nil, topicName: nil, chatId: 4, personName: "Rajanshee", ownerName: "Rajanshee Singh"),
            DashboardTask.mock(id: 5, title: "Archived Mayur", status: .ignored, topicId: nil, topicName: nil, chatId: 5, personName: "Mayur", ownerName: "Mayur")
        ]

        let visibleOptions = DashboardTaskListFilters.ownerChips(
            for: tasks.filter { $0.status == .open },
            currentUser: currentUser
        )
        XCTAssertEqual(visibleOptions.map(\.label), ["For me"])

        let addOptions = DashboardTaskListFilters.ownerAddOptions(
            visibleOptions: visibleOptions,
            allTasks: tasks,
            currentUser: currentUser
        )
        XCTAssertEqual(addOptions.map(\.label), ["Rajanshee Singh", "Mayur"])
        XCTAssertEqual(addOptions.map(\.count), [2, 1])
    }

    func testDashboardTaskOwnerSearchOptionsIncludePeopleDirectoryMatches() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(id: 1, title: "Open me", status: .open, topicId: nil, topicName: nil, chatId: 1, personName: "Pratyush", ownerName: "Me"),
            DashboardTask.mock(id: 2, title: "Archived Rajanshee", status: .ignored, topicId: nil, topicName: nil, chatId: 2, personName: "Rajanshee", ownerName: "Rajanshee Singh"),
            DashboardTask.mock(id: 3, title: "Archived Rajanshee 2", status: .ignored, topicId: nil, topicName: nil, chatId: 3, personName: "Rajanshee", ownerName: "Rajanshee Singh")
        ]
        let people = [
            RelationGraph.Node.mock(entityId: 10, displayName: "Deeeeeksha", interactionScore: 600, lastInteractionAt: nil),
            RelationGraph.Node.mock(entityId: 11, displayName: "Akhil", interactionScore: 500, lastInteractionAt: nil),
            RelationGraph.Node.mock(entityId: 12, displayName: "Rajanshee Singh", interactionScore: 100, lastInteractionAt: nil)
        ]
        let visibleOptions = DashboardTaskListFilters.ownerChips(
            for: tasks.filter { $0.status == .open },
            currentUser: currentUser
        )

        let allOptions = DashboardTaskListFilters.ownerSearchOptions(
            visibleOptions: visibleOptions,
            allTasks: tasks,
            people: people,
            currentUser: currentUser,
            query: ""
        )
        XCTAssertEqual(Array(allOptions.map(\.label).prefix(3)), ["Rajanshee Singh", "Deeeeeksha", "Akhil"])

        let searchedOptions = DashboardTaskListFilters.ownerSearchOptions(
            visibleOptions: visibleOptions,
            allTasks: tasks,
            people: people,
            currentUser: currentUser,
            query: "dee"
        )
        XCTAssertEqual(searchedOptions.map(\.label), ["Deeeeeksha"])
    }

    func testDashboardReplyQueueCountIncludesEveryPipelineCategory() {
        let chats = [
            makeChat(id: 51_001, title: "On me", chatType: .privateChat(userId: 51_101), unreadCount: 1, lastMessageDate: Date()),
            makeChat(id: 51_002, title: "On them", chatType: .privateChat(userId: 51_102), unreadCount: 1, lastMessageDate: Date().addingTimeInterval(-60)),
            makeChat(id: 51_003, title: "Quiet", chatType: .privateChat(userId: 51_103), unreadCount: 1, lastMessageDate: Date().addingTimeInterval(-120))
        ]
        let categories: [FollowUpItem.Category] = [.onMe, .onThem, .quiet]
        let items = zip(chats, categories).compactMap { chat, category -> FollowUpItem? in
            guard let lastMessage = chat.lastMessage else { return nil }
            return FollowUpItem(
                chat: chat,
                category: category,
                lastMessage: lastMessage,
                timeSinceLastActivity: Date().timeIntervalSince(lastMessage.date),
                suggestedAction: nil
            )
        }

        XCTAssertEqual(DashboardReplyQueueMetrics.sidebarCount(for: items), 3)
    }

    func testDashboardTaskProfileFilterMatchesPersonAliasesFromPeopleSearch() {
        let currentUser = TGUser(
            id: 99,
            firstName: "Pratyush",
            lastName: "",
            username: "pratzyy",
            phoneNumber: nil,
            isBot: false
        )
        let tasks = [
            DashboardTask.mock(id: 1, title: "Follow up with Rajanshee", status: .open, topicId: nil, topicName: nil, chatId: 1, personName: "Rajanshee", ownerName: "Me"),
            DashboardTask.mock(id: 2, title: "Closed Rajanshee work", status: .done, topicId: nil, topicName: nil, chatId: 2, personName: "Rajanshee", ownerName: "Me"),
            DashboardTask.mock(id: 3, title: "Ask Deeeeeksha", status: .open, topicId: nil, topicName: nil, chatId: 3, personName: "Deeeeeksha", ownerName: "Me")
        ]
        let people = [
            RelationGraph.Node.mock(entityId: 10, displayName: "Rajanshee Singh", interactionScore: 700, lastInteractionAt: nil),
            RelationGraph.Node.mock(entityId: 11, displayName: "Deeeeeksha", interactionScore: 600, lastInteractionAt: nil)
        ]
        let visibleOptions = DashboardTaskListFilters.ownerChips(
            for: tasks.filter { $0.status == .open },
            currentUser: currentUser
        )

        let searchOptions = DashboardTaskListFilters.ownerSearchOptions(
            visibleOptions: visibleOptions,
            allTasks: tasks,
            people: people,
            currentUser: currentUser,
            query: "rajan"
        )
        XCTAssertEqual(searchOptions.first?.label, "Rajanshee Singh")
        XCTAssertEqual(searchOptions.first?.count, 2)

        let rajansheeOpen = DashboardTaskListFilters.filteredTasks(
            tasks.filter { $0.status == .open },
            status: nil,
            ownerFilter: .owner("Rajanshee Singh"),
            currentUser: currentUser
        )
        XCTAssertEqual(rajansheeOpen.map(\.id), [1])
    }

    func testDashboardTaskPeopleOptionsShowTwoTaskPeopleSortedByCount() {
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "A",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 101,
                personName: "Rajanshee",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 2,
                title: "B",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 102,
                personName: "Deeeeeksha",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 3,
                title: "C",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 103,
                personName: "Rajanshee",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 4,
                title: "D",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 104,
                personName: "Akhil",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 5,
                title: "E",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 105,
                personName: "Deeeeeksha",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 6,
                title: "F",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 106,
                personName: "Akhil",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 7,
                title: "G",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 107,
                personName: "Akhil",
                ownerName: "Me"
            ),
            DashboardTask.mock(
                id: 8,
                title: "H",
                status: .open,
                topicId: nil,
                topicName: nil,
                chatId: 108,
                personName: "One-off",
                ownerName: "Me"
            )
        ]

        let options = DashboardTaskPeople.personOptions(for: tasks)

        XCTAssertEqual(options.map { $0.name }, ["Akhil", "Deeeeeksha", "Rajanshee"])
        XCTAssertEqual(options.map { $0.count }, [3, 2, 2])
    }

    func testDashboardTaskFilterSortsNewestActivityBeforePriority() {
        let base = Date(timeIntervalSince1970: 1_777_400_000)
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "Older high priority",
                status: .open,
                topicId: 10,
                topicName: "Ops",
                chatId: 100,
                personName: "Akhil",
                priority: .high,
                latestSourceDate: base.addingTimeInterval(-3_600)
            ),
            DashboardTask.mock(
                id: 2,
                title: "Newer medium priority",
                status: .open,
                topicId: 10,
                topicName: "Ops",
                chatId: 101,
                personName: "Rahul",
                priority: .medium,
                latestSourceDate: base
            )
        ]

        let filtered = DashboardTaskFilter.apply(tasks, status: .open)

        XCTAssertEqual(filtered.map(\.id), [2, 1])
    }

    func testDashboardPeopleDirectoryBuildsOperatorLenses() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let akhil = RelationGraph.Node.mock(
            entityId: 1,
            displayName: "Akhil",
            interactionScore: 95,
            lastInteractionAt: now.addingTimeInterval(-3_600)
        )
        let rahul = RelationGraph.Node.mock(
            entityId: 2,
            displayName: "Rahul",
            interactionScore: 80,
            lastInteractionAt: now.addingTimeInterval(-2 * 86_400)
        )
        let stale = RelationGraph.Node.mock(
            entityId: 3,
            displayName: "Priya",
            interactionScore: 70,
            lastInteractionAt: now.addingTimeInterval(-40 * 86_400)
        )

        let signals = DashboardPeopleDirectory.buildSignals(
            contacts: [stale, rahul, akhil],
            replyCountsByPersonId: [2: 1],
            taskCountsByPersonId: [1: 2],
            staleContactIds: [3],
            now: now
        )

        XCTAssertEqual(
            DashboardPeopleDirectory.filtered(signals, lens: .needsYou).map(\.contact.entityId),
            [1, 2]
        )
        XCTAssertEqual(
            DashboardPeopleDirectory.filtered(signals, lens: .goingCold).map(\.contact.entityId),
            [3]
        )
        XCTAssertEqual(
            DashboardPeopleDirectory.filtered(signals, lens: .recent).map(\.contact.entityId),
            [1, 2, 3]
        )
    }

    func testDashboardPeopleDirectoryBuildsSignalsFromTasksAndReplyQueueWork() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let akhil = RelationGraph.Node.mock(
            entityId: 1,
            displayName: "Akhil",
            interactionScore: 95,
            lastInteractionAt: now.addingTimeInterval(-3_600)
        )
        let rahul = RelationGraph.Node.mock(
            entityId: 2,
            displayName: "Rahul",
            interactionScore: 80,
            lastInteractionAt: now.addingTimeInterval(-2 * 86_400)
        )
        let priya = RelationGraph.Node.mock(
            entityId: 3,
            displayName: "Priya",
            interactionScore: 60,
            lastInteractionAt: now.addingTimeInterval(-10 * 86_400)
        )

        let signals = DashboardPeopleDirectory.buildSignals(
            contacts: [akhil, rahul, priya],
            tasks: [
                DashboardTask.mock(
                    id: 1,
                    title: "Send deck",
                    status: .open,
                    topicId: nil,
                    topicName: nil,
                    chatId: 10,
                    personName: "Akhil"
                ),
                DashboardTask.mock(
                    id: 2,
                    title: "Ignored old work",
                    status: .ignored,
                    topicId: nil,
                    topicName: nil,
                    chatId: 11,
                    personName: "Priya"
                )
            ],
            followUpItems: [
                .mockPrivate(
                    chatId: 20,
                    userId: 2,
                    title: "Rahul",
                    category: .onMe,
                    senderName: "Rahul",
                    text: "Can you send the pitch deck?"
                ),
                .mockPrivate(
                    chatId: 21,
                    userId: 3,
                    title: "Priya",
                    category: .onThem,
                    senderName: "Priya",
                    text: "Waiting for them"
                )
            ],
            staleContactIds: [3],
            now: now
        )

        let signalById = Dictionary(uniqueKeysWithValues: signals.map { ($0.contact.entityId, $0) })
        XCTAssertEqual(signalById[1]?.openTaskCount, 1)
        XCTAssertEqual(signalById[2]?.openReplyCount, 1)
        XCTAssertEqual(signalById[3]?.openTaskCount, 0)
        XCTAssertEqual(signalById[3]?.openReplyCount, 0)
        XCTAssertEqual(
            DashboardPeopleDirectory.filtered(signals, lens: .needsYou).map(\.contact.entityId),
            [1, 2]
        )
    }

    func testDashboardPeopleRenderWindowPagesLargeDirectories() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let signals = (0..<125).map { index in
            DashboardPersonSignal(
                contact: RelationGraph.Node.mock(
                    entityId: Int64(index),
                    displayName: "Person \(index)",
                    interactionScore: Double(index),
                    lastInteractionAt: now
                ),
                openReplyCount: 0,
                openTaskCount: 0,
                stale: false,
                latestActivityAt: now
            )
        }

        let firstWindow = DashboardPeopleRenderWindow(pageSize: 40, loadedCount: 40)
        XCTAssertEqual(firstWindow.visibleSignals(from: signals).count, 40)
        XCTAssertFalse(firstWindow.hasLoadedAll(totalCount: signals.count))
        XCTAssertEqual(firstWindow.nextLoadedCount(totalCount: signals.count), 80)

        let lastWindow = DashboardPeopleRenderWindow(pageSize: 40, loadedCount: 120)
        XCTAssertEqual(lastWindow.nextLoadedCount(totalCount: signals.count), 125)
    }

    func testDashboardTopicMatcherBuildsSidebarItemsFromCachedSnapshots() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let pinned = DashboardTopic(
            id: 1,
            name: "Inner Circle",
            rationale: "Pinned workspace",
            score: 9_001,
            rank: 4,
            createdAt: now,
            updatedAt: now
        )
        let popular = DashboardTopic(
            id: 2,
            name: "First Dollar",
            rationale: "Company workspace",
            score: 80,
            rank: 1,
            createdAt: now,
            updatedAt: now
        )
        let tiny = DashboardTopic(
            id: 3,
            name: "Rare Thing",
            rationale: "Low signal",
            score: 70,
            rank: 2,
            createdAt: now,
            updatedAt: now
        )
        let chats = (0..<12).map { index in
            DashboardTopicMatcher.ChatSnapshot(
                id: Int64(index),
                title: "First Dollar chat \(index)",
                preview: index == 0 ? "also discussed inner circle" : nil
            )
        } + [
            DashboardTopicMatcher.ChatSnapshot(id: 100, title: "Rare Thing", preview: nil)
        ]

        let items = DashboardTopicMatcher.sidebarItems(
            topics: [tiny, popular, pinned],
            chats: chats
        )

        XCTAssertEqual(items.map(\.id), [1, 2])
        XCTAssertEqual(items.first?.chatCount, 1)
        XCTAssertTrue(items.first?.isPinned == true)
        XCTAssertEqual(items.last?.chatCount, 12)
    }

    func testDashboardTopicSemanticSearchKeepsChatScopedMessageMatches() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let first = TGMessage(
            id: 77,
            chatId: 10,
            senderId: .user(1),
            date: now,
            textContent: "Send the pitch deck to Dacoit",
            mediaType: nil,
            isOutgoing: false,
            chatTitle: "Rahul",
            senderName: "Rahul"
        )
        let second = TGMessage(
            id: 77,
            chatId: 20,
            senderId: .user(2),
            date: now.addingTimeInterval(-60),
            textContent: "Deck asks from the investor group",
            mediaType: nil,
            isOutgoing: false,
            chatTitle: "First Dollar",
            senderName: "Akhil"
        )

        let results = DashboardTopicSemanticSearchEngine.results(
            query: "pitch deck",
            mode: .search,
            topicName: "First Dollar",
            chatTitles: [10: "Rahul", 20: "First Dollar"],
            ftsHits: [.init(message: first, score: 4)],
            vectorHits: [.init(message: second, score: 0.82)],
            recentMessages: [],
            tasks: [],
            replies: [],
            limit: 10
        )

        XCTAssertEqual(Set(results.map { "\($0.chatId):\($0.messageId ?? 0)" }), ["10:77", "20:77"])
    }

    func testDashboardTopicSemanticSearchCatchUpBlendsTasksRepliesAndRecentMessages() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let reply = FollowUpItem.mockPrivate(
            chatId: 30,
            userId: 3,
            title: "Rahul",
            category: .onMe,
            senderName: "Rahul",
            text: "Can you send the deck?"
        )
        let task = DashboardTask.mock(
            id: 1,
            title: "Send Dacoit pitch deck",
            status: .open,
            topicId: 5,
            topicName: "First Dollar",
            chatId: 30,
            personName: "Rahul",
            updatedAt: now,
            latestSourceDate: now
        )
        let recent = DashboardPersonRecentMessage(
            chatId: 40,
            chatTitle: "First Dollar",
            senderName: "Akhil",
            text: "We need better deck positioning before the call.",
            date: now.addingTimeInterval(-600),
            isOutgoing: false
        )

        let results = DashboardTopicSemanticSearchEngine.results(
            query: "",
            mode: .catchUp,
            topicName: "First Dollar",
            chatTitles: [30: "Rahul", 40: "First Dollar"],
            ftsHits: [],
            vectorHits: [],
            recentMessages: [recent],
            tasks: [task],
            replies: [reply],
            limit: 10
        )

        XCTAssertTrue(results.contains { $0.source == .task && $0.title == "Send Dacoit pitch deck" })
        XCTAssertTrue(results.contains { $0.source == .reply && $0.chatId == 30 })
        XCTAssertTrue(results.contains { $0.source == .recent && $0.chatId == 40 })
    }

    func testDashboardPersonContextSummaryHighlightsOpenWorkAndRecentMessages() {
        let now = Date(timeIntervalSince1970: 1_777_400_000)
        let contact = RelationGraph.Node.mock(
            entityId: 42,
            displayName: "Rahul",
            interactionScore: 80,
            lastInteractionAt: now.addingTimeInterval(-3_600)
        )

        let summary = DashboardPersonContextSummary.make(
            contact: contact,
            openTaskCount: 1,
            openReplyCount: 1,
            messages: [
                DashboardPersonRecentMessage(
                    chatId: 10,
                    chatTitle: "Rahul Singh",
                    senderName: "Rahul",
                    text: "Can you send me the pitch deck?",
                    date: now.addingTimeInterval(-600),
                    isOutgoing: false
                ),
                DashboardPersonRecentMessage(
                    chatId: 20,
                    chatTitle: "First Dollar",
                    senderName: "Rahul",
                    text: "We should follow up on the listing.",
                    date: now.addingTimeInterval(-3_600),
                    isOutgoing: false
                )
            ],
            now: now
        )

        XCTAssertTrue(summary.headline.contains("1 reply"))
        XCTAssertTrue(summary.headline.contains("1 task"))
        XCTAssertEqual(summary.recentChatCount, 2)
        XCTAssertTrue(summary.detail.contains("pitch deck"))
        XCTAssertEqual(summary.snippets.first?.chatTitle, "Rahul Singh")
    }

    func testDashboardTaskCandidateResolvesSourceDatesFromChatScopedMessages() {
        let wrongAIDate = Date(timeIntervalSince1970: 1_777_248_840)
        let actualSourceDate = Date(timeIntervalSince1970: 1_777_402_120)
        let otherChatDate = Date(timeIntervalSince1970: 1_777_100_000)
        let candidate = DashboardTaskCandidate(
            stableFingerprint: "task",
            title: "Send Dacoit pitch deck",
            summary: "Rahul asked for the deck.",
            suggestedAction: "Send the deck.",
            ownerName: "Me",
            personName: "Rahul",
            chatId: 2014843525,
            chatTitle: "Rahul Singh Bhadoriya",
            topicName: nil,
            priority: .medium,
            status: .open,
            confidence: 0.95,
            createdAt: Date(timeIntervalSince1970: 1_777_403_000),
            dueAt: nil,
            sourceMessages: [
                DashboardTaskSourceMessage(
                    chatId: 2014843525,
                    messageId: 459099078656,
                    senderName: "Rahul",
                    text: "Bro, can you please send me te pitch deck for dacoit",
                    date: wrongAIDate
                )
            ]
        )
        let messages = [
            TGMessage(
                id: 459099078656,
                chatId: 999,
                senderId: .user(1),
                date: otherChatDate,
                textContent: "same id different chat",
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Other",
                senderName: "Other"
            ),
            TGMessage(
                id: 459099078656,
                chatId: 2014843525,
                senderId: .user(2),
                date: actualSourceDate,
                textContent: "Bro, can you please send me te pitch deck for dacoit",
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Rahul Singh Bhadoriya",
                senderName: "Rahul"
            )
        ]

        let resolved = candidate.resolvingSourceMetadata(from: messages, myUserId: 99)

        XCTAssertEqual(resolved.sourceMessages.first?.date, actualSourceDate)
    }

    func testDashboardListTimestampUsesCompactDashboardStyle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_777_405_020)
        let sameDay = Date(timeIntervalSince1970: 1_777_402_120)
        let older = Date(timeIntervalSince1970: 1_777_248_840)

        XCTAssertEqual(
            DateFormatting.dashboardListTimestamp(from: sameDay, now: now, calendar: calendar),
            "48m"
        )
        XCTAssertEqual(
            DateFormatting.dashboardListTimestamp(from: older, now: now, calendar: calendar),
            "1d"
        )
    }

    func testDashboardTaskFilterExcludesBotChatIds() {
        let tasks = [
            DashboardTask.mock(
                id: 1,
                title: "Approve bot task",
                status: .open,
                topicId: 10,
                topicName: "Payments",
                chatId: 100,
                personName: "Bot"
            ),
            DashboardTask.mock(
                id: 2,
                title: "Reply to person",
                status: .open,
                topicId: 11,
                topicName: "Partnerships",
                chatId: 101,
                personName: "Akhil"
            )
        ]

        let filtered = DashboardTaskFilter.excludingChatIds(tasks, [100])

        XCTAssertEqual(filtered.map(\.id), [2])
    }

    func testDashboardTaskRefreshPolicyScansOnlyNewMessages() {
        XCTAssertFalse(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: nil,
            syncedLatestMessageId: nil
        ))
        XCTAssertTrue(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: 20,
            syncedLatestMessageId: nil
        ))
        XCTAssertFalse(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: 20,
            syncedLatestMessageId: 20
        ))
        XCTAssertTrue(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: 20,
            syncedLatestMessageId: 20,
            forceRescan: true
        ))
        XCTAssertFalse(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: nil,
            syncedLatestMessageId: 20,
            forceRescan: true
        ))
        XCTAssertTrue(DashboardTaskRefreshPolicy.shouldScan(
            latestMessageId: 21,
            syncedLatestMessageId: 20
        ))
    }

    func testDashboardTopicAndTaskParsersAcceptEnvelopeResponses() throws {
        let topicsJSON = """
        {
          "topics": [
            {"name": "First Dollar", "rationale": "Revenue and early customers", "score": 0.91},
            {"name": "Inner Circle", "rationale": "Core collaborators", "score": 0.82}
          ]
        }
        """
        let topics = try DashboardTopicParser.parse(topicsJSON)
        XCTAssertEqual(topics.map(\.name), ["First Dollar", "Inner Circle"])

        let tasksJSON = """
        {
          "tasks": [
            {
              "stableFingerprint": "first-dollar:contract",
              "title": "Review contract",
              "summary": "Akhil asked for a contract pass.",
              "suggestedAction": "Reply with reviewed notes",
              "ownerName": "Me",
              "personName": "Akhil",
              "chatId": "10",
              "chatTitle": "Akhil",
              "topicName": "First Dollar",
              "priority": "high",
              "confidence": 0.9,
              "dueAtISO8601": null,
              "sourceMessages": [
                {
                  "chatId": "10",
                  "messageId": "501",
                  "senderName": "Akhil",
                  "text": "Can you review this?",
                  "dateISO8601": "2026-04-24T10:00:00Z"
                }
              ]
            }
          ]
        }
        """

        let tasks = try DashboardTaskParser.parse(tasksJSON)
        XCTAssertEqual(tasks.first?.chatId, 10)
        XCTAssertEqual(tasks.first?.sourceMessages.first?.chatId, 10)
        XCTAssertEqual(tasks.first?.sourceMessages.first?.messageId, 501)
    }

    func testDashboardTaskParserDoesNotDefaultMissingOwnerToMe() throws {
        let tasksJSON = """
        {
          "tasks": [
            {
              "stableFingerprint": "based-games:rev-share",
              "title": "Post rev-share announcement",
              "summary": "Someone was asked to post the announcement.",
              "suggestedAction": "Share the announcement.",
              "personName": "Rajanshee",
              "chatId": "10",
              "chatTitle": "Based Games s2 <> Inner Circle",
              "topicName": "Based Games",
              "priority": "medium",
              "confidence": 0.9,
              "dueAtISO8601": null,
              "sourceMessages": [
                {
                  "chatId": "10",
                  "messageId": "501",
                  "senderName": "Kshitij",
                  "text": "@Rajanshee can you post this in Inner Circle and RT as well?",
                  "dateISO8601": "2026-04-24T10:00:00Z"
                }
              ]
            }
          ]
        }
        """

        let tasks = try DashboardTaskParser.parse(tasksJSON)
        XCTAssertEqual(tasks.first?.ownerName, "Unknown")
    }

    func testDashboardTopicPromptPrefersCompanyWorkspacesOverGenericThemes() {
        XCTAssertTrue(
            DashboardTopicPrompt.systemPrompt.contains("company, project, fund, community, or workspace")
        )
        XCTAssertTrue(
            DashboardTopicPrompt.systemPrompt.contains("First Dollar")
        )
        XCTAssertTrue(
            DashboardTopicPrompt.systemPrompt.contains("Avoid generic buckets")
        )
    }

    func testDashboardTaskTriageParserAcceptsReplyQueueEffortAndIgnoreRoutes() throws {
        let json = """
        {
          "decisions": [
            {
              "chatId": "10",
              "route": "reply_queue",
              "confidence": 0.91,
              "reason": "Only needs a short response.",
              "supportingMessageIds": ["101"]
            },
            {
              "chatId": 11,
              "route": "effort_task",
              "confidence": 0.88,
              "reason": "Requires non-trivial follow-up work.",
              "supportingMessageIds": [201]
            },
            {
              "chatId": 12,
              "route": "ignore",
              "confidence": 0.82,
              "reason": "Assigned to someone else.",
              "supportingMessageIds": [],
              "completedTaskIds": []
            },
            {
              "chatId": 13,
              "route": "completed_task",
              "confidence": 0.9,
              "reason": "The latest reply shows the existing task was completed.",
              "supportingMessageIds": [301, 302],
              "completedTaskIds": ["42"]
            }
          ]
        }
        """

        let decisions = try DashboardTaskTriageParser.parse(json)

        XCTAssertEqual(decisions.map(\.chatId), [10, 11, 12, 13])
        XCTAssertEqual(decisions.map(\.route), [.replyQueue, .effortTask, .ignore, .completedTask])
        XCTAssertEqual(decisions[0].supportingMessageIds, [101])
        XCTAssertEqual(decisions[1].supportingMessageIds, [201])
        XCTAssertEqual(decisions[3].completedTaskIds, [42])
    }

    @MainActor
    func testTaskIndexCoordinatorRoutesReplyOnlyToReplyQueueInsteadOfTasks() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let replyChat = makeChat(
                id: 101,
                title: "Akhil",
                chatType: .privateChat(userId: 201),
                unreadCount: 1,
                lastMessageDate: now
            )
            let taskChat = makeChat(
                id: 102,
                title: "Builder Group",
                chatType: .basicGroup(groupId: 302),
                unreadCount: 1,
                lastMessageDate: now.addingTimeInterval(-60),
                memberCount: 5
            )
            let ignoredChat = makeChat(
                id: 103,
                title: "Sarv / Opengotchi",
                chatType: .basicGroup(groupId: 303),
                unreadCount: 1,
                lastMessageDate: now.addingTimeInterval(-120),
                memberCount: 4
            )

            await DatabaseManager.shared.upsertLiveMessages(
                chatId: replyChat.id,
                messages: [
                    makeRecord(id: 10101, chatId: replyChat.id, text: "Can you confirm?", date: now)
                ]
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: taskChat.id,
                messages: [
                    makeRecord(id: 10201, chatId: taskChat.id, text: "Can you prepare the partner brief?", date: now)
                ]
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: ignoredChat.id,
                messages: [
                    makeRecord(id: 10301, chatId: ignoredChat.id, text: "Sarv send UGC example selfie", date: now)
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(replyChat.id):confirm:10101",
                    title: "Confirm with Akhil",
                    summary: "Akhil asked for a quick confirmation.",
                    suggestedAction: "Reply with confirmation.",
                    ownerName: "Me",
                    personName: "Akhil",
                    chatId: replyChat.id,
                    chatTitle: replyChat.title,
                    topicName: nil,
                    priority: .medium,
                    status: .open,
                    confidence: 0.76,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: replyChat.id,
                            messageId: 10101,
                            senderName: "Tester",
                            text: "Can you confirm?",
                            date: now
                        )
                    ]
                ),
                DashboardTaskCandidate(
                    stableFingerprint: "\(ignoredChat.id):ugc-selfie:10301",
                    title: "Send UGC example selfie",
                    summary: "Sarv needs a UGC example selfie.",
                    suggestedAction: "Send Sarv a selfie.",
                    ownerName: "Me",
                    personName: "Sarv",
                    chatId: ignoredChat.id,
                    chatTitle: ignoredChat.title,
                    topicName: nil,
                    priority: .medium,
                    status: .open,
                    confidence: 0.74,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: ignoredChat.id,
                            messageId: 10301,
                            senderName: "Tester",
                            text: "Sarv send UGC example selfie",
                            date: now
                        )
                    ]
                )
            ])

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: replyChat.id,
                        route: .replyQueue,
                        confidence: 0.91,
                        reason: "Only needs a short response.",
                        supportingMessageIds: [10101]
                    ),
                    DashboardTaskTriageResultDTO(
                        chatId: taskChat.id,
                        route: .effortTask,
                        confidence: 0.88,
                        reason: "Needs real preparation.",
                        supportingMessageIds: [10201]
                    ),
                    DashboardTaskTriageResultDTO(
                        chatId: ignoredChat.id,
                        route: .ignore,
                        confidence: 0.84,
                        reason: "Assigned to Sarv.",
                        supportingMessageIds: [10301]
                    )
                ],
                tasksByChatId: [
                    taskChat.id: DashboardTaskCandidate(
                        stableFingerprint: "\(taskChat.id):partner-brief:10201",
                        title: "Prepare partner brief",
                        summary: "Builder Group asked for a partner brief.",
                        suggestedAction: "Prepare the brief before replying.",
                        ownerName: "Me",
                        personName: "Builder Group",
                        chatId: taskChat.id,
                        chatTitle: taskChat.title,
                        topicName: nil,
                        priority: .medium,
                        status: .open,
                        confidence: 0.88,
                        createdAt: now,
                        dueAt: nil,
                        sourceMessages: [
                            DashboardTaskSourceMessage(
                                chatId: taskChat.id,
                                messageId: 10201,
                                senderName: "Tester",
                                text: "Can you prepare the partner brief?",
                                date: now
                            )
                        ]
                    )
                ]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [replyChat, taskChat, ignoredChat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertEqual(openTasks.map(\.chatId), [taskChat.id])
            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(Set(ignoredTasks.map(\.chatId)), Set([replyChat.id, ignoredChat.id]))
            let extractedChatIds = await recorder.extractedChatIds()
            XCTAssertEqual(extractedChatIds, [taskChat.id])

            let replySync = await DatabaseManager.shared.loadDashboardTaskSyncState(chatId: replyChat.id)
            let ignoredSync = await DatabaseManager.shared.loadDashboardTaskSyncState(chatId: ignoredChat.id)
            XCTAssertEqual(replySync?.latestMessageId, 10101)
            XCTAssertEqual(ignoredSync?.latestMessageId, 10301)
        }
    }

    @MainActor
    func testTaskIndexCoordinatorIgnoresOpenTaskWhenTriageReturnsIgnoreWithoutMessageIds() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 104,
                title: "Banko <> First Dollar",
                chatType: .basicGroup(groupId: 304),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 4
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 10401,
                        chatId: chat.id,
                        text: "I'll send across new access codes",
                        date: now
                    )
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):access-codes:10401",
                    title: "Send new access codes",
                    summary: "Someone said they will send new access codes.",
                    suggestedAction: "Send across the new access codes.",
                    ownerName: "Me",
                    personName: "Deeeeeksha",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Banko",
                    priority: .medium,
                    status: .open,
                    confidence: 0.93,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 10401,
                            senderName: "Unknown",
                            text: "I'll send across new access codes",
                            date: now
                        )
                    ]
                )
            ])

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .ignore,
                        confidence: 0.89,
                        reason: "Another person accepted the work.",
                        supportingMessageIds: []
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertTrue(openTasks.isEmpty)
            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(ignoredTasks.map(\.title), ["Send new access codes"])
            let extractedChatIds = await recorder.extractedChatIds()
            XCTAssertTrue(extractedChatIds.isEmpty)
        }
    }

    @MainActor
    func testTaskIndexCoordinatorIgnoresStaleOpenTaskWhenExtractionNoLongerReturnsIt() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 105,
                title: "Banko <> First Dollar",
                chatType: .basicGroup(groupId: 305),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 4
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(id: 10501, chatId: chat.id, text: "@pratzyy can we individually send access codes?", date: now.addingTimeInterval(-120)),
                    makeRecord(id: 10502, chatId: chat.id, text: "I'll send across new access codes", date: now)
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):access-codes:10502",
                    title: "Send new access codes",
                    summary: "The thread originally looked like access-code work for the user.",
                    suggestedAction: "Send across the new access codes.",
                    ownerName: "Me",
                    personName: "Deeeeeksha",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Banko",
                    priority: .medium,
                    status: .open,
                    confidence: 0.93,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 10502,
                            senderName: "Unknown",
                            text: "I'll send across new access codes",
                            date: now
                        )
                    ]
                )
            ])

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .effortTask,
                        confidence: 0.86,
                        reason: "There may be task-like access-code context.",
                        supportingMessageIds: [10501]
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertTrue(openTasks.isEmpty)
            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(ignoredTasks.map(\.title), ["Send new access codes"])
            let extractedChatIds = await recorder.extractedChatIds()
            XCTAssertEqual(extractedChatIds, [chat.id])
        }
    }

    @MainActor
    func testTaskIndexCoordinatorKeepsOpenTasksOwnedByAnotherNamedPersonOnLoad() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 141,
                title: "Based Games s2 <> Inner Circle",
                chatType: .basicGroup(groupId: 441),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 12
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14101,
                        chatId: chat.id,
                        text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                        date: now
                    )
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):rev-share:14101",
                    title: "Post rev-share announcement in Inner Circle and RT",
                    summary: "Kshitij asked Rajanshee to post and retweet the announcement.",
                    suggestedAction: "Share the announcement and retweet the post.",
                    ownerName: "Rajanshee",
                    personName: "Rajanshee",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Based Games",
                    priority: .medium,
                    status: .open,
                    confidence: 0.97,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14101,
                            senderName: "Kshitij",
                            text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                            date: now
                        )
                    ]
                )
            ])

            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: true
            )

            let openTasks = TaskIndexCoordinator.shared.tasks.filter { $0.status == .open }
            XCTAssertEqual(openTasks.map(\.title), ["Post rev-share announcement in Inner Circle and RT"])
            XCTAssertEqual(openTasks.first?.ownerName, "Rajanshee")
        }
    }

    @MainActor
    func testTaskIndexCoordinatorKeepsAnotherNamedOwnerBeforeCurrentUserLoads() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let chat = makeChat(
                id: 143,
                title: "Based Games s2 <> Inner Circle",
                chatType: .basicGroup(groupId: 443),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 12
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):rev-share:14301",
                    title: "Post rev-share announcement in Inner Circle and RT",
                    summary: "Kshitij asked Rajanshee to post and retweet the announcement.",
                    suggestedAction: "Share the announcement and retweet the post.",
                    ownerName: "Rajanshee",
                    personName: "Rajanshee",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Based Games",
                    priority: .medium,
                    status: .open,
                    confidence: 0.97,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14301,
                            senderName: "Kshitij",
                            text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                            date: now
                        )
                    ]
                )
            ])

            let telegramService = PipelineTestTelegramService(
                currentUser: nil,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.loadFromStore(
                telegramService: telegramService,
                includeBotsInAISearch: true
            )

            let openTasks = TaskIndexCoordinator.shared.tasks.filter { $0.status == .open }
            XCTAssertEqual(openTasks.map(\.title), ["Post rev-share announcement in Inner Circle and RT"])
            XCTAssertEqual(openTasks.first?.ownerName, "Rajanshee")
        }
    }

    @MainActor
    func testTaskIndexCoordinatorPersistsExtractedTaskOwnedByAnotherNamedPerson() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 142,
                title: "Based Games s2 <> Inner Circle",
                chatType: .basicGroup(groupId: 442),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 12
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14201,
                        chatId: chat.id,
                        text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                        date: now
                    )
                ]
            )

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .effortTask,
                        confidence: 0.96,
                        reason: "AI incorrectly routed this as an effort task.",
                        supportingMessageIds: [14201]
                    )
                ],
                tasksByChatId: [
                    chat.id: DashboardTaskCandidate(
                        stableFingerprint: "\(chat.id):rev-share:14201",
                        title: "Post rev-share announcement in Inner Circle and RT",
                        summary: "Kshitij asked Rajanshee to post and retweet the announcement.",
                        suggestedAction: "Share the announcement and retweet the post.",
                        ownerName: "Rajanshee",
                        personName: "Rajanshee",
                        chatId: chat.id,
                        chatTitle: chat.title,
                        topicName: "Based Games",
                        priority: .medium,
                        status: .open,
                        confidence: 0.97,
                        createdAt: now,
                        dueAt: nil,
                        sourceMessages: [
                            DashboardTaskSourceMessage(
                                chatId: chat.id,
                                messageId: 14201,
                                senderName: "Kshitij",
                                text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                                date: now
                            )
                        ]
                    )
                ]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertEqual(openTasks.map(\.title), ["Post rev-share announcement in Inner Circle and RT"])
            XCTAssertEqual(openTasks.first?.ownerName, "Rajanshee")
            let extractedChatIds = await recorder.extractedChatIds()
            XCTAssertEqual(extractedChatIds, [chat.id])
            let sync = await DatabaseManager.shared.loadDashboardTaskSyncState(chatId: chat.id)
            XCTAssertEqual(sync?.latestMessageId, 14201)
        }
    }

    @MainActor
    func testTaskIndexCoordinatorMarksOutgoingMessagesAsMeForDashboardAI() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 144,
                title: "Banko <> First Dollar",
                chatType: .basicGroup(groupId: 444),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 4
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14401,
                        chatId: chat.id,
                        text: "Can we individually send access codes?",
                        date: now.addingTimeInterval(-240),
                        isOutgoing: false,
                        senderUserId: 201,
                        senderName: "Deeeeeksha"
                    ),
                    makeRecord(
                        id: 14402,
                        chatId: chat.id,
                        text: "I will send the codes.",
                        date: now,
                        isOutgoing: true,
                        senderUserId: 1,
                        senderName: nil
                    )
                ]
            )

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .ignore,
                        confidence: 0.9,
                        reason: "Only recording AI input.",
                        supportingMessageIds: [14402]
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let messagesByChat = await recorder.candidateMessagesByChat()
            XCTAssertEqual(
                messagesByChat[chat.id]?.map(\.senderFirstName),
                ["Deeeeeksha", "[ME]"]
            )
        }
    }

    @MainActor
    func testTaskIndexCoordinatorSendsOpenTaskEvidenceToTriageForStaleCleanup() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 145,
                title: "Banko <> First Dollar",
                chatType: .basicGroup(groupId: 445),
                unreadCount: 1,
                lastMessageDate: now,
                memberCount: 4
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14501,
                        chatId: chat.id,
                        text: "@deeksharungta @pratzyy",
                        date: now.addingTimeInterval(-420),
                        senderUserId: 301,
                        senderName: "Karan"
                    ),
                    makeRecord(
                        id: 14502,
                        chatId: chat.id,
                        text: "Can we individually send access codes?",
                        date: now.addingTimeInterval(-360),
                        senderUserId: 301,
                        senderName: "Karan"
                    ),
                    makeRecord(
                        id: 14503,
                        chatId: chat.id,
                        text: "So we assign an access code uniquely to each user",
                        date: now.addingTimeInterval(-240),
                        senderUserId: 201,
                        senderName: "Deeeeeksha"
                    ),
                    makeRecord(
                        id: 14504,
                        chatId: chat.id,
                        text: "I'll send across new access codes",
                        date: now.addingTimeInterval(-120),
                        senderUserId: 301,
                        senderName: nil
                    ),
                    makeRecord(
                        id: 14505,
                        chatId: chat.id,
                        text: "Okieeee",
                        date: now,
                        senderUserId: 201,
                        senderName: "Deeeeeksha"
                    )
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):access-codes:14504",
                    title: "Send new access codes",
                    summary: "The thread discussed sending new access codes.",
                    suggestedAction: "Send across the new access codes.",
                    ownerName: "Me",
                    personName: "Deeeeeksha",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Banko",
                    priority: .medium,
                    status: .open,
                    confidence: 0.93,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14503,
                            senderName: "Deeeeeksha",
                            text: "So we assign an access code uniquely to each user",
                            date: now.addingTimeInterval(-240)
                        ),
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14504,
                            senderName: "Unknown",
                            text: "I'll send across new access codes",
                            date: now.addingTimeInterval(-120)
                        )
                    ]
                )
            ])

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .ignore,
                        confidence: 0.95,
                        reason: "Existing task evidence shows a non-user sender took the work.",
                        supportingMessageIds: [14504]
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTaskDTOs = await recorder.openTasksByChat()
            XCTAssertEqual(openTaskDTOs[chat.id]?.first?.ownerName, "Me")
            XCTAssertEqual(openTaskDTOs[chat.id]?.first?.sourceMessages.map(\.messageId), [14503, 14504])
            XCTAssertEqual(openTaskDTOs[chat.id]?.first?.sourceMessages.last?.text, "I'll send across new access codes")

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertTrue(openTasks.isEmpty)
            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(ignoredTasks.map(\.title), ["Send new access codes"])
        }
    }

    @MainActor
    func testTaskIndexCoordinatorRescansOpenTaskChatsOutsideVisibleCandidates() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: -146,
                title: "Banko <> First Dollar",
                chatType: .basicGroup(groupId: 446),
                unreadCount: 0,
                lastMessageDate: now,
                memberCount: 4
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14601,
                        chatId: chat.id,
                        text: "So we assign an access code uniquely to each user",
                        date: now.addingTimeInterval(-240),
                        senderUserId: 201,
                        senderName: "Deeeeeksha"
                    ),
                    makeRecord(
                        id: 14602,
                        chatId: chat.id,
                        text: "I'll send across new access codes",
                        date: now.addingTimeInterval(-120),
                        senderUserId: 301,
                        senderName: "Karan"
                    )
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):access-codes:14602",
                    title: "Send new access codes",
                    summary: "The thread discussed sending new access codes.",
                    suggestedAction: "Send across the new access codes.",
                    ownerName: "Me",
                    personName: "Deeeeeksha",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Banko",
                    priority: .medium,
                    status: .open,
                    confidence: 0.93,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14602,
                            senderName: "Karan",
                            text: "I'll send across new access codes",
                            date: now.addingTimeInterval(-120)
                        )
                    ]
                )
            ])

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .ignore,
                        confidence: 0.95,
                        reason: "Existing task evidence shows another person owns the work.",
                        supportingMessageIds: [14602]
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = []
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let candidateMessages = await recorder.candidateMessagesByChat()
            XCTAssertEqual(candidateMessages[chat.id]?.map(\.messageId), [14601, 14602])

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertTrue(openTasks.isEmpty)
            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(ignoredTasks.map(\.title), ["Send new access codes"])
        }
    }

    @MainActor
    func testTaskIndexCoordinatorReplacesStaleMeTaskWhenExtractionReassignsOwner() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: -147,
                title: "Based Games s2 <> Inner Circle",
                chatType: .basicGroup(groupId: 447),
                unreadCount: 0,
                lastMessageDate: now,
                memberCount: 12
            )

            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 14701,
                        chatId: chat.id,
                        text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                        date: now,
                        senderUserId: 201,
                        senderName: "Kshitij"
                    )
                ]
            )
            _ = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):stale-me:14701",
                    title: "Post rev-share announcement in Inner Circle and RT",
                    summary: "A stale pass incorrectly assigned this to the user.",
                    suggestedAction: "Share the announcement and retweet the post.",
                    ownerName: "Me",
                    personName: "Rajanshee",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: "Based Games",
                    priority: .medium,
                    status: .open,
                    confidence: 0.97,
                    createdAt: now,
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 14701,
                            senderName: "Kshitij",
                            text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                            date: now
                        )
                    ]
                )
            ])

            let replacement = DashboardTaskCandidate(
                stableFingerprint: "\(chat.id):rajanshee-post-rev-share:14701",
                title: "Post rev-share announcement in Inner Circle and RT",
                summary: "Kshitij asked Rajanshee to post and retweet the announcement.",
                suggestedAction: "Share the announcement and retweet the post.",
                ownerName: "Rajanshee",
                personName: "Rajanshee",
                chatId: chat.id,
                chatTitle: chat.title,
                topicName: "Based Games",
                priority: .medium,
                status: .open,
                confidence: 0.97,
                createdAt: now,
                dueAt: nil,
                sourceMessages: [
                    DashboardTaskSourceMessage(
                        chatId: chat.id,
                        messageId: 14701,
                        senderName: "Kshitij",
                        text: "@Rajanshee can you post this in Inner Circle and RT as well?",
                        date: now
                    )
                ]
            )

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .effortTask,
                        confidence: 0.95,
                        reason: "The durable task is explicitly assigned to Rajanshee.",
                        supportingMessageIds: [14701]
                    )
                ],
                tasksByChatId: [chat.id: replacement]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = []
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertEqual(openTasks.map(\.ownerName), ["Rajanshee"])
            XCTAssertEqual(openTasks.map(\.stableFingerprint), [replacement.stableFingerprint])

            let ignoredTasks = await DatabaseManager.shared.loadDashboardTasks(status: .ignored)
            XCTAssertEqual(ignoredTasks.map(\.ownerName), ["Me"])
            XCTAssertEqual(ignoredTasks.map(\.stableFingerprint), ["\(chat.id):stale-me:14701"])
        }
    }

    @MainActor
    func testTaskIndexCoordinatorMarksExistingTaskDoneWhenReplyCompletesIt() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let myUser = TGUser(
                id: 99,
                firstName: "Pratyush",
                lastName: "",
                username: "pratzyy",
                phoneNumber: nil,
                isBot: false
            )
            let chat = makeChat(
                id: 104,
                title: "Rahul Singh Bhadoriya",
                chatType: .privateChat(userId: 204),
                unreadCount: 1,
                lastMessageDate: now
            )

            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: 10401,
                        chatId: chat.id,
                        text: "Can you send me the pitch deck?",
                        date: now.addingTimeInterval(-600)
                    ),
                    makeRecord(
                        id: 10402,
                        chatId: chat.id,
                        text: "Sent it here.",
                        date: now,
                        isOutgoing: true,
                        senderUserId: myUser.id,
                        senderName: "Pratyush"
                    )
                ]
            )

            let inserted = await DatabaseManager.shared.upsertDashboardTasks([
                DashboardTaskCandidate(
                    stableFingerprint: "\(chat.id):pitch-deck:10401",
                    title: "Send pitch deck",
                    summary: "Rahul asked for the pitch deck.",
                    suggestedAction: "Send Rahul the pitch deck.",
                    ownerName: "Me",
                    personName: "Rahul",
                    chatId: chat.id,
                    chatTitle: chat.title,
                    topicName: nil,
                    priority: .medium,
                    status: .open,
                    confidence: 0.84,
                    createdAt: now.addingTimeInterval(-600),
                    dueAt: nil,
                    sourceMessages: [
                        DashboardTaskSourceMessage(
                            chatId: chat.id,
                            messageId: 10401,
                            senderName: "Rahul",
                            text: "Can you send me the pitch deck?",
                            date: now.addingTimeInterval(-600)
                        )
                    ]
                )
            ])
            let taskId = try XCTUnwrap(inserted.first?.id)

            let recorder = DashboardTaskTriageRecorder()
            let provider = DashboardTaskTriageAIProvider(
                recorder: recorder,
                decisions: [
                    DashboardTaskTriageResultDTO(
                        chatId: chat.id,
                        route: .completedTask,
                        confidence: 0.92,
                        reason: "The user sent the requested deck.",
                        supportingMessageIds: [10402],
                        completedTaskIds: [taskId]
                    )
                ],
                tasksByChatId: [:]
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: myUser,
                historyByChatId: [:]
            )
            telegramService.authState = .ready
            telegramService.chats = [chat]
            let aiService = AIService(testingProvider: provider)

            TaskIndexCoordinator.shared.stop()
            await TaskIndexCoordinator.shared.refreshNow(
                telegramService: telegramService,
                aiService: aiService,
                includeBotsInAISearch: true
            )

            let openTasks = await DatabaseManager.shared.loadDashboardTasks(status: .open)
            XCTAssertTrue(openTasks.isEmpty)
            let doneTasks = await DatabaseManager.shared.loadDashboardTasks(status: .done)
            XCTAssertEqual(doneTasks.map(\.id), [taskId])
            let extractedChatIds = await recorder.extractedChatIds()
            XCTAssertTrue(extractedChatIds.isEmpty)
            let openTaskCountsByChat = await recorder.openTaskCountsByChat()
            XCTAssertEqual(openTaskCountsByChat[chat.id], 1)
            let sync = await DatabaseManager.shared.loadDashboardTaskSyncState(chatId: chat.id)
            XCTAssertEqual(sync?.latestMessageId, 10402)
        }
    }

    @MainActor
    func testAttentionStoreLocksImmediatelyDuringFollowUpLoad() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let chat = makeChat(
                id: 44_001,
                title: "Startup Cache Check",
                chatType: .privateChat(userId: 44_101),
                unreadCount: 1,
                lastMessageDate: now
            )
            await DatabaseManager.shared.upsertLiveMessages(
                chatId: chat.id,
                messages: [
                    makeRecord(
                        id: chat.lastMessage?.id ?? 1,
                        chatId: chat.id,
                        text: "Can you check this?",
                        date: now
                    )
                ]
            )

            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: 99,
                    firstName: "Pratyush",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chat.id: [chat.lastMessage].compactMap { $0 }]
            )
            telegramService.chats = [chat]
            let callCounter = PipelineCategorizationCallCounter()
            let aiService = AIService(
                testingProvider: CountingPipelineAIProvider(
                    callCounter: callCounter,
                    pipelineCategoryResult: PipelineCategoryDTO(
                        status: "decision",
                        category: "on_me",
                        urgency: "high",
                        suggestedAction: "Reply with confirmation."
                    )
                )
            )

            let store = AttentionStore.shared
            store.loadFollowUps(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: true
            )

            XCTAssertTrue(store.isFollowUpsLoading)

            for _ in 0..<100 where store.isFollowUpsLoading {
                try await Task.sleep(for: .milliseconds(20))
            }

            XCTAssertFalse(store.isFollowUpsLoading)
            let aiCallCount = await callCounter.currentValue()
            XCTAssertEqual(aiCallCount, 1)
        }
    }

    @MainActor
    func testAttentionStoreHydratesNewlyVisibleCachedFollowUpsWithoutAI() async throws {
        try await withTempDatabase { _ in
            let now = Date()
            let initiallyVisibleChats = [
                makeChat(
                    id: 45_001,
                    title: "Initial cached one",
                    chatType: .privateChat(userId: 45_101),
                    unreadCount: 1,
                    lastMessageDate: now
                ),
                makeChat(
                    id: 45_002,
                    title: "Initial cached two",
                    chatType: .privateChat(userId: 45_102),
                    unreadCount: 1,
                    lastMessageDate: now.addingTimeInterval(-60)
                )
            ]
            let newlyVisibleChats = [
                makeChat(
                    id: 45_003,
                    title: "Later cached three",
                    chatType: .privateChat(userId: 45_103),
                    unreadCount: 1,
                    lastMessageDate: now.addingTimeInterval(-120)
                ),
                makeChat(
                    id: 45_004,
                    title: "Later cached four",
                    chatType: .privateChat(userId: 45_104),
                    unreadCount: 1,
                    lastMessageDate: now.addingTimeInterval(-180)
                )
            ]
            let allChats = initiallyVisibleChats + newlyVisibleChats

            for chat in allChats {
                guard let lastMessage = chat.lastMessage else {
                    XCTFail("Expected test chat to have a last message")
                    return
                }
                await MessageCacheService.shared.cachePipelineCategory(
                    chatId: chat.id,
                    category: "on_me",
                    suggestedAction: "Reply from cached row.",
                    lastMessageId: lastMessage.id
                )
                await MessageCacheService.shared.cacheMessages(chatId: chat.id, messages: [lastMessage])
            }

            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: 99,
                    firstName: "Pratyush",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: Dictionary(uniqueKeysWithValues: allChats.map { chat in
                    (chat.id, [chat.lastMessage].compactMap { $0 })
                })
            )
            telegramService.chats = initiallyVisibleChats

            let callCounter = PipelineCategorizationCallCounter()
            let aiService = AIService(
                testingProvider: CountingPipelineAIProvider(
                    callCounter: callCounter,
                    pipelineCategoryResult: PipelineCategoryDTO(
                        status: "decision",
                        category: "quiet",
                        urgency: "none",
                        suggestedAction: ""
                    )
                )
            )

            let store = AttentionStore.shared
            store.loadFollowUps(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: true
            )

            for _ in 0..<100 where store.isFollowUpsLoading {
                try await Task.sleep(for: .milliseconds(20))
            }

            XCTAssertEqual(store.followUpItems.map(\.chat.id).sorted(), initiallyVisibleChats.map(\.id).sorted())
            let initialAICallCount = await callCounter.currentValue()
            XCTAssertEqual(initialAICallCount, 0)

            telegramService.chats = allChats
            store.backgroundRefreshPipeline(
                telegramService: telegramService,
                aiService: aiService,
                includeBots: true
            )

            for _ in 0..<100 where store.followUpItems.count < allChats.count {
                try await Task.sleep(for: .milliseconds(20))
            }

            XCTAssertEqual(store.followUpItems.map(\.chat.id).sorted(), allChats.map(\.id).sorted())
            let finalAICallCount = await callCounter.currentValue()
            XCTAssertEqual(finalAICallCount, 0)
        }
    }

    func testTDLibClientWrapperRecreatesUpdateStreamAfterClose() {
        let wrapper = TDLibClientWrapper()
        let initialGeneration = wrapper.updateStreamGenerationForTesting

        wrapper.close()

        XCTAssertGreaterThan(wrapper.updateStreamGenerationForTesting, initialGeneration)
    }

    func testMessageCacheEditUpdatesOlderSQLiteMessageAndInvalidatesEmbedding() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 86
            let older = makeRecord(
                id: 601,
                chatId: chatId,
                text: "old indexed wording",
                date: Date().addingTimeInterval(-60 * 86_400)
            )
            let newer = (0..<60).map { offset in
                makeRecord(
                    id: Int64(700 + offset),
                    chatId: chatId,
                    text: "newer visible message \(offset)",
                    date: Date().addingTimeInterval(TimeInterval(-offset * 60))
                )
            }

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [older] + newer,
                preferredOldestMessageId: older.id,
                isSearchReady: true
            )
            try await VectorStore.shared.storeBatchThrowing([
                VectorStore.EmbeddingRecord(
                    messageId: older.id,
                    chatId: chatId,
                    vector: [0.1, 0.2, 0.3],
                    textPreview: older.textContent ?? ""
                )
            ])
            await MessageCacheService.shared.invalidateAll()

            await MessageCacheService.shared.updateMessageContent(
                chatId: chatId,
                messageId: older.id,
                textContent: "edited indexed wording",
                mediaType: nil
            )

            let stored = await DatabaseManager.shared.loadMessages(chatId: chatId, limit: 100)
            let invalidatedEmbeddingCount = try await embeddingCount(chatId: chatId, messageId: older.id)
            XCTAssertEqual(stored.first(where: { $0.id == older.id })?.textContent, "edited indexed wording")
            XCTAssertEqual(invalidatedEmbeddingCount, 0)
        }
    }

    func testRecentSyncRecoveryRefreshOverridesFreshStateForMostRecentVisibleChats() async throws {
        let coordinator = RecentSyncCoordinator()
        let now = Date()
        let chats: [TGChat] = (0..<9).map { index in
            let chatId = Int64(901 + index)
            return TGChat(
                id: chatId,
                title: "Chat \(index)",
                chatType: .privateChat(userId: Int64(index + 1)),
                unreadCount: 0,
                lastMessage: makeTGMessage(
                    id: chatId * 10,
                    chatId: chatId,
                    text: "latest",
                    date: now.addingTimeInterval(TimeInterval(-index * 120))
                ),
                memberCount: nil,
                order: Int64(100 - index),
                isInMainList: true,
                smallPhotoFileId: nil
            )
        }

        let freshestChat = chats[0]
        let secondFreshestChat = chats[1]
        let oldestChat = chats[8]

        await coordinator.scheduleRecoveryRefreshForTesting(chats: chats)

        let freshState = DatabaseManager.RecentSyncStateRecord(
            chatId: freshestChat.id,
            latestSyncedMessageId: freshestChat.lastMessage?.id ?? 0,
            lastRecentSyncAt: now
        )
        let secondFreshState = DatabaseManager.RecentSyncStateRecord(
            chatId: secondFreshestChat.id,
            latestSyncedMessageId: secondFreshestChat.lastMessage?.id ?? 0,
            lastRecentSyncAt: now
        )
        let oldestFreshState = DatabaseManager.RecentSyncStateRecord(
            chatId: oldestChat.id,
            latestSyncedMessageId: oldestChat.lastMessage?.id ?? 0,
            lastRecentSyncAt: now
        )

        let freshestShouldRefresh = await coordinator.shouldRefreshForTesting(chat: freshestChat, state: freshState)
        let secondShouldRefresh = await coordinator.shouldRefreshForTesting(chat: secondFreshestChat, state: secondFreshState)
        let oldestShouldRefresh = await coordinator.shouldRefreshForTesting(chat: oldestChat, state: oldestFreshState)

        XCTAssertTrue(freshestShouldRefresh)
        XCTAssertTrue(secondShouldRefresh)
        XCTAssertFalse(oldestShouldRefresh)

        let recoveryChatIds = await coordinator.recoveryChatIdsForTesting()
        XCTAssertTrue(recoveryChatIds.contains(freshestChat.id))
        XCTAssertTrue(recoveryChatIds.contains(secondFreshestChat.id))
        XCTAssertFalse(recoveryChatIds.contains(oldestChat.id))
    }

    @MainActor
    func testIndexingAndRecentSyncResolveUnknownSupergroupMemberCounts() async throws {
        let smallSupergroup = makeChat(
            id: 1901,
            title: "Small Supergroup",
            chatType: .supergroup(supergroupId: 901, isChannel: false),
            unreadCount: 0,
            lastMessageDate: Date(),
            memberCount: nil
        )
        let largeSupergroup = makeChat(
            id: 1902,
            title: "Large Supergroup",
            chatType: .supergroup(supergroupId: 902, isChannel: false),
            unreadCount: 0,
            lastMessageDate: Date(),
            memberCount: nil
        )
        let channel = makeChat(
            id: 1903,
            title: "Announcement Channel",
            chatType: .supergroup(supergroupId: 903, isChannel: true),
            unreadCount: 0,
            lastMessageDate: Date(),
            memberCount: nil
        )
        let telegramService = PipelineTestTelegramService(
            currentUser: nil,
            historyByChatId: [:],
            resolvedMemberCounts: [
                smallSupergroup.id: 12,
                largeSupergroup.id: AppConstants.Indexing.maxIndexedGroupMembers + 1
            ]
        )
        telegramService.chats = [smallSupergroup, largeSupergroup, channel]

        let indexableChats = await IndexScheduler().indexableChatsForTesting(using: telegramService)
        let recentSyncChats = await RecentSyncCoordinator().indexableChatsForTesting(using: telegramService)

        XCTAssertEqual(indexableChats.map(\.id), [smallSupergroup.id])
        XCTAssertEqual(indexableChats.first?.memberCount, 12)
        XCTAssertEqual(recentSyncChats.map(\.id), [smallSupergroup.id])
        XCTAssertEqual(recentSyncChats.first?.memberCount, 12)
    }

    func testTelegramServiceReconnectRecoveryTriggerRequiresReadyTransition() {
        XCTAssertTrue(
            TelegramService.shouldTriggerRecoveryRefreshForTesting(
                previousConnectionState: .connectionStateWaitingForNetwork,
                newConnectionState: .connectionStateReady,
                authState: .ready
            )
        )
        XCTAssertFalse(
            TelegramService.shouldTriggerRecoveryRefreshForTesting(
                previousConnectionState: .connectionStateReady,
                newConnectionState: .connectionStateReady,
                authState: .ready
            )
        )
        XCTAssertFalse(
            TelegramService.shouldTriggerRecoveryRefreshForTesting(
                previousConnectionState: .connectionStateConnecting,
                newConnectionState: .connectionStateReady,
                authState: .waitingForPhoneNumber
            )
        )
    }

    func testSearchChatEligibilityFilterSharesPipelineScopeAgeAndGroupRules() {
        let now = Date()
        let recentPrivate = makeChat(
            id: 1,
            title: "Recent DM",
            chatType: .privateChat(userId: 11),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-3_600)
        )
        let recentGroup = makeChat(
            id: 2,
            title: "Recent Group",
            chatType: .basicGroup(groupId: 22),
            unreadCount: 2,
            lastMessageDate: now.addingTimeInterval(-7_200),
            memberCount: 8
        )
        let midSizeGroup = makeChat(
            id: 8,
            title: "Mid Size Group",
            chatType: .basicGroup(groupId: 88),
            unreadCount: 1,
            lastMessageDate: now.addingTimeInterval(-5_400),
            memberCount: 35
        )
        let stalePrivate = makeChat(
            id: 3,
            title: "Stale DM",
            chatType: .privateChat(userId: 33),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-(15 * 86_400))
        )
        let noisyGroup = makeChat(
            id: 4,
            title: "Noisy Group",
            chatType: .basicGroup(groupId: 44),
            unreadCount: AppConstants.FollowUp.maxGroupUnread + 1,
            lastMessageDate: now.addingTimeInterval(-1_800),
            memberCount: 8
        )
        let hugeGroup = makeChat(
            id: 5,
            title: "Huge Group",
            chatType: .basicGroup(groupId: 55),
            unreadCount: 1,
            lastMessageDate: now.addingTimeInterval(-1_800),
            memberCount: AppConstants.FollowUp.maxGroupMembers + 1
        )
        let channel = makeChat(
            id: 6,
            title: "Channel",
            chatType: .supergroup(supergroupId: 66, isChannel: true),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-1_800)
        )

        let result = SearchChatEligibilityFilter.collectCandidateChats(
            from: [recentPrivate, recentGroup, midSizeGroup, stalePrivate, noisyGroup, hugeGroup, channel],
            scope: .all,
            replyQueueQuery: false,
            now: now
        )

        XCTAssertEqual(result.included.map(\.id), [recentPrivate.id, recentGroup.id, midSizeGroup.id])
        XCTAssertTrue(result.exclusions.contains(.init(reason: "older than 14 days", chatTitle: "Stale DM")))
        XCTAssertTrue(result.exclusions.contains(.init(reason: "group unread too high", chatTitle: "Noisy Group")))
        XCTAssertTrue(result.exclusions.contains(.init(reason: "group too large", chatTitle: "Huge Group")))
        XCTAssertTrue(result.exclusions.contains(.init(reason: "channel skipped", chatTitle: "Channel")))
    }

    func testSearchChatEligibilityFilterPreservesReplyQueueAgeOverrideAndBotFiltering() async {
        let now = Date()
        let staleButEligibleDM = makeChat(
            id: 7,
            title: "Old DM",
            chatType: .privateChat(userId: 77),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-(30 * 86_400))
        )
        let botDM = makeChat(
            id: 8,
            title: "Reminder Bot",
            chatType: .privateChat(userId: 88),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-3_600)
        )
        let normalDM = makeChat(
            id: 9,
            title: "Normal DM",
            chatType: .privateChat(userId: 99),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-1_800)
        )

        let base = SearchChatEligibilityFilter.collectCandidateChats(
            from: [staleButEligibleDM, botDM, normalDM],
            scope: .dms,
            replyQueueQuery: true,
            now: now
        )
        XCTAssertEqual(base.included.map(\.id), [staleButEligibleDM.id, botDM.id, normalDM.id])

        let likelyFiltered = SearchChatEligibilityFilter.applyingLikelyBotFilter(
            to: base,
            includeBots: false,
            isLikelyBot: { $0.id == botDM.id }
        )
        XCTAssertEqual(likelyFiltered.included.map(\.id), [staleButEligibleDM.id, normalDM.id])
        XCTAssertTrue(likelyFiltered.exclusions.contains(.init(reason: "bot filtered", chatTitle: "Reminder Bot")))

        let asyncFiltered = await SearchChatEligibilityFilter.applyingBotFilter(
            to: base,
            includeBots: false,
            isBot: { $0.id == botDM.id }
        )
        XCTAssertEqual(asyncFiltered.included.map(\.id), [staleButEligibleDM.id, normalDM.id])
        XCTAssertTrue(asyncFiltered.exclusions.contains(.init(reason: "bot filtered", chatTitle: "Reminder Bot")))
    }

    func testLauncherVisibleChatsFilterHidesBotChatsWhenDisabled() {
        let now = Date()
        let botDM = makeChat(
            id: 41,
            title: "Reminder Bot",
            chatType: .privateChat(userId: 141),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-60)
        )
        let normalDM = makeChat(
            id: 42,
            title: "Normal DM",
            chatType: .privateChat(userId: 142),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-120)
        )
        let group = makeChat(
            id: 43,
            title: "Shipping Group",
            chatType: .basicGroup(groupId: 143),
            unreadCount: 1,
            lastMessageDate: now.addingTimeInterval(-180),
            memberCount: 6
        )

        let all = LauncherVisibleChatsFilter.filterChats(
            from: [botDM, normalDM, group],
            scope: .all,
            pipelineMatchingIds: nil,
            searchText: "",
            searchResultChatIds: [],
            includeBots: false,
            isLikelyBot: { $0.id == botDM.id }
        )
        XCTAssertEqual(all.map(\.id), [normalDM.id, group.id])

        let dms = LauncherVisibleChatsFilter.filterChats(
            from: [botDM, normalDM, group],
            scope: .dms,
            pipelineMatchingIds: nil,
            searchText: "",
            searchResultChatIds: [],
            includeBots: false,
            isLikelyBot: { $0.id == botDM.id }
        )
        XCTAssertEqual(dms.map(\.id), [normalDM.id])
    }

    @MainActor
    func testTelegramBotFilterDoesNotGuessFromTitleWithoutMetadata() {
        let service = TelegramService()
        let chat = makeChat(
            id: 44,
            title: "Reminder Bot",
            chatType: .privateChat(userId: 144),
            unreadCount: 0,
            lastMessageDate: Date()
        )

        XCTAssertFalse(service.isLikelyBotChat(chat))
    }

    func testRelationGraphStoresTelegramBotMetadataAndFiltersPeopleLists() async throws {
        try await withTempDatabase { _ in
            await RelationGraph.shared.upsertNode(
                entityId: 141,
                type: AppConstants.Graph.userEntityType,
                name: "Poke",
                username: "interaction_poke_bot",
                isBot: true
            )
            await RelationGraph.shared.upsertNode(
                entityId: 142,
                type: AppConstants.Graph.userEntityType,
                name: "Parth",
                username: nil,
                isBot: false
            )

            let bot = await RelationGraph.shared.getNode(entityId: 141)
            XCTAssertEqual(bot?.isBot, true)

            let human = await RelationGraph.shared.getNode(entityId: 142)
            XCTAssertEqual(human?.isBot, false)

            let topContacts = await RelationGraph.shared.topContacts(category: nil, limit: 10)
            XCTAssertEqual(topContacts.map(\.entityId), [142])

            let contactsByCategory = await RelationGraph.shared.contactsByCategory()
            let groupedContactIds = Set(contactsByCategory.values.flatMap { $0.map(\.entityId) })
            XCTAssertFalse(groupedContactIds.contains(141))
            XCTAssertTrue(groupedContactIds.contains(142))
        }
    }

    func testRelationGraphPreservesBotMetadataWhenLaterUpsertLacksMetadata() async throws {
        try await withTempDatabase { _ in
            await RelationGraph.shared.upsertNode(
                entityId: 151,
                type: AppConstants.Graph.userEntityType,
                name: "Reminder",
                username: "reminder",
                isBot: true
            )
            await RelationGraph.shared.upsertNode(
                entityId: 151,
                type: AppConstants.Graph.userEntityType,
                name: "Reminder renamed",
                username: nil
            )

            let node = await RelationGraph.shared.getNode(entityId: 151)
            XCTAssertEqual(node?.displayName, "Reminder renamed")
            XCTAssertEqual(node?.isBot, true)
        }
    }

    func testLauncherChatPreviewResolverUsesRecentContextWhenLatestMessageIsOpaqueMedia() {
        let now = Date()
        let chatId: Int64 = 4301
        let currentMessage = makeTGMessage(
            id: 43011,
            chatId: chatId,
            text: nil,
            date: now,
            mediaType: .photo
        )
        let earlierContext = makeTGMessage(
            id: 43010,
            chatId: chatId,
            text: "Need to lock the invite copy before tonight.",
            date: now.addingTimeInterval(-60)
        )
        let chat = TGChat(
            id: chatId,
            title: "Ahaan Raizada | Brainstorm",
            chatType: .privateChat(userId: 301),
            unreadCount: 0,
            lastMessage: currentMessage,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let resolution = LauncherChatPreviewResolver.resolvePreview(
            for: chat,
            recentMessages: [currentMessage, earlierContext]
        )

        XCTAssertEqual(resolution.text, "Need to lock the invite copy before tonight.")
        XCTAssertEqual(resolution.source, .recentContext)
    }

    func testLauncherChatPreviewResolverHidesOpaqueMediaWithoutUsefulContext() {
        let now = Date()
        let chatId: Int64 = 4302
        let currentMessage = makeTGMessage(
            id: 43021,
            chatId: chatId,
            text: nil,
            date: now,
            mediaType: .photo
        )
        let chat = TGChat(
            id: chatId,
            title: "Media Only Chat",
            chatType: .privateChat(userId: 302),
            unreadCount: 0,
            lastMessage: currentMessage,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let resolution = LauncherChatPreviewResolver.resolvePreview(
            for: chat,
            recentMessages: [currentMessage]
        )

        XCTAssertEqual(resolution.text, "")
        XCTAssertEqual(resolution.source, .none)
    }

    func testLauncherChatPreviewResolverKeepsSpecificMediaSlugOnCurrentMessage() {
        let now = Date()
        let chatId: Int64 = 4303
        let currentMessage = makeTGMessage(
            id: 43031,
            chatId: chatId,
            text: "pitch-deck-v4.pdf",
            date: now,
            mediaType: .document
        )
        let earlierContext = makeTGMessage(
            id: 43030,
            chatId: chatId,
            text: "Sharing the latest deck now.",
            date: now.addingTimeInterval(-60)
        )
        let chat = TGChat(
            id: chatId,
            title: "Deck Thread",
            chatType: .privateChat(userId: 303),
            unreadCount: 0,
            lastMessage: currentMessage,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let resolution = LauncherChatPreviewResolver.resolvePreview(
            for: chat,
            recentMessages: [currentMessage, earlierContext]
        )

        XCTAssertEqual(resolution.text, "pitch-deck-v4.pdf")
        XCTAssertEqual(resolution.source, .currentMessage)
    }

    func testLauncherChatPreviewResolverSkipsSyntheticPlaceholderContext() {
        let now = Date()
        let chatId: Int64 = 4304
        let currentMessage = makeTGMessage(
            id: 43041,
            chatId: chatId,
            text: nil,
            date: now,
            mediaType: .photo
        )
        let syntheticPlaceholder = makeTGMessage(
            id: 43040,
            chatId: chatId,
            text: "[Media]",
            date: now.addingTimeInterval(-60)
        )
        let realContext = makeTGMessage(
            id: 43039,
            chatId: chatId,
            text: "Need to review the brainstorm notes before tomorrow.",
            date: now.addingTimeInterval(-120)
        )
        let chat = TGChat(
            id: chatId,
            title: "Placeholder Cache Chat",
            chatType: .privateChat(userId: 304),
            unreadCount: 0,
            lastMessage: currentMessage,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let resolution = LauncherChatPreviewResolver.resolvePreview(
            for: chat,
            recentMessages: [currentMessage, syntheticPlaceholder, realContext]
        )

        XCTAssertEqual(resolution.text, "Need to review the brainstorm notes before tomorrow.")
        XCTAssertEqual(resolution.source, .recentContext)
    }

    func testFollowUpPipelineAnalyzerCollectCandidateChatsExcludesLikelyBotsWhenDisabled() {
        let now = Date()
        let botDM = makeChat(
            id: 51,
            title: "Reminder Bot",
            chatType: .privateChat(userId: 151),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-60)
        )
        let normalDM = makeChat(
            id: 52,
            title: "Normal DM",
            chatType: .privateChat(userId: 152),
            unreadCount: 0,
            lastMessageDate: now.addingTimeInterval(-120)
        )

        let result = FollowUpPipelineAnalyzer.collectCandidateChats(
            from: [botDM, normalDM],
            includeBots: false,
            isLikelyBot: { $0.id == botDM.id }
        )

        XCTAssertEqual(result.map(\.id), [normalDM.id])
    }

    func testFollowUpPipelineAnalyzerFillsBlankOnMeSuggestion() {
        let suggestion = FollowUpPipelineAnalyzer.fallbackSuggestedAction(
            for: .onMe,
            existing: "",
            age: 600
        )

        XCTAssertEqual(suggestion, "Reply with a concrete next step.")
    }

    func testFollowUpPipelineAnalyzerFillsRecentOnThemSuggestionWhenBlank() {
        let suggestion = FollowUpPipelineAnalyzer.fallbackSuggestedAction(
            for: .onThem,
            existing: nil,
            age: 600
        )

        XCTAssertEqual(suggestion, "Wait for their next message.")
    }

    func testFollowUpPipelineAnalyzerClearsReplyStyleSuggestionForQuietCategory() {
        let suggestion = FollowUpPipelineAnalyzer.fallbackSuggestedAction(
            for: .quiet,
            existing: "Reply with a concrete next step.",
            age: 600
        )

        XCTAssertNil(suggestion)
    }

    func testFollowUpPipelineAnalyzerRepairsReplyStyleSuggestionForOnThemCategory() {
        let suggestion = FollowUpPipelineAnalyzer.fallbackSuggestedAction(
            for: .onThem,
            existing: "Reply to Lakshay",
            age: 600
        )

        XCTAssertEqual(suggestion, "Wait for their next message.")
    }

    @MainActor
    func testFollowUpPipelineAnalyzerTrustsAIDecisionWithoutHeuristicOverride() async throws {
        try await withTempDatabase { _ in
            let myUserId: Int64 = 99
            let latestOutbound = makeTGMessage(
                id: 802,
                chatId: 2014843525,
                text: "Will send it tomorrow morning",
                date: Date(timeIntervalSince1970: 1_776_714_640),
                senderUserId: myUserId,
                senderName: "Pratzyy",
                isOutgoing: true
            )
            let priorInbound = makeTGMessage(
                id: 801,
                chatId: 2014843525,
                text: "Need this today?",
                date: Date(timeIntervalSince1970: 1_776_714_000),
                senderUserId: 201,
                senderName: "Rahul Singh Bhadoriya"
            )
            let chat = TGChat(
                id: 2014843525,
                title: "Rahul Singh Bhadoriya",
                chatType: .privateChat(userId: 201),
                unreadCount: 0,
                lastMessage: latestOutbound,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: myUserId,
                    firstName: "Pratzyy",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chat.id: [latestOutbound, priorInbound]]
            )
            let aiService = AIService(
                testingProvider: StubAIProvider(
                    pipelineCategoryResult: PipelineCategoryDTO(
                        status: "decision",
                        category: "on_me",
                        urgency: "high",
                        suggestedAction: "Send the proposal"
                    )
                )
            )

            let item = await FollowUpPipelineAnalyzer.categorizeChat(
                chat: chat,
                myUserId: myUserId,
                telegramService: telegramService,
                aiService: aiService
            )

            XCTAssertEqual(item?.category, .onMe)
            XCTAssertEqual(item?.suggestedAction, "Send the proposal")

            let cached = await MessageCacheService.shared.getPipelineCategory(chatId: chat.id)
            XCTAssertEqual(cached?.category, "on_me")
            XCTAssertEqual(cached?.suggestedAction, "Send the proposal")
        }
    }

    @MainActor
    func testFollowUpPipelineAnalyzerUsesAIForSmallGroups() async throws {
        try await withTempDatabase { _ in
            let myUserId: Int64 = 99
            let callCounter = PipelineCategorizationCallCounter()
            let messages = [
                makeTGMessage(
                    id: 2520776704,
                    chatId: -1003542166930,
                    text: "Can you send the event recap?",
                    date: Date(timeIntervalSince1970: 1_775_732_000),
                    senderUserId: 44,
                    senderName: "Akhil B"
                ),
                makeTGMessage(
                    id: 2520776705,
                    chatId: -1003542166930,
                    text: "Sure, will do it in 10 mins",
                    date: Date(timeIntervalSince1970: 1_775_735_000),
                    senderUserId: myUserId,
                    senderName: "Pratzyy",
                    isOutgoing: true
                )
            ]
            let chat = TGChat(
                id: -1003542166930,
                title: "Small Inner Circle",
                chatType: .supergroup(supergroupId: 88, isChannel: false),
                unreadCount: 0,
                lastMessage: messages.last,
                memberCount: 12,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: myUserId,
                    firstName: "Pratzyy",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chat.id: messages],
                resolvedMemberCounts: [chat.id: 12]
            )
            let aiService = AIService(
                testingProvider: CountingPipelineAIProvider(
                    callCounter: callCounter,
                    pipelineCategoryResult: PipelineCategoryDTO(
                        status: "decision",
                        category: "on_me",
                        urgency: "high",
                        suggestedAction: "Send the recap"
                    )
                )
            )

            let item = await FollowUpPipelineAnalyzer.categorizeChat(
                chat: chat,
                myUserId: myUserId,
                telegramService: telegramService,
                aiService: aiService
            )

            XCTAssertEqual(item?.category, .onMe)
            XCTAssertEqual(item?.suggestedAction, "Send the recap")
            let aiCallCount = await callCounter.currentValue()
            XCTAssertEqual(aiCallCount, 1)

            let cached = await MessageCacheService.shared.getPipelineCategory(chatId: chat.id)
            XCTAssertEqual(cached?.category, "on_me")
            XCTAssertEqual(cached?.suggestedAction, "Send the recap")
        }
    }

    @MainActor
    func testFollowUpPipelineAnalyzerUsesLocalRulesForUnknownSizeGroups() async throws {
        try await withTempDatabase { _ in
            let myUserId: Int64 = 99
            let callCounter = PipelineCategorizationCallCounter()
            let messages = [
                makeTGMessage(
                    id: 2520776704,
                    chatId: -1003542166929,
                    text: "i cant remember the name, it was like cafe plus co workinh vibe (not dark) had a glass room conference situation",
                    date: Date(timeIntervalSince1970: 1_775_660_000),
                    senderUserId: 42,
                    senderName: "Rajanshee Singh"
                ),
                makeTGMessage(
                    id: 2542796800,
                    chatId: -1003542166929,
                    text: "yc startup school is first come first serve. many good profiles got rejected. we should definelty use the chance to put our brand first and do something.",
                    date: Date(timeIntervalSince1970: 1_775_724_000),
                    senderUserId: 43,
                    senderName: "Unknown"
                ),
                makeTGMessage(
                    id: 2570059776,
                    chatId: -1003542166929,
                    text: "few things : - have our builders to showcase at their event. doesn’t have to do a buildathon, just pick top past people to present from our communities - us as speakers representing agentic summer",
                    date: Date(timeIntervalSince1970: 1_775_732_000),
                    senderUserId: 44,
                    senderName: "Akhil B"
                ),
                makeTGMessage(
                    id: 2587885568,
                    chatId: -1003542166929,
                    text: "thank you",
                    date: Date(timeIntervalSince1970: 1_775_735_000),
                    senderUserId: 45,
                    senderName: "Priyanshu Ratnakar"
                )
            ]
            let chat = TGChat(
                id: -1003542166929,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 88, isChannel: false),
                unreadCount: 0,
                lastMessage: messages.last,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: myUserId,
                    firstName: "Pratzyy",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chat.id: messages],
                resolvedMemberCounts: [:]
            )
            let aiService = AIService(
                testingProvider: CountingPipelineAIProvider(
                    callCounter: callCounter,
                    pipelineCategoryResult: PipelineCategoryDTO(
                        status: "decision",
                        category: "on_me",
                        urgency: "high",
                        suggestedAction: "Reply with event plan"
                    )
                )
            )

            let item = await FollowUpPipelineAnalyzer.categorizeChat(
                chat: chat,
                myUserId: myUserId,
                telegramService: telegramService,
                aiService: aiService
            )

            XCTAssertEqual(item?.category, .quiet)
            XCTAssertNil(item?.suggestedAction)
            let aiCallCount = await callCounter.currentValue()
            XCTAssertEqual(aiCallCount, 0)

            let cached = await MessageCacheService.shared.getPipelineCategory(chatId: chat.id)
            XCTAssertEqual(cached?.category, "quiet")
            XCTAssertEqual(cached?.suggestedAction, "")
        }
    }

    func testMessageCacheServiceIgnoresLegacyPipelineCacheSchemaVersion() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 777
            await DatabaseManager.shared.savePipelineCache(
                DatabaseManager.PipelineCacheRecord(
                    chatId: chatId,
                    category: "on_me",
                    suggestedAction: "Reply with a concrete next step.",
                    lastMessageId: 9001,
                    analyzedAt: Date(),
                    schemaVersion: MessageCacheService.pipelineCacheSchemaVersion - 1
                )
            )

            let cached = await MessageCacheService.shared.getPipelineCategory(chatId: chatId)
            XCTAssertNil(cached)
        }
    }

    func testConversationReplyHeuristicsIgnoresUnreadBurstWithoutReplySignal() {
        let myUserId: Int64 = 99
        let chat = TGChat(
            id: 2014843525,
            title: "Rahul Singh Bhadoriya",
            chatType: .privateChat(userId: 201),
            unreadCount: 1,
            lastMessage: nil,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let messages = [
            makeTGMessage(
                id: 700,
                chatId: chat.id,
                text: "1966",
                date: Date(timeIntervalSince1970: 1_775_852_994),
                senderUserId: myUserId,
                senderName: "Pratzyy",
                isOutgoing: true
            ),
            makeTGMessage(
                id: 701,
                chatId: chat.id,
                text: "https://etherscan.io/tx/0x6f935cbf381a36a10b57e5e9a5fbffba84b98a3046cbd6fe63a1b25735415e2c",
                date: Date(timeIntervalSince1970: 1_775_853_276),
                senderUserId: 201,
                senderName: "Rahul Singh Bhadoriya"
            ),
            makeTGMessage(
                id: 702,
                chatId: chat.id,
                text: "We still in the game",
                date: Date(timeIntervalSince1970: 1_776_356_495),
                senderUserId: 201,
                senderName: "Rahul Singh Bhadoriya"
            ),
            makeTGMessage(
                id: 703,
                chatId: chat.id,
                text: "Mazedar",
                date: Date(timeIntervalSince1970: 1_776_714_640),
                senderUserId: 201,
                senderName: "Rahul Singh Bhadoriya"
            )
        ]

        XCTAssertFalse(
            ConversationReplyHeuristics.hasPendingReplySignal(
                chat: chat,
                messages: messages,
                myUserId: myUserId
            )
        )
    }

    func testAppLaunchPresentationModeDefaultsToMenuBarPanel() {
        let mode = AppLaunchPresentationMode.resolve(
            environment: [:],
            allowsDebugWindow: true
        )

        XCTAssertEqual(mode, .menuBarPanel)
    }

    func testAppLaunchPresentationModeUsesDebugWindowWhenEnvEnabled() {
        let mode = AppLaunchPresentationMode.resolve(
            environment: [AppLaunchPresentationMode.environmentKey: "1"],
            allowsDebugWindow: true
        )

        XCTAssertEqual(mode, .debugWindow)
    }

    func testAppDashboardLaunchPolicyDefaultsToDashboardWindow() {
        XCTAssertTrue(AppDashboardLaunchPolicy.opensDashboardOnLaunch(environment: [:]))
        XCTAssertTrue(AppLaunchPresentationMode.menuBarPanel.activatesAsRegularApp)
    }

    func testAppDashboardLaunchPolicyAllowsExplicitOptOut() {
        XCTAssertFalse(
            AppDashboardLaunchPolicy.opensDashboardOnLaunch(
                environment: [AppDashboardLaunchPolicy.environmentKey: "0"]
            )
        )
    }

    func testLauncherChromeActionsKeepSettingsOutOfQuickLauncher() {
        XCTAssertEqual(LauncherChromeAction.allCases, [.dashboard])
        XCTAssertFalse(LauncherChromeAction.allCases.map(\.rawValue).contains("settings"))
        XCTAssertFalse(LauncherChromeAction.allCases.map(\.rawValue).contains("preferences"))
    }

    func testPidgyBrandingDefinesDashboardIdentity() {
        XCTAssertEqual(PidgyBranding.appName, "Pidgy")
        XCTAssertEqual(PidgyBranding.dashboardWindowTitle, "Pidgy")
        XCTAssertEqual(PidgyBranding.logoAssetName, "PidgyLogo")
        XCTAssertFalse(PidgyBranding.dashboardTagline.isEmpty)
    }

    @MainActor
    func testPreferencesRoutingUsesDashboardPreferencesPage() {
        let store = DashboardNavigationStore.shared
        store.show(.dashboard)

        PreferencesRouting.showAuthoritativePreferences(in: store)

        XCTAssertEqual(store.selectedPage, .preferences)
        XCTAssertEqual(PreferencesRouting.authoritativePage, .preferences)
        XCTAssertTrue(DashboardPreferencePage.allCases.contains(.pricing))
        XCTAssertTrue(DashboardPreferencePage.allCases.contains(.diagnostics))
    }

    func testDashboardChromePolicyFocusesPreferencesOnly() {
        XCTAssertEqual(DashboardChromePolicy.policy(for: .preferences), .focusedPreferences)
        XCTAssertFalse(DashboardChromePolicy.policy(for: .preferences).showsDashboardSidebar)
        XCTAssertFalse(DashboardChromePolicy.policy(for: .preferences).showsDashboardTopBar)

        for page in DashboardPage.allCases where page != .preferences {
            XCTAssertEqual(DashboardChromePolicy.policy(for: page), .standard)
            XCTAssertTrue(DashboardChromePolicy.policy(for: page).showsDashboardSidebar)
            XCTAssertTrue(DashboardChromePolicy.policy(for: page).showsDashboardTopBar)
        }
    }

    func testPreferencesResetPlanCoversCredentialsDefaultsAndPidgyDataDirectory() {
        XCTAssertEqual(
            Set(PreferencesResetPlan.credentialKeysToDelete),
            Set([
                .apiId,
                .apiHash,
                .aiProviderType,
                .aiApiKeyOpenAI,
                .aiApiKeyClaude,
                .aiModelOpenAI,
                .aiModelClaude,
                .aiApiKey,
                .aiModel
            ])
        )
        XCTAssertEqual(
            Set(PreferencesResetPlan.userDefaultsKeysToDelete),
            Set([
                AppConstants.Preferences.includeBotsInAISearchKey,
                AppConstants.Preferences.dashboardTaskTriageContextVersionKey
            ])
        )

        let appSupport = URL(fileURLWithPath: "/tmp/pidgy-support", isDirectory: true)
        XCTAssertEqual(
            PreferencesResetPlan.pidgyDataDirectory(in: appSupport),
            appSupport.appendingPathComponent("Pidgy", isDirectory: true)
        )
    }

    @MainActor
    func testDashboardDiagnosticsBuildsRoutingSnapshotsWithoutNetwork() async {
        let aiService = AIService(
            testingProvider: NoAIProvider(),
            providerType: .none,
            providerModel: "",
            isConfigured: false
        )

        let snapshots = await DashboardDiagnosticsService.routingSnapshots(
            query: "who do I need to reply to",
            aiService: aiService,
            now: Date(timeIntervalSince1970: 1_744_329_600),
            timezone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(snapshots.first?.query, "who do I need to reply to")
        XCTAssertEqual(snapshots.first?.runtimeIntent, .agenticSearch)
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)
    }

    func testQueryInterpreterRoutesCoreMVPQueries() {
        let interpreter = QueryInterpreter()
        let now = Date(timeIntervalSince1970: 1_744_329_600) // April 2025-ish fixed point

        let exact = interpreter.parse(
            query: "where I shared wallet address",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(exact.family, .exactLookup)
        XCTAssertEqual(exact.preferredEngine, .messageLookup)

        let artifactWithRecipient = interpreter.parse(
            query: "wallet I sent to Rahul",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(artifactWithRecipient.family, .exactLookup)
        XCTAssertEqual(artifactWithRecipient.preferredEngine, .messageLookup)

        let replyQueue = interpreter.parse(
            query: "who do I need to reply to only groups",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(replyQueue.family, .replyQueue)
        XCTAssertEqual(replyQueue.scope, .groups)

        let summary = interpreter.parse(
            query: "summarize my chats with Akhil from last week",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(summary.family, .summary)
        XCTAssertEqual(summary.preferredEngine, .summarize)
        XCTAssertNotNil(summary.timeRange)

        let replyExpanded = interpreter.parse(
            query: "What is on me today?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(replyExpanded.family, .replyQueue)
        XCTAssertEqual(replyExpanded.preferredEngine, .replyTriage)

        let summaryExpanded = interpreter.parse(
            query: "What are the key takeaways from the last week with Piyush?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(summaryExpanded.family, .summary)
        XCTAssertEqual(summaryExpanded.preferredEngine, .summarize)
        XCTAssertNotNil(summaryExpanded.timeRange)

        let builderProgramSummary = interpreter.parse(
            query: "What did we discuss about the builder program with Jack and Emma?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(builderProgramSummary.family, .summary)
        XCTAssertEqual(builderProgramSummary.preferredEngine, .summarize)

        let latestWithAkhil = interpreter.parse(
            query: "What's the latest with Akhil?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(latestWithAkhil.family, .summary)
        XCTAssertEqual(latestWithAkhil.preferredEngine, .summarize)

        let akhilDiscussion = interpreter.parse(
            query: "What did Akhil and I discuss last week?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(akhilDiscussion.family, .summary)
        XCTAssertEqual(akhilDiscussion.preferredEngine, .summarize)
        XCTAssertNotNil(akhilDiscussion.timeRange)

        let worthCheckingGroups = interpreter.parse(
            query: "anything worth checking in groups?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(worthCheckingGroups.family, .replyQueue)
        XCTAssertEqual(worthCheckingGroups.preferredEngine, .replyTriage)
        XCTAssertEqual(worthCheckingGroups.scope, .groups)

        let relationship = interpreter.parse(
            query: "What is the current state of my relationship with Rahul?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(relationship.family, .relationship)
        XCTAssertEqual(relationship.preferredEngine, .graphCRM)

        let staleRelationship = interpreter.parse(
            query: "Which contacts haven’t replied in a while?",
            now: now,
            timezone: TimeZone(secondsFromGMT: 0)!,
            activeFilter: .all
        )
        XCTAssertEqual(staleRelationship.family, .relationship)
    }

    @MainActor
    func testSearchCoordinatorShowsImmediateSummaryLoadingStateForDeterministicSummaryPrompt() {
        let aiService = AIService()
        aiService.configure(type: .none, apiKey: "")
        let coordinator = SearchCoordinator()
        let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])

        coordinator.triggerSearch(
            query: "What are the key takeaways from chat with Akhil?",
            activeScope: .all,
            aiSearchSourceChats: [],
            scopedAISearchSourceChats: [],
            includeBotsInAISearch: false,
            telegramService: telegramService,
            aiService: aiService,
            pipelineCategoryProvider: { _ in nil },
            pipelineHintProvider: { _ in "unknown" }
        )

        XCTAssertEqual(coordinator.aiSearchMode, .summarySearch)
        XCTAssertTrue(coordinator.isAISearching)
        XCTAssertNotNil(coordinator.searchStartedAt)
    }

    @MainActor
    func testSearchCoordinatorShowsImmediateReplyQueueLoadingStateForWorthCheckingPrompt() {
        let aiService = AIService()
        aiService.configure(type: .none, apiKey: "")
        let coordinator = SearchCoordinator()
        let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])

        coordinator.triggerSearch(
            query: "anything worth checking in groups?",
            activeScope: .all,
            aiSearchSourceChats: [],
            scopedAISearchSourceChats: [],
            includeBotsInAISearch: false,
            telegramService: telegramService,
            aiService: aiService,
            pipelineCategoryProvider: { _ in nil },
            pipelineHintProvider: { _ in "unknown" }
        )

        XCTAssertEqual(coordinator.aiSearchMode, .agenticSearch)
        XCTAssertTrue(coordinator.isAISearching)
        XCTAssertNotNil(coordinator.searchStartedAt)
    }

    @MainActor
    func testWorthCheckingPromptRunsDedicatedReplyQueuePath() async throws {
        try await withTempDatabase { _ in
            let myUserId: Int64 = 100
            let chatId: Int64 = -7_001
            let now = Date()
            let message = makeTGMessage(
                id: 12,
                chatId: chatId,
                text: "Pratzyy can you review this before launch?",
                date: now.addingTimeInterval(-60),
                senderUserId: 201,
                senderName: "Alice"
            )
            let groupChat = TGChat(
                id: chatId,
                title: "Launch Group",
                chatType: .supergroup(supergroupId: 7001, isChannel: false),
                unreadCount: 1,
                lastMessage: message,
                memberCount: 5,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: [message], append: false)
            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: myUserId,
                    firstName: "Pratzyy",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chatId: [message]]
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")
            let coordinator = SearchCoordinator()
            let querySpec = QueryInterpreter().parse(
                query: "anything worth checking in groups?",
                now: now,
                timezone: TimeZone(secondsFromGMT: 0)!,
                activeFilter: .all
            )

            let results = try await coordinator.executeAgenticSearch(
                query: "anything worth checking in groups?",
                querySpec: querySpec,
                searchRunID: coordinator.activeSearchRunID,
                activeScope: .all,
                aiSearchSourceChats: [groupChat],
                includeBotsInAISearch: false,
                telegramService: telegramService,
                aiService: aiService,
                pipelineCategoryProvider: { _ in nil },
                pipelineHintProvider: { _ in "quiet" }
            )

            XCTAssertTrue(results.contains { result in
                if case .replyQueueResult = result { return true }
                return false
            })
            XCTAssertFalse(results.contains { result in
                if case .agenticResult = result { return true }
                return false
            })
        }
    }

    @MainActor
    func testQueryRouterUsesAIPlannerFallbackForAmbiguousSummaryPrompt() async {
        let plannerResult = QueryPlannerResultDTO(
            family: "summary",
            scope: "inherit",
            timeRange: "last_week",
            people: ["jack", "emma"],
            topicTerms: ["builder program"],
            confidence: 0.93
        )
        let router = QueryRouter(
            aiProvider: StubAIProvider(queryPlannerResult: plannerResult),
            queryInterpreter: QueryInterpreter()
        )
        let now = Date(timeIntervalSince1970: 1_744_329_600)

        let resolved = await router.resolveQuerySpec(
            query: "Jack and Emma builder program context?",
            activeFilter: .all,
            timezone: TimeZone(secondsFromGMT: 0)!,
            now: now
        )

        XCTAssertEqual(resolved.family, .summary)
        XCTAssertEqual(resolved.preferredEngine, .summarize)
        XCTAssertNotNil(resolved.timeRange)
        XCTAssertEqual(resolved.plannerHints?.people, ["jack", "emma"])
        XCTAssertEqual(resolved.plannerHints?.topicTerms, ["builder", "program"])
        XCTAssertGreaterThanOrEqual(resolved.parseConfidence, 0.93)
    }

    @MainActor
    func testQueryRouterPlannerCanClearFalsePositiveMonthRange() async {
        let plannerResult = QueryPlannerResultDTO(
            family: "reply_queue",
            scope: "groups",
            timeRange: "none",
            people: [],
            topicTerms: [],
            confidence: 0.95
        )
        let router = QueryRouter(
            aiProvider: StubAIProvider(queryPlannerResult: plannerResult),
            queryInterpreter: QueryInterpreter()
        )
        let now = Date(timeIntervalSince1970: 1_777_065_600)

        let resolved = await router.resolveQuerySpec(
            query: "anything may be worth checking in groups?",
            activeFilter: .all,
            timezone: TimeZone(secondsFromGMT: 0)!,
            now: now
        )

        XCTAssertEqual(resolved.family, .replyQueue)
        XCTAssertNil(resolved.timeRange)
    }

    @MainActor
    func testQueryRouterFallsBackWhenAIPlannerFails() async {
        let router = QueryRouter(
            aiProvider: StubAIProvider(queryPlannerError: AIError.providerNotConfigured),
            queryInterpreter: QueryInterpreter()
        )
        let now = Date(timeIntervalSince1970: 1_744_329_600)

        let resolved = await router.resolveQuerySpec(
            query: "Jack and Emma builder program context?",
            activeFilter: .all,
            timezone: TimeZone(secondsFromGMT: 0)!,
            now: now
        )

        XCTAssertEqual(resolved.family, .topicSearch)
        XCTAssertEqual(resolved.preferredEngine, .semanticRetrieval)
        XCTAssertNil(resolved.plannerHints)
    }

    @MainActor
    func testAIServicePersistsProviderScopedKeysWithoutResettingOnNone() async throws {
        let service = AIService()
        service.configure(type: .openai, apiKey: "sk-openai", model: nil)
        service.configure(type: .claude, apiKey: "sk-claude", model: "claude-custom")
        service.configure(type: .none, apiKey: "", model: nil)

        let reloaded = AIService()
        XCTAssertEqual(reloaded.providerType, .none)

        let openAI = try XCTUnwrap(reloaded.persistedConfiguration(for: .openai))
        XCTAssertEqual(openAI.apiKey, "sk-openai")
        XCTAssertEqual(openAI.model, AppConstants.AI.defaultOpenAIModel)

        let claude = try XCTUnwrap(reloaded.persistedConfiguration(for: .claude))
        XCTAssertEqual(claude.apiKey, "sk-claude")
        XCTAssertEqual(claude.model, "claude-custom")
    }

    func testKeychainManagerUsesNativeKeychainForAISecretsWhenForcedForTesting() throws {
        let service = "pidgy.tests.\(UUID().uuidString)"
        KeychainManager.configureForTesting(
            storageDirectoryOverride: tempCredentialDirectory,
            keychainServiceOverride: service,
            nativeKeyOverride: [.aiApiKeyOpenAI]
        )
        defer {
            try? KeychainManager.delete(for: .aiApiKeyOpenAI)
            KeychainManager.configureForTesting(storageDirectoryOverride: tempCredentialDirectory)
        }

        try KeychainManager.save("sk-native", for: .aiApiKeyOpenAI)
        let retrieved = try XCTUnwrap(KeychainManager.retrieve(for: .aiApiKeyOpenAI))
        XCTAssertEqual(retrieved, "sk-native")

        if let tempCredentialDirectory {
            let fileURL = tempCredentialDirectory.appendingPathComponent(KeychainManager.Key.aiApiKeyOpenAI.rawValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testKeychainManagerMigratesAISecretsFromFileToNativeKeychainWhenForcedForTesting() throws {
        let service = "pidgy.tests.\(UUID().uuidString)"
        try KeychainManager.save("sk-legacy-file", for: .aiApiKeyClaude)
        let legacyFileURL = try XCTUnwrap(tempCredentialDirectory).appendingPathComponent(KeychainManager.Key.aiApiKeyClaude.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFileURL.path))

        KeychainManager.configureForTesting(
            storageDirectoryOverride: tempCredentialDirectory,
            keychainServiceOverride: service,
            nativeKeyOverride: [.aiApiKeyClaude]
        )
        defer {
            try? KeychainManager.delete(for: .aiApiKeyClaude)
            KeychainManager.configureForTesting(storageDirectoryOverride: tempCredentialDirectory)
        }

        let migrated = try XCTUnwrap(KeychainManager.retrieve(for: .aiApiKeyClaude))
        XCTAssertEqual(migrated, "sk-legacy-file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFileURL.path))

        try KeychainManager.delete(for: .aiApiKeyClaude)
        XCTAssertNil(try KeychainManager.retrieve(for: .aiApiKeyClaude))

        if let tempCredentialDirectory {
            let fileURL = tempCredentialDirectory.appendingPathComponent(KeychainManager.Key.aiApiKeyClaude.rawValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    func testKeychainManagerTreatsTelegramAPIHashAsProductionNativeSecret() {
        XCTAssertTrue(KeychainManager.usesNativeKeychainInProductionForTesting(.apiHash))
    }

    @MainActor
    func testSummaryEngineBuildsFocusedRetrievalQueryForPersonScopedRecap() {
        let prompts = [
            "What are the key takeaways from the last week with Akhil?",
            "what are the key takeaways from chat with Akhil?",
            "Catch me up on Akhil from last week.",
            "What did Akhil and I discuss last week?",
            "Summarize my recent Akhil chats.",
            "What's the recent context from my Akhil chats?",
            "Give me the last-week recap for Akhil.",
            "Catch me up on the latest Akhil thread.",
            "What's the latest with Akhil?"
        ]

        for prompt in prompts {
            let retrieval = SummaryEngine.shared.retrievalQueryForTesting(prompt)
            XCTAssertEqual(retrieval, "akhil", prompt)
        }
    }

    @MainActor
    func testSummaryEngineKeepsDuplicateMessageIdsFromDifferentChats() {
        let first = makeTGMessage(
            id: 7001,
            chatId: 8801,
            text: "First chat context should stay in the merge.",
            date: Date().addingTimeInterval(-60)
        )
        let second = makeTGMessage(
            id: 7001,
            chatId: 8802,
            text: "Second chat context should also stay in the merge.",
            date: Date()
        )

        let merged = SummaryEngine.shared.mergedSummaryMessagesForTesting(
            cached: [first],
            local: [second]
        )

        XCTAssertEqual(Set(merged.map { "\($0.chatId):\($0.id)" }), Set(["8801:7001", "8802:7001"]))
    }

    @MainActor
    func testSummaryEngineUsesLocalMessagesWithinRequestedTimeWindow() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 777
            let oldDate = Date(timeIntervalSince1970: 1_744_000_000)
            let recentDate = Date(timeIntervalSince1970: 1_744_600_000)

            let oldRecord = makeRecord(id: 501, chatId: chatId, text: "Decision: ship the weekly update on Friday.", date: oldDate)
            let recentRecord = makeRecord(id: 502, chatId: chatId, text: "Newest chatter outside the requested range.", date: recentDate)

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [oldRecord, recentRecord],
                preferredOldestMessageId: oldRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let oldMessage = makeTGMessage(
                id: oldRecord.id,
                chatId: chatId,
                text: oldRecord.textContent ?? "",
                date: oldRecord.date
            )
            let latestMessage = makeTGMessage(
                id: recentRecord.id,
                chatId: chatId,
                text: recentRecord.textContent ?? "",
                date: recentRecord.date
            )

            let chat = TGChat(
                id: chatId,
                title: "Akhil",
                chatType: .privateChat(userId: 99),
                unreadCount: 0,
                lastMessage: latestMessage,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let timeRange = TimeRangeConstraint(
                startDate: oldDate.addingTimeInterval(-60),
                endDate: oldDate.addingTimeInterval(60),
                label: "Focused window"
            )

            let querySpec = QuerySpec(
                rawQuery: "what did we decide with Akhil",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: timeRange,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [.init(message: oldMessage, score: 1.0)],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingMessageIds, [501])
            XCTAssertTrue(output.summaryText.contains("Decision: ship the weekly update on Friday."))
            XCTAssertFalse(output.summaryText.contains("Newest chatter outside the requested range."))
        }
    }

    @MainActor
    func testSummaryEngineMergesDurableHistoryWithRecentCacheWhenNoTimeRange() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 7771
            let recentDate = Date().addingTimeInterval(-10 * 60)
            let olderDate = recentDate.addingTimeInterval(-2 * 86_400)

            let decisionRecord = makeRecord(
                id: 511,
                chatId: chatId,
                text: "Decision: ship the founder deck after Rahul review.",
                date: olderDate
            )
            let indexedRecentRecord = makeRecord(
                id: 512,
                chatId: chatId,
                text: "Indexed recent context that should still stay available.",
                date: recentDate.addingTimeInterval(-60)
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [decisionRecord, indexedRecentRecord],
                preferredOldestMessageId: decisionRecord.id,
                isSearchReady: true
            )

            let liveRecentMessage = makeTGMessage(
                id: 513,
                chatId: chatId,
                text: "Very recent cache-only chatter.",
                date: recentDate
            )
            await MessageCacheService.shared.cacheMessages(
                chatId: chatId,
                messages: [liveRecentMessage],
                append: true
            )

            let decisionMessage = makeTGMessage(
                id: decisionRecord.id,
                chatId: chatId,
                text: decisionRecord.textContent ?? "",
                date: decisionRecord.date
            )

            let chat = TGChat(
                id: chatId,
                title: "Rahul",
                chatType: .privateChat(userId: 991),
                unreadCount: 1,
                lastMessage: liveRecentMessage,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "what did we decide with Rahul",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [.init(message: decisionMessage, score: 1.0)],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertTrue(output.supportingMessageIds.contains(511))
            XCTAssertTrue(output.summaryText.contains("Decision: ship the founder deck after Rahul review."))
        }
    }

    @MainActor
    func testSummaryEngineTreatsKeyTakeawaysAsGenericSummaryCueNotTopicConstraint() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 7788
            let withinRange = Date(timeIntervalSince1970: 1_775_817_926)
            let olderDate = withinRange.addingTimeInterval(-10 * 86_400)

            let recentRecord = makeRecord(
                id: 551,
                chatId: chatId,
                text: "We should finalize the sponsorship budget and the media team plan tomorrow.",
                date: withinRange
            )
            let olderRecord = makeRecord(
                id: 552,
                chatId: chatId,
                text: "Much older Akhil context that should stay outside the requested week.",
                date: olderDate
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [olderRecord, recentRecord],
                preferredOldestMessageId: olderRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let recentMessage = makeTGMessage(
                id: recentRecord.id,
                chatId: chatId,
                text: recentRecord.textContent ?? "",
                date: recentRecord.date
            )

            let chat = TGChat(
                id: chatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 301),
                unreadCount: 0,
                lastMessage: recentMessage,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let timeRange = TimeRangeConstraint(
                startDate: withinRange.addingTimeInterval(-60),
                endDate: withinRange.addingTimeInterval(60),
                label: "Last week"
            )

            let querySpec = QuerySpec(
                rawQuery: "What are the key takeaways from the last week with Akhil?",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: timeRange,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [.init(message: recentMessage, score: 0.92)],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, chatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("sponsorship budget"))
            XCTAssertFalse(output.summaryText.lowercased().contains("older akhil context"))
        }
    }

    @MainActor
    func testSummaryEngineFindsPersonScopedRecapFromSenderNameFallback() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 7799
            let withinRange = Date(timeIntervalSince1970: 1_775_731_828)

            let firstRecord = DatabaseManager.MessageRecord(
                id: 651,
                chatId: chatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange,
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let secondRecord = DatabaseManager.MessageRecord(
                id: 652,
                chatId: chatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange.addingTimeInterval(600),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [firstRecord, secondRecord],
                preferredOldestMessageId: firstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let lastMessage = TGMessage(
                id: secondRecord.id,
                chatId: chatId,
                senderId: .user(42),
                date: secondRecord.date,
                textContent: secondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Akhil B",
                senderName: "Akhil B"
            )

            let chat = TGChat(
                id: chatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 42),
                unreadCount: 0,
                lastMessage: lastMessage,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let timeRange = TimeRangeConstraint(
                startDate: withinRange.addingTimeInterval(-60),
                endDate: withinRange.addingTimeInterval(660),
                label: "Last week"
            )

            let querySpec = QuerySpec(
                rawQuery: "What are the key takeaways from the last week with Akhil?",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: timeRange,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, chatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("builders"))
            XCTAssertTrue(output.summaryText.lowercased().contains("5k"))
        }
    }

    @MainActor
    func testSummaryEnginePrefersSenderRichGroupOverMediaOnlyDirectChat() async throws {
        try await withTempDatabase { _ in
            let directChatId: Int64 = 7801
            let groupChatId: Int64 = 7802
            let withinRange = Date(timeIntervalSince1970: 1_776_172_247)

            let directRecord = DatabaseManager.MessageRecord(
                id: 701,
                chatId: directChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange,
                textContent: nil,
                mediaTypeRaw: TGMessage.MediaType.other.rawValue,
                isOutgoing: false
            )
            let groupFirstRecord = DatabaseManager.MessageRecord(
                id: 702,
                chatId: groupChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange.addingTimeInterval(-2 * 86_400),
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let groupSecondRecord = DatabaseManager.MessageRecord(
                id: 703,
                chatId: groupChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange.addingTimeInterval(-1 * 86_400),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: directChatId,
                messages: [directRecord],
                preferredOldestMessageId: directRecord.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: groupChatId,
                messages: [groupFirstRecord, groupSecondRecord],
                preferredOldestMessageId: groupFirstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let directChat = TGChat(
                id: directChatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 42),
                unreadCount: 0,
                lastMessage: TGMessage(
                    id: directRecord.id,
                    chatId: directChatId,
                    senderId: .user(42),
                    date: directRecord.date,
                    textContent: nil,
                    mediaType: .other,
                    isOutgoing: false,
                    chatTitle: "Akhil B",
                    senderName: "Akhil B"
                ),
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let groupChat = TGChat(
                id: groupChatId,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 88, isChannel: false),
                unreadCount: 0,
                lastMessage: TGMessage(
                    id: groupSecondRecord.id,
                    chatId: groupChatId,
                    senderId: .user(42),
                    date: groupSecondRecord.date,
                    textContent: groupSecondRecord.textContent,
                    mediaType: nil,
                    isOutgoing: false,
                    chatTitle: "AI Weekends <> Inner Circle",
                    senderName: "Akhil B"
                ),
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let timeRange = TimeRangeConstraint(
                startDate: withinRange.addingTimeInterval(-7 * 86_400),
                endDate: withinRange.addingTimeInterval(60),
                label: "Last week"
            )
            let querySpec = QuerySpec(
                rawQuery: "What are the key takeaways from the last week with Akhil?",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: timeRange,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [directChat, groupChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, groupChatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("builders"))
            XCTAssertFalse(output.summaryText.contains("[Media]"))
        }
    }

    @MainActor
    func testSummaryEnginePrefersFocusedAkhilContextAcrossPromptVariants() async throws {
        try await withTempDatabase { _ in
            let genericChatId: Int64 = 7803
            let focusedChatId: Int64 = 7804
            let withinRange = Date(timeIntervalSince1970: 1_776_172_247)

            let genericRecord = DatabaseManager.MessageRecord(
                id: 801,
                chatId: genericChatId,
                senderUserId: 91,
                senderName: "Core Member",
                date: withinRange,
                textContent: "Akhil join emergent",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let focusedFirstRecord = DatabaseManager.MessageRecord(
                id: 802,
                chatId: focusedChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange.addingTimeInterval(-2 * 86_400),
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let focusedSecondRecord = DatabaseManager.MessageRecord(
                id: 803,
                chatId: focusedChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: withinRange.addingTimeInterval(-1 * 86_400),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: genericChatId,
                messages: [genericRecord],
                preferredOldestMessageId: genericRecord.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: focusedChatId,
                messages: [focusedFirstRecord, focusedSecondRecord],
                preferredOldestMessageId: focusedFirstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let genericMessage = TGMessage(
                id: genericRecord.id,
                chatId: genericChatId,
                senderId: .user(91),
                date: genericRecord.date,
                textContent: genericRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Core(EANSG)",
                senderName: genericRecord.senderName
            )
            let focusedFirstMessage = TGMessage(
                id: focusedFirstRecord.id,
                chatId: focusedChatId,
                senderId: .user(42),
                date: focusedFirstRecord.date,
                textContent: focusedFirstRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: focusedFirstRecord.senderName
            )
            let focusedSecondMessage = TGMessage(
                id: focusedSecondRecord.id,
                chatId: focusedChatId,
                senderId: .user(42),
                date: focusedSecondRecord.date,
                textContent: focusedSecondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: focusedSecondRecord.senderName
            )

            let genericChat = TGChat(
                id: genericChatId,
                title: "Core(EANSG)",
                chatType: .supergroup(supergroupId: 89, isChannel: false),
                unreadCount: 0,
                lastMessage: genericMessage,
                memberCount: nil,
                order: 3,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let focusedChat = TGChat(
                id: focusedChatId,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 90, isChannel: false),
                unreadCount: 0,
                lastMessage: focusedSecondMessage,
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let prompts = [
                "What are the key takeaways from the last week with Akhil?",
                "what are the key takeaways from chat with Akhil?",
                "Catch me up on Akhil from last week."
            ]

            for prompt in prompts {
                let timeRange = TimeRangeConstraint(
                    startDate: withinRange.addingTimeInterval(-7 * 86_400),
                    endDate: withinRange.addingTimeInterval(60),
                    label: "Last week"
                )
                let querySpec = QuerySpec(
                    rawQuery: prompt,
                    mode: .summarySearch,
                    family: .summary,
                    preferredEngine: .summarize,
                    scope: .all,
                    scopeWasExplicit: false,
                    replyConstraint: .none,
                    timeRange: timeRange,
                    parseConfidence: 0.9,
                    unsupportedFragments: []
                )

                let telegramService = TestTelegramService(
                    scoredHits: [
                        .init(message: genericMessage, score: 0.96),
                        .init(message: focusedFirstMessage, score: 0.72),
                        .init(message: focusedSecondMessage, score: 0.69)
                    ],
                    vectorHits: []
                )
                let aiService = AIService()
                aiService.configure(type: .none, apiKey: "")

                let execution = await SummaryEngine.shared.search(
                    query: querySpec,
                    scope: .all,
                    scopedChats: [genericChat, focusedChat],
                    telegramService: telegramService,
                    aiService: aiService
                )

                let output = try XCTUnwrap(execution.output, prompt)
                XCTAssertEqual(output.supportingChatId, focusedChatId, prompt)
                XCTAssertTrue(output.summaryText.lowercased().contains("builders"), prompt)
                XCTAssertTrue(output.summaryText.lowercased().contains("5k"), prompt)
                XCTAssertFalse(output.summaryText.lowercased().contains("emergent"), prompt)
            }
        }
    }

    @MainActor
    func testSummaryEngineDefaultsSingleEntityRecapToRecentContextWithoutExplicitTimeRange() async throws {
        try await withTempDatabase { _ in
            let oldChatId: Int64 = 7805
            let recentChatId: Int64 = 7806
            let now = Date()
            let oldDate = now.addingTimeInterval(-40 * 86_400)
            let recentDate = now.addingTimeInterval(-2 * 86_400)

            let oldRecord = DatabaseManager.MessageRecord(
                id: 811,
                chatId: oldChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: oldDate,
                textContent: "Old Akhil planning thread about media articles and SEO that should not win a recent recap by default.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let recentFirstRecord = DatabaseManager.MessageRecord(
                id: 812,
                chatId: recentChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: recentDate,
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let recentSecondRecord = DatabaseManager.MessageRecord(
                id: 813,
                chatId: recentChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: recentDate.addingTimeInterval(300),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: oldChatId,
                messages: [oldRecord],
                preferredOldestMessageId: oldRecord.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: recentChatId,
                messages: [recentFirstRecord, recentSecondRecord],
                preferredOldestMessageId: recentFirstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let oldMessage = TGMessage(
                id: oldRecord.id,
                chatId: oldChatId,
                senderId: .user(42),
                date: oldRecord.date,
                textContent: oldRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Akhil B",
                senderName: "Akhil B"
            )
            let recentFirstMessage = TGMessage(
                id: recentFirstRecord.id,
                chatId: recentChatId,
                senderId: .user(42),
                date: recentFirstRecord.date,
                textContent: recentFirstRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )
            let recentSecondMessage = TGMessage(
                id: recentSecondRecord.id,
                chatId: recentChatId,
                senderId: .user(42),
                date: recentSecondRecord.date,
                textContent: recentSecondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )

            let oldChat = TGChat(
                id: oldChatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 42),
                unreadCount: 0,
                lastMessage: oldMessage,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let recentChat = TGChat(
                id: recentChatId,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 91, isChannel: false),
                unreadCount: 0,
                lastMessage: recentSecondMessage,
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "Give me a quick recap of my chats with Akhil.",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [
                    .init(message: oldMessage, score: 0.98),
                    .init(message: recentFirstMessage, score: 0.73),
                    .init(message: recentSecondMessage, score: 0.71)
                ],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [oldChat, recentChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, recentChatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("builders"))
            XCTAssertTrue(output.summaryText.lowercased().contains("5k"))
            XCTAssertFalse(output.summaryText.lowercased().contains("seo"))
        }
    }

    @MainActor
    func testSummaryEngineCombinesTopRecentAnchoredChatsForPersonScopedRecap() async throws {
        try await withTempDatabase { _ in
            let strategyChatId: Int64 = 7807
            let eventsChatId: Int64 = 7808
            let now = Date()
            let strategyDate = now.addingTimeInterval(-3 * 86_400)
            let eventsDate = now.addingTimeInterval(-2 * 86_400)

            let strategyFirstRecord = DatabaseManager.MessageRecord(
                id: 821,
                chatId: strategyChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: strategyDate,
                textContent: "i need to setup a media team and travel budgets to execute.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let strategySecondRecord = DatabaseManager.MessageRecord(
                id: 822,
                chatId: strategyChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: strategyDate.addingTimeInterval(240),
                textContent: "need to crack sponsorship for this.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let eventsFirstRecord = DatabaseManager.MessageRecord(
                id: 823,
                chatId: eventsChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: eventsDate,
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let eventsSecondRecord = DatabaseManager.MessageRecord(
                id: 824,
                chatId: eventsChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: eventsDate.addingTimeInterval(300),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: strategyChatId,
                messages: [strategyFirstRecord, strategySecondRecord],
                preferredOldestMessageId: strategyFirstRecord.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: eventsChatId,
                messages: [eventsFirstRecord, eventsSecondRecord],
                preferredOldestMessageId: eventsFirstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let strategyFirstMessage = TGMessage(
                id: strategyFirstRecord.id,
                chatId: strategyChatId,
                senderId: .user(42),
                date: strategyFirstRecord.date,
                textContent: strategyFirstRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Core(EANSG)",
                senderName: "Akhil B"
            )
            let strategySecondMessage = TGMessage(
                id: strategySecondRecord.id,
                chatId: strategyChatId,
                senderId: .user(42),
                date: strategySecondRecord.date,
                textContent: strategySecondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "Core(EANSG)",
                senderName: "Akhil B"
            )
            let eventsFirstMessage = TGMessage(
                id: eventsFirstRecord.id,
                chatId: eventsChatId,
                senderId: .user(42),
                date: eventsFirstRecord.date,
                textContent: eventsFirstRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )
            let eventsSecondMessage = TGMessage(
                id: eventsSecondRecord.id,
                chatId: eventsChatId,
                senderId: .user(42),
                date: eventsSecondRecord.date,
                textContent: eventsSecondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )

            let strategyChat = TGChat(
                id: strategyChatId,
                title: "Core(EANSG)",
                chatType: .supergroup(supergroupId: 92, isChannel: false),
                unreadCount: 0,
                lastMessage: strategySecondMessage,
                memberCount: nil,
                order: 3,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let eventsChat = TGChat(
                id: eventsChatId,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 93, isChannel: false),
                unreadCount: 0,
                lastMessage: eventsSecondMessage,
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "Give me a quick recap of my chats with Akhil.",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [
                    .init(message: strategyFirstMessage, score: 0.96),
                    .init(message: strategySecondMessage, score: 0.91),
                    .init(message: eventsFirstMessage, score: 0.73),
                    .init(message: eventsSecondMessage, score: 0.71)
                ],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [strategyChat, eventsChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, strategyChatId)
            XCTAssertTrue(output.title.contains("Recent Akhil Context"))
            XCTAssertTrue(output.summaryText.lowercased().contains("media team"))
            XCTAssertTrue(output.summaryText.lowercased().contains("builders"))
            XCTAssertTrue(output.summaryText.lowercased().contains("5k"))
            XCTAssertTrue(Set(output.supportingMessageIds).isSuperset(of: [821, 823]))
        }
    }

    @MainActor
    func testSummaryEngineDoesNotLetHighVolumePersonDMBeatRicherRecentContext() async throws {
        try await withTempDatabase { _ in
            let noisyDirectChatId: Int64 = 7809
            let focusedGroupChatId: Int64 = 7810
            let now = Date()

            let directRecords: [DatabaseManager.MessageRecord] = (0..<12).map { index in
                DatabaseManager.MessageRecord(
                    id: Int64(830 + index),
                    chatId: noisyDirectChatId,
                    senderUserId: 42,
                    senderName: "Akhil B",
                    date: now.addingTimeInterval(TimeInterval(-(index + 1) * 300)),
                    textContent: ["done", "one min", "check once", "hmm", "okay", "yess", "cool", "got it", "later", "noted", "fine", "send?"][index],
                    mediaTypeRaw: nil,
                    isOutgoing: false
                )
            }

            let focusedFirstRecord = DatabaseManager.MessageRecord(
                id: 850,
                chatId: focusedGroupChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: now.addingTimeInterval(-2 * 86_400),
                textContent: "few things: have our builders to showcase at their event and us as speakers representing agentic summer",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let focusedSecondRecord = DatabaseManager.MessageRecord(
                id: 851,
                chatId: focusedGroupChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: now.addingTimeInterval(-2 * 86_400 + 300),
                textContent: "lifi will confirm their 5k in a bit.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: noisyDirectChatId,
                messages: directRecords,
                preferredOldestMessageId: directRecords.last?.id ?? 830,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: focusedGroupChatId,
                messages: [focusedFirstRecord, focusedSecondRecord],
                preferredOldestMessageId: focusedFirstRecord.id,
                isSearchReady: true
            )
            await MessageCacheService.shared.invalidateAll()

            let directMessages = directRecords.map { record in
                TGMessage(
                    id: record.id,
                    chatId: noisyDirectChatId,
                    senderId: .user(42),
                    date: record.date,
                    textContent: record.textContent,
                    mediaType: nil,
                    isOutgoing: false,
                    chatTitle: "Akhil B",
                    senderName: "Akhil B"
                )
            }
            let focusedFirstMessage = TGMessage(
                id: focusedFirstRecord.id,
                chatId: focusedGroupChatId,
                senderId: .user(42),
                date: focusedFirstRecord.date,
                textContent: focusedFirstRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )
            let focusedSecondMessage = TGMessage(
                id: focusedSecondRecord.id,
                chatId: focusedGroupChatId,
                senderId: .user(42),
                date: focusedSecondRecord.date,
                textContent: focusedSecondRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: "AI Weekends <> Inner Circle",
                senderName: "Akhil B"
            )

            let noisyDirectChat = TGChat(
                id: noisyDirectChatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 42),
                unreadCount: 0,
                lastMessage: directMessages.first,
                memberCount: nil,
                order: 4,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let focusedGroupChat = TGChat(
                id: focusedGroupChatId,
                title: "AI Weekends <> Inner Circle",
                chatType: .supergroup(supergroupId: 94, isChannel: false),
                unreadCount: 0,
                lastMessage: focusedSecondMessage,
                memberCount: nil,
                order: 3,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "What are the key takeaways from chat with Akhil?",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let scoredHits = directMessages.map { TelegramService.LocalMessageSearchHit(message: $0, score: 0.93) } + [
                .init(message: focusedFirstMessage, score: 0.88),
                .init(message: focusedSecondMessage, score: 0.87)
            ]

            let telegramService = TestTelegramService(
                scoredHits: scoredHits,
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [noisyDirectChat, focusedGroupChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, focusedGroupChatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("builders"))
            XCTAssertTrue(output.summaryText.lowercased().contains("5k"))
            XCTAssertFalse(output.summaryText.lowercased().contains("check once"))
        }
    }

    @MainActor
    func testSummaryEnginePrefersFocusedRecapChatOverGenericMentions() async throws {
        try await withTempDatabase { _ in
            let genericChatId: Int64 = 778
            let focusedChatId: Int64 = 779
            let baseDate = Date(timeIntervalSince1970: 1_775_817_926)

            let genericMessage = makeRecord(
                id: 601,
                chatId: genericChatId,
                text: "First dollar first dollar radar room",
                date: baseDate.addingTimeInterval(-120)
            )
            let focusedMessage = makeRecord(
                id: 602,
                chatId: focusedChatId,
                text: "First Dollar is a base native talent network. You can run UGC campaigns, dev/design bounties, and Radar Room helps founders get users and feedback.",
                date: baseDate.addingTimeInterval(-60)
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: genericChatId,
                messages: [genericMessage],
                preferredOldestMessageId: genericMessage.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: focusedChatId,
                messages: [focusedMessage],
                preferredOldestMessageId: focusedMessage.id,
                isSearchReady: true
            )

            let genericChat = TGChat(
                id: genericChatId,
                title: "Generic chatter",
                chatType: .privateChat(userId: 201),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let focusedChat = TGChat(
                id: focusedChatId,
                title: "First Dollar Overview",
                chatType: .privateChat(userId: 202),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let genericTG = makeTGMessage(id: genericMessage.id, chatId: genericChatId, text: genericMessage.textContent ?? "", date: genericMessage.date)
            let focusedTG = makeTGMessage(id: focusedMessage.id, chatId: focusedChatId, text: focusedMessage.textContent ?? "", date: focusedMessage.date)

            let querySpec = QuerySpec(
                rawQuery: "Give me a quick summary of First Dollar.",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [
                    .init(message: genericTG, score: 1.0),
                    .init(message: focusedTG, score: 0.72)
                ],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [genericChat, focusedChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, focusedChatId)
            XCTAssertTrue(output.summaryText.lowercased().contains("base native talent network"))
        }
    }

    @MainActor
    func testSummaryEngineRejectsFakePersonTopicOverlap() async throws {
        try await withTempDatabase { _ in
            let sophiaChatId: Int64 = 780
            let walletChatId: Int64 = 781
            let baseDate = Date()

            let sophiaMessage = makeRecord(
                id: 611,
                chatId: sophiaChatId,
                text: "Sophia said she will take a look tomorrow.",
                date: baseDate.addingTimeInterval(-120)
            )
            let walletMessage = makeRecord(
                id: 612,
                chatId: walletChatId,
                text: "Send wallet address for salary.",
                date: baseDate.addingTimeInterval(-60)
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: sophiaChatId,
                messages: [sophiaMessage],
                preferredOldestMessageId: sophiaMessage.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: walletChatId,
                messages: [walletMessage],
                preferredOldestMessageId: walletMessage.id,
                isSearchReady: true
            )

            let sophiaChat = TGChat(
                id: sophiaChatId,
                title: "Sophia",
                chatType: .privateChat(userId: 203),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let walletChat = TGChat(
                id: walletChatId,
                title: "Ops",
                chatType: .privateChat(userId: 204),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let sophiaTG = makeTGMessage(id: sophiaMessage.id, chatId: sophiaChatId, text: sophiaMessage.textContent ?? "", date: sophiaMessage.date)
            let walletTG = makeTGMessage(id: walletMessage.id, chatId: walletChatId, text: walletMessage.textContent ?? "", date: walletMessage.date)

            let querySpec = QuerySpec(
                rawQuery: "Summarize my chats with Sophia about wallet addresses.",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(
                scoredHits: [
                    .init(message: sophiaTG, score: 0.9),
                    .init(message: walletTG, score: 0.85)
                ],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [sophiaChat, walletChat],
                telegramService: telegramService,
                aiService: aiService
            )

            XCTAssertNil(execution.output)
        }
    }

    @MainActor
    func testSummaryEnginePlannerHintsPreferSenderAnchoredAkhilChatOverIncidentalMention() async throws {
        try await withTempDatabase { _ in
            let genericChatId: Int64 = 8891
            let focusedChatId: Int64 = 8892
            let baseDate = Date().addingTimeInterval(-2 * 86_400)

            let genericRecord = DatabaseManager.MessageRecord(
                id: 991,
                chatId: genericChatId,
                senderUserId: 10,
                senderName: "Core Member",
                date: baseDate,
                textContent: "Send location once Akhil",
                mediaTypeRaw: nil,
                isOutgoing: false
            )
            let focusedRecord = DatabaseManager.MessageRecord(
                id: 992,
                chatId: focusedChatId,
                senderUserId: 42,
                senderName: "Akhil B",
                date: baseDate.addingTimeInterval(-300),
                textContent: "I'll get him added to our Claude plan to use.",
                mediaTypeRaw: nil,
                isOutgoing: false
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: genericChatId,
                messages: [genericRecord],
                preferredOldestMessageId: genericRecord.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: focusedChatId,
                messages: [focusedRecord],
                preferredOldestMessageId: focusedRecord.id,
                isSearchReady: true
            )

            let genericChat = TGChat(
                id: genericChatId,
                title: "Core(EANSG)",
                chatType: .basicGroup(groupId: genericChatId),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: 8,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let focusedChat = TGChat(
                id: focusedChatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 42),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let genericTG = TGMessage(
                id: genericRecord.id,
                chatId: genericChatId,
                senderId: .user(10),
                date: genericRecord.date,
                textContent: genericRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: genericChat.title,
                senderName: genericRecord.senderName
            )
            let focusedTG = TGMessage(
                id: focusedRecord.id,
                chatId: focusedChatId,
                senderId: .user(42),
                date: focusedRecord.date,
                textContent: focusedRecord.textContent,
                mediaType: nil,
                isOutgoing: false,
                chatTitle: focusedChat.title,
                senderName: focusedRecord.senderName
            )

            let querySpec = QuerySpec(
                rawQuery: "What's the latest with Akhil?",
                mode: .summarySearch,
                family: .summary,
                preferredEngine: .summarize,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.65,
                unsupportedFragments: [],
                plannerHints: QueryPlannerHints(
                    people: ["akhil"],
                    topicTerms: []
                )
            )

            let telegramService = TestTelegramService(
                scoredHits: [
                    .init(message: genericTG, score: 1.0),
                    .init(message: focusedTG, score: 0.58)
                ],
                vectorHits: []
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")

            let execution = await SummaryEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [genericChat, focusedChat],
                telegramService: telegramService,
                aiService: aiService
            )

            let output = try XCTUnwrap(execution.output)
            XCTAssertEqual(output.supportingChatId, focusedChatId)
        }
    }

    @MainActor
    func testSearchCoordinatorSemanticSearchPrefersFocusedTopicChatOverGenericChatter() async throws {
        let genericChatId: Int64 = 790
        let focusedChatId: Int64 = 791
        let baseDate = Date()

        let genericChat = TGChat(
            id: genericChatId,
            title: "Generic First Dollar chatter",
            chatType: .privateChat(userId: 210),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let focusedChat = TGChat(
            id: focusedChatId,
            title: "First Dollar Website",
            chatType: .privateChat(userId: 211),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 2,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let genericMessage = makeTGMessage(
            id: 621,
            chatId: genericChatId,
            text: "First Dollar is moving fast and First Dollar keeps coming up in founder chats.",
            date: baseDate.addingTimeInterval(-120)
        )
        let focusedMessage = makeTGMessage(
            id: 622,
            chatId: focusedChatId,
            text: "We should add stronger First Dollar case studies to the study website before launch.",
            date: baseDate.addingTimeInterval(-60)
        )

        let telegramService = TestTelegramService(
            scoredHits: [
                .init(message: genericMessage, score: 1.0),
                .init(message: focusedMessage, score: 0.72)
            ],
            vectorHits: []
        )
        let aiService = AIService()
        aiService.configure(type: .none, apiKey: "")

        let coordinator = SearchCoordinator()
        let results = await coordinator.semanticResultsForTesting(
            query: "What's latest with First Dollar case studies?",
            scope: .all,
            scopedChats: [genericChat, focusedChat],
            telegramService: telegramService,
            aiService: aiService
        )

        XCTAssertEqual(results.first?.chatId, focusedChatId)
        XCTAssertTrue(results.first?.matchingMessages.first?.lowercased().contains("case stud") == true)
    }

    @MainActor
    func testSearchCoordinatorSemanticSearchRejectsSplitPersonTopicFalsePositive() async throws {
        let personChatId: Int64 = 792
        let topicChatId: Int64 = 793
        let baseDate = Date()

        let personChat = TGChat(
            id: personChatId,
            title: "Rupam",
            chatType: .privateChat(userId: 212),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let topicChat = TGChat(
            id: topicChatId,
            title: "Campaign Ops",
            chatType: .privateChat(userId: 213),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 2,
            isInMainList: true,
            smallPhotoFileId: nil
        )

        let personMessage = makeTGMessage(
            id: 623,
            chatId: personChatId,
            text: "Rupam said he will take a look tomorrow.",
            date: baseDate.addingTimeInterval(-120)
        )
        let topicMessage = makeTGMessage(
            id: 624,
            chatId: topicChatId,
            text: "We should whitelist the bounty campaign once the docs are final.",
            date: baseDate.addingTimeInterval(-60)
        )

        let telegramService = TestTelegramService(
            scoredHits: [
                .init(message: personMessage, score: 0.92),
                .init(message: topicMessage, score: 0.88)
            ],
            vectorHits: []
        )
        let aiService = AIService()
        aiService.configure(type: .none, apiKey: "")

        let coordinator = SearchCoordinator()
        let results = await coordinator.semanticResultsForTesting(
            query: "Show me discussions about Rupam whitelisting bounties.",
            scope: .all,
            scopedChats: [personChat, topicChat],
            telegramService: telegramService,
            aiService: aiService
        )

        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testSearchCoordinatorSemanticSearchAppliesParsedTimeRange() async throws {
        let oldChatId: Int64 = 794
        let recentChatId: Int64 = 795
        let now = Date()
        let timeRange = TimeRangeConstraint(
            startDate: now.addingTimeInterval(-7 * 86_400),
            endDate: now,
            label: "Last Week"
        )
        let oldChat = TGChat(
            id: oldChatId,
            title: "Old Wallet",
            chatType: .privateChat(userId: 214),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let recentChat = TGChat(
            id: recentChatId,
            title: "Recent Wallet",
            chatType: .privateChat(userId: 215),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 2,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let oldMessage = makeTGMessage(
            id: 625,
            chatId: oldChatId,
            text: "The wallet address conversation happened a long time ago.",
            date: now.addingTimeInterval(-30 * 86_400)
        )
        let recentMessage = makeTGMessage(
            id: 626,
            chatId: recentChatId,
            text: "The wallet address was updated this week.",
            date: now.addingTimeInterval(-2 * 86_400)
        )

        let telegramService = TestTelegramService(
            scoredHits: [
                .init(message: oldMessage, score: 1.0),
                .init(message: recentMessage, score: 0.4)
            ],
            vectorHits: []
        )
        let aiService = AIService()
        aiService.configure(type: .none, apiKey: "")

        let coordinator = SearchCoordinator()
        let results = await coordinator.semanticResultsForTesting(
            query: "wallet address",
            scope: .all,
            scopedChats: [oldChat, recentChat],
            telegramService: telegramService,
            aiService: aiService,
            timeRange: timeRange
        )

        XCTAssertEqual(results.map(\.chatId), [recentChatId])
    }

    @MainActor
    func testPatternSearchEnginePrefersOutgoingWalletMessagesForBroadShareQuery() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 9001
            let chat = TGChat(
                id: chatId,
                title: "Wallet Chat",
                chatType: .privateChat(userId: 101),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let incoming = makeRecord(
                id: 701,
                chatId: chatId,
                text: "Can you check if this wallet works 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                date: Date().addingTimeInterval(-300),
                isOutgoing: false
            )
            let outgoing = makeRecord(
                id: 702,
                chatId: chatId,
                text: "Here is the wallet I shared 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                date: Date().addingTimeInterval(-120),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [incoming, outgoing],
                preferredOldestMessageId: incoming.id,
                isSearchReady: true
            )

            let querySpec = QuerySpec(
                rawQuery: "where I shared wallet address",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let results = await PatternSearchEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )

            XCTAssertEqual(results.first?.message.id, 702)
            XCTAssertTrue(results.first?.outgoingBiasApplied == true)
        }
    }

    @MainActor
    func testPatternSearchEngineAppliesParsedTimeRange() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 9004
            let now = Date()
            let oldWallet = makeRecord(
                id: 703,
                chatId: chatId,
                text: "Here is the wallet I shared 0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                date: now.addingTimeInterval(-30 * 86_400),
                isOutgoing: true
            )
            let recentWallet = makeRecord(
                id: 704,
                chatId: chatId,
                text: "Here is the wallet I shared 0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
                date: now.addingTimeInterval(-2 * 86_400),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [oldWallet, recentWallet],
                preferredOldestMessageId: oldWallet.id,
                isSearchReady: true
            )

            let chat = TGChat(
                id: chatId,
                title: "Wallet History",
                chatType: .privateChat(userId: 103),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let querySpec = QuerySpec(
                rawQuery: "where I shared wallet address",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: TimeRangeConstraint(
                    startDate: now.addingTimeInterval(-7 * 86_400),
                    endDate: now,
                    label: "Last Week"
                ),
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let results = await PatternSearchEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )

            XCTAssertEqual(results.map(\.message.id), [704])
        }
    }

    @MainActor
    func testPatternSearchEngineRequiresSpecificURLMatchForExactURLQuery() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 9002
            let urlMessage = makeRecord(
                id: 801,
                chatId: chatId,
                text: "Docs are here https://acme.com/docs?ref=123",
                date: Date().addingTimeInterval(-120),
                isOutgoing: true
            )
            let domainOnlyMessage = makeRecord(
                id: 802,
                chatId: chatId,
                text: "acme.com is the main site if you need it",
                date: Date().addingTimeInterval(-60),
                isOutgoing: true
            )
            let unrelatedMessage = makeRecord(
                id: 803,
                chatId: chatId,
                text: "Let me know if you need anything else",
                date: Date(),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [urlMessage, domainOnlyMessage, unrelatedMessage],
                preferredOldestMessageId: urlMessage.id,
                isSearchReady: true
            )

            let chat = TGChat(
                id: chatId,
                title: "Acme",
                chatType: .privateChat(userId: 102),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "where I sent https://acme.com/docs?ref=123",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let results = await PatternSearchEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )

            XCTAssertEqual(results.map(\.message.id), [801])
            XCTAssertEqual(results.first?.matchKind, .url)
        }
    }

    @MainActor
    func testPatternSearchEngineRequiresArtifactAndRecipientContextForSentToPersonQuery() async throws {
        try await withTempDatabase { _ in
            let rahulChatId: Int64 = 9101
            let groupChatId: Int64 = 9102
            let otherWalletChatId: Int64 = 9103

            let rahulChat = TGChat(
                id: rahulChatId,
                title: "Rahul Singh Bhadoriya",
                chatType: .privateChat(userId: 201),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 3,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let groupChat = TGChat(
                id: groupChatId,
                title: "Towow Official <> First Dollar",
                chatType: .supergroup(supergroupId: groupChatId, isChannel: false),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: 12,
                order: 2,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let otherWalletChat = TGChat(
                id: otherWalletChatId,
                title: "Akhil B",
                chatType: .privateChat(userId: 202),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let correctWalletMessage = makeRecord(
                id: 901,
                chatId: rahulChatId,
                text: "Here is the wallet 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                date: Date().addingTimeInterval(-180),
                isOutgoing: true
            )
            let rahulMentionOnly = makeRecord(
                id: 902,
                chatId: groupChatId,
                text: "I am talking to Rahul about it",
                date: Date().addingTimeInterval(-120),
                isOutgoing: true
            )
            let walletButWrongPerson = makeRecord(
                id: 903,
                chatId: otherWalletChatId,
                text: "Here is the wallet 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                date: Date().addingTimeInterval(-60),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: rahulChatId,
                messages: [correctWalletMessage],
                preferredOldestMessageId: correctWalletMessage.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: groupChatId,
                messages: [rahulMentionOnly],
                preferredOldestMessageId: rahulMentionOnly.id,
                isSearchReady: true
            )
            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: otherWalletChatId,
                messages: [walletButWrongPerson],
                preferredOldestMessageId: walletButWrongPerson.id,
                isSearchReady: true
            )

            let querySpec = QuerySpec(
                rawQuery: "wallet I sent to Rahul",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let results = await PatternSearchEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [rahulChat, groupChat, otherWalletChat],
                telegramService: telegramService
            )

            XCTAssertEqual(results.map(\.message.id), [901])
            XCTAssertEqual(results.first?.chatTitle, "Rahul Singh Bhadoriya")
        }
    }

    @MainActor
    func testPatternSearchEngineMatchesExactEmailAndMeetArtifacts() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 9201
            let emailMessage = makeRecord(
                id: 951,
                chatId: chatId,
                text: "Please forward this to team@firstdollar.money for email tracking.",
                date: Date().addingTimeInterval(-120),
                isOutgoing: true
            )
            let meetMessage = makeRecord(
                id: 952,
                chatId: chatId,
                text: "Meet here https://meet.google.com/mhf-stnj-uuv",
                date: Date().addingTimeInterval(-60),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [emailMessage, meetMessage],
                preferredOldestMessageId: emailMessage.id,
                isSearchReady: true
            )

            let chat = TGChat(
                id: chatId,
                title: "Artifacts",
                chatType: .privateChat(userId: 301),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])

            let emailQuery = QuerySpec(
                rawQuery: "Find the team@firstdollar.money email tracking message",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )
            let emailResults = await PatternSearchEngine.shared.search(
                query: emailQuery,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )
            XCTAssertEqual(emailResults.first?.message.id, 951)

            let meetQuery = QuerySpec(
                rawQuery: "Show me the Google Meet link mhf-stnj-uuv",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )
            let meetResults = await PatternSearchEngine.shared.search(
                query: meetQuery,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )
            XCTAssertEqual(meetResults.first?.message.id, 952)
        }
    }

    @MainActor
    func testPatternSearchEngineReturnsNoResultForNonexistentMeetCode() async throws {
        try await withTempDatabase { _ in
            let chatId: Int64 = 9202
            let meetMessage = makeRecord(
                id: 961,
                chatId: chatId,
                text: "Meet here https://meet.google.com/mhf-stnj-uuv",
                date: Date(),
                isOutgoing: true
            )

            await DatabaseManager.shared.upsertIndexedMessages(
                chatId: chatId,
                messages: [meetMessage],
                preferredOldestMessageId: meetMessage.id,
                isSearchReady: true
            )

            let chat = TGChat(
                id: chatId,
                title: "Meetings",
                chatType: .privateChat(userId: 302),
                unreadCount: 0,
                lastMessage: nil,
                memberCount: nil,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )

            let querySpec = QuerySpec(
                rawQuery: "Show me the Google Meet link abc-defg-hij",
                mode: .messageSearch,
                family: .exactLookup,
                preferredEngine: .messageLookup,
                scope: .all,
                scopeWasExplicit: false,
                replyConstraint: .none,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let telegramService = TestTelegramService(scoredHits: [], vectorHits: [])
            let results = await PatternSearchEngine.shared.search(
                query: querySpec,
                scope: .all,
                scopedChats: [chat],
                telegramService: telegramService
            )

            XCTAssertTrue(results.isEmpty)
        }
    }

    func testReplyQueueTriagePromptCarriesEarlierRequestForInputIntoGroupDigest() {
        let candidate = ReplyQueueCandidateDTO(
            chatId: -5040366323,
            chatName: "Banko",
            chatType: "group",
            unreadCount: 0,
            memberCount: 6,
            localSignal: "quiet",
            pipelineHint: "quiet",
            replyOwed: true,
            strictReplySignal: false,
            effectiveGroupReplySignal: false,
            messages: [
                makeSnippet(
                    id: 1,
                    sender: "Karan Ruparel",
                    text: "Haan making some fixes but gib more input",
                    relativeTimestamp: "2d ago",
                    chatId: -5040366323,
                    chatName: "Banko"
                ),
                makeSnippet(
                    id: 2,
                    sender: "Aritra",
                    text: "Design changes that need to be made and are already on figma. Cc @divi280605 @ultraviolet1000",
                    relativeTimestamp: "1d ago",
                    chatId: -5040366323,
                    chatName: "Banko"
                )
            ]
        )

        let prompt = ReplyQueueTriagePrompt.userMessage(
            query: "What is on me today?",
            scope: .all,
            candidates: [candidate]
        )

        XCTAssertTrue(prompt.contains("earlierRequestForInputExists: true"))
        XCTAssertTrue(prompt.contains("earlierRequestForInputText: Haan making some fixes but gib more input"))
        XCTAssertTrue(prompt.contains("ccStyleHandleMentions: true"))
    }

    func testConversationReplyHeuristicsAllowsWorthCheckingGroupForOlderAskPlusCcTaskDump() {
        let myUserId: Int64 = 99
        let chat = TGChat(
            id: -5040366323,
            title: "Banko",
            chatType: .basicGroup(groupId: -5040366323),
            unreadCount: 1,
            lastMessage: nil,
            memberCount: 6,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let baseDate = Date(timeIntervalSince1970: 1_776_000_000)
        let messages = [
            makeTGMessage(
                id: 1,
                chatId: chat.id,
                text: "Haan making some fixes but gib more input",
                date: baseDate.addingTimeInterval(-120),
                senderUserId: 201,
                senderName: "Karan"
            ),
            makeTGMessage(
                id: 2,
                chatId: chat.id,
                text: "Design changes that need to be made and are already on figma. Cc @divi280605 @ultraviolet1000",
                date: baseDate.addingTimeInterval(-60),
                senderUserId: 202,
                senderName: "Aritra"
            )
        ]

        XCTAssertTrue(
            ConversationReplyHeuristics.hasWorthCheckingGroupOpportunity(
                chat: chat,
                messages: messages,
                myUserId: myUserId,
                myUsername: "pratzyy",
                supportingMessageIds: [1, 2]
            )
        )
    }

    func testConversationReplyHeuristicsRejectsWorthCheckingForExplanatoryGroupThread() {
        let myUserId: Int64 = 99
        let chat = TGChat(
            id: -1001613656434,
            title: "Inner Circle",
            chatType: .basicGroup(groupId: -1001613656434),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: 6,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let message = makeTGMessage(
            id: 3,
            chatId: chat.id,
            text: "you mean to get the code from contract address? its too difficult, even if you try you won't get the exact code",
            date: Date(timeIntervalSince1970: 1_776_000_000),
            senderUserId: 301,
            senderName: "cashlessman.eth"
        )

        XCTAssertFalse(
            ConversationReplyHeuristics.hasWorthCheckingGroupOpportunity(
                chat: chat,
                messages: [message],
                myUserId: myUserId,
                myUsername: "pratzyy",
                supportingMessageIds: [3]
            )
        )
    }

    func testConversationReplyHeuristicsAllowsWorthCheckingWhenSupportIdsOnlyPointAtLatestTaskDump() {
        let myUserId: Int64 = 99
        let chat = TGChat(
            id: -7770001,
            title: "Builders Group",
            chatType: .basicGroup(groupId: -7770001),
            unreadCount: 1,
            lastMessage: nil,
            memberCount: 6,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let baseDate = Date(timeIntervalSince1970: 1_776_100_000)
        var fillerMessages: [TGMessage] = []
        for index in 0..<7 {
            fillerMessages.append(
                makeTGMessage(
                    id: Int64(100 + index),
                    chatId: chat.id,
                    text: "noted \(index)",
                    date: baseDate.addingTimeInterval(TimeInterval(index * 60)),
                    senderUserId: Int64(300 + index),
                    senderName: "Member \(index)"
                )
            )
        }
        let earlierAsk = makeTGMessage(
            id: 90,
            chatId: chat.id,
            text: "can you share more input on the builder list",
            date: baseDate.addingTimeInterval(-120),
            senderUserId: 201,
            senderName: "Karan"
        )
        let latestTaskDump = makeTGMessage(
            id: 200,
            chatId: chat.id,
            text: "Design changes that need to be made and are already on figma. Cc @divi280605 @ultraviolet1000",
            date: baseDate.addingTimeInterval(8 * 60),
            senderUserId: 202,
            senderName: "Aritra"
        )
        var messages = [earlierAsk]
        messages.append(contentsOf: fillerMessages)
        messages.append(latestTaskDump)

        XCTAssertTrue(
            ConversationReplyHeuristics.hasWorthCheckingGroupOpportunity(
                chat: chat,
                messages: messages,
                myUserId: myUserId,
                myUsername: "pratzyy",
                supportingMessageIds: [200]
            )
        )
    }

    func testConversationReplyHeuristicsRejectsWorthCheckingWhenClosureFollowsSupportedTaskDump() {
        let myUserId: Int64 = 99
        let chat = TGChat(
            id: -7770002,
            title: "Builders Group",
            chatType: .basicGroup(groupId: -7770002),
            unreadCount: 1,
            lastMessage: nil,
            memberCount: 6,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        let baseDate = Date(timeIntervalSince1970: 1_776_100_000)
        let messages = [
            makeTGMessage(
                id: 301,
                chatId: chat.id,
                text: "gib more input on this once you look",
                date: baseDate.addingTimeInterval(-120),
                senderUserId: 201,
                senderName: "Karan"
            ),
            makeTGMessage(
                id: 302,
                chatId: chat.id,
                text: "Design changes that need to be made and are already on figma. Cc @divi280605 @ultraviolet1000",
                date: baseDate.addingTimeInterval(-60),
                senderUserId: 202,
                senderName: "Aritra"
            ),
            makeTGMessage(
                id: 303,
                chatId: chat.id,
                text: "Already added",
                date: baseDate,
                senderUserId: 203,
                senderName: "Deeksha"
            )
        ]

        XCTAssertFalse(
            ConversationReplyHeuristics.hasWorthCheckingGroupOpportunity(
                chat: chat,
                messages: messages,
                myUserId: myUserId,
                myUsername: "pratzyy",
                supportingMessageIds: [302]
            )
        )
    }

    func testReplyQueueTriagePromptTreatsAlreadyAddedAsClosureSignal() {
        let candidate = ReplyQueueCandidateDTO(
            chatId: -5212516832,
            chatName: "Bhavyam <> First Dollar",
            chatType: "group",
            unreadCount: 0,
            memberCount: 4,
            localSignal: "quiet",
            pipelineHint: "quiet",
            replyOwed: false,
            strictReplySignal: false,
            effectiveGroupReplySignal: false,
            messages: [
                makeSnippet(
                    id: 10,
                    sender: "Rajanshee Singh",
                    text: "@deeksharungta possible to add this in bounty only?",
                    relativeTimestamp: "3d ago",
                    chatId: -5212516832,
                    chatName: "Bhavyam <> First Dollar"
                ),
                makeSnippet(
                    id: 11,
                    sender: "Unknown",
                    text: "Should we extend the bounty? I am not seeing much quality submissions right now",
                    relativeTimestamp: "2d ago",
                    chatId: -5212516832,
                    chatName: "Bhavyam <> First Dollar"
                ),
                makeSnippet(
                    id: 12,
                    sender: "Deeeeeksha",
                    text: "Already added 🫡",
                    relativeTimestamp: "1d ago",
                    chatId: -5212516832,
                    chatName: "Bhavyam <> First Dollar"
                )
            ]
        )

        let prompt = ReplyQueueTriagePrompt.userMessage(
            query: "What is on me today?",
            scope: .all,
            candidates: [candidate]
        )

        XCTAssertTrue(prompt.contains("latestClosureText: Already added 🫡"))
        XCTAssertTrue(prompt.contains("closureAfterLatestActionable: true"))
    }

    func testPromptsRouteArtifactDeliveryOutOfReplyQueue() {
        XCTAssertTrue(
            ReplyQueueTriagePrompt.systemPrompt.contains("send or share a pitch deck")
        )
        XCTAssertTrue(
            PipelineCategoryPrompt.systemPrompt.contains("send or share a pitch deck")
        )
        XCTAssertTrue(
            PipelineCategoryPrompt.systemPrompt.contains("Bro, can you please send me the pitch deck")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("send or share a pitch deck")
        )
    }

    func testDashboardPromptsDoNotPromoteSomeoneElseCoordinationToUserTask() {
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("let's find a time")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("not an effort_task")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("Do not infer ownership from \"we\" or \"let's\"")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("let's find a time")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("Do not extract tasks from another person narrating their own plan")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("Someone else saying \"I'll send\"")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("If a non-[ME] sender says \"I'll send\"")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("ownerName \"Me\" requires direct evidence")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("\"can we have\" with no named owner")
        )
        XCTAssertTrue(
            DashboardTaskPrompt.systemPrompt.contains("If [ME] already sent or shared the requested thing")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("Existing open task source evidence")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("current stored ownerName")
        )
        XCTAssertTrue(
            DashboardTaskTriagePrompt.systemPrompt.contains("ownerName \"Me\" only when the user is directly named")
        )
    }

    func testReplyQueuePromptAndModelSupportWorthCheckingAndRedirectedDMs() {
        let candidate = ReplyQueueCandidateDTO(
            chatId: 6743321353,
            chatName: "Tom🔥",
            chatType: "private",
            unreadCount: 0,
            memberCount: nil,
            localSignal: "reply_owed",
            pipelineHint: "on_me",
            replyOwed: true,
            strictReplySignal: true,
            effectiveGroupReplySignal: true,
            messages: [
                makeSnippet(
                    id: 20,
                    sender: "Tom🔥",
                    text: "Can I get a review on my @yetchxyz thread",
                    relativeTimestamp: "2d ago",
                    chatId: 6743321353,
                    chatName: "Tom🔥"
                ),
                makeSnippet(
                    id: 21,
                    sender: "[ME]",
                    text: "Hey you should ping the bounty owner",
                    relativeTimestamp: "2d ago",
                    chatId: 6743321353,
                    chatName: "Tom🔥"
                ),
                makeSnippet(
                    id: 22,
                    sender: "[ME]",
                    text: "He will be better to give feedback",
                    relativeTimestamp: "2d ago",
                    chatId: 6743321353,
                    chatName: "Tom🔥"
                ),
                makeSnippet(
                    id: 23,
                    sender: "Tom🔥",
                    text: "Smiles ok chad",
                    relativeTimestamp: "2d ago",
                    chatId: 6743321353,
                    chatName: "Tom🔥"
                )
            ]
        )

        let prompt = ReplyQueueTriagePrompt.userMessage(
            query: "What is on me today?",
            scope: .all,
            candidates: [candidate]
        )
        XCTAssertTrue(prompt.contains("privateOwnershipHint: private_waiting_on_them"))

        let result = ReplyQueueResult(
            chatId: 6743321353,
            chatTitle: "Tom🔥",
            suggestedAction: "Check whether a follow-up is still useful.",
            reason: "There was an older ask, but it now belongs in the secondary bucket.",
            confidence: 0.73,
            urgency: .medium,
            classification: .worthChecking,
            supportingMessageIds: [20],
            latestMessageDate: Date(),
            score: 8,
            source: "ai"
        )
        XCTAssertEqual(result.replyability, .worthChecking)
        XCTAssertEqual(result.replyability.label, "CHECK")
    }

    @MainActor
    func testReplyQueueLocalFallbackHonorsEffectiveGroupSignal() async throws {
        try await withTempDatabase { _ in
            let myUserId: Int64 = 100
            let chatId: Int64 = -8_001
            let now = Date()
            let messages = [
                makeTGMessage(
                    id: 31,
                    chatId: chatId,
                    text: "Can someone check the release notes?",
                    date: now.addingTimeInterval(-120),
                    senderUserId: 201,
                    senderName: "Alice"
                ),
                makeTGMessage(
                    id: 32,
                    chatId: chatId,
                    text: "Pratzyy can you review this before we ship?",
                    date: now.addingTimeInterval(-60),
                    senderUserId: 202,
                    senderName: "Bob"
                )
            ]
            let groupChat = TGChat(
                id: chatId,
                title: "Small Ops Group",
                chatType: .supergroup(supergroupId: 8001, isChannel: false),
                unreadCount: 2,
                lastMessage: messages.last,
                memberCount: 5,
                order: 1,
                isInMainList: true,
                smallPhotoFileId: nil
            )
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: messages, append: false)
            let telegramService = PipelineTestTelegramService(
                currentUser: TGUser(
                    id: myUserId,
                    firstName: "Pratzyy",
                    lastName: "",
                    username: "pratzyy",
                    phoneNumber: nil,
                    isBot: false
                ),
                historyByChatId: [chatId: messages]
            )
            let aiService = AIService()
            aiService.configure(type: .none, apiKey: "")
            let querySpec = QuerySpec(
                rawQuery: "anything worth checking in groups?",
                mode: .agenticSearch,
                family: .replyQueue,
                preferredEngine: .replyTriage,
                scope: .groups,
                scopeWasExplicit: true,
                replyConstraint: .pipelineOnMeOnly,
                timeRange: nil,
                parseConfidence: 0.9,
                unsupportedFragments: []
            )

            let execution = await ReplyQueueEngine.shared.search(
                query: querySpec.rawQuery,
                querySpec: querySpec,
                aiSearchSourceChats: [groupChat],
                includeBotsInAISearch: false,
                telegramService: telegramService,
                aiService: aiService,
                pipelineHintProvider: { _ in "quiet" }
            )

            XCTAssertEqual(execution.results.first?.chatId, chatId)
            XCTAssertEqual(execution.results.first?.classification, .onMe)
        }
    }

    func testLegacyMessageImportPreservesExistingSQLiteHistory() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let appSupportDirectory = tempDirectory.appendingPathComponent("PidgySupport", isDirectory: true)
        let databaseURL = tempDirectory.appendingPathComponent("pidgy-tests.sqlite", isDirectory: false)
        let chatId: Int64 = 9_801
        let now = Date()

        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: databaseURL,
            appSupportDirectoryOverride: appSupportDirectory
        )
        await DatabaseManager.shared.initialize()
        await DatabaseManager.shared.upsertIndexedMessages(
            chatId: chatId,
            messages: [
                makeRecord(id: 1, chatId: chatId, text: "oldest rich history", date: now.addingTimeInterval(-40 * 86_400)),
                makeRecord(id: 3, chatId: chatId, text: "newest rich history", date: now)
            ],
            preferredOldestMessageId: 1,
            isSearchReady: true
        )
        await DatabaseManager.shared.close()

        let legacyDirectory = appSupportDirectory.appendingPathComponent(
            AppConstants.Storage.messageCacheDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "chatId": \(chatId),
          "oldestMessageId": 2,
          "messages": [
            {
              "id": 2,
              "chatId": \(chatId),
              "senderUserId": 200,
              "senderName": "Legacy",
              "date": \(now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970),
              "textContent": "legacy cached middle message",
              "mediaTypeRaw": null,
              "isOutgoing": false
            }
          ]
        }
        """
        try legacyJSON.data(using: .utf8)?.write(
            to: legacyDirectory.appendingPathComponent("chat-\(chatId).json"),
            options: [.atomic]
        )

        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: databaseURL,
            appSupportDirectoryOverride: appSupportDirectory
        )
        await DatabaseManager.shared.initialize()

        let messages = await DatabaseManager.shared.loadMessages(chatId: chatId, limit: 10)
        XCTAssertEqual(Set(messages.map(\.id)), Set([1, 2, 3]))
        let syncState = await DatabaseManager.shared.loadSyncState(chatId: chatId)
        XCTAssertEqual(syncState?.lastIndexedMessageId, 1)
        XCTAssertEqual(syncState?.isSearchReady, true)

        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(databaseURLOverride: nil)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func withTempDatabase(
        _ body: (URL) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let appSupportDirectory = tempDirectory.appendingPathComponent("PidgySupport", isDirectory: true)
        let databaseURL = tempDirectory.appendingPathComponent("pidgy-tests.sqlite", isDirectory: false)

        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: databaseURL,
            appSupportDirectoryOverride: appSupportDirectory
        )
        await DatabaseManager.shared.initialize()
        await MessageCacheService.shared.invalidateAllLocalData()
        await MessageCacheService.shared.invalidateAll()

        do {
            try await body(databaseURL)
        } catch {
            await MessageCacheService.shared.resetInMemoryCachesForTesting()
            await DatabaseManager.shared.close()
            await DatabaseManager.shared.configureForTesting(
                databaseURLOverride: nil,
                appSupportDirectoryOverride: nil
            )
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }

        await MessageCacheService.shared.resetInMemoryCachesForTesting()
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(
            databaseURLOverride: nil,
            appSupportDirectoryOverride: nil
        )
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeRecord(
        id: Int64,
        chatId: Int64,
        text: String,
        daysAgo: TimeInterval,
        isOutgoing: Bool = false
    ) -> DatabaseManager.MessageRecord {
        makeRecord(
            id: id,
            chatId: chatId,
            text: text,
            date: Date().addingTimeInterval(-(daysAgo * 86_400)),
            isOutgoing: isOutgoing
        )
    }

    private func makeRecord(
        id: Int64,
        chatId: Int64,
        text: String,
        date: Date,
        isOutgoing: Bool = false,
        senderUserId: Int64 = 1,
        senderName: String? = "Tester"
    ) -> DatabaseManager.MessageRecord {
        DatabaseManager.MessageRecord(
            id: id,
            chatId: chatId,
            senderUserId: senderUserId,
            senderName: senderName,
            date: date,
            textContent: text,
            mediaTypeRaw: nil,
            isOutgoing: isOutgoing
        )
    }

    private func makeTGMessage(
        id: Int64,
        chatId: Int64,
        text: String?,
        date: Date,
        senderUserId: Int64 = 1,
        senderName: String = "Tester",
        isOutgoing: Bool = false,
        mediaType: TGMessage.MediaType? = nil
    ) -> TGMessage {
        TGMessage(
            id: id,
            chatId: chatId,
            senderId: .user(senderUserId),
            date: date,
            textContent: text,
            mediaType: mediaType,
            isOutgoing: isOutgoing,
            chatTitle: "Chat \(chatId)",
            senderName: senderName
        )
    }

    private func makeChat(
        id: Int64,
        title: String,
        chatType: TGChat.ChatType,
        unreadCount: Int,
        lastMessageDate: Date,
        memberCount: Int? = nil
    ) -> TGChat {
        TGChat(
            id: id,
            title: title,
            chatType: chatType,
            unreadCount: unreadCount,
            lastMessage: makeTGMessage(
                id: id * 100,
                chatId: id,
                text: "latest",
                date: lastMessageDate
            ),
            memberCount: memberCount,
            order: id,
            isInMainList: true,
            smallPhotoFileId: nil
        )
    }

    private func makeSnippet(
        id: Int64,
        sender: String,
        text: String,
        relativeTimestamp: String,
        chatId: Int64,
        chatName: String
    ) -> MessageSnippet {
        MessageSnippet(
            messageId: id,
            senderFirstName: sender,
            text: text,
            relativeTimestamp: relativeTimestamp,
            chatId: chatId,
            chatName: chatName
        )
    }

    private func embeddingCount(chatId: Int64, messageId: Int64) async throws -> Int {
        try await DatabaseManager.shared.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM embeddings
                    WHERE chat_id = ? AND message_id = ?
                    """,
                arguments: [chatId, messageId]
            ) ?? 0
        }
    }
}

private extension DashboardTask {
    static func mock(
        id: Int64,
        title: String,
        status: DashboardTaskStatus,
        topicId: Int64?,
        topicName: String?,
        chatId: Int64,
        personName: String,
        ownerName: String = "Me",
        priority: DashboardTaskPriority = .medium,
        updatedAt: Date = Date(),
        latestSourceDate: Date? = nil
    ) -> DashboardTask {
        DashboardTask(
            id: id,
            stableFingerprint: "mock-\(id)",
            title: title,
            summary: title,
            suggestedAction: title,
            ownerName: ownerName,
            personName: personName,
            chatId: chatId,
            chatTitle: personName,
            topicId: topicId,
            topicName: topicName,
            priority: priority,
            status: status,
            confidence: 1,
            createdAt: Date(),
            updatedAt: updatedAt,
            dueAt: nil,
            snoozedUntil: nil,
            latestSourceDate: latestSourceDate
        )
    }
}

private extension FollowUpItem {
    static func mockPrivate(
        chatId: Int64,
        userId: Int64,
        title: String,
        category: FollowUpItem.Category,
        senderName: String,
        text: String
    ) -> FollowUpItem {
        let message = TGMessage(
            id: 1,
            chatId: chatId,
            senderId: .user(userId),
            date: Date(),
            textContent: text,
            mediaType: nil,
            isOutgoing: false,
            chatTitle: title,
            senderName: senderName
        )
        let chat = TGChat(
            id: chatId,
            title: title,
            chatType: .privateChat(userId: userId),
            unreadCount: 1,
            lastMessage: message,
            memberCount: nil,
            order: 1,
            isInMainList: true,
            smallPhotoFileId: nil
        )
        return FollowUpItem(
            chat: chat,
            category: category,
            lastMessage: message,
            timeSinceLastActivity: 0,
            suggestedAction: nil
        )
    }
}

private extension RelationGraph.Node {
    static func mock(
        entityId: Int64,
        displayName: String,
        interactionScore: Double,
        lastInteractionAt: Date?
    ) -> RelationGraph.Node {
        RelationGraph.Node(
            entityId: entityId,
            entityType: "user",
            displayName: displayName,
            username: nil,
            category: "General",
            categorySource: "test",
            interactionScore: interactionScore,
            lastInteractionAt: lastInteractionAt,
            firstSeenAt: nil,
            metadata: nil
        )
    }
}

@MainActor
private final class TestTelegramService: TelegramService {
    private let stubScoredHits: [LocalMessageSearchHit]
    private let stubVectorHits: [LocalMessageSearchHit]

    init(
        scoredHits: [LocalMessageSearchHit],
        vectorHits: [LocalMessageSearchHit]
    ) {
        self.stubScoredHits = scoredHits
        self.stubVectorHits = vectorHits
        super.init()
    }

    override func localScoredSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [LocalMessageSearchHit] {
        stubScoredHits
    }

    override func localVectorSearch(query: String, chatIds: [Int64]? = nil, limit: Int = 50) async -> [LocalMessageSearchHit] {
        stubVectorHits
    }
}

@MainActor
private final class PipelineTestTelegramService: TelegramService {
    private let historyByChatId: [Int64: [TGMessage]]
    private let resolvedMemberCounts: [Int64: Int]

    init(
        currentUser: TGUser?,
        historyByChatId: [Int64: [TGMessage]],
        resolvedMemberCounts: [Int64: Int] = [:]
    ) {
        self.historyByChatId = historyByChatId
        self.resolvedMemberCounts = resolvedMemberCounts
        super.init()
        self.currentUser = currentUser
    }

    override func getChatHistory(
        chatId: Int64,
        fromMessageId: Int64 = 0,
        limit: Int = 50,
        onlyLocal: Bool = false,
        priority: RateLimiter.Priority = .userInitiated
    ) async throws -> [TGMessage] {
        let sorted = (historyByChatId[chatId] ?? []).sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return lhs.id > rhs.id
        }

        guard fromMessageId != 0 else {
            return Array(sorted.prefix(limit))
        }

        guard let index = sorted.firstIndex(where: { $0.id == fromMessageId }) else {
            return []
        }

        let older = sorted.suffix(from: sorted.index(after: index))
        return Array(older.prefix(limit))
    }

    override func resolvedMemberCount(for chat: TGChat) async -> Int? {
        if let count = resolvedMemberCounts[chat.id] {
            return count
        }
        return await super.resolvedMemberCount(for: chat)
    }
}

private actor PipelineCategorizationCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int {
        value
    }
}

private actor DashboardTaskTriageRecorder {
    private var extractedIds: [Int64] = []
    private var triageBatchCounts: [Int] = []
    private var recordedOpenTaskCountsByChat: [Int64: Int] = [:]
    private var recordedCandidateMessagesByChat: [Int64: [MessageSnippet]] = [:]
    private var recordedOpenTasksByChat: [Int64: [DashboardTaskTriageOpenTaskDTO]] = [:]

    func recordTriageBatch(count: Int) {
        triageBatchCounts.append(count)
    }

    func recordTriageCandidates(_ candidates: [DashboardTaskTriageCandidateDTO]) {
        for candidate in candidates {
            recordedOpenTaskCountsByChat[candidate.chatId] = candidate.openTasks.count
            recordedCandidateMessagesByChat[candidate.chatId] = candidate.messages
            recordedOpenTasksByChat[candidate.chatId] = candidate.openTasks
        }
    }

    func recordExtraction(chatId: Int64) {
        extractedIds.append(chatId)
    }

    func extractedChatIds() -> [Int64] {
        extractedIds
    }

    func openTaskCountsByChat() -> [Int64: Int] {
        recordedOpenTaskCountsByChat
    }

    func candidateMessagesByChat() -> [Int64: [MessageSnippet]] {
        recordedCandidateMessagesByChat
    }

    func openTasksByChat() -> [Int64: [DashboardTaskTriageOpenTaskDTO]] {
        recordedOpenTasksByChat
    }
}

private struct DashboardTaskTriageAIProvider: AIProvider {
    let recorder: DashboardTaskTriageRecorder
    let decisions: [DashboardTaskTriageResultDTO]
    let tasksByChatId: [Int64: DashboardTaskCandidate]

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64] {
        throw AIError.providerNotConfigured
    }

    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageDashboardTaskCandidates(
        candidates: [DashboardTaskTriageCandidateDTO]
    ) async throws -> [DashboardTaskTriageResultDTO] {
        await recorder.recordTriageBatch(count: candidates.count)
        await recorder.recordTriageCandidates(candidates)
        let candidateIds = Set(candidates.map(\.chatId))
        return decisions.filter { candidateIds.contains($0.chatId) }
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        throw AIError.providerNotConfigured
    }

    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO {
        throw AIError.providerNotConfigured
    }

    func discoverDashboardTopics(messages: [MessageSnippet]) async throws -> [DashboardTopicDTO] {
        return []
    }

    func extractDashboardTasks(
        chat: TGChat,
        topics: [DashboardTopic],
        messages: [MessageSnippet]
    ) async throws -> [DashboardTaskCandidate] {
        await recorder.recordExtraction(chatId: chat.id)
        return tasksByChatId[chat.id].map { [$0] } ?? []
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        throw AIError.providerNotConfigured
    }

    func testConnection() async throws -> Bool {
        true
    }
}

private struct CountingPipelineAIProvider: AIProvider {
    let callCounter: PipelineCategorizationCallCounter
    let pipelineCategoryResult: PipelineCategoryDTO

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64] {
        throw AIError.providerNotConfigured
    }

    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageDashboardTaskCandidates(
        candidates: [DashboardTaskTriageCandidateDTO]
    ) async throws -> [DashboardTaskTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        throw AIError.providerNotConfigured
    }

    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO {
        await callCounter.increment()
        return pipelineCategoryResult
    }

    func discoverDashboardTopics(messages: [MessageSnippet]) async throws -> [DashboardTopicDTO] {
        throw AIError.providerNotConfigured
    }

    func extractDashboardTasks(
        chat: TGChat,
        topics: [DashboardTopic],
        messages: [MessageSnippet]
    ) async throws -> [DashboardTaskCandidate] {
        throw AIError.providerNotConfigured
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        throw AIError.providerNotConfigured
    }

    func testConnection() async throws -> Bool {
        throw AIError.providerNotConfigured
    }
}

private struct StubAIProvider: AIProvider {
    var queryPlannerResult: QueryPlannerResultDTO?
    var queryPlannerError: Error?
    var pipelineCategoryResult: PipelineCategoryDTO?
    var pipelineCategoryError: Error?

    func summarize(messages: [MessageSnippet], prompt: String) async throws -> String {
        throw AIError.providerNotConfigured
    }

    func semanticSearch(query: String, messages: [MessageSnippet]) async throws -> [SemanticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func rerankResults(
        query: String,
        candidates: [(chatId: Int64, chatTitle: String, snippet: String)]
    ) async throws -> [Int64] {
        throw AIError.providerNotConfigured
    }

    func agenticSearch(
        query: String,
        constraints: AgenticSearchConstraintsDTO,
        candidates: [AgenticCandidateDTO]
    ) async throws -> [AgenticSearchResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageReplyQueue(
        query: String,
        scope: QueryScope,
        candidates: [ReplyQueueCandidateDTO]
    ) async throws -> [ReplyQueueTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func triageDashboardTaskCandidates(
        candidates: [DashboardTaskTriageCandidateDTO]
    ) async throws -> [DashboardTaskTriageResultDTO] {
        throw AIError.providerNotConfigured
    }

    func generateFollowUpSuggestion(chatTitle: String, messages: [MessageSnippet]) async throws -> (Bool, String) {
        throw AIError.providerNotConfigured
    }

    func categorizePipelineChat(context: PipelineChatContext, messages: [MessageSnippet]) async throws -> PipelineCategoryDTO {
        if let pipelineCategoryError {
            throw pipelineCategoryError
        }
        return pipelineCategoryResult ?? PipelineCategoryDTO(
            status: "decision",
            category: "quiet",
            urgency: "low",
            suggestedAction: ""
        )
    }

    func discoverDashboardTopics(messages: [MessageSnippet]) async throws -> [DashboardTopicDTO] {
        throw AIError.providerNotConfigured
    }

    func extractDashboardTasks(
        chat: TGChat,
        topics: [DashboardTopic],
        messages: [MessageSnippet]
    ) async throws -> [DashboardTaskCandidate] {
        throw AIError.providerNotConfigured
    }

    func planQuery(
        query: String,
        activeFilter: QueryScope,
        deterministicSpec: QuerySpec
    ) async throws -> QueryPlannerResultDTO {
        if let queryPlannerError {
            throw queryPlannerError
        }
        return queryPlannerResult ?? QueryPlannerResultDTO(
            family: deterministicSpec.family.rawValue,
            scope: "inherit",
            timeRange: "inherit",
            people: [],
            topicTerms: [],
            confidence: deterministicSpec.parseConfidence
        )
    }

    func testConnection() async throws -> Bool {
        throw AIError.providerNotConfigured
    }
}
