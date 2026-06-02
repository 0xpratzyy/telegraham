import Foundation
import Combine

/// Owns the Slack connection lifecycle: the interactive OAuth connect, the
/// launch-time restore from Keychain, and disconnect. On success it builds a
/// `SlackService`, registers it on `SourceRegistry`, and kicks off the first
/// load. Publishes a small state enum for the Preferences UI.
@MainActor
final class SlackConnectionManager: ObservableObject {
    enum State: Equatable {
        case unavailable               // no client id bundled — Slack disabled
        case disconnected
        case connecting
        case connected(workspace: String)
        case failed(String)
    }

    static let shared = SlackConnectionManager()

    @Published private(set) var state: State
    private(set) var service: SlackService?
    private let api = SlackAPIClient()

    init() {
        state = BundledSecrets.hasSlackClientId ? .disconnected : .unavailable
    }

    /// Recreate the service from stored tokens on launch. No-op when Slack
    /// isn't bundled or nothing was previously connected.
    func restore() {
        guard BundledSecrets.hasSlackClientId else { state = .unavailable; return }
        guard let token = try? KeychainManager.retrieve(for: .slackAccessToken),
              let teamId = try? KeychainManager.retrieve(for: .slackTeamId),
              let authedUser = try? KeychainManager.retrieve(for: .slackAuthedUserId) else {
            state = .disconnected
            return
        }
        let teamName = try? KeychainManager.retrieve(for: .slackTeamName)
        let refresh = try? KeychainManager.retrieve(for: .slackRefreshToken)
        let expiry = (try? KeychainManager.retrieve(for: .slackTokenExpiry))
            .flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0) }
        activate(teamId: teamId, teamName: teamName, authedUser: authedUser, token: token, refresh: refresh, expiry: expiry)
    }

    /// Interactive "Connect Slack" — runs the OAuth+PKCE flow, persists the
    /// token, and brings the workspace online.
    func connect() async {
        guard let clientId = BundledSecrets.slackClientId else { state = .unavailable; return }
        state = .connecting
        do {
            let access = try await SlackOAuth.connect(clientId: clientId, api: api)
            guard let token = access.userAccessToken,
                  let authedUser = access.authedUser?.id,
                  let teamId = access.team?.id else {
                state = .failed("Slack didn't return a user token")
                return
            }
            let teamName = access.team?.name
            let refresh = access.userRefreshToken
            let expiry = access.userExpiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

            // token + team + user ids are what restore() needs next launch —
            // if they don't persist, the user appears connected now and
            // mysteriously logs out next launch. Surface that rather than
            // swallow it. The rest (teamName/refresh/expiry) stay best-effort.
            do {
                try KeychainManager.save(token, for: .slackAccessToken)
                try KeychainManager.save(teamId, for: .slackTeamId)
                try KeychainManager.save(authedUser, for: .slackAuthedUserId)
            } catch {
                state = .failed("Couldn't save Slack credentials to the Keychain. Please try connecting again.")
                return
            }
            if let teamName { try? KeychainManager.save(teamName, for: .slackTeamName) }
            if let refresh { try? KeychainManager.save(refresh, for: .slackRefreshToken) }
            if let expiry { try? KeychainManager.save(String(expiry.timeIntervalSince1970), for: .slackTokenExpiry) }

            activate(teamId: teamId, teamName: teamName, authedUser: authedUser, token: token, refresh: refresh, expiry: expiry)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Disconnect: drop the source from the registry and clear stored tokens.
    func disconnect() {
        if let service {
            service.shutdown()
            SourceRegistry.shared.unregister(service)
        }
        service = nil
        for key: KeychainManager.Key in [.slackAccessToken, .slackRefreshToken, .slackTeamId, .slackTeamName, .slackAuthedUserId] {
            try? KeychainManager.delete(for: key)
        }
        state = .disconnected
    }

    private func activate(teamId: String, teamName: String?, authedUser: String, token: String, refresh: String?, expiry: Date?) {
        guard let clientId = BundledSecrets.slackClientId else { return }
        // Cancel any prior service's loop before replacing it (reconnect path).
        self.service?.shutdown()
        let service = SlackService(
            clientId: clientId,
            teamId: teamId,
            teamName: teamName,
            authedUserNativeId: authedUser,
            accessToken: token,
            refreshToken: refresh,
            tokenExpiry: expiry,
            api: api
        )
        self.service = service
        SourceRegistry.shared.register(service)
        state = .connected(workspace: teamName ?? teamId)
        Task { await service.start() }
    }
}
