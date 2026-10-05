import Foundation
import CryptoKit
import Security

/// Public-client OAuth contract for locally hosted, open-source clients.
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
enum ChatGPTAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    enum Failure: LocalizedError, Equatable {
        case securityCheck, cancelled, timedOut, invalidToken, signInRequired, planNotEnabled
        case remote(status: Int, code: String, requestID: String?)
        var errorDescription: String? {
            switch self {
            case .securityCheck: return "ChatGPT sign-in failed a security check. Please try again."
            case .cancelled: return "ChatGPT sign-in was cancelled."
            case .timedOut: return "ChatGPT sign-in timed out. Please try again."
            case .invalidToken: return "ChatGPT returned credentials Pidgy couldn't verify."
            case .signInRequired: return "Please sign in to ChatGPT again."
            case .planNotEnabled: return "ChatGPT plan usage wasn't enabled. Continue with ChatGPT to grant access, or choose an API key."
            case .remote(let status, let code, _):
                switch code {
                case "subscription_sharing_usage_limit_exceeded": return "ChatGPT usage limit reached. Review your plan or Pidgy's limit in Manage usage."
                case "subscription_sharing_user_not_eligible": return "This ChatGPT account or workspace isn't eligible for plan usage. Choose another account or an API key."
                default: return "ChatGPT request failed (HTTP \(status), \(code)). Try again later or review your connection."
                }
            }
        }
    }

    struct Transaction {
        let state: String
        let nonce: String
        let verifier: String
        var redirectURI: String
        let clientID: String?
        let createdAt: Date
        init(redirectURI: String, clientID: String? = nil, now: Date = Date()) {
            self.state = ChatGPTAuth.randomValue()
            self.nonce = ChatGPTAuth.randomValue()
            self.verifier = ChatGPTAuth.randomValue()
            self.redirectURI = redirectURI
            self.clientID = clientID
            self.createdAt = now
        }

        func authorizationURL(hostID: String, loginHint: String? = nil, idTokenHint: String? = nil,
                              consent: Bool = false) -> URL {
            var parts = URLComponents(string: issuer + "/api/accounts/authorize")!
            var fields = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                          "redirect_uri": redirectURI, "response_type": "code", "scope": scopes,
                          "resource": resource, "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": challenge(verifier)]
            if clientID == nil { fields["agent_name_hint"] = "Pidgy" }
            if clientID != nil { fields["login_hint"] = loginHint; fields["id_token_hint"] = idTokenHint }
            if consent { fields["prompt"] = "consent" }
            parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return parts.url!
        }

        func exchangeFields(callback: [String: String], now: Date = Date()) throws -> [String: String] {
            guard now.timeIntervalSince(createdAt) < 300, now >= createdAt,
                  callback["state"] == state else { throw Failure.securityCheck }
            if callback["error"] != nil { throw Failure.cancelled }
            guard let code = callback["code"], !code.isEmpty else { throw Failure.securityCheck }
            let issued = callback["client_id"] ?? clientID
            guard let issued, issued.hasPrefix("oaiapp_"),
                  clientID == nil || issued == clientID else { throw Failure.securityCheck }
            return ["grant_type": "authorization_code", "client_id": issued, "code": code,
                    "code_verifier": verifier, "redirect_uri": redirectURI, "resource": resource]
        }
    }

    struct TokenResponse: Decodable {
        let access_token: String?
        let refresh_token: String?
        let id_token: String?
        let token_type: String?
        let scope: String?
        let expires_in: Int?
    }

    struct Identity: Equatable {
        let subject: String
        let email: String?
        let name: String?
    }

    struct JWKS: Decodable {
        struct Key: Decodable { let kty: String; let kid: String; let n: String?; let e: String?; let alg: String?; let use: String? }
        let keys: [Key]
    }

    static func validateIDToken(_ token: String, keys: JWKS, clientID: String, nonce: String,
                                now: Date = Date()) throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerData = decodeURL(String(parts[0])),
              let payloadData = decodeURL(String(parts[1])), let signature = decodeURL(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let jwk = keys.keys.first(where: { $0.kid == kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig") }),
              let n = jwk.n.flatMap(decodeURL), let e = jwk.e.flatMap(decodeURL) else { throw Failure.invalidToken }
        let der = derElement(0x30, derInteger(n) + derInteger(e))
        guard let key = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                    kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                    Data((String(parts[0]) + "." + String(parts[1])).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw Failure.invalidToken }
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audience.contains(clientID),
              audience.count == 1 || claims["azp"] as? String == clientID,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970 - 5,
              let iat = claims["iat"] as? Double, iat <= now.timeIntervalSince1970 + 5,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 5,
              claims["nonce"] as? String == nonce,
              let subject = claims["sub"] as? String, !subject.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw Failure.invalidToken }
        return Identity(subject: subject, email: claims["email"] as? String, name: claims["name"] as? String)
    }

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    static func randomValue() -> String { encodeURL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })) }
    static func challenge(_ value: String) -> String { encodeURL(Data(SHA256.hash(data: Data(value.utf8)))) }
    static func encodeURL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeURL(_ value: String) -> Data? {
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
    private static func derInteger(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty { value = Data([0]) }
        if value.first! & 0x80 != 0 { value.insert(0, at: 0) }
        return derElement(0x02, value)
    }
    private static func derElement(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = bytes.count
        var encoded: [UInt8] = []
        if length < 128 { encoded = [UInt8(length)] }
        else {
            while length > 0 { encoded.insert(UInt8(length & 255), at: 0); length >>= 8 }
            encoded.insert(0x80 | UInt8(encoded.count), at: 0)
        }
        return Data([tag] + encoded) + bytes
    }
}
