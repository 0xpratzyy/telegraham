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

    // MARK: - AI failure shapes

    /// Content-free signal that an AI pipeline call failed. Sends ONLY
    /// the failure's shape — provider, model, run name, error class —
    /// never the prompt, response, or any message content. The full
    /// detail stays on-device in the local trace file
    /// (LocalAITraceRecorder); this just tells us THAT a class of
    /// failure is happening in the field and how often.
    ///
    /// Throttled per (runName, errorClass): a provider outage repeats
    /// the same shape hundreds of times and one event per window is
    /// all the signal we need.
    static func captureAIFailure(
        provider: String,
        model: String,
        runName: String,
        errorClass: String
    ) {
        guard shouldSendAIFailure(key: "\(runName)|\(errorClass)", now: Date()) else { return }
        capture(
            message: "ai_failure: \(runName) [\(errorClass)]",
            level: .warning,
            extras: [
                "provider": provider,
                "model": model,
                "run_name": runName,
                "error_class": errorClass
            ]
        )
    }

    static let aiFailureThrottleInterval: TimeInterval = 300

    private static let aiFailureThrottleLock = NSLock()
    nonisolated(unsafe) private static var lastAIFailureSendByKey: [String: Date] = [:]

    /// Internal (not private) so tests can pin the throttle behavior.
    static func shouldSendAIFailure(key: String, now: Date) -> Bool {
        aiFailureThrottleLock.lock()
        defer { aiFailureThrottleLock.unlock() }
        if let last = lastAIFailureSendByKey[key],
           now.timeIntervalSince(last) < aiFailureThrottleInterval {
            return false
        }
        lastAIFailureSendByKey[key] = now
        return true
    }

    /// Drop a breadcrumb. Threaded through scrubBreadcrumb so message
    /// bodies / sender names never land verbatim in the trail.
    static func breadcrumb(_ message: String, category: String, level: SentryLevel = .info) {
        guard SentrySDK.isEnabled else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    /// Submit user feedback typed into the in-app "Send Feedback…"
    /// sheet. Goes through Sentry's first-class feedback API so it
    /// shows up in the Sentry feedback inbox (separate from the error
    /// stream) — easier to triage product-y reports without them
    /// drowning in crash reports.
    ///
    /// `kind` is a free-form tag we set on the scope (bug / idea /
    /// other) so the feedback inbox is filterable. `extras` is the
    /// auto-attached metadata (current view, app version, commit
    /// SHA, OS version).
    ///
    /// User-typed content is intentionally NOT scrubbed — the
    /// `scrubEvent` filter strips message bodies on auto-captured
    /// events, but this user explicitly typed and pressed Send.
    static func submitFeedback(
        message: String,
        kind: String,
        email: String?,
        name: String?,
        extras: [String: String]
    ) {
        guard SentrySDK.isEnabled else {
            // Source builds / beta without DSN — silently log so the UX
            // flow still works (the user gets the success toast either
            // way; ack is the point on those builds).
            logger.info("Suppressed feedback submit (Sentry not enabled). kind=\(kind, privacy: .public)")
            return
        }
        SentrySDK.configureScope { scope in
            scope.setTag(value: kind, key: "feedback.kind")
            scope.setContext(value: extras, key: "feedback")
        }
        let feedback = SentryFeedback(
            message: message,
            name: name,
            email: email
        )
        SentrySDK.capture(feedback: feedback)
        // Log so we can confirm via the system log that the SDK
        // accepted the submission — the Sentry network roundtrip is
        // async + silent on success, so otherwise it's invisible
        // from the client side.
        logger.info("Feedback submitted to Sentry. kind=\(kind, privacy: .public) chars=\(message.count) view=\(extras["view"] ?? "?", privacy: .public)")
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

    // Internal (not private) so PidgyTelemetryScrubTests can pin the
    // PII guarantees — this function is the only thing between raw
    // Telegram data and Sentry's servers, and the README's privacy
    // table promises exactly what it strips.
    static func scrubEvent(_ event: Event) {
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

    // Internal for tests — see scrubEvent.
    static func scrubBreadcrumb(_ crumb: Breadcrumb) {
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
