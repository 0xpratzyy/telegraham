import Foundation

/// PaymentService backed by Dodo Payments' license keys — the
/// CleanShot model. Subscribe via hosted checkout → Dodo emails a key
/// → activate it here → validate on launch. Dodo ties key validity to
/// subscription status, so a lapsed sub makes `validate` return false
/// and the app locks automatically.
///
/// The activate/validate/deactivate endpoints are PUBLIC (no API key),
/// so this runs entirely client-side with no server or secret.
struct DodoLicenseService: PaymentService {
    /// Offline grace: a successful validate keeps the app active for
    /// this long, so transient network failures / offline use don't
    /// lock a paying user. Re-validated on each launch.
    static let validationGraceDays = 5

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = BundledSecrets.dodoBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func checkoutURL(for plan: PidgyPlan) -> URL? {
        BundledSecrets.dodoCheckoutURL(for: plan)
    }

    /// Validate the stored license key. Returns the paid-through date
    /// (now + grace) when valid, nil otherwise — fed into
    /// EntitlementStore.markActive.
    func refreshEntitlement() async -> EntitlementRefresh {
        guard let licenseKey = (try? KeychainManager.retrieve(for: .dodoLicenseKey)) ?? nil,
              !licenseKey.isEmpty else { return .unknown }
        switch await validate(licenseKey: licenseKey) {
        case .valid:
            // Verified now → active through the offline-grace window. Re-validated
            // on each launch, so a later cancel/refund flips this to .lapsed and
            // the grace window then runs out instead of renewing.
            return .active(until: Date().addingTimeInterval(Double(Self.validationGraceDays) * 86_400))
        case .invalid:
            return .lapsed
        case .unreachable:
            return .unknown
        }
    }

    // MARK: - Public Dodo license API

    enum LicenseError: Error, LocalizedError {
        case activationFailed(String)
        var errorDescription: String? {
            switch self {
            case .activationFailed(let m): return m
            }
        }
    }

    /// Activate a key for this device; returns the instance id Dodo
    /// assigns (persisted so we can deactivate later).
    func activate(licenseKey: String, deviceName: String) async throws -> ActivationResult {
        let body: [String: Any] = ["license_key": licenseKey, "name": deviceName]
        let (data, http) = try await post("/licenses/activate", body: body)
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw LicenseError.activationFailed(msg ?? "Activation failed (\(http.statusCode)). Check the key and your device limit.")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else {
            throw LicenseError.activationFailed("Unexpected activation response.")
        }
        // Dodo nests the product as { product: { product_id } } — the only place
        // the tier is exposed (validate returns just { valid }).
        let productID = (json?["product"] as? [String: Any])?["product_id"] as? String
        return ActivationResult(instanceID: id, productID: productID)
    }

    /// Three-state so the caller can tell "Dodo says the key is invalid"
    /// (revoke) from "couldn't reach Dodo" (keep the cached entitlement).
    /// Conflating these is what let a network blip look like a lapsed sub.
    enum ValidationResult { case valid, invalid, unreachable }

    func validate(licenseKey: String) async -> ValidationResult {
        let response: (Data, HTTPURLResponse)
        do {
            response = try await post("/licenses/validate", body: ["license_key": licenseKey])
        } catch {
            return .unreachable  // transport failure — offline / DNS / timeout
        }
        let (data, http) = response
        if (500..<600).contains(http.statusCode) {
            return .unreachable  // server-side blip — not a real "invalid"
        }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid  // 4xx / unparseable → the key genuinely isn't valid
        }
        return ((json["valid"] as? Bool) ?? false) ? .valid : .invalid
    }

    func deactivate(licenseKey: String, instanceID: String) async {
        _ = try? await post("/licenses/deactivate", body: [
            "license_key": licenseKey,
            "license_key_instance_id": instanceID
        ])
    }

    private func post(_ path: String, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LicenseError.activationFailed("No HTTP response")
        }
        return (data, http)
    }
}
