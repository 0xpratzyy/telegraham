import Foundation
import CryptoKit
import AppKit
import Network

/// Drives the Slack "Connect" flow using OAuth 2.1 + PKCE on a public
/// client — no client secret, no backend. We open the system browser to
/// Slack's consent screen, catch the `http://localhost:53682/slack/callback`
/// redirect with a one-shot loopback listener, then exchange the code for a
/// user token via `oauth.v2.access` (PKCE `code_verifier`, no secret).
enum SlackOAuth {
    static let callbackPort: UInt16 = 53682
    static let redirectURI = "http://localhost:53682/slack/callback"

    /// User-token read scopes for the read-only digest. Desktop/PKCE flows
    /// can't request bot scopes, and a user token sees what the user sees.
    static let userScopes = [
        "channels:read", "channels:history",
        "groups:read", "groups:history",
        "im:read", "im:history",
        "mpim:read", "mpim:history",
        "users:read"
    ]

    enum OAuthError: LocalizedError {
        case cannotBuildURL
        case stateMismatch
        case denied(String)
        case noCode

        var errorDescription: String? {
            switch self {
            case .cannotBuildURL: return "Couldn't build the Slack authorization URL"
            case .stateMismatch: return "Slack sign-in failed a security check (state mismatch)"
            case .denied(let reason): return "Slack sign-in was cancelled or denied (\(reason))"
            case .noCode: return "Slack didn't return an authorization code"
            }
        }
    }

    /// Runs the full interactive flow and returns the raw token response.
    /// `@MainActor` because it opens the browser via `NSWorkspace`.
    @MainActor
    static func connect(clientId: String, api: SlackAPIClient) async throws -> SlackOAuthAccess {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeString(byteCount: 16)

        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "user_scope", value: userScopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizeURL = components.url else { throw OAuthError.cannotBuildURL }

        // Begin listening before opening the browser; the redirect won't
        // arrive until the user authorizes (seconds away), so there's no race.
        let server = LocalCallbackServer(port: callbackPort)
        async let callback = server.waitForCallback(timeout: 300)
        NSWorkspace.shared.open(authorizeURL)
        let params = try await callback

        if let error = params["error"] { throw OAuthError.denied(error) }
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.noCode }

        return try await api.exchangeCode(
            clientId: clientId,
            code: code,
            codeVerifier: verifier,
            redirectURI: redirectURI
        )
    }

    // MARK: - PKCE helpers

    private static func randomURLSafeString(byteCount: Int) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        return base64URLEncode(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot loopback HTTP server that captures a single OAuth redirect
/// (`GET /slack/callback?code=…&state=…`), replies to the browser with a
/// small "return to Pidgy" page, then stops. Bound to `127.0.0.1` only so
/// it never accepts outside connections (and avoids a firewall prompt).
final class LocalCallbackServer: @unchecked Sendable {
    enum CallbackError: LocalizedError {
        case listenFailed(Error)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .listenFailed: return "Couldn't open the local sign-in listener"
            case .timedOut: return "Slack sign-in timed out"
            }
        }
    }

    private let port: NWEndpoint.Port
    private let lock = NSLock()
    private var listener: NWListener?
    private var finished = false
    private var continuation: CheckedContinuation<[String: String], Error>?

    init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener: NWListener
            do {
                listener = try NWListener(using: params)
            } catch {
                finish(.failure(CallbackError.listenFailed(error)))
                return
            }
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(CallbackError.timedOut))
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let firstLine = data
                .flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\r\n", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            self.sendClosingPage(on: connection)
            self.finish(.success(Self.queryParams(fromRequestLine: firstLine)))
        }
    }

    private func sendClosingPage(on connection: NWConnection) {
        let html = """
        <html><head><meta charset="utf-8"></head>
        <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:80px;color:#1a1a1a">
        <h2>Pidgy is connected to Slack</h2>
        <p>You can close this tab and return to Pidgy.</p>
        </body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func queryParams(fromRequestLine line: String) -> [String: String] {
        // e.g. "GET /slack/callback?code=…&state=… HTTP/1.1"
        let fields = line.split(separator: " ")
        guard fields.count >= 2,
              let query = fields[1].split(separator: "?", maxSplits: 1).dropFirst().first
        else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let activeListener = listener
        listener = nil
        lock.unlock()

        activeListener?.cancel()
        continuation.resume(with: result)
    }
}
