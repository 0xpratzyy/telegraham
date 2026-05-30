import Foundation

/// Thin async client for the Slack Web API methods Pidgy's read-only sync
/// uses. An `actor` so token updates and the reactive 429 backoff are
/// serialized. The proactive ~1/min pacing for `conversations.history`
/// (the non-Marketplace limit) lives in the sync layer; here we only
/// react to `429` responses by honoring `Retry-After`.
actor SlackAPIClient {
    enum SlackAPIError: Error, LocalizedError {
        case notAuthenticated
        case http(Int)
        case slack(String)        // Slack `error` code from an `ok:false` body
        case decoding(Error)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Slack is not connected"
            case .http(let code): return "Slack HTTP \(code)"
            case .slack(let code): return "Slack error: \(code)"
            case .decoding: return "Couldn't parse Slack response"
            case .transport: return "Couldn't reach Slack"
            }
        }
    }

    private let session: URLSession
    private let base = URL(string: "https://slack.com/api/")!
    private var accessToken: String?

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func setAccessToken(_ token: String?) {
        accessToken = token
    }

    // MARK: - OAuth (no bearer; PKCE = no client secret)

    /// Exchange an authorization code for a user token.
    func exchangeCode(
        clientId: String,
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> SlackOAuthAccess {
        try await post(
            "oauth.v2.access",
            form: [
                "client_id": clientId,
                "code": code,
                "code_verifier": codeVerifier,
                "redirect_uri": redirectURI
            ],
            authorized: false
        )
    }

    /// Refresh a rotating token (only used when token rotation is enabled).
    func refreshToken(clientId: String, refreshToken: String) async throws -> SlackOAuthAccess {
        try await post(
            "oauth.v2.access",
            form: [
                "client_id": clientId,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ],
            authorized: false
        )
    }

    // MARK: - Reads

    /// Channels / DMs the authed user is a member of.
    func conversationsList(cursor: String? = nil, limit: Int = 200) async throws -> SlackConversationsList {
        var form = [
            "types": "public_channel,private_channel,mpim,im",
            "exclude_archived": "true",
            "limit": String(limit)
        ]
        if let cursor { form["cursor"] = cursor }
        return try await post("users.conversations", form: form, authorized: true)
    }

    /// Messages in a conversation, newest-first. `oldest`/`latest` are
    /// Slack ts strings; `limit` is capped at 15 for non-Marketplace apps.
    func conversationsHistory(
        channel: String,
        oldest: String? = nil,
        latest: String? = nil,
        limit: Int = 15,
        cursor: String? = nil
    ) async throws -> SlackHistory {
        var form = [
            "channel": channel,
            "limit": String(limit)
        ]
        if let oldest { form["oldest"] = oldest }
        if let latest { form["latest"] = latest }
        if let cursor { form["cursor"] = cursor }
        return try await post("conversations.history", form: form, authorized: true)
    }

    /// Replies in a single thread. `ts` is the thread parent's timestamp.
    /// Returns the parent followed by its replies; same envelope shape as
    /// `conversations.history`. Subject to the same paced rate limit, so
    /// callers fetch on demand (one open thread at a time) rather than in bulk.
    func conversationsReplies(
        channel: String,
        ts: String,
        limit: Int = 30,
        cursor: String? = nil
    ) async throws -> SlackHistory {
        var form = [
            "channel": channel,
            "ts": ts,
            "limit": String(limit)
        ]
        if let cursor { form["cursor"] = cursor }
        return try await post("conversations.replies", form: form, authorized: true)
    }

    func usersInfo(user: String) async throws -> SlackUsersInfo {
        try await post("users.info", form: ["user": user], authorized: true)
    }

    /// All members of the workspace (paginated). Used once to warm the
    /// name cache so message-mention decoding never needs per-user lookups.
    func usersList(cursor: String? = nil, limit: Int = 200) async throws -> SlackUsersList {
        var form = ["limit": String(limit)]
        if let cursor { form["cursor"] = cursor }
        return try await post("users.list", form: form, authorized: true)
    }

    // MARK: - Transport

    private func post<T: Decodable & SlackEnvelope>(
        _ method: String,
        form: [String: String],
        authorized: Bool
    ) async throws -> T {
        var request = URLRequest(url: base.appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if authorized {
            guard let accessToken else { throw SlackAPIError.notAuthenticated }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Self.encodeForm(form)

        // One retry honoring Retry-After on a 429.
        for attempt in 0..<2 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw SlackAPIError.transport(error)
            }

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429, attempt == 0 {
                    let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init) ?? 60
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw SlackAPIError.http(http.statusCode)
                }
            }

            let decoded: T
            do {
                decoded = try Self.decoder.decode(T.self, from: data)
            } catch {
                throw SlackAPIError.decoding(error)
            }
            guard decoded.ok else {
                throw SlackAPIError.slack(decoded.error ?? "unknown")
            }
            return decoded
        }
        throw SlackAPIError.http(429)
    }

    private static func encodeForm(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs: [String] = form.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        let body = pairs.joined(separator: "&")
        return Data(body.utf8)
    }
}
