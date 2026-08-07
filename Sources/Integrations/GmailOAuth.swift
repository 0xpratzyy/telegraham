import Foundation
import CryptoKit
import AppKit

struct GmailOAuthToken: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }
}

private struct GmailOAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum GmailOAuth {
    static let callbackPort: UInt16 = 53683
    static let redirectURI = "http://127.0.0.1:53683/gmail/callback"
    /// Account chooser is required even after the first authorization; without
    /// it Google's remembered session makes “Add account” silently reconnect
    /// the mailbox already in Pidgy.
    static let authorizationPrompt = "select_account consent"
    static let scopes = [
        "openid",
        "email",
        "https://www.googleapis.com/auth/gmail.readonly"
    ]

    enum OAuthError: LocalizedError {
        case invalidAuthorizationURL
        case stateMismatch
        case denied(String)
        case noCode
        case tokenRequestFailed(String)
        case invalidTokenResponse

        var errorDescription: String? {
            switch self {
            case .invalidAuthorizationURL: return "Couldn't build the Google authorization URL."
            case .stateMismatch: return "Google sign-in failed a security check."
            case .denied(let reason) where reason == "access_denied":
                return "Google denied access. While Pidgy is in testing, use an approved test account and try again."
            case .denied(let reason): return "Google sign-in was cancelled or denied (\(reason))."
            case .noCode: return "Google didn't return an authorization code."
            case .tokenRequestFailed(let reason): return "Google couldn't complete sign-in: \(reason)"
            case .invalidTokenResponse: return "Google returned a token response Pidgy couldn't read."
            }
        }
    }

    @MainActor
    static func connect(clientId: String, clientSecret: String) async throws -> GmailOAuthToken {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = codeChallenge(for: verifier)
        let state = randomURLSafeString(byteCount: 16)
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: authorizationPrompt),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { throw OAuthError.invalidAuthorizationURL }
        let server = LocalCallbackServer(port: callbackPort, serviceName: "Gmail")
        async let callback = server.waitForCallback(timeout: 300)
        NSWorkspace.shared.open(url)
        let params = try await callback
        if let error = params["error"] { throw OAuthError.denied(error) }
        guard params["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = params["code"] else { throw OAuthError.noCode }
        return try await exchangeCode(
            clientId: clientId,
            clientSecret: clientSecret,
            code: code,
            verifier: verifier
        )
    }

    static func refresh(clientId: String, clientSecret: String, refreshToken: String) async throws -> GmailOAuthToken {
        try await tokenRequest([
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
    }

    private static func exchangeCode(
        clientId: String,
        clientSecret: String,
        code: String,
        verifier: String
    ) async throws -> GmailOAuthToken {
        try await tokenRequest([
            "client_id": clientId,
            "client_secret": clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI
        ])
    }

    private static func tokenRequest(_ fields: [String: String]) async throws -> GmailOAuthToken {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { key, value in
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                return "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidTokenResponse
        }
        return try tokenResponse(from: data, statusCode: http.statusCode)
    }

    static func tokenResponse(from data: Data, statusCode: Int) throws -> GmailOAuthToken {
        guard (200..<300).contains(statusCode) else {
            if let response = try? JSONDecoder().decode(GmailOAuthErrorResponse.self, from: data) {
                throw OAuthError.tokenRequestFailed(response.errorDescription ?? response.error)
            }
            throw OAuthError.invalidTokenResponse
        }
        guard let token = try? JSONDecoder().decode(GmailOAuthToken.self, from: data) else {
            throw OAuthError.invalidTokenResponse
        }
        return token
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        let data = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) })
        return base64URL(data)
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
