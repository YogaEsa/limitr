import XCTest
@testable import LimitrCore

final class NotificationRulesTests: XCTestCase {

    private func window(usedPercent: Double, resetsAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> UsageWindow {
        UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: usedPercent,
                    resetsAt: resetsAt, windowMinutes: 300, staleness: .fresh)
    }
    func testStaysSilentBelowTheRedThreshold() {
        var rules = NotificationRules()
        let amber = UsageWindow(source: .claude, label: "five_hour", usedPercent: 84, resetsAt: .distantFuture, windowMinutes: 300, staleness: .fresh)

        XCTAssertEqual(rules.evaluate([amber]), [])
        XCTAssertEqual(rules.evaluate([amber]), [])
    }

    func testAlertsOnceWhenAWindowGoesRed() {
        var rules = NotificationRules()
        let red = UsageWindow(source: .claude, label: "five_hour", usedPercent: 85, resetsAt: .distantFuture, windowMinutes: 300, staleness: .fresh)

        XCTAssertEqual(rules.evaluate([red]).count, 1)
        XCTAssertEqual(rules.evaluate([red]), [])
    }

    /// Climbing further into the red must not produce a second notification — the old
    /// 70/85/95 ladder is exactly the spam this replaced.
    func testDoesNotAlertAgainAsUsageClimbsWithinTheSameWindow() {
        var rules = NotificationRules()
        let resets = Date.distantFuture
        let window = { (used: Double) in
            UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: used,
                        resetsAt: resets, windowMinutes: 300, staleness: .fresh)
        }

        let alerts = [70.0, 86, 90, 95, 99, 100].flatMap { rules.evaluate([window($0)]) }

