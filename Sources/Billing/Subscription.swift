import Foundation

/// The two paid tiers (monthly). BYOK is the privacy-max tier — the
/// user supplies their own AI key, which goes direct to the provider
/// and never transits Pidgy infra. Bundled routes through the
/// non-logging AI proxy with a per-user gate token.
enum PidgyPlan: String, Codable, CaseIterable, Identifiable, Sendable {
    case byok
    case bundled

    var id: String { rawValue }

    var monthlyPriceUSD: Int {
        switch self {
        case .byok: return 10
        case .bundled: return 20
        }
    }

    var title: String {
        switch self {
        case .byok: return "Bring your own key"
        case .bundled: return "Pidgy AI"
        }
    }

    var tagline: String {
        switch self {
        case .byok: return "Most private — your AI key, your bill, nothing through us"
        case .bundled: return "Zero setup — we run the AI for you"
        }
    }
}

/// What the app is currently entitled to, derived from the local trial
/// clock and (once wired) a merchant-of-record-verified subscription.
enum EntitlementStatus: Equatable, Sendable {
    /// Never chosen a plan — onboarding shows plan selection.
    case none
    /// Inside the free trial window.
    case trial(daysLeft: Int, plan: PidgyPlan)
    /// Paid subscription verified and current.
    case active(PidgyPlan)
    /// Trial ended with no active subscription — paywall.
    case expired(PidgyPlan)

    /// AI features are usable while trialing or active.
    var unlocksAI: Bool {
        switch self {
        case .trial, .active: return true
        case .none, .expired: return false
        }
    }
}

/// Locally-persisted subscription facts. The trial clock is local; the
/// paid side (`activeUntil`) is only ever set from a PaymentService
/// verification against the MoR backend — never trusted from the client
/// alone for charging, only for unlocking already-paid access.
struct Subscription: Codable, Equatable, Sendable {
    var selectedPlan: PidgyPlan?
    var trialStartedAt: Date?
    var activeUntil: Date?

    static let trialDays = 14

    /// Pure status derivation — no I/O, so it's unit-testable. Active
    /// subscription wins; else the trial window; else expired/none.
    func status(now: Date = Date(), trialDays: Int = Subscription.trialDays) -> EntitlementStatus {
        guard let plan = selectedPlan else { return .none }

        if let activeUntil, activeUntil > now {
            return .active(plan)
        }

        if let trialStartedAt {
            let trialEnd = trialStartedAt.addingTimeInterval(Double(trialDays) * 86_400)
            if trialEnd > now {
                let daysLeft = max(1, Int((trialEnd.timeIntervalSince(now) / 86_400).rounded(.up)))
                return .trial(daysLeft: daysLeft, plan: plan)
            }
        }

        // A plan was chosen but neither an active sub nor a live trial
        // covers it — gate AI behind the paywall.
        return .expired(plan)
    }
}

/// Hands off to the payment provider (Dodo Payments, merchant-of-record)
/// and reports back whether a subscription is verified. Hosted-checkout
/// model: open `checkoutURL` in the browser, the MoR webhook provisions
/// the entitlement server-side, and `refreshEntitlement` reads it back.
protocol PaymentService: Sendable {
    /// Hosted checkout URL for a plan, or nil when payments aren't wired
    /// yet (the app then stays in trial/BYOK-only mode).
    func checkoutURL(for plan: PidgyPlan) -> URL?
    /// Verify the current subscription with the backend. Returns the
    /// paid-through date, or nil if there's no active subscription.
    func refreshEntitlement() async -> Date?
    /// Activate a license key for this device; returns the provider's
    /// instance id (persisted so the device can be deactivated later).
    func activate(licenseKey: String, deviceName: String) async throws -> String
    /// Release a device's activation slot.
    func deactivate(licenseKey: String, instanceID: String) async
}

/// Placeholder until Dodo + the entitlement backend are live (issue
/// #41). Charges nothing and verifies nothing — the app runs on the
/// local trial clock and the BYOK path, which need no server.
struct UnconfiguredPaymentService: PaymentService {
    struct NotConfigured: Error {}
    func checkoutURL(for plan: PidgyPlan) -> URL? { nil }
    func refreshEntitlement() async -> Date? { nil }
    func activate(licenseKey: String, deviceName: String) async throws -> String { throw NotConfigured() }
    func deactivate(licenseKey: String, instanceID: String) async {}
}
