import XCTest
@testable import LimitrCore

final class SurfaceModeTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = UUID().uuidString
        addTeardownBlock { UserDefaults().removeSuite(named: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// The menu bar is what every existing install already has. Reading an unset default
    /// as the notch would move someone's readings out from under them on the upgrade that
    /// introduced the setting.
    func testDefaultsToTheMenuBarWhenNothingHasBeenSaved() {
        XCTAssertEqual(SurfaceMode.load(from: defaults()), .menuBar)
    }

    func testRoundTripsThroughDefaults() {
        let store = defaults()

        SurfaceMode.notch.save(to: store)

        XCTAssertEqual(SurfaceMode.load(from: store), .notch)
    }

    /// The stored value is a raw string, so anything can be in there — a key hand-edited
    /// with `defaults write`, or a mode a later build knows and this one does not. Falling
    /// back is what keeps that from leaving the app with no surface at all.
    func testFallsBackToTheMenuBarForAValueItCannotRepresent() {
        let store = defaults()
        store.set("dynamicIsland", forKey: "surfaceMode")

        XCTAssertEqual(SurfaceMode.load(from: store), .menuBar)
    }
}
