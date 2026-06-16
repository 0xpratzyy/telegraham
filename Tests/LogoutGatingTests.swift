import XCTest
@testable import Pidgy

/// Guards the "Log out doesn't work" fix: the app returns to the Telegram
/// login screen when an authenticated session closes — but ONLY then. It
/// must not pop the login window during first-run auth (no prior `.ready`)
/// or while the app is quitting (stop() closes the session during
/// termination).
final class LogoutGatingTests: XCTestCase {
    func testLogoutFromAuthenticatedSessionReturnsToLogin() {
        XCTAssertTrue(AppDelegate.shouldReturnToLoginScreen(
            on: .loggingOut, hadAuthenticatedSession: true, isTerminating: false))
        XCTAssertTrue(AppDelegate.shouldReturnToLoginScreen(
            on: .closed, hadAuthenticatedSession: true, isTerminating: false))
    }

    func testNoReturnDuringFirstRunAuth() {
        // Never been `.ready` yet — closing/uninitialized states during
        // initial login must not bounce to a login window.
        XCTAssertFalse(AppDelegate.shouldReturnToLoginScreen(
            on: .closed, hadAuthenticatedSession: false, isTerminating: false))
        XCTAssertFalse(AppDelegate.shouldReturnToLoginScreen(
            on: .loggingOut, hadAuthenticatedSession: false, isTerminating: false))
    }

    func testNoReturnWhileTerminating() {
        // telegramService.stop() closes the session during quit — don't
        // present a window mid-termination.
        XCTAssertFalse(AppDelegate.shouldReturnToLoginScreen(
            on: .closed, hadAuthenticatedSession: true, isTerminating: true))
    }

    func testNonClosingStatesNeverTrigger() {
        for state: AuthState in [.ready, .waitingForPhoneNumber, .waitingForQrCode(link: "x"),
                                 .waitingForCode(codeInfo: nil), .waitingForPassword(hint: nil),
                                 .closing, .uninitialized] {
            XCTAssertFalse(
                AppDelegate.shouldReturnToLoginScreen(
                    on: state, hadAuthenticatedSession: true, isTerminating: false),
                "\(state) should not trigger a return to login"
            )
        }
    }
}
