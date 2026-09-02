import XCTest
@testable import LimitrCore

final class NotchSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ source: UsageSource,
        account: String = "a",
        label: String,
        percent: Double,
        minutes: Int,
        staleness: Staleness = .fresh
    ) -> UsageWindow {
        UsageWindow(
            source: source,
            accountID: account,
            accountName: account,
            label: label,
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(3_600 * 4),
            windowMinutes: minutes,
            staleness: staleness
        )
    }

    private func summary(
        _ windows: [UsageWindow],
        accounts: [UsageSource: String],
        history: UsageHistory = UsageHistory(),
        activity: ActivityPulse = ActivityPulse()
    ) -> NotchSummary {
        NotchSummary.make(windows: windows, accountIDs: accounts, history: history,
                          activity: activity, now: now)
    }

    /// The same binding rule the menu bar uses, reached through the same function, so the
    /// two can never name different windows or different numbers.
    func testAgreesWithTheMenuBarAboutWhichWindowSpeaks() {
        let windows = [
            window(.claude, label: "five_hour", percent: 41, minutes: 300),
            window(.claude, label: "seven_day", percent: 88, minutes: 10_080)
        ]
        let row = summary(windows, accounts: [.claude: "a"]).rows.first
        XCTAssertEqual(row?.window.label, "seven_day")

        let bar = MenuBarSummary.make(windows: windows, accountIDs: [.claude: "a"]).items.first
        XCTAssertEqual(row?.window.usedPercent, bar?.percent)
    }

    func testReportsNothingForAServiceWithNoActiveAccount() {
        XCTAssertTrue(summary([window(.claude, label: "five_hour", percent: 41, minutes: 300)],
                              accounts: [:]).isEmpty)
    }

    /// A trend needs ten minutes of history before it means anything — the same floor the
    /// panel's chip uses, because a delta across two polls describes the poll interval.
    func testCarriesTheTrendAndTheProjectionOnceThereIsEnoughHistory() throws {
        let old = window(.claude, label: "five_hour", percent: 30, minutes: 300)
        let current = window(.claude, label: "five_hour", percent: 45, minutes: 300)
        var history = UsageHistory()
        history.record([old], now: now.addingTimeInterval(-1_800))
        history.record([current], now: now)

        let row = try XCTUnwrap(summary([current], accounts: [.claude: "a"], history: history).rows.first)
        XCTAssertEqual(try XCTUnwrap(row.trend), 15, accuracy: 0.001)
        XCTAssertNotNil(row.burn)
    }

    func testSaysNothingAboutTrendOrBurnWithoutHistory() {
        let row = summary([window(.claude, label: "five_hour", percent: 45, minutes: 300)],
                          accounts: [.claude: "a"]).rows.first
        XCTAssertNil(row?.trend)
        XCTAssertNil(row?.burn)
    }

    func testMarksAServiceWorkingWhileItsPulseIsLit() {
        var activity = ActivityPulse()
        activity.tick(source: .codex, accountID: "c", at: now)
        let rows = summary(
            [window(.claude, label: "five_hour", percent: 10, minutes: 300),
             window(.codex, account: "c", label: "primary", percent: 20, minutes: 300)],
            accounts: [.claude: "a", .codex: "c"],
            activity: activity
        ).rows
        XCTAssertEqual(rows.first { $0.source == .codex }?.isWorking, true)
        XCTAssertEqual(rows.first { $0.source == .claude }?.isWorking, false)
    }

    /// Claude before Codex, matching the panel's service tabs and the menu bar's order.
    func testOrdersClaudeBeforeCodex() {
        let rows = summary(
            [window(.codex, account: "c", label: "primary", percent: 20, minutes: 300),
             window(.claude, label: "five_hour", percent: 10, minutes: 300)],
            accounts: [.claude: "a", .codex: "c"]
        ).rows
        XCTAssertEqual(rows.map(\.source), [.claude, .codex])
    }

    /// Staleness is carried through whole rather than flattened to a Bool, so the view
    /// applies the same `.fresh`-only rule every other surface applies.
    func testCarriesStalenessThroughUntouched() {
        let row = summary([window(.codex, account: "c", label: "primary", percent: 20,
                                  minutes: 300, staleness: .stale)],
                          accounts: [.codex: "c"]).rows.first
        XCTAssertEqual(row?.window.staleness, .stale)
    }
}
