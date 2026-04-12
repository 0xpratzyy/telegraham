import XCTest
@testable import Pidgy

final class PidgyCoreTests: XCTestCase {
    override func tearDown() async throws {
        await MessageCacheService.shared.invalidateAll()
        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(databaseURLOverride: nil)
        try await super.tearDown()
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
            await MessageCacheService.shared.cacheMessages(chatId: chatId, messages: [recentMessage], append: true)

            let syncStateAfterRecentWrite = await DatabaseManager.shared.loadSyncState(chatId: chatId)
            XCTAssertEqual(syncStateAfterRecentWrite?.lastIndexedMessageId, 301)
            XCTAssertEqual(syncStateAfterRecentWrite?.isSearchReady, true)

            let recentSyncState = await DatabaseManager.shared.loadRecentSyncState(chatId: chatId)
            XCTAssertEqual(recentSyncState?.latestSyncedMessageId, 401)
        }
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

    private func withTempDatabase(
        _ body: (URL) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let databaseURL = tempDirectory.appendingPathComponent("pidgy-tests.sqlite", isDirectory: false)

        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(databaseURLOverride: databaseURL)
        await DatabaseManager.shared.initialize()
        await MessageCacheService.shared.invalidateAllLocalData()
        await MessageCacheService.shared.invalidateAll()

        do {
            try await body(databaseURL)
        } catch {
            await DatabaseManager.shared.close()
            await DatabaseManager.shared.configureForTesting(databaseURLOverride: nil)
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }

        await DatabaseManager.shared.close()
        await DatabaseManager.shared.configureForTesting(databaseURLOverride: nil)
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
        isOutgoing: Bool = false
    ) -> DatabaseManager.MessageRecord {
        DatabaseManager.MessageRecord(
            id: id,
            chatId: chatId,
            senderUserId: 1,
            senderName: "Tester",
            date: date,
            textContent: text,
            mediaTypeRaw: nil,
            isOutgoing: isOutgoing
        )
    }

    private func makeTGMessage(
        id: Int64,
        chatId: Int64,
        text: String,
        date: Date
    ) -> TGMessage {
        TGMessage(
            id: id,
            chatId: chatId,
            senderId: .user(1),
            date: date,
            textContent: text,
            mediaType: nil,
            isOutgoing: false,
            chatTitle: "Chat \(chatId)",
            senderName: "Tester"
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
