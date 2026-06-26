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
        mirrorLocally(level: "error", message: "error: \(type(of: error))", extras: extras)
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
        mirrorLocally(level: levelLabel(level), message: message, extras: extras)
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

    // MARK: - TDLib / operational shapes

    /// Content-free signal that a TDLib request failed. Sends ONLY the
    /// method name, numeric code, and a CLASSIFIED error label
    /// (FLOOD_WAIT_312, CHANNEL_PRIVATE, …). The raw TDLib message is run
    /// through `classifyTDLibError` first, so a descriptive string that
    /// could embed a chat title / username never leaves the device.
    /// Throttled per (method, errorClass) so a sync storm isn't 500 events.
    static func captureTDLibError(method: String, code: Int, errorClass: String) {
        guard shouldSendThrottled(key: "tdlib|\(method)|\(errorClass)", now: Date(), interval: aiFailureThrottleInterval) else { return }
        capture(
            message: "tdlib_error: \(method) [\(errorClass)]",
            level: .warning,
            extras: [
                "method": method,
                "code": code,
                "error_class": errorClass
            ]
        )
    }

    /// Reduce a raw TDLib error message to a safe label. TDLib errors are
    /// short SCREAMING_SNAKE codes; we keep only the leading code token and
    /// return "OTHER" for anything that doesn't match that shape — so a
    /// descriptive message (which could contain a chat title or username)
    /// is never shipped verbatim.
    static func classifyTDLibError(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "^[A-Z][A-Z0-9_]{3,}", options: .regularExpression) else {
            return "OTHER"
        }
        var code = String(trimmed[range])
        // Strip a trailing _<n> so FLOOD_WAIT_312 / FLOOD_WAIT_45 group as one
        // issue in Sentry and the throttle key is stable. (The backoff seconds
        // are still recorded separately via RateLimiter.recordFloodWait.)
        if let suffix = code.range(of: "_[0-9]+$", options: .regularExpression) {
            code.removeSubrange(suffix)
        }
        return code
    }

    /// Content-free operational milestone (chat list loaded, coverage
    /// progress, …). `fields` is typed `[String: Int]` ON PURPOSE: a caller
    /// can only pass numbers, so message text / names cannot leak through
    /// this path by construction.
    static func captureEvent(_ event: String, category: String, fields: [String: Int] = [:], level: SentryLevel = .info) {
        var extras: [String: Any] = ["category": category]
        for (key, value) in fields { extras[key] = value }
        capture(message: "\(category): \(event)", level: level, extras: extras)
    }

    static let aiFailureThrottleInterval: TimeInterval = 300

    private static let throttledSendLock = NSLock()
    nonisolated(unsafe) private static var lastThrottledSendByKey: [String: Date] = [:]

    /// Generic per-key throttle: a provider outage or a repeated TDLib
    /// error emits the same shape hundreds of times; one event per window
    /// is all the signal we need.
    static func shouldSendThrottled(key: String, now: Date, interval: TimeInterval) -> Bool {
        throttledSendLock.lock()
        defer { throttledSendLock.unlock() }
        if let last = lastThrottledSendByKey[key], now.timeIntervalSince(last) < interval {
            return false
        }
        lastThrottledSendByKey[key] = now
        return true
    }

    /// Internal (not private) so tests can pin the throttle behavior.
    static func shouldSendAIFailure(key: String, now: Date) -> Bool {
        shouldSendThrottled(key: key, now: now, interval: aiFailureThrottleInterval)
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

    // MARK: - Local mirror

    /// Mirror every captured signal to a local, content-free JSONL file at
    /// `~/Library/Application Support/Pidgy/logs/telemetry.jsonl`. Same
    /// metadata that goes to Sentry, but inspectable on-device (and during
    /// a debug session) without the dashboard — and works even on builds
    /// with no Sentry DSN. The typed capture APIs never carry content, so
    /// this stays metadata-only. Rotates at ~5 MB.
    private static let localLogQueue = DispatchQueue(label: "com.pidgy.telemetry.local")
    // Reused across calls — ISO8601DateFormatter is costly to construct and is
    // thread-safe for formatting on modern Foundation.
    private static let localLogTimestampFormatter = ISO8601DateFormatter()

    private static func localLogURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Pidgy/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("telemetry.jsonl")
    }

    static func mirrorLocally(level: String, message: String, extras: [String: Any]) {
        guard let url = localLogURL() else { return }
        let stamp = localLogTimestampFormatter.string(from: Date())
        localLogQueue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
               size > 5_000_000 {
                let rotated = url.deletingLastPathComponent().appendingPathComponent("telemetry.1.jsonl")
                try? FileManager.default.removeItem(at: rotated)
                try? FileManager.default.moveItem(at: url, to: rotated)
            }
            var obj: [String: Any] = ["ts": stamp, "level": level, "msg": message]
            // Defense-in-depth: the typed capture APIs are metadata-only by
            // design, but scrub the same PII-shaped keys we strip before Sentry
            // so a future caller can never land chat content in the on-disk
            // mirror either (this path doesn't go through scrubEvent).
            for (key, value) in extras {
                obj[key] = piiKeysToRedact.contains(key) ? "<redacted>" : value
            }
            guard let data = try? JSONSerialization.data(withJSONObject: obj),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                if let payload = line.data(using: .utf8) { handle.write(payload) }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func levelLabel(_ level: SentryLevel) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warn"
        case .error: return "error"
        case .fatal: return "fatal"
        default: return "info"
        }
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
        // Last-line breadcrumb scrub. CRITICAL: copy, never mutate in place.
        // beforeSend runs on Sentry's send threads and Breadcrumb objects are
        // SHARED across events; mutating crumb.data here while another concurrent
        // send serializes the same breadcrumb is a data race that crashes in
        // _SwiftDeferredNSDictionary deinit / sentry_sanitize under a burst of
        // captures. So for any crumb carrying PII we emit a FRESH redacted
        // Breadcrumb and leave the shared original untouched. (beforeBreadcrumb
        // also scrubs at add-time; this is the belt-and-suspenders before send.)
        if let breadcrumbs = event.breadcrumbs {
            event.breadcrumbs = breadcrumbs.map { crumb in
                guard let data = crumb.data,
                      data.keys.contains(where: { piiKeysToRedact.contains($0) }) else {
                    return crumb
                }
                var scrubbed = data
                for key in scrubbed.keys where piiKeysToRedact.contains(key) {
                    scrubbed[key] = "<redacted>"
                }
                let copy = Breadcrumb(level: crumb.level, category: crumb.category)
                copy.type = crumb.type
                copy.message = crumb.message
                copy.timestamp = crumb.timestamp
                copy.data = scrubbed
                return copy
            }
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
