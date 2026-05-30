import Foundation

/// Provides exponential backoff retry logic for async throwing operations.
enum RetryHelper {
    /// Retries an async throwing closure with exponential backoff.
    /// - Parameters:
    ///   - maxAttempts: Maximum number of attempts (default: 3)
    ///   - initialDelay: Delay before the first retry (default: 500ms)
    ///   - operation: The async throwing closure to execute
    /// - Returns: The result of the operation
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: Duration = .milliseconds(500),
        operation: () async throws -> T
    ) async throws -> T {
        // Guard a misconfigured 0/negative count: `1...maxAttempts` would trap,
        // and the loop would leave `lastError` nil for the throw below.
        let attempts = max(1, maxAttempts)
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error

                // Don't retry non-transient errors
                if let aiError = error as? AIError {
                    switch aiError {
                    case .noAPIKey, .providerNotConfigured, .parsingError:
                        throw error
                    case .httpError(let code, _) where code == 401 || code == 403:
                        throw error // Auth errors are not retryable
                    default:
                        break // Retryable (network errors, 429, 500, 502, 503)
                    }
                }

                if attempt < attempts {
                    // Exponential backoff + jitter so parallel callers don't
                    // resynchronize into a burst against the provider. Capped so
                    // a deep retry chain can't sleep absurdly long.
                    let jitter = Duration.milliseconds(Int.random(in: 0...250))
                    try? await Task.sleep(for: delay + jitter)
                    delay = min(delay * 2, .seconds(20))
                }
            }
        }
        // Unreachable in practice (attempts >= 1 always sets lastError on the
        // failing path); the fallback just avoids a force-unwrap.
        throw lastError ?? CancellationError()
    }
}
