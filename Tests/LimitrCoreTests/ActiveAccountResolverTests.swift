import XCTest
@testable import LimitrCore

final class ActiveAccountResolverTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()
    private let third = UUID()

    func testKeepsAnExplicitChoiceWhileItIsStillSigningIn() {
        // The regression this exists for: picking an account and then signing into it
        // used to bounce back to the already-connected one on the next poll. The sign-in
        // being in flight is now what says so, rather than the choice being explicit at
        // all — see `testHandsOverWhenTheChosenAccountHasNoLoginAndAnotherDoes`.
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [first],
            active: second,
            chosen: second,
            settling: [second]
        )
        XCTAssertEqual(chosen, second)
    }

    func testHandsOverWhenTheChosenAccountHasNoLoginAndAnotherDoes() {
        // The reported bug. A choice made by hand used to outrank connectivity for good,
        // so `~/.limitr/active.sh` kept exporting an account with no credential: `claude`
        // in a brand-new terminal asked for a login the user had already completed on the
        // other account.
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [second],
            active: first,
            chosen: first,
            settling: []
        )
        XCTAssertEqual(chosen, second)
    }

    func testRestoresTheChosenAccountOnceItSignsIn() {
        // Handing over is a loan, not a transfer: the choice is still recorded, so the
        // account the user picked takes the default back the moment it has a login again.
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [first, second],
            active: second,
            chosen: first,
            settling: []
        )
        XCTAssertEqual(chosen, first)
    }

    func testKeepsTheChosenAccountWhenNothingIsConnected() {
        // Nothing to hand over to, so standing the choice down would only lose it.
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [],
            active: second,
            chosen: first,
            settling: []
        )
        XCTAssertEqual(chosen, first)
    }

    func testFirstAccountToSignInAdoptsWhenNothingWasChosenByHand() {
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [second],
            active: first,
            chosen: nil,
            settling: []
        )
        XCTAssertEqual(chosen, second)
    }

    func testKeepsTheStandingDefaultWhileNoAccountIsConnected() {
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [],
            active: first,
            chosen: nil,
            settling: []
        )
        XCTAssertEqual(chosen, first)
    }

    func testKeepsTheStandingDefaultWhileItsOwnSignInIsInFlight() {
        // Same protection the chosen account gets, for the account that merely inherited
        // the default: a sign-in makes it read as disconnected for the whole of its run.
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [second],
            active: first,
            chosen: nil,
            settling: [first]
        )
        XCTAssertEqual(chosen, first)
    }

    func testKeepsAConnectedActiveAccount() {
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [first, second],
            active: first,
            chosen: nil,
            settling: []
        )
        XCTAssertEqual(chosen, first)
    }

    func testFillsTheGapWhenTheActiveAccountIsGone() {
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [second],
            active: third,
            chosen: third,
            settling: []
        )
        XCTAssertEqual(chosen, second)
    }

    func testFallsBackToTheFirstAccountWhenNoneIsConnected() {
        let chosen = ActiveAccountResolver.resolve(
            candidates: [first, second],
            connected: [],
            active: nil,
            chosen: nil,
            settling: []
        )
        XCTAssertEqual(chosen, first)
    }

    func testReturnsNilWithoutCandidates() {
        XCTAssertNil(ActiveAccountResolver.resolve(
            candidates: [],
            connected: [],
            active: first,
            chosen: first,
            settling: []
        ))
    }
}
