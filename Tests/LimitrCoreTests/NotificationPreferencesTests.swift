import XCTest
@testable import LimitrCore

final class NotificationPreferencesTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = UUID().uuidString
        addTeardownBlock { UserDefaults().removeSuite(named: suite) }
        return UserDefaults(suiteName: suite)!
    }

    func testStartsAtTheThresholdTheUIHasAlwaysUsed() {
        XCTAssertEqual(NotificationPreferences().redThreshold, 85)
        XCTAssertTrue(NotificationPreferences().alertsOnRed)
        XCTAssertTrue(NotificationPreferences().alertsOnReset)
    }

    /// A threshold at 0 would fire on an empty window and one at 100 would fire only after
    /// the limit was already spent. Neither is a setting; both are ways to break the alert.
    func testClampsTheThresholdToAUsefulRange() {
        XCTAssertEqual(NotificationPreferences(redThreshold: 0).redThreshold, NotificationPreferences.thresholdRange.lowerBound)
        XCTAssertEqual(NotificationPreferences(redThreshold: 100).redThreshold, NotificationPreferences.thresholdRange.upperBound)
        XCTAssertEqual(NotificationPreferences(redThreshold: 70).redThreshold, 70)
    }

    /// Changing one setting must not be a way around the clamp, so every edit is routed
    /// back through the initialiser that enforces it.
    func testChangingOneSettingKeepsTheOthersAndStillClamps() {
        let preferences = NotificationPreferences(redThreshold: 70, alertsOnRed: false, alertsOnReset: true)

        let changed = preferences.with(redThreshold: 200)

        XCTAssertEqual(changed.redThreshold, NotificationPreferences.thresholdRange.upperBound)
        XCTAssertFalse(changed.alertsOnRed)
        XCTAssertTrue(changed.alertsOnReset)
    }

    func testRoundTripsThroughDefaults() {
        let store = defaults()
        var preferences = NotificationPreferences(redThreshold: 60, alertsOnRed: false, alertsOnReset: true)

        preferences.save(to: store)

        XCTAssertEqual(NotificationPreferences.load(from: store), preferences)
    }

    func testFallsBackToTheDefaultsWhenNothingHasBeenSaved() {
        XCTAssertEqual(NotificationPreferences.load(from: defaults()), NotificationPreferences())
    }

    /// A stored value from a build with a different range must still land inside this
    /// build's, rather than reinstating a threshold the UI can no longer represent.
    func testClampsAThresholdItReadsBackFromDefaults() {
        let store = defaults()
        store.set(3, forKey: "notificationRedThreshold")

        XCTAssertEqual(NotificationPreferences.load(from: store).redThreshold, NotificationPreferences.thresholdRange.lowerBound)
    }
}
