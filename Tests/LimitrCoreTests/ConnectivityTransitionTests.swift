import XCTest
@testable import LimitrCore

final class ConnectivityTransitionTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()

    func testReportsAnAccountThatJustSignedIn() {
        // The reported bug. Pressing Sign in on the welcome screen starts a browser login
        // that lands minutes later, and nothing was watching for it: the welcome screen
        // stayed in front of a working account until the user ran the scan again.
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [first: false],
            current: [first: true]
        )
        XCTAssertEqual(arrived, [first])
    }

    func testTreatsAFirstReadingAsNoTransition() {
        // The half that makes this safe. Every account arrives with no previous reading at
        // launch, and the common first run is someone already signed in at the default
        // paths — so counting a first reading would close the welcome screen before the
        // user had answered it, and the scan that finds a login living somewhere custom
        // would never be offered.
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [:],
            current: [first: true, second: true]
        )
        XCTAssertTrue(arrived.isEmpty)
    }

    func testIgnoresAnAccountThatSignedOut() {
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [first: true],
            current: [first: false]
        )
        XCTAssertTrue(arrived.isEmpty)
    }

    func testIgnoresAnAccountThatWasAlreadyConnected() {
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [first: true],
            current: [first: true]
        )
        XCTAssertTrue(arrived.isEmpty)
    }

    func testReportsOnlyTheAccountThatChanged() {
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [first: true, second: false],
            current: [first: true, second: true]
        )
        XCTAssertEqual(arrived, [second])
    }

    func testIgnoresAnAccountThatIsNoLongerBeingRead() {
        // A removed account disappears from the current reading; it has not signed in.
        let arrived = ConnectivityTransition.newlyConnected(
            previous: [first: false, second: false],
            current: [first: true]
        )
        XCTAssertEqual(arrived, [first])
    }
}
