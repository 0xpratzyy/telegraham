import Foundation

/// Token-bucket rate limiter for TDLib API calls.
/// Conservative defaults to ensure TGSearch is invisible to Telegram's rate limiting.
actor RateLimiter {
    private let maxTokens: Double
    private let refillRate: Double // tokens per second
    private var tokens: Double
    private var lastRefill: ContinuousClock.Instant

    /// - Parameters:
    ///   - maxTokens: Maximum burst capacity
    ///   - refillRate: Tokens added per second
    init(maxTokens: Double = AppConstants.RateLimit.maxTokens, refillRate: Double = AppConstants.RateLimit.refillRate) {
        self.maxTokens = maxTokens
        self.refillRate = refillRate
        self.tokens = maxTokens
        self.lastRefill = .now
    }

    /// Acquires a token, waiting if necessary.
    func acquire() async {
        refillTokens()

        if tokens >= 1 {
            tokens -= 1
            return
        }

        // Wait until a token is available
        let waitTime = (1.0 - tokens) / refillRate
        try? await Task.sleep(for: .milliseconds(Int(waitTime * 1000)))
        refillTokens()
        tokens = max(0, tokens - 1)
    }

    private func refillTokens() {
        let now = ContinuousClock.Instant.now
        let elapsed = now - lastRefill
        let secondsElapsed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(maxTokens, tokens + secondsElapsed * refillRate)
        lastRefill = now
    }
}
