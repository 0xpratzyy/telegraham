import Foundation

/// Central switch for whether AI features are unlocked. Combines the
/// entitlement status with a master kill-switch and a grandfather bypass.
///
/// `enforce` ships **false**: until the paywall cutover, AI is always allowed
/// so the live beta is unaffected. Flip it to `true` only once trials +
/// subscriptions + the Worker license gate (`ENFORCE_LICENSE`) are live.
enum BillingGate {
    /// Master switch. Keep false until the cutover.
    static let enforce = false

    private static let foundingKey = "pidgy.billing.foundingTester"

    /// Grandfathered installs keep full access for free even after the cutover.
    static var isFoundingTester: Bool {
        UserDefaults.standard.bool(forKey: foundingKey)
    }

    /// Call once at launch. Anyone who runs a build BEFORE the cutover (while
    /// `enforce` is false) is grandfathered for free — the flag persists, so
    /// when `enforce` later flips true they keep access while genuinely-new
    /// installs (which never ran a pre-cutover build) must subscribe. No
    /// session/DB probing needed: pre-cutover presence is the signal.
    static func grandfatherPreCutoverInstall() {
        guard !enforce,
              UserDefaults.standard.object(forKey: foundingKey) == nil else { return }
        UserDefaults.standard.set(true, forKey: foundingKey)
    }

    /// Whether AI features should be available for the given entitlement state.
    static func aiAllowed(_ status: EntitlementStatus) -> Bool {
        guard enforce else { return true }
        return status.unlocksAI || isFoundingTester
    }

    /// Whether the billing surface — the plan picker, subscribe / manage
    /// buttons, trial banners, and the onboarding plan step — should be shown.
    /// Kept hidden in release builds until the cutover so a pre-cutover beta
    /// never surfaces a half-live billing flow wired to test checkout. Always
    /// shown in DEBUG so the whole flow can be QA'd locally before flipping
    /// `enforce`. Independent of `aiAllowed`, which stays permissive in beta.
    static var showBillingUI: Bool {
        #if DEBUG
        return true
        #else
        return enforce
        #endif
    }
}
