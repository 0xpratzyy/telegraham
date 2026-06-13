import XCTest
@testable import Pidgy

final class SubscriptionTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    func testNoPlanIsNone() {
        XCTAssertEqual(Subscription().status(now: t0), .none)
    }

    func testTrialWindowAndDaysLeft() {
        var sub = Subscription()
        sub.selectedPlan = .byok
        sub.trialStartedAt = t0

        // Day 0: full 14 days.
        if case let .trial(daysLeft, plan) = sub.status(now: t0, trialDays: 14) {
            XCTAssertEqual(daysLeft, 14)
            XCTAssertEqual(plan, .byok)
        } else { XCTFail("expected trial") }

        // Mid-trial rounds up remaining days.
        if case let .trial(daysLeft, _) = sub.status(now: t0.addingTimeInterval(10 * day), trialDays: 14) {
            XCTAssertEqual(daysLeft, 4)
        } else { XCTFail("expected trial") }
    }

    func testTrialExpiresToPaywall() {
        var sub = Subscription()
        sub.selectedPlan = .bundled
        sub.trialStartedAt = t0
        XCTAssertEqual(sub.status(now: t0.addingTimeInterval(15 * day), trialDays: 14), .expired(.bundled))
        // Expired does NOT unlock AI.
        XCTAssertFalse(sub.status(now: t0.addingTimeInterval(15 * day), trialDays: 14).unlocksAI)
    }

    func testActiveSubscriptionWinsOverExpiredTrial() {
        var sub = Subscription()
        sub.selectedPlan = .bundled
        sub.trialStartedAt = t0                                   // trial long over
        sub.activeUntil = t0.addingTimeInterval(40 * day)         // but paid through day 40
        let s = sub.status(now: t0.addingTimeInterval(20 * day), trialDays: 14)
        XCTAssertEqual(s, .active(.bundled))
        XCTAssertTrue(s.unlocksAI)
    }

    func testLapsedSubscriptionFallsToExpired() {
        var sub = Subscription()
        sub.selectedPlan = .byok
        sub.trialStartedAt = t0
        sub.activeUntil = t0.addingTimeInterval(30 * day)         // paid, then lapsed
        XCTAssertEqual(sub.status(now: t0.addingTimeInterval(31 * day), trialDays: 14), .expired(.byok))
    }

    @MainActor
    func testStoreStartTrialDoesNotResetClockOnReselect() {
        let suiteName = "sub-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var clock = t0
        let store = EntitlementStore(defaults: defaults, now: { clock })
        store.startTrial(plan: .byok)
        // Switching plan 5 days in must NOT grant a fresh 14 days.
        clock = t0.addingTimeInterval(5 * day)
        store.startTrial(plan: .bundled)
        if case let .trial(daysLeft, plan) = store.status {
            XCTAssertEqual(plan, .bundled, "plan switch is honored")
            // ~9 days left (14 - 5), computed against the ORIGINAL start.
            XCTAssertLessThanOrEqual(daysLeft, 9)
        } else {
            XCTFail("expected trial, got \(store.status)")
        }
    }

    @MainActor
    func testStorePersistsAcrossInstances() {
        let suiteName = "sub-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        EntitlementStore(defaults: defaults, now: { self.t0 }).startTrial(plan: .bundled)
        let reloaded = EntitlementStore(defaults: defaults, now: { self.t0.addingTimeInterval(self.day) })
        XCTAssertEqual(reloaded.selectedPlan, .bundled)
        if case .trial = reloaded.status {} else if case .expired = reloaded.status {} else {
            XCTFail("expected a started-trial status, got \(reloaded.status)")
        }
    }
}
