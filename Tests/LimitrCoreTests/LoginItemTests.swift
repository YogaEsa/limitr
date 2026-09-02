import ServiceManagement
import XCTest
@testable import LimitrCore

final class LoginItemTests: XCTestCase {

    /// Records what the stubbed Service Management backend was asked to do.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ call: String) {
            lock.lock(); defer { lock.unlock() }
            storage.append(call)
        }

        var made: [String] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private func loginItem(status: SMAppService.Status, calls: Calls = Calls()) -> LoginItem {
        LoginItem(
            status: { status },
            register: { calls.record("register") },
            unregister: { calls.record("unregister") }
        )
    }

    // MARK: - Reading the state

    func testReportsEnabledWhenTheServiceIsRegistered() {
        XCTAssertEqual(loginItem(status: .enabled).state, .enabled)
    }

    func testReportsDisabledWhenTheServiceHasNeverBeenRegistered() {
        XCTAssertEqual(loginItem(status: .notRegistered).state, .disabled)
    }

    /// Switching a login item off in System Settings is the user overruling the app, and
    /// re-registering does not lift it. Collapsing this into `.disabled` would put a
    /// toggle on screen that silently refuses to move.
    func testReportsApprovalSeparatelyFromBeingSwitchedOff() {
        XCTAssertEqual(loginItem(status: .requiresApproval).state, .requiresApproval)
    }

    /// `swift run LimitrApp` has no app bundle for Service Management to register, and
    /// neither does a binary that was copied out of one. Offering the toggle there would
    /// promise something that cannot happen.
    func testReportsUnavailableWhenThereIsNoBundleToRegister() {
        XCTAssertEqual(loginItem(status: .notFound).state, .unavailable)
    }

    // MARK: - Changing it

    func testTurningItOnRegistersTheService() throws {
        let calls = Calls()

        try loginItem(status: .notRegistered, calls: calls).setEnabled(true)

        XCTAssertEqual(calls.made, ["register"])
    }

    func testTurningItOffUnregistersTheService() throws {
        let calls = Calls()

        try loginItem(status: .enabled, calls: calls).setEnabled(false)

        XCTAssertEqual(calls.made, ["unregister"])
    }

    /// The registration already exists; only the user can lift their own refusal, so the
    /// app asks them rather than repeating a call that changes nothing.
    func testTurningItOnDoesNotRegisterAgainWhenApprovalIsRequired() {
        let calls = Calls()

        XCTAssertThrowsError(try loginItem(status: .requiresApproval, calls: calls).setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemError, .requiresApproval)
        }
        XCTAssertEqual(calls.made, [])
    }

    func testTurningItOnDoesNothingWhenThereIsNoBundle() {
        let calls = Calls()

        XCTAssertThrowsError(try loginItem(status: .notFound, calls: calls).setEnabled(true)) { error in
            XCTAssertEqual(error as? LoginItemError, .unavailable)
        }
        XCTAssertEqual(calls.made, [])
    }

    /// Turning off something the system has already forgotten is not a failure, and
    /// reporting one would put an error on screen for reaching the state that was asked
    /// for.
    func testTurningItOffWhenItIsAlreadyOffIsNotAnError() throws {
        let calls = Calls()

        try loginItem(status: .notRegistered, calls: calls).setEnabled(false)

        XCTAssertEqual(calls.made, [])
    }
}
