import Foundation

struct GmailSourceAdapter: SourceAdapter {
    let source: IntegrationSource = .gmail
    let capabilities = SourceCapabilities(
        canReadHistory: true,
        canReceiveLiveUpdates: false,
        canSend: false
    )

    private let client: HTTPSourceClient

    init(accessToken: String, session: URLSession = .shared) throws {
        client = try HTTPSourceClient(source: .gmail, bearerToken: accessToken, session: session)
    }

    func currentAccount() async throws -> ExternalSourceAccount {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        let profile = try JSONDecoder().decode(Profile.self, from: await client.data(url: url))
        return ExternalSourceAccount(
            externalID: profile.emailAddress.lowercased(),
            displayName: profile.emailAddress,
            email: profile.emailAddress
        )
    }

    func listConversations(cursor: SyncCursor?, limit: Int) async throws -> ConversationPage {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads")!
        var items = [
            URLQueryItem(name: "maxResults", value: String(max(1, min(limit, 100)))),
            // Pidgy is a read-only inbox, not a full mailbox backup. Limiting
            // the first projection to Inbox keeps connect fast and matches the
            // Superhuman-style surface the user is opening.
            URLQueryItem(name: "q", value: "in:inbox")
        ]
        if let cursor { items.append(URLQueryItem(name: "pageToken", value: cursor.rawValue)) }
        components.queryItems = items
        let response = try JSONDecoder().decode(ThreadList.self, from: await client.data(url: components.url!))
        let account = try await currentAccount()
        let accountID = CanonicalID.account(source: .gmail, externalID: account.externalID)
        let conversations = (response.threads ?? []).map { thread in
            CanonicalConversation(
                id: CanonicalID.conversation(source: .gmail, accountID: accountID, externalID: thread.id),
                accountID: accountID,
                source: .gmail,
                externalID: thread.id,
                kind: .thread,
                title: thread.snippet?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Email thread",
                updatedAt: nil
            )
        }
        return ConversationPage(
            conversations: conversations,
            nextCursor: response.nextPageToken.map(SyncCursor.init(rawValue:))
        )
    }

    func fetchMessages(
        conversation: CanonicalConversation,
        cursor: SyncCursor?,
        limit: Int
    ) async throws -> MessagePage {
        let encoded = conversation.externalID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversation.externalID
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(encoded)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return try Self.messagePage(
            from: await client.data(url: components.url!),
            conversation: conversation,
            limit: limit
        )
    }

    /// Pure decoding seam used by focused tests. Gmail routinely returns
    /// duplicate header names (especially Received), multipart bodies whose
    /// HTML part appears before plain text, and URL-safe base64 without
    /// padding; none of those should crash or leak markup into Pidgy.
    static func messagePage(
        from data: Data,
        conversation: CanonicalConversation,
        limit: Int
    ) throws -> MessagePage {
        let thread = try JSONDecoder().decode(ThreadDetail.self, from: data)
        let messages = (thread.messages ?? [])
            .suffix(max(1, limit))
            .map { message in
                let headers = (message.payload?.headers ?? []).reduce(into: [String: String]()) { result, header in
                    let key = header.name.lowercased()
                    // The first Subject/From is canonical; duplicate transport
                    // headers are irrelevant to the inbox projection.
                    if result[key] == nil { result[key] = header.value }
                }
                let sender = headers["from"]
                let timestamp = Double(message.internalDate ?? "")
                    .map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
                return CanonicalMessage(
                    id: CanonicalID.message(source: .gmail, conversationID: conversation.id, externalID: message.id),
                    conversationID: conversation.id,
                    source: .gmail,
                    externalID: message.id,
                    threadRootID: thread.id,
                    senderExternalID: Self.emailAddress(in: sender),
                    senderName: sender,
                    subject: headers["subject"],
                    date: timestamp,
                    text: Self.bodyText(payload: message.payload) ?? message.snippet,
                    isOutgoing: message.labelIds?.contains("SENT") == true,
                    isUnread: message.labelIds?.contains("UNREAD") == true
                )
            }
        return MessagePage(messages: messages, nextCursor: nil)
    }

    static func bodyText(payload: Payload?) -> String? {
        guard let payload else { return nil }
        if let plain = decodedPart(in: payload, mimeType: "text/plain") {
            return normalizedBody(plain)
        }
        if let html = decodedPart(in: payload, mimeType: "text/html") {
            return normalizedBody(plainText(fromHTML: html))
        }
        return nil
    }

    private static func decodedPart(in payload: Payload, mimeType: String) -> String? {
        if payload.mimeType?.lowercased() == mimeType,
           let encoded = payload.body?.data,
           let decoded = decodeBase64URL(encoded) {
            return decoded
        }
        for part in payload.parts ?? [] {
            if let decoded = decodedPart(in: part, mimeType: mimeType) { return decoded }
        }
        return nil
    }

    private static func normalizedBody(_ value: String) -> String? {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func plainText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</(p|div|li|tr|h[1-6])>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func emailAddress(in value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return String(value[range]).lowercased()
    }

    private struct Profile: Decodable { let emailAddress: String }
    private struct ThreadList: Decodable {
        let threads: [ThreadSummary]?
        let nextPageToken: String?
    }
    private struct ThreadSummary: Decodable { let id: String; let snippet: String? }
    private struct ThreadDetail: Decodable { let id: String; let messages: [Message]? }
    private struct Message: Decodable {
        let id: String
        let internalDate: String?
        let labelIds: [String]?
        let snippet: String?
        let payload: Payload?
    }
    struct Payload: Decodable {
        let mimeType: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Payload]?
    }
    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String? }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
