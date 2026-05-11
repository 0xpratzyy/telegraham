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

    /// Sentry DSN baked in for crash + error telemetry
    /// (`PIDGY_SENTRY_DSN`). Returns nil when blank — `PidgyTelemetry.start`
    /// then skips Sentry init entirely so source builds never make
    /// outbound telemetry requests by accident.
    static let sentryDsn: String? = stringValue(forKey: "PidgyBundledSentryDsn")

    /// Short git SHA of the build, stamped by a postBuildScript. Useful in
    /// the About page so a tester's bug report can be tied to a specific
    /// build.
    static let buildCommitSHA: String = stringValue(forKey: "PidgyBuildCommitSHA") ?? "unknown"

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
