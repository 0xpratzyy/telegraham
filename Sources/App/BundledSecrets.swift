//
//  BundledSecrets.swift
//  Pidgy
//
//  Reads credentials baked into the app bundle at build time via the
//  `Config/BetaSecrets.xcconfig` (+ gitignored `BetaSecrets.local.xcconfig`)
//  pipeline. Empty values mean "not bundled" — the code paths that consume
//  these fall back to the user-entry / Keychain flows.
//

import Foundation

enum BundledSecrets {
    /// Telegram api_id from `PIDGY_TG_API_ID` (numeric).
    static let telegramApiId: Int32? = {
        guard let raw = stringValue(forKey: "PidgyBundledTelegramApiId"),
              let value = Int32(raw)
        else { return nil }
        return value
    }()

    /// Telegram api_hash from `PIDGY_TG_API_HASH` (hex string).
    static let telegramApiHash: String? = stringValue(forKey: "PidgyBundledTelegramApiHash")

    /// OpenAI API key baked in for zero-config beta testers
    /// (`PIDGY_BUNDLED_OPENAI_API_KEY`). Returns nil if the build did not
    /// include one — the AI Settings page falls back to BYO key.
    static let openAIApiKey: String? = stringValue(forKey: "PidgyBundledOpenAIApiKey")

    /// AI proxy endpoint (`PIDGY_AI_PROXY_URL`) — the deployed
    /// infra/ai-proxy Worker's chat-completions URL. When present together
    /// with `aiProxyToken`, the zero-setup flow routes OpenAI requests
    /// through the proxy with the revocable gate token, so the raw OpenAI
    /// key no longer needs to ship in the bundle (issue #26).
    static let aiProxyURL: URL? = {
        guard let raw = stringValue(forKey: "PidgyBundledAIProxyURL"),
              let url = URL(string: raw),
              url.scheme == "https"
        else { return nil }
        return url
    }()

    /// Gate token (`PIDGY_AI_PROXY_TOKEN`) the app presents to the AI proxy
    /// as its Bearer credential. Bundled → extractable like any baked-in
    /// value, but revocable server-side and worthless outside the proxy.
    static let aiProxyToken: String? = stringValue(forKey: "PidgyBundledAIProxyToken")

    /// True when both proxy values are present — the zero-setup AI
    /// bootstrap then prefers the proxy over the bundled raw key.
    static var hasBundledAIProxy: Bool {
        aiProxyURL != nil && (aiProxyToken?.isEmpty == false)
    }

    // MARK: - Dodo Payments (license-key subscriptions)

    /// Base URL for Dodo's PUBLIC license endpoints (activate / validate
    /// / deactivate — no API key needed). Test:
    /// https://test.dodopayments.com · Live: https://live.dodopayments.com
    static let dodoBaseURL: URL = {
        guard let raw = stringValue(forKey: "PidgyBundledDodoBaseURL"),
              let url = URL(string: raw), url.scheme == "https" else {
            return URL(string: "https://test.dodopayments.com")!
        }
        return url
    }()

    /// Hosted-checkout URL per plan (from the Dodo dashboard product
    /// page). Non-secret. Empty until the products are created.
    static func dodoCheckoutURL(for plan: PidgyPlan) -> URL? {
        let key = plan == .byok ? "PidgyBundledDodoCheckoutBYOK" : "PidgyBundledDodoCheckoutBundled"
        guard let raw = stringValue(forKey: key), let url = URL(string: raw) else { return nil }
        return url
    }

    /// Dodo customer-portal link (manage / upgrade / downgrade / cancel).
    /// Non-secret. Empty until you paste your portal URL from Dodo.
    static var dodoPortalURL: URL? {
        guard let raw = stringValue(forKey: "PidgyBundledDodoPortalURL"),
              let url = URL(string: raw) else { return nil }
        return url
    }

    /// Resolve a Dodo product id (from the activate response) → plan. The ids
    /// are embedded in the per-plan checkout URLs (`…/buy/{product_id}`), so we
    /// derive the mapping from those — no extra config, and it stays correct
    /// across test/live since both flow from the same checkout URLs.
    static func planForDodoProduct(id: String) -> PidgyPlan? {
        guard !id.isEmpty else { return nil }
        return PidgyPlan.allCases.first {
            dodoCheckoutURL(for: $0)?.absoluteString.contains(id) == true
        }
    }

    /// Sentry DSN baked in for crash + error telemetry
    /// (`PIDGY_SENTRY_DSN`). Returns nil when blank — `PidgyTelemetry.start`
    /// then skips Sentry init entirely so source builds never make
    /// outbound telemetry requests by accident.
    static let sentryDsn: String? = stringValue(forKey: "PidgyBundledSentryDsn")

    /// Short git SHA of the build. Useful in the About page + the
    /// feedback sheet so a tester's bug report can be tied to a
    /// specific build.
    ///
    /// Read from a sidecar file at `Contents/Resources/PidgyBuildSHA.txt`
    /// that the post-build script writes. We stopped stamping the
    /// Info.plist directly because Xcode's `ProcessInfoPlistFile`
    /// re-emits the plist from source on incremental builds and
    /// silently clobbers any in-place edit, leaving every dev build
    /// stuck at "unknown".
    ///
    /// Falls back to the legacy Info.plist key (still wired in
    /// project.yml as a no-op placeholder) and then to "unknown" so
    /// the field never crashes a caller.
    static let buildCommitSHA: String = {
        if let url = Bundle.main.url(forResource: "PidgyBuildSHA", withExtension: "txt"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return stringValue(forKey: "PidgyBuildCommitSHA") ?? "unknown"
    }()

    // NOTE: the LangSmith key accessors were removed deliberately. LLM
    // traces (which contain raw Telegram message text) are now written
    // by LocalAITraceRecorder to a local file only — no third-party
    // tracing endpoint exists in the app, in any configuration. Don't
    // reintroduce a remote tracing key without revisiting the privacy
    // promises in README "Telemetry honesty".

    /// True when both Telegram credentials are present — the auth flow can
    /// then skip its credential entry step and go straight to QR / phone.
    static var hasBundledTelegramCredentials: Bool {
        telegramApiId != nil && (telegramApiHash?.isEmpty == false)
    }

    /// True when an OpenAI key is baked in. Lets onboarding pre-configure
    /// the AI provider so the dashboard's reply queue / task extraction
    /// works on first launch without the user pasting a key.
    static var hasBundledOpenAIKey: Bool {
        openAIApiKey?.isEmpty == false
    }

    private static func stringValue(forKey key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Xcode leaves the literal "$(VARIABLE)" in place when nothing
        // resolves it, so treat that as "not present" too.
        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return nil
        }
        return trimmed
    }
}
