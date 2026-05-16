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

    /// LangSmith API key for LLM call tracing (`PIDGY_BUNDLED_LANGSMITH_API_KEY`).
    /// When nil/empty, `LangSmithTracer.record` is a no-op so no traces leave
    /// the device. Intended as temporary observability scaffolding — remove
    /// once we've extracted the eval fixtures we need.
    ///
    /// **Release builds always return nil** — the LangSmith tracer ships
    /// raw prompt + response (Telegram message text) to LangChain's servers,
    /// which is fine for dev-loop debugging but inappropriate for distributed
    /// builds. The xcconfig also keeps the key out of the Release Info.plist
    /// for defense in depth; this Swift gate ensures even a Debug-keyed
    /// build that somehow ends up shipped won't actually trace.
    static let langSmithApiKey: String? = {
        #if DEBUG
        return stringValue(forKey: "PidgyBundledLangSmithApiKey")
        #else
        return nil
        #endif
    }()

    /// Optional override for the LangSmith project name traces land in
    /// (`PIDGY_BUNDLED_LANGSMITH_PROJECT`). Defaults to "pidgy-dev" when blank.
    /// Release-gated for symmetry with the key.
    static let langSmithProjectName: String? = {
        #if DEBUG
        return stringValue(forKey: "PidgyBundledLangSmithProject")
        #else
        return nil
        #endif
    }()

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
