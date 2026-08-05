import XCTest
@testable import Pidgy

final class MultiSourceIntegrationTests: XCTestCase {
    func testGmailOAuthIsStrictlyReadOnly() {
        XCTAssertEqual(
            Set(GmailOAuth.scopes),
            Set([
                "openid",
                "email",
                "https://www.googleapis.com/auth/gmail.readonly"
            ])
        )
        XCTAssertFalse(GmailOAuth.scopes.contains { scope in
            scope.contains("gmail.modify") || scope.contains("gmail.compose") || scope.contains("gmail.send")
        })
    }

    func testGmailOAuthExplainsTestingAccessDenial() {
        let error = GmailOAuth.OAuthError.denied("access_denied")
        XCTAssertEqual(
            error.errorDescription,
            "Google denied access. While Pidgy is in testing, use an approved test account and try again."
        )
    }

    func testGmailOAuthPreservesGoogleTokenErrorDescription() {
        let data = Data(#"{"error":"invalid_grant","error_description":"Authorization code expired."}"#.utf8)

        XCTAssertThrowsError(try GmailOAuth.tokenResponse(from: data, statusCode: 400)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Google couldn't complete sign-in: Authorization code expired."
            )
        }
    }

    func testGmailParserPrefersPlainTextAndPreservesUnreadState() throws {
        let plainText = "The plain-text answer is ready."
        let payload: [String: Any] = [
            "id": "thread-1",
            "messages": [[
                "id": "message-1",
                "internalDate": "1722800000000",
                "labelIds": ["INBOX", "UNREAD"],
                "snippet": "Fallback snippet",
                "payload": [
                    "mimeType": "multipart/alternative",
                    "headers": [
                        ["name": "Received", "value": "transport-one"],
                        ["name": "Received", "value": "transport-two"],
                        ["name": "From", "value": "Alice Example <ALICE@example.com>"],
                        ["name": "Subject", "value": "Project update"]
                    ],
                    "parts": [
                        [
                            "mimeType": "text/html",
                            "headers": [],
                            "body": ["data": Self.base64URL("<p>Wrong HTML choice</p>")]
                        ],
                        [
                            "mimeType": "text/plain",
                            "headers": [],
                            "body": ["data": Self.base64URL(plainText)]
                        ]
                    ]
                ]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let page = try GmailSourceAdapter.messagePage(
            from: data,
            conversation: Self.gmailConversation,
            limit: 100
        )

        XCTAssertEqual(page.messages.count, 1)
        XCTAssertEqual(page.messages[0].text, plainText)
        XCTAssertEqual(page.messages[0].subject, "Project update")
        XCTAssertEqual(page.messages[0].senderExternalID, "alice@example.com")
        XCTAssertTrue(page.messages[0].isUnread)
        XCTAssertFalse(page.messages[0].isOutgoing)
    }

    func testGmailParserSanitizesHTMLOnlyMessages() throws {
        let html = "<style>hidden{}</style><p>Hello &amp; welcome</p><script>doBadThing()</script><div>Second line</div>"
        let payload: [String: Any] = [
            "id": "thread-2",
            "messages": [[
                "id": "message-2",
                "internalDate": "1722800001000",
                "labelIds": ["INBOX"],
                "payload": [
                    "mimeType": "text/html",
                    "headers": [["name": "Subject", "value": "HTML mail"]],
                    "body": ["data": Self.base64URL(html)]
                ]
            ]]
        ]

        let page = try GmailSourceAdapter.messagePage(
            from: JSONSerialization.data(withJSONObject: payload),
            conversation: Self.gmailConversation,
            limit: 100
        )
        let text = try XCTUnwrap(page.messages.first?.text)

        XCTAssertTrue(text.contains("Hello & welcome"))
        XCTAssertTrue(text.contains("Second line"))
        XCTAssertFalse(text.contains("<p>"))
        XCTAssertFalse(text.contains("doBadThing"))
        XCTAssertFalse(page.messages[0].isUnread)
    }

    func testSourceIDRoundTripsAccountQualifiedProviders() throws {
        let sources = [
            SourceID.telegram,
            SourceID(kind: .slack, account: "T123"),
            SourceID(kind: .gmail, account: "me@example.com"),
            SourceID(kind: .whatsapp, account: "manual-import")
        ]
        for source in sources {
            XCTAssertEqual(SourceID(rawValue: source.rawValue), source)
            XCTAssertEqual(try JSONDecoder().decode(SourceID.self, from: JSONEncoder().encode(source)), source)
        }
    }

    func testCanonicalIDsAreStableAndSourceSeparated() {
        let gmail = CanonicalID.conversation(source: .gmail, accountID: "a", externalID: "same")
        let slack = CanonicalID.conversation(source: .slack, accountID: "a", externalID: "same")
        XCTAssertEqual(gmail, CanonicalID.conversation(source: .gmail, accountID: "a", externalID: "same"))
        XCTAssertNotEqual(gmail, slack)
        XCTAssertNotEqual(CanonicalID.legacyInt64(gmail), CanonicalID.legacyInt64(slack))
    }

    func testDashboardSourceScopeOnlyOffersConnectedProviders() {
        XCTAssertEqual(
            DashboardSourceScope.available(for: [.slack, .telegram]),
            [.all, .telegram, .slack]
        )
        XCTAssertEqual(DashboardSourceScope(kind: .slack).kind, .slack)
        XCTAssertNil(DashboardSourceScope.all.kind)
    }

    func testWhatsAppParserHandlesMultilineAndOutgoingIdentity() throws {
        let export = """
        8/3/2026, 9:14 PM - Pratyush: First line
        continuation
        8/3/2026, 9:15 PM - Maya: Reply
        """
        let parsed = try WhatsAppExportParser.parse(
            export,
            fileName: "WhatsApp Chat with Maya.txt",
            ownerName: "Pratyush"
        )
        XCTAssertEqual(parsed.conversation.title, "Maya")
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.messages[0].text, "First line\ncontinuation")
        XCTAssertTrue(parsed.messages[0].isOutgoing)
        XCTAssertFalse(parsed.messages[1].isOutgoing)
    }

    @MainActor
    func testSourceRegistryLookupCacheInvalidatesWithSourcePublication() {
        let registry = SourceRegistry()
        let source = RegistryTestSource()
        let first = Self.chat(id: 101, userId: 201, title: "First")
        source.replaceChats([first])
        registry.register(source)

        XCTAssertEqual(registry.chat(id: first.id)?.title, "First")
        XCTAssertEqual(registry.privateChat(userId: 201)?.id, first.id)

        let replacement = Self.chat(id: 102, userId: 202, title: "Replacement")
        source.replaceChats([replacement])

        XCTAssertNil(registry.chat(id: first.id))
        XCTAssertEqual(registry.chat(id: replacement.id)?.title, "Replacement")
        XCTAssertEqual(registry.visibleChats.map(\.id), [replacement.id])
        registry.unregister(source)
    }

    private static func chat(id: Int64, userId: Int64, title: String) -> TGChat {
        TGChat(
            id: id,
            title: title,
            chatType: .privateChat(userId: userId),
            unreadCount: 0,
            lastMessage: nil,
            memberCount: nil,
            order: 0,
            isInMainList: true,
            smallPhotoFileId: nil,
            source: SourceID(kind: .slack, account: "test")
        )
    }

    private static let gmailConversation = CanonicalConversation(
        id: "gmail-conversation",
        accountID: "gmail-account",
        source: .gmail,
        externalID: "thread",
        kind: .thread,
        title: "Test thread",
        updatedAt: nil
    )

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class RegistryTestSource: ObservableObject, MessageSource {
    nonisolated let sourceID = SourceID(kind: .slack, account: "test")
    @Published private(set) var chats: [TGChat] = []
    var currentUser: TGUser?
    var visibleChats: [TGChat] { chats.filter(\.isInMainList) }
    var isReady = true

    func replaceChats(_ replacement: [TGChat]) {
        chats = replacement
    }

    func chatHistory(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [TGMessage] { [] }
    func user(id: Int64) async throws -> TGUser? { nil }
    nonisolated func isLikelyBot(chat: TGChat) -> Bool { false }
}