        XCTAssertEqual(alerts.count, 1, "one window going red is one notification, not four")
        guard case .threshold(_, 85) = alerts[0] else { return XCTFail("expected the red threshold, got \(alerts[0])") }
    }

    /// Weekly Claude limits used to skip the 70% notice specially. With a single red
    /// threshold that carve-out is gone, and they alert on the same terms as everything else.
    func testWeeklyClaudeAlertsOnTheSameRedThreshold() {
        var rules = NotificationRules()
        let weekly = UsageWindow(source: .claude, label: "seven_day", usedPercent: 90, resetsAt: .distantFuture, windowMinutes: 10_080, staleness: .fresh)

        XCTAssertEqual(rules.evaluate([weekly]).count, 1)
        XCTAssertEqual(rules.evaluate([weekly]), [])
    }

    /// The live Claude endpoint returns a reset instant whose sub-second component moves
    /// on every request — observed going from 07:00:00.322552Z to 06:59:59.855010Z across
    /// two polls 100s apart. Compared exactly, every poll looks like a brand-new window.
    func testIgnoresSubSecondJitterInResetInstant() {
        var rules = NotificationRules()
        let jitter = [0.322552, -0.144990, 0.401, -0.09, 0.25]
        let boundary = ISO8601DateFormatter().date(from: "2026-08-12T07:00:00Z")!

        let alerts = jitter.flatMap { offset in
            rules.evaluate([
                UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: 88,
                            resetsAt: boundary.addingTimeInterval(offset), windowMinutes: 300, staleness: .fresh)
            ])
        }

        XCTAssertEqual(alerts.count, 1, "jittering reset instants must not re-trigger alerts")
        guard case .threshold(_, 85) = alerts[0] else { return XCTFail("expected the red threshold, got \(alerts[0])") }
    }

    func testStillReportsGenuineWindowRollover() {
        var rules = NotificationRules()
        let first = ISO8601DateFormatter().date(from: "2026-08-12T07:00:00Z")!
        let window = { (resets: Date) in
            UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: 72,
                        resetsAt: resets, windowMinutes: 300, staleness: .fresh)
        }

        _ = rules.evaluate([window(first)])
        let rolled = rules.evaluate([window(first.addingTimeInterval(5 * 3600))])

        XCTAssertEqual(rolled.count, 1)
        guard case .reset = rolled[0] else { return XCTFail("a real rollover must still report a reset, got \(rolled[0])") }
    }

    /// A window that rolls over while still red reports the reset, then is free to go red
    /// again inside the new window.
    func testRedAlertRearmsAfterAReset() {
        var rules = NotificationRules()
        let first = ISO8601DateFormatter().date(from: "2026-08-12T07:00:00Z")!
        let window = { (resets: Date) in
            UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: 92,
                        resetsAt: resets, windowMinutes: 300, staleness: .fresh)
        }

        XCTAssertEqual(rules.evaluate([window(first)]).count, 1)
        let rolled = rules.evaluate([window(first.addingTimeInterval(5 * 3600))])
        guard case .reset = rolled[0] else { return XCTFail("expected a reset, got \(rolled[0])") }

        let afterReset = rules.evaluate([window(first.addingTimeInterval(5 * 3600))])
        XCTAssertEqual(afterReset.count, 1, "the red alert must re-arm for the new window")
    }

    func testDoesNotAlertWhileIdleAcrossManyPolls() {
        var rules = NotificationRules()
        let boundary = ISO8601DateFormatter().date(from: "2026-08-12T07:00:00Z")!

        let alerts = (0..<8).flatMap { index in
            rules.evaluate([
                UsageWindow(source: .claude, accountID: "acc", label: "five_hour", usedPercent: 0,
                            resetsAt: boundary.addingTimeInterval(Double(index % 2) * 0.4 - 0.2),
                            windowMinutes: 300, staleness: .fresh)
            ])
        }

        XCTAssertEqual(alerts, [], "an idle account must stay silent")
    }

    // MARK: - Honouring the user's preferences

    /// The threshold is a setting now, and the alert must fire where the user put it —
    /// the same number the usage bars turn red at.
    func testFiresAtTheThresholdTheUserChose() {
        var rules = NotificationRules(preferences: NotificationPreferences(redThreshold: 60))

        let alerts = rules.evaluate([window(usedPercent: 65)])

        guard case .threshold(_, let threshold)? = alerts.first else { return XCTFail("expected a threshold alert, got \(alerts)") }
        XCTAssertEqual(threshold, 60)
    }

    func testStaysSilentBelowTheThresholdTheUserChose() {
        var rules = NotificationRules(preferences: NotificationPreferences(redThreshold: 90))

        XCTAssertTrue(rules.evaluate([window(usedPercent: 88)]).isEmpty)
    }

    func testSaysNothingAboutTheRedLineWhenThatAlertIsSwitchedOff() {
        var rules = NotificationRules(preferences: NotificationPreferences(alertsOnRed: false))

        XCTAssertTrue(rules.evaluate([window(usedPercent: 99)]).isEmpty)
    }

    /// Switching off the red alert must not switch off the reset one — they are the two
    /// halves of the cycle and people want them independently.
    func testStillReportsAResetWhenOnlyTheRedAlertIsOff() {
        var rules = NotificationRules(preferences: NotificationPreferences(alertsOnRed: false))
        _ = rules.evaluate([window(usedPercent: 99)])

        let alerts = rules.evaluate([window(usedPercent: 1, resetsAt: Date(timeIntervalSince1970: 2_000_000_000))])

        guard case .reset? = alerts.first else { return XCTFail("expected a reset alert, got \(alerts)") }
    }

    func testSaysNothingAboutAResetWhenThatAlertIsSwitchedOff() {
        var rules = NotificationRules(preferences: NotificationPreferences(alertsOnReset: false))
        _ = rules.evaluate([window(usedPercent: 10)])

        XCTAssertTrue(rules.evaluate([window(usedPercent: 1, resetsAt: Date(timeIntervalSince1970: 2_000_000_000))]).isEmpty)
    }
}
