import Foundation

/// Token-bucket rate limiter for TDLib API calls.
/// Conservative defaults to ensure Pidgy is invisible to Telegram's rate limiting.
actor RateLimiter {
    enum Priority: String {
        case userInitiated = "user"
        case background = "background"
    }

    private struct Bucket {
        let capacity: Double
        let refillRate: Double
        var tokens: Double
        var lastRefill: ContinuousClock.Instant

        init(capacity: Double, refillRate: Double) {
            self.capacity = capacity
            self.refillRate = refillRate
            self.tokens = capacity
            self.lastRefill = .now
        }
    }

    private let defaultCapacity: Double
    private let defaultRefillRate: Double
    private var globalBucket: Bucket
    private var methodBuckets: [String: Bucket] = [:]
    private var queuedUserInitiated = 0
    private var queuedBackground = 0
    private var globalCooldownUntil: Date?
    private var methodCooldownUntil: [String: Date] = [:]
    private var isHistoryCallInFlight = false

    /// - Parameters:
    ///   - maxTokens: Maximum burst capacity
    ///   - refillRate: Tokens added per second
    init(maxTokens: Double = AppConstants.RateLimit.maxTokens, refillRate: Double = AppConstants.RateLimit.refillRate) {
        self.defaultCapacity = maxTokens
        self.defaultRefillRate = refillRate
        self.globalBucket = Bucket(capacity: maxTokens, refillRate: refillRate)
    }

    /// Acquires a token, waiting if necessary.
    func acquire() async {
        await acquire(priority: .userInitiated, method: AppConstants.RateLimit.defaultMethod)
    }

    func acquire(
        priority: Priority,
        method: String,
        floodWaitSeconds: Int? = nil
    ) async {
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppConstants.RateLimit.defaultMethod
            : method

        if let floodWaitSeconds, floodWaitSeconds > 0 {
            recordFloodWait(method: normalizedMethod, seconds: floodWaitSeconds)
        }

        incrementQueue(for: priority)
        defer { decrementQueue(for: priority) }

        while true {
            if let waitSeconds = cooldownWaitSeconds(for: normalizedMethod), waitSeconds > 0 {
                logThrottle(priority: priority, method: normalizedMethod, waitSeconds: waitSeconds)
                try? await Task.sleep(for: .milliseconds(Int(waitSeconds * 1000)))
                continue
            }

            if priority == .background && queuedUserInitiated > 0 {
                logThrottle(priority: priority, method: normalizedMethod, waitSeconds: nil)
                try? await Task.sleep(
                    for: .milliseconds(Int(AppConstants.RateLimit.backgroundPriorityPollIntervalMilliseconds))
                )
                continue
            }

            refill(&globalBucket)

            var bucket = bucket(for: normalizedMethod)
            refill(&bucket)

            if globalBucket.tokens >= 1, bucket.tokens >= 1 {
                globalBucket.tokens -= 1
                bucket.tokens -= 1
                methodBuckets[normalizedMethod] = bucket
                return
            }

            let methodWaitSeconds = bucket.tokens >= 1 ? 0 : max((1.0 - bucket.tokens) / bucket.refillRate, 0.05)
            let globalWaitSeconds = globalBucket.tokens >= 1 ? 0 : max((1.0 - globalBucket.tokens) / globalBucket.refillRate, 0.05)
            let waitSeconds = max(methodWaitSeconds, globalWaitSeconds, 0.05)
            methodBuckets[normalizedMethod] = bucket
            logThrottle(priority: priority, method: normalizedMethod, waitSeconds: waitSeconds)

            let pollMilliseconds = priority == .userInitiated
                ? AppConstants.RateLimit.userPriorityPollIntervalMilliseconds
                : AppConstants.RateLimit.backgroundPriorityPollIntervalMilliseconds
            let sleepMilliseconds = max(Int(waitSeconds * 1000), Int(pollMilliseconds))
            try? await Task.sleep(for: .milliseconds(sleepMilliseconds))
        }
    }

    func acquireCall(
        priority: Priority,
        method: String,
        floodWaitSeconds: Int? = nil
    ) async {
        let normalizedMethod = normalized(method)
        await acquire(priority: priority, method: normalizedMethod, floodWaitSeconds: floodWaitSeconds)
        if shouldSerializeInFlight(method: normalizedMethod) {
            await acquireSerializedHistorySlot(priority: priority, method: normalizedMethod)
        }
    }

    func releaseCall(method: String) {
        let normalizedMethod = normalized(method)
        guard shouldSerializeInFlight(method: normalizedMethod) else { return }
        isHistoryCallInFlight = false
    }

    func recordFloodWait(method: String, seconds: Int) {
        let normalizedMethod = normalized(method)
        let backoffSeconds = Double(max(seconds, 0)) * AppConstants.RateLimit.floodWaitBackoffMultiplier
        guard backoffSeconds > 0 else { return }
        let cooldownUntil = Date().addingTimeInterval(backoffSeconds)
        globalCooldownUntil = max(globalCooldownUntil ?? .distantPast, cooldownUntil)
        methodCooldownUntil[normalizedMethod] = max(methodCooldownUntil[normalizedMethod] ?? .distantPast, cooldownUntil)
        print("[RateLimiter] FLOOD_WAIT backoff \(String(format: "%.1f", backoffSeconds))s for \(normalizedMethod)")
    }

    private func acquireSerializedHistorySlot(priority: Priority, method: String) async {
        while isHistoryCallInFlight {
            logThrottle(priority: priority, method: method, waitSeconds: nil)
            try? await Task.sleep(
                for: .milliseconds(Int(AppConstants.RateLimit.backgroundPriorityPollIntervalMilliseconds))
            )
        }
        isHistoryCallInFlight = true
    }

    private func shouldSerializeInFlight(method: String) -> Bool {
        method == "getChatHistory"
    }

    private func normalized(_ method: String) -> String {
        method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppConstants.RateLimit.defaultMethod
            : method
    }

    private func cooldownWaitSeconds(for method: String) -> Double? {
        let now = Date()
        let globalWait = globalCooldownUntil.map { $0.timeIntervalSince(now) } ?? 0
        let methodWait = methodCooldownUntil[method].map { $0.timeIntervalSince(now) } ?? 0
        let waitSeconds = max(globalWait, methodWait)
        if waitSeconds <= 0 {
            if let globalCooldownUntil, globalCooldownUntil <= now {
                self.globalCooldownUntil = nil
            }
            if let methodCooldown = methodCooldownUntil[method], methodCooldown <= now {
                methodCooldownUntil.removeValue(forKey: method)
            }
            return nil
        }
        return waitSeconds
    }

    private func bucket(for method: String) -> Bucket {
        if let existing = methodBuckets[method] {
            return existing
        }

        let budget = budget(for: method)
        let bucket = Bucket(capacity: budget, refillRate: budget)
        methodBuckets[method] = bucket
        return bucket
    }

    private func budget(for method: String) -> Double {
        switch method {
        case "getUser", "getChat", "getSupergroup", "getMe":
            return 10
        case "searchMessages":
            return 3
        case "getChatHistory":
            return 1
        case "searchChatMessages", "loadChats":
            return 5
        default:
            return min(defaultCapacity, defaultRefillRate)
        }
    }

    private func refill(_ bucket: inout Bucket) {
        let now = ContinuousClock.Instant.now
        let elapsed = now - bucket.lastRefill
        let secondsElapsed = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        bucket.tokens = min(bucket.capacity, bucket.tokens + secondsElapsed * bucket.refillRate)
        bucket.lastRefill = now
    }

    private func incrementQueue(for priority: Priority) {
        switch priority {
        case .userInitiated:
            queuedUserInitiated += 1
        case .background:
            queuedBackground += 1
        }
    }

    private func decrementQueue(for priority: Priority) {
        switch priority {
        case .userInitiated:
            queuedUserInitiated = max(0, queuedUserInitiated - 1)
        case .background:
            queuedBackground = max(0, queuedBackground - 1)
        }
    }

    private func logThrottle(priority: Priority, method: String, waitSeconds: Double?) {
        let queueDepth = queuedUserInitiated + queuedBackground
        if let waitSeconds {
            print(
                "[RateLimiter] throttled method=\(method) priority=\(priority.rawValue) " +
                "queueDepth=\(queueDepth) globalTokens=\(String(format: "%.2f", globalBucket.tokens)) " +
                "wait=\(String(format: "%.2f", waitSeconds))s"
            )
        } else {
            print(
                "[RateLimiter] yielding background work method=\(method) priority=\(priority.rawValue) " +
                "queueDepth=\(queueDepth)"
            )
        }
    }
}
