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
        var lastError: Error?
        var delay = initialDelay

        for attempt in 1...maxAttempts {
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

                if attempt < maxAttempts {
                    try? await Task.sleep(for: delay)
                    delay *= 2
                }
            }
        }
        throw lastError!
    }
}
