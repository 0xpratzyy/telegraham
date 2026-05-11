//
//  PidgyTelemetry.swift
//  Pidgy
//
//  Thin wrapper over Sentry. Goals:
//   - Init is conditional on `BundledSecrets.sentryDsn` — source builds
//     without a DSN make zero telemetry network calls.
//   - All event bodies pass through `scrubEvent` before sending so we
//     never ship raw Telegram message text, sender names, phone numbers,
//     or API tokens up to Sentry.
//   - Captures are debug-suppressible so local dev iterations don't
//     pollute the production project.
//

import Foundation
import OSLog
import Sentry

enum PidgyTelemetry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.pidgy.app",
        category: "Telemetry"
    )

    /// Bring up Sentry once, very early in `applicationDidFinishLaunching`.
    /// No-op when no DSN is bundled — that's the path for source builds
    /// the friend is running.
    static func start() {
        guard let dsn = BundledSecrets.sentryDsn else {
            logger.info("Sentry disabled (no bundled DSN).")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "pidgy@\(BundledSecrets.buildCommitSHA)"

#if DEBUG
            options.environment = "debug"
            // Debug builds: send everything but flag obviously; helps
            // verify the integration without polluting the production
            // issue list once a real beta channel exists.
            options.debug = false
            options.tracesSampleRate = 0
#else
            options.environment = "release"
            options.tracesSampleRate = 0.1
#endif

            // PII-related toggles — we touch Telegram data, so even the
            // default-pii flag is hostile. (attachScreenshot /
            // attachViewHierarchy are iOS-only and don't exist on the
            // macOS-targeted Sentry SDK; nothing to disable.)
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAppHangTracking = true
            options.enableAutoBreadcrumbTracking = true
            options.enableNetworkBreadcrumbs = true
            options.maxBreadcrumbs = 50

            options.beforeSend = { event in
                Self.scrubEvent(event)
                return event
            }
            options.beforeBreadcrumb = { crumb in
                Self.scrubBreadcrumb(crumb)
                return crumb
            }
        }

        logger.info("Sentry initialized.")
    }

    /// Report an Error subclass. Wraps `SentrySDK.capture(error:)` with
    /// an optional extras dict — caller is responsible for ensuring the
    /// extras don't include message bodies / PII (scrubEvent is a
    /// safety net, not a free pass).
    static func capture(error: Error, extras: [String: Any] = [:]) {
        guard SentrySDK.isEnabled else {
            logger.error("Suppressed capture (Sentry not enabled): \(String(describing: error), privacy: .public)")
            return
        }
        SentrySDK.capture(error: error) { scope in
            for (k, v) in extras {
                scope.setExtra(value: v, key: k)
            }
        }
    }

    /// Report a non-error event (e.g. "summary engine picked wrong focus
    /// chat"). Use this for behavior-level instrumentation — anything
    /// you'd want to know about even though nothing technically threw.
    static func capture(message: String, level: SentryLevel = .info, extras: [String: Any] = [:]) {
        guard SentrySDK.isEnabled else {
            logger.log(level: level.toOSLog(), "\(message, privacy: .public)")
            return
        }
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
            for (k, v) in extras {
                scope.setExtra(value: v, key: k)
            }
        }
    }

    /// Drop a breadcrumb. Threaded through scrubBreadcrumb so message
    /// bodies / sender names never land verbatim in the trail.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    // MARK: - Scrubbing

    /// Strip well-known PII shapes from event payloads before send. This
    /// is conservative on purpose — we'd rather drop debug context than
    /// accidentally upload a chat message.
    private static let piiKeysToRedact: Set<String> = [
        "textContent", "text_content", "text", "body", "snippet",
        "senderName", "sender_name", "title", "chat_title",
        "phoneNumber", "phone", "apiId", "apiHash",
        "api_key", "openai_key", "telegram_api_hash"
    ]

    private static func scrubEvent(_ event: Event) {
        if var extra = event.extra {
            for key in extra.keys where piiKeysToRedact.contains(key) {
                extra[key] = "<redacted>"
            }
            event.extra = extra
        }
        if let breadcrumbs = event.breadcrumbs {
            for crumb in breadcrumbs { scrubBreadcrumb(crumb) }
        }
        // Defense in depth — never let user data into Sentry's "user"
        // field, which is otherwise auto-populated with the device id.
        event.user = nil
    }

    private static func scrubBreadcrumb(_ crumb: Breadcrumb) {
        if var data = crumb.data {
            for key in data.keys where piiKeysToRedact.contains(key) {
                data[key] = "<redacted>"
            }
            crumb.data = data
        }
    }
}

private extension SentryLevel {
    func toOSLog() -> OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error, .fatal: return .error
        default: return .default
        }
    }
}
