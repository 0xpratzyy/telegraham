import XCTest
import Sentry
@testable import Pidgy

/// Pins the PII guarantees of `PidgyTelemetry.scrubEvent` /
/// `scrubBreadcrumb` — the only code standing between raw Telegram
/// data and Sentry's servers. The README's "What hits the network"
/// table promises that event bodies are stripped of message text,
/// sender names, phone numbers, and API tokens before send; these
/// tests make that promise a compile-and-test-time invariant instead
/// of a code-review hope.
///
/// First file outside PidgyCoreTests.swift — the start of the
/// per-module test split (audit task M3.1).
final class PidgyTelemetryScrubTests: XCTestCase {

    /// Every key the scrubber promises to redact, with a
    /// representative dangerous value.
    private static let piiExtras: [String: Any] = [
        "textContent": "hey, my new number is +1 555 123 4567",
        "text_content": "wire details: DE89 3704 0044 0532 0130 00",
        "text": "raw message body",
        "body": "another raw body",
        "snippet": "…snippet of a private chat…",
        "senderName": "Alice Example",
        "sender_name": "alice_ex",
        "title": "Family group",
        "chat_title": "Founders WhatsApp refugees",
        "phoneNumber": "+15551234567",
        "phone": "+44 7700 900123",
        "apiId": "1234567",
        "apiHash": "0123456789abcdef0123456789abcdef",
        "api_key": "sk-live-supersecret",
        "openai_key": "sk-proj-anothersecret",
        "telegram_api_hash": "fedcba9876543210fedcba9876543210",
    ]

    // MARK: - scrubEvent

    func testScrubEventRedactsEveryPromisedPIIKey() {
        let event = Event()
        event.extra = Self.piiExtras

        PidgyTelemetry.scrubEvent(event)

        for key in Self.piiExtras.keys {
            XCTAssertEqual(
                event.extra?[key] as? String,
                "<redacted>",
                "PII key '\(key)' must be redacted before the event leaves the process"
            )
        }
    }

    func testScrubEventPreservesSafeDiagnosticKeys() {
        let event = Event()
        event.extra = [
            "chatId": Int64(-1_001_234_567_890),
            "messageCount": 42,
            "engine": "reply_queue",
            "durationMs": 137.5,
        ]

        PidgyTelemetry.scrubEvent(event)

        XCTAssertEqual(event.extra?["chatId"] as? Int64, -1_001_234_567_890)
        XCTAssertEqual(event.extra?["messageCount"] as? Int, 42)
        XCTAssertEqual(event.extra?["engine"] as? String, "reply_queue")
        XCTAssertEqual(event.extra?["durationMs"] as? Double, 137.5)
    }

    func testScrubEventAlwaysNullsUserField() {
        let event = Event()
        let user = User(userId: "device-1234")
        user.email = "pii@example.com"
        event.user = user

        PidgyTelemetry.scrubEvent(event)

        XCTAssertNil(event.user, "event.user must never reach Sentry — defense in depth against device-id correlation")
    }

    func testScrubEventHandlesNilExtraAndNilBreadcrumbs() {
        let event = Event()
        event.extra = nil
        event.breadcrumbs = nil

        // Must not crash and must still null the user.
        PidgyTelemetry.scrubEvent(event)
        XCTAssertNil(event.user)
        XCTAssertNil(event.extra)
    }

    func testScrubEventScrubsAttachedBreadcrumbs() {
        let event = Event()
        let crumb = Breadcrumb(level: .info, category: "sync")
        crumb.data = [
            "text": "private message body",
            "senderName": "Bob",
            "chatId": Int64(99),
        ]
        event.breadcrumbs = [crumb]

        PidgyTelemetry.scrubEvent(event)

        let scrubbed = event.breadcrumbs?.first?.data
        XCTAssertEqual(scrubbed?["text"] as? String, "<redacted>")
        XCTAssertEqual(scrubbed?["senderName"] as? String, "<redacted>")
        XCTAssertEqual(scrubbed?["chatId"] as? Int64, 99, "non-PII breadcrumb data must survive")
    }

    // MARK: - scrubBreadcrumb

    func testScrubBreadcrumbRedactsPIIDataKeys() {
        let crumb = Breadcrumb(level: .info, category: "launcher")
        crumb.data = [
            "body": "do not ship this upstream",
            "phone": "+15550001111",
            "api_key": "sk-whoops",
            "query_family": "topic_search",
        ]

        PidgyTelemetry.scrubBreadcrumb(crumb)

        XCTAssertEqual(crumb.data?["body"] as? String, "<redacted>")
        XCTAssertEqual(crumb.data?["phone"] as? String, "<redacted>")
        XCTAssertEqual(crumb.data?["api_key"] as? String, "<redacted>")
        XCTAssertEqual(crumb.data?["query_family"] as? String, "topic_search")
    }

    func testScrubBreadcrumbHandlesNilData() {
        let crumb = Breadcrumb(level: .info, category: "empty")
        crumb.data = nil

        // Must not crash.
        PidgyTelemetry.scrubBreadcrumb(crumb)
        XCTAssertNil(crumb.data)
    }

    /// Canary: redaction must replace values with a non-empty marker,
    /// not delete the key — a deleted key looks identical to "was never
    /// set", which would make Sentry triage misleading about what
    /// context originally existed.
    func testRedactionUsesVisibleMarkerNotDeletion() {
        let event = Event()
        event.extra = ["text": "secret"]

        PidgyTelemetry.scrubEvent(event)

        XCTAssertNotNil(event.extra?["text"], "redacted keys should remain present")
        XCTAssertEqual(event.extra?["text"] as? String, "<redacted>")
    }
}
