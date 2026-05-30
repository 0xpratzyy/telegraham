import Foundation

/// Process-wide pacer for Slack's tightly-limited read endpoints.
///
/// `conversations.history` and `conversations.replies` are ~1 request/minute
/// *each* on the non-Marketplace tier (post-May-2025 apps). Without proactive
/// pacing, concurrent callers — the background sync coordinator fans out four
/// `chatHistory` fetches at once, and an interactive evidence-panel open fires
/// a thread hydration on top — burst into simultaneous 429s, and the reactive
/// 429 handler then parks each caller for ~60s. That produces the "Slack keeps
/// freezing for a minute" behaviour.
///
/// This actor serializes + spaces those calls so the limit is respected
/// proactively. Each limited method gets its own bucket, so background history
/// sync never delays interactive reply hydration (a different method) and
/// vice-versa. Generous endpoints (`conversations.list`, `users.*`) are left to
/// the reactive 429 backoff in `SlackAPIClient`.
actor SlackRateLimiter {
    static let shared = SlackRateLimiter()

    /// Minimum spacing between calls to the same limited method (~1/min + margin).
    private static let interval: TimeInterval = 61
    private static let limitedMethods: Set<String> = [
        "conversations.history",
        "conversations.replies",
    ]

    /// Earliest time the next call to each limited method may run.
    private var nextSlot: [String: Date] = [:]

    /// Reserve and wait for a pacing slot if `method` is rate-limited; no-op
    /// otherwise. The reserve (read+write of `nextSlot`) is synchronous within
    /// the actor, so concurrent callers can't claim the same slot — they queue
    /// at `interval` apart and then sleep until their reserved time.
    func acquireIfLimited(_ method: String) async {
        guard Self.limitedMethods.contains(method) else { return }
        let now = Date()
        let slot = max(now, nextSlot[method] ?? .distantPast)
        nextSlot[method] = slot.addingTimeInterval(Self.interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            try? await Task.sleep(for: .seconds(wait))
        }
    }
}
