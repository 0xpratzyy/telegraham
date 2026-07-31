//
//  InviteService.swift
//  Pidgy
//
//  Beta invite gate + referrals. Onboarding hard-gates on an invite code
//  (validated server-side by the AI proxy Worker's /v1/invite routes);
//  every onboarded install receives personal codes to hand out, and each
//  successful referral pays the referrer bonus codes + a counted referral
//  (redeemed as free Pro months at billing cutover).
//
//  Identity: the ONLY thing that leaves the machine is the random
//  per-install id (PidgyTelemetry.installId) and the code string — never
//  the Telegram account. Redemption is idempotent per install, so a
//  "Reset all local data" + re-onboard returns the same registration
//  instead of burning a second code.
//

import Foundation

@MainActor
final class InviteService: ObservableObject {
    static let shared = InviteService()

    struct PersonalCode: Identifiable, Equatable, Codable {
        let code: String
        var redeemed: Bool
        var id: String { code }
    }

    enum RedeemError: LocalizedError, Equatable {
        case invalidCode
        case codeAlreadyUsed
        case tooManyAttempts
        case network

        var errorDescription: String? {
            switch self {
            case .invalidCode:
                return "That code doesn't look right. Codes look like PIDGY-ABC123."
            case .codeAlreadyUsed:
                return "That code has already been used. Ask your friend for a fresh one."
            case .tooManyAttempts:
                return "Too many attempts. Try again tomorrow."
            case .network:
                return "Couldn't reach the invite server. Check your connection and try again."
            }
        }
    }

    /// True while the code entry is being validated server-side.
    @Published private(set) var isRedeeming = false
    /// This install's personal codes (with per-code redeemed state).
    @Published private(set) var codes: [PersonalCode] = []
    /// Successful referrals credited to this install.
    @Published private(set) var referrals = 0
    /// True once this install redeemed a code (cached locally, healed from
    /// the server on refreshStatus()).
    @Published private(set) var isRegistered: Bool

    /// The gate only applies to builds that can actually validate a code —
    /// distributed beta builds bundle the proxy. Source builds (no proxy)
    /// skip the step entirely rather than dead-ending the flow.
    nonisolated static var gateRequired: Bool { BundledSecrets.hasBundledAIProxy }

    private init() {
        isRegistered = UserDefaults.standard.bool(forKey: AppConstants.Preferences.inviteRegisteredKey)
        if let data = UserDefaults.standard.data(forKey: AppConstants.Preferences.inviteCodesCacheKey),
           let cached = try? JSONDecoder().decode([PersonalCode].self, from: data) {
            codes = cached
        }
        referrals = UserDefaults.standard.integer(forKey: AppConstants.Preferences.inviteReferralsKey)
    }

    // MARK: - API

    /// Validate + redeem an invite code for this install. Publishes the
    /// personal codes on success. Throws a user-presentable RedeemError.
    func redeem(code raw: String) async throws {
        guard let url = endpoint("redeem"), let token = BundledSecrets.aiProxyToken else {
            throw RedeemError.network
        }
        isRedeeming = true
        defer { isRedeeming = false }

        let payload: [String: String] = [
            "code": raw.trimmingCharacters(in: .whitespacesAndNewlines),
            "installId": PidgyTelemetry.installId
        ]
        let (data, status) = try await post(url: url, token: token, payload: payload)
        switch status {
        case 200:
            let response = try? JSONDecoder().decode(RedeemResponse.self, from: data)
            guard let response, response.ok == true else { throw RedeemError.network }
            apply(
                codes: (response.codes ?? []).map { PersonalCode(code: $0, redeemed: false) },
                referrals: response.referrals ?? 0,
                registered: true
            )
        case 404, 400: throw RedeemError.invalidCode
        case 409: throw RedeemError.codeAlreadyUsed
        case 429: throw RedeemError.tooManyAttempts
        default: throw RedeemError.network
        }
    }

    /// Refresh codes + referral count from the server (silent — UI shows
    /// the cache until this lands). Also self-heals a lost local flag:
    /// a registered install that reset its defaults gets re-marked here.
    func refreshStatus() async {
        guard let url = endpoint("status"), let token = BundledSecrets.aiProxyToken else { return }
        let payload = ["installId": PidgyTelemetry.installId]
        guard let (data, status) = try? await post(url: url, token: token, payload: payload),
              status == 200,
              let response = try? JSONDecoder().decode(StatusResponse.self, from: data)
        else { return }
        guard response.registered else { return }
        apply(
            codes: (response.codes ?? []).map { PersonalCode(code: $0.code, redeemed: $0.redeemed) },
            referrals: response.referrals ?? 0,
            registered: true
        )
    }

    // MARK: - Internals

    private func apply(codes newCodes: [PersonalCode], referrals newReferrals: Int, registered: Bool) {
        codes = newCodes
        referrals = newReferrals
        isRegistered = registered
        let defaults = UserDefaults.standard
        defaults.set(registered, forKey: AppConstants.Preferences.inviteRegisteredKey)
        defaults.set(newReferrals, forKey: AppConstants.Preferences.inviteReferralsKey)
        if let data = try? JSONEncoder().encode(newCodes) {
            defaults.set(data, forKey: AppConstants.Preferences.inviteCodesCacheKey)
        }
    }

    /// Rewrite the bundled proxy URL onto an invite route, keeping
    /// scheme/host/port (same pattern as the managed AI endpoint).
    private func endpoint(_ route: String) -> URL? {
        guard let proxyURL = BundledSecrets.aiProxyURL,
              var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.path = "/v1/invite/\(route)"
        return components.url
    }

    private func post(url: URL, token: String, payload: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, status)
        } catch {
            throw RedeemError.network
        }
    }

    private struct RedeemResponse: Decodable {
        let ok: Bool?
        let codes: [String]?
        let referrals: Int?
        let alreadyRegistered: Bool?
    }

    private struct StatusResponse: Decodable {
        struct CodeEntry: Decodable {
            let code: String
            let redeemed: Bool
        }
        let registered: Bool
        let codes: [CodeEntry]?
        let referrals: Int?
    }
}
