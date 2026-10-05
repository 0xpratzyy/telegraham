//
//  AccountService.swift
//  Pidgy
//
//  Thin, app-shaped wrapper around Clerk. Pidgy is local-first: the account
//  exists ONLY so a person is the same person across machines — invites,
//  referrals, and the paid license attach to it. It never sees a message.
//
//  Fully optional: when no publishable key is bundled (source builds) every
//  entry point is a no-op and onboarding skips the sign-in step. The rest
//  of the app keys off `AccountService.isConfigured` + `profile`.
//

import AppKit
import AuthenticationServices
import ClerkKit
import Foundation
import OSLog

@MainActor
final class AccountService: ObservableObject {
    static let shared = AccountService()

    /// What the UI needs to render "signed in as …". Cached in defaults so
    /// Preferences shows the row before Clerk finishes loading on launch.
    struct Profile: Codable, Equatable {
        let id: String
        let email: String?
        let displayName: String?
        let avatarURL: URL?

        var label: String { displayName ?? email ?? "Signed in" }
    }

    enum Provider: String, CaseIterable, Identifiable {
        case google, apple
        var id: String { rawValue }
        var title: String {
            switch self {
            case .google: return "Continue with Google"
            case .apple: return "Continue with Apple"
            }
        }
        fileprivate var clerkProvider: OAuthProvider {
            switch self {
            case .google: return .google
            case .apple: return .apple
            }
        }
    }

    enum SignInError: LocalizedError, Equatable {
        case cancelled
        case notConfigured
        case incomplete
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .notConfigured: return "Accounts aren't configured in this build."
            case .incomplete: return "Sign-in needs another step Pidgy doesn't support yet. Try a different provider."
            case .failed(let message): return message
            }
        }
    }

    /// True when a publishable key is bundled. Static so onboarding can route
    /// before the shared instance is touched.
    nonisolated static var isConfigured: Bool { BundledSecrets.clerkPublishableKey?.isEmpty == false }

    @Published private(set) var profile: Profile?
    @Published private(set) var isBusy = false
    /// Clerk has fetched its environment + client — until then `profile` may
    /// be the cached copy from last launch.
    @Published private(set) var isLoaded = false

    private var didConfigure = false
    private var eventTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.pidgy.app", category: "account")

    var isSignedIn: Bool { profile != nil }

    private init() {
        if let data = UserDefaults.standard.data(forKey: AppConstants.Preferences.accountProfileCacheKey),
           let cached = try? JSONDecoder().decode(Profile.self, from: data) {
            profile = cached
        }
    }

    // MARK: - Lifecycle

    /// Call once at launch. Safe to call again; safe when unconfigured.
    func configureIfNeeded() {
        guard !didConfigure, let key = BundledSecrets.clerkPublishableKey, !key.isEmpty else { return }
        didConfigure = true
        Clerk.configure(publishableKey: key)

        eventTask = Task { [weak self] in
            for await event in Clerk.shared.auth.events {
                guard let self else { return }
                switch event {
                case .sessionChanged, .signedOut, .accountDeleted, .signInCompleted, .signUpCompleted:
                    self.refreshProfile()
                default:
                    break
                }
            }
        }

        // Clerk loads environment + client asynchronously after configure.
        // Poll briefly so `isLoaded` flips and a stale cached profile (user
        // revoked the session elsewhere) is corrected on launch.
        Task { [weak self] in
            for _ in 0..<50 {
                if Clerk.shared.isLoaded { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self else { return }
            self.isLoaded = Clerk.shared.isLoaded
            if self.isLoaded { self.refreshProfile() }
        }
    }

    // MARK: - Actions

    /// Runs the hosted OAuth flow in an ASWebAuthenticationSession sheet.
    /// Both providers go through the browser redirect (no Sign in with
    /// Apple entitlement needed — Pidgy ships outside the App Store).
    func signIn(with provider: Provider) async throws {
        guard didConfigure else { throw SignInError.notConfigured }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await Clerk.shared.auth.signInWithOAuth(
                provider: provider.clerkProvider,
                prefersEphemeralWebBrowserSession: false
            )
            switch result {
            case .signIn(let signIn):
                guard signIn.status == .complete else { throw SignInError.incomplete }
            case .signUp(let signUp):
                guard signUp.status == .complete else { throw SignInError.incomplete }
            }
            refreshProfile()
        } catch let error as SignInError {
            throw error
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw SignInError.cancelled
        } catch let error as ClerkAPIError {
            logger.error("Clerk sign-in failed: \(error.code, privacy: .public)")
            throw SignInError.failed(error.longMessage ?? error.message ?? "Sign-in failed. Please try again.")
        } catch {
            let ns = error as NSError
            if ns.domain == ASWebAuthenticationSessionErrorDomain,
               ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                throw SignInError.cancelled
            }
            logger.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            throw SignInError.failed("Couldn't finish signing in. Check your connection and try again.")
        }
    }

    func signOut() async {
        guard didConfigure else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Clerk.shared.auth.signOut()
        } catch {
            logger.error("Sign-out failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshProfile()
    }

    /// Short-lived session JWT for the proxy Worker (account linking).
    /// Nil when signed out or unconfigured.
    func sessionToken() async -> String? {
        guard didConfigure, Clerk.shared.session != nil else { return nil }
        return try? await Clerk.shared.auth.getToken()
    }

    // MARK: - Private

    private func refreshProfile() {
        guard didConfigure else { return }
        let user = Clerk.shared.user
        let next: Profile? = user.map { u in
            let name = [u.firstName, u.lastName].compactMap { $0 }.joined(separator: " ")
            return Profile(
                id: u.id,
                email: u.primaryEmailAddress?.emailAddress ?? u.emailAddresses.first?.emailAddress,
                displayName: name.isEmpty ? nil : name,
                avatarURL: u.hasImage ? URL(string: u.imageUrl) : nil
            )
        }
        guard next != profile else { return }
        profile = next
        let defaults = UserDefaults.standard
        if let next, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: AppConstants.Preferences.accountProfileCacheKey)
        } else {
            defaults.removeObject(forKey: AppConstants.Preferences.accountProfileCacheKey)
        }
    }
}
