import Foundation

/// Decodable shapes for the subset of the Slack Web API that Pidgy's
/// read-only sync needs. All decoded with
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`, so snake_case
/// wire keys (`access_token`, `next_cursor`, …) map to camelCase here.
///
/// Only the fields we actually consume are modeled; Slack returns far more.

// MARK: - Shared

struct SlackResponseMetadata: Decodable, Sendable {
    let nextCursor: String?
}

/// Every Slack Web API response carries `ok`; on failure `error` holds a
/// machine-readable code (e.g. "ratelimited", "invalid_auth", "not_in_channel").
protocol SlackEnvelope {
    var ok: Bool { get }
    var error: String? { get }
}

// MARK: - oauth.v2.access

struct SlackOAuthAccess: Decodable, Sendable, SlackEnvelope {
    let ok: Bool
    let error: String?
    let appId: String?
    let authedUser: AuthedUser?
    let team: Team?

    // Token-rotation refresh responses (grant_type=refresh_token) may return
    // the new token at the top level rather than under `authed_user`; capture
    // both and prefer the nested user value.
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?

    var userAccessToken: String? { authedUser?.accessToken ?? accessToken }
    var userRefreshToken: String? { authedUser?.refreshToken ?? refreshToken }
    var userExpiresIn: Int? { authedUser?.expiresIn ?? expiresIn }

    struct AuthedUser: Decodable, Sendable {
        let id: String
        let scope: String?
        /// The user token (`xoxp-…`). Present on a successful user-scope grant.
        let accessToken: String?
        let tokenType: String?
        /// Only present when token rotation is enabled; absent for the
        /// long-lived (non-rotating) token we use by default.
        let refreshToken: String?
        let expiresIn: Int?
    }

    struct Team: Decodable, Sendable {
        let id: String
        let name: String?
    }
}

// MARK: - users.conversations / conversations.list

struct SlackConversationsList: Decodable, Sendable, SlackEnvelope {
    let ok: Bool
    let error: String?
    let channels: [SlackConversation]?
    let responseMetadata: SlackResponseMetadata?
}

struct SlackConversation: Decodable, Sendable {
    let id: String
    let name: String?
    let isChannel: Bool?
    let isGroup: Bool?
    let isIm: Bool?
    let isMpim: Bool?
    let isPrivate: Bool?
    let isArchived: Bool?
    let isMember: Bool?
    /// For DMs (`is_im`), the id of the other user.
    let user: String?
    let numMembers: Int?
    let topic: ValueHolder?

    struct ValueHolder: Decodable, Sendable {
        let value: String?
    }
}

// MARK: - conversations.history

struct SlackHistory: Decodable, Sendable, SlackEnvelope {
    let ok: Bool
    let error: String?
    let messages: [SlackMessage]?
    let hasMore: Bool?
    let responseMetadata: SlackResponseMetadata?
}

struct SlackMessage: Decodable, Sendable {
    let type: String?
    let subtype: String?
    let user: String?
    let botId: String?
    let text: String?
    /// Slack message id + sort key, e.g. "1700000000.000100".
    let ts: String
    let threadTs: String?
}

// MARK: - users.info

struct SlackUsersInfo: Decodable, Sendable, SlackEnvelope {
    let ok: Bool
    let error: String?
    let user: SlackUser?
}

// MARK: - users.list (bulk user load → warm the name cache once)

struct SlackUsersList: Decodable, Sendable, SlackEnvelope {
    let ok: Bool
    let error: String?
    let members: [SlackUser]?
    let responseMetadata: SlackResponseMetadata?
}

struct SlackUser: Decodable, Sendable {
    let id: String
    let name: String?
    let realName: String?
    let deleted: Bool?
    let isBot: Bool?
    let teamId: String?
    let profile: Profile?

    struct Profile: Decodable, Sendable {
        let displayName: String?
        let realName: String?
        let image72: String?
        let email: String?
    }
}
