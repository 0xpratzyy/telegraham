import XCTest
@testable import Pidgy

/// Guards that the cost meter bills cached/cache-read input at the discounted
/// rate (OpenAI 50%, Anthropic 10%) instead of full list price — the
/// "meter overstates spend" fix.
final class AIPricingCachedTests: XCTestCase {
    private func gpt5() -> AIModelPricing {
        AIUsagePricingCatalog.pricing(for: .openAI, model: "gpt-5")!
    }

    func testNoCacheMatchesListPrice() {
        // 1M input @ $1.25 + 1M output @ $10 = $11.25 (also exercises the
        // 2-arg form, confirming backward compatibility).
        XCTAssertEqual(
            gpt5().estimatedCostUSD(inputTokens: 1_000_000, outputTokens: 1_000_000),
            11.25, accuracy: 1e-9
        )
    }

    func testFullyCachedInputBilledAtHalf() {
        // all 1M input cached → 1M × 0.5 × $1.25 = $0.625
        XCTAssertEqual(
            gpt5().estimatedCostUSD(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0),
            0.625, accuracy: 1e-9
        )
    }

    func testPartialCacheIsCheaperThanList() {
        let p = gpt5()
        let full = p.estimatedCostUSD(inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0)
        // 200k uncached + 800k×0.5 = 600k effective × $1.25/M = $0.75
        let cached = p.estimatedCostUSD(inputTokens: 1_000_000, cachedInputTokens: 800_000, outputTokens: 0)
        XCTAssertEqual(full, 1.25, accuracy: 1e-9)
        XCTAssertEqual(cached, 0.75, accuracy: 1e-9)
        XCTAssertLessThan(cached, full)
    }

    func testClaudeCacheReadAtTenPercent() {
        let p = AIUsagePricingCatalog.pricing(for: .claude, model: "claude-sonnet-4")!
        // 1M total input, all cache-read → 1M × 0.1 × $3 = $0.30
        XCTAssertEqual(
            p.estimatedCostUSD(inputTokens: 1_000_000, cachedInputTokens: 1_000_000, outputTokens: 0),
            0.30, accuracy: 1e-9
        )
    }

    func testCachedClampedToInput() {
        // cached can never exceed input (no negative uncached).
        let p = gpt5()
        XCTAssertEqual(
            p.estimatedCostUSD(inputTokens: 100, cachedInputTokens: 999, outputTokens: 0),
            p.estimatedCostUSD(inputTokens: 100, cachedInputTokens: 100, outputTokens: 0),
            accuracy: 1e-12
        )
    }
}
