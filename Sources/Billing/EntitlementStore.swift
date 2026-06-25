import Foundation
import Combine

/// Owns the persisted `Subscription` and publishes the derived
/// `EntitlementStatus` the UI gates on. The trial clock lives here; the
/// paid side is refreshed from the injected `PaymentService`.
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore(payments: DodoLicenseService())

    @Published private(set) var status: EntitlementStatus = .none

    private var subscription: Subscription {
        didSet { persist(); recompute() }
    }
    private let payments: PaymentService
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        payments: PaymentService = UnconfiguredPaymentService(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.payments = payments
        self.defaults = defaults
        self.now = now
        self.subscription = Self.load(from: defaults)
        recompute()
    }

    var selectedPlan: PidgyPlan? { subscription.selectedPlan }

    /// Begin the free trial on the chosen plan. No-op if a trial for
    /// some plan already started (switching plans mid-trial keeps the
    /// original clock — you don't get a fresh 14 days by toggling).
    func startTrial(plan: PidgyPlan) {
        var updated = subscription
        updated.selectedPlan = plan
        if updated.trialStartedAt == nil {
            updated.trialStartedAt = now()
        }
        subscription = updated
    }

    /// Record a verified paid subscription (called after a successful
    /// PaymentService refresh / webhook confirmation).
    func markActive(plan: PidgyPlan, until: Date) {
        var updated = subscription
        updated.selectedPlan = plan
        updated.activeUntil = until
        subscription = updated
    }

    /// Pull the latest paid-through date from the payment backend and
    /// fold it in. Safe to call on launch and after returning from
    /// checkout.
    func refreshFromBackend() async {
        switch await payments.refreshEntitlement() {
        case .active(let until):
            if let plan = subscription.selectedPlan {
                markActive(plan: plan, until: until)
            }
        case .lapsed:
            // Backend says the subscription ended — drop the paid entitlement so
            // status falls back to trial/expired. Network failures return
            // .unknown (below), NOT .lapsed, so this only fires on a real
            // cancellation / refund, never on an offline launch.
            if subscription.activeUntil != nil {
                var updated = subscription
                updated.activeUntil = nil
                subscription = updated
            }
        case .unknown:
            break  // offline / transient — keep the cached entitlement (grace window)
        }
    }

    func checkoutURL(for plan: PidgyPlan) -> URL? {
        payments.checkoutURL(for: plan)
    }

    /// Dodo customer-portal link for managing the live subscription —
    /// upgrade/downgrade/cancel/update card. This is the ONLY way to switch
    /// plans; the app never toggles the plan locally. nil until configured.
    var manageSubscriptionURL: URL? { BundledSecrets.dodoPortalURL }

    /// True when a license key is stored for this device.
    var hasLicenseKey: Bool {
        (try? KeychainManager.retrieve(for: .dodoLicenseKey)).flatMap { $0 }?.isEmpty == false
    }

    /// Activate a license key on this device, persist it, and refresh
    /// entitlement. Throws on activation failure (bad key / device limit).
    func activateLicense(_ licenseKey: String, deviceName: String) async throws {
        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await payments.activate(licenseKey: trimmed, deviceName: deviceName)
        do {
            try KeychainManager.save(trimmed, for: .dodoLicenseKey)
            try KeychainManager.save(result.instanceID, for: .dodoLicenseInstanceID)
        } catch {
            // The slot is now consumed on Dodo but we couldn't persist the key —
            // release it and surface the error so the user can retry, rather than
            // silently locking out a device that can never deactivate.
            await payments.deactivate(licenseKey: trimmed, instanceID: result.instanceID)
            throw error
        }
        // The activate response carries the product → set the tier so the
        // entitlement reflects what they actually bought, even if no plan was
        // pre-selected (e.g. after a reset that cleared selectedPlan).
        if let productID = result.productID,
           let plan = BundledSecrets.planForDodoProduct(id: productID) {
            var updated = subscription
            updated.selectedPlan = plan
            subscription = updated
        }
        await refreshFromBackend()
    }

    /// Release this device's activation slot and forget the key.
    func removeLicense() async {
        if let key = (try? KeychainManager.retrieve(for: .dodoLicenseKey)).flatMap({ $0 }),
           let instance = (try? KeychainManager.retrieve(for: .dodoLicenseInstanceID)).flatMap({ $0 }) {
            await payments.deactivate(licenseKey: key, instanceID: instance)
        }
        try? KeychainManager.delete(for: .dodoLicenseKey)
        try? KeychainManager.delete(for: .dodoLicenseInstanceID)
        var updated = subscription
        updated.activeUntil = nil
        subscription = updated
    }

    /// Reset-all-data hook: wipe billing state with everything else.
    func reset() {
        subscription = Subscription()
    }

    private func recompute() {
        status = subscription.status(now: now())
    }

    // MARK: - Persistence

    private static let key = AppConstants.Preferences.subscriptionStateKey

    private static func load(from defaults: UserDefaults) -> Subscription {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Subscription.self, from: data) else {
            return Subscription()
        }
        return decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(subscription) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
