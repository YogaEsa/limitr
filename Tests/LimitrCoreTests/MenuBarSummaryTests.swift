import XCTest
@testable import LimitrCore

final class MenuBarSummaryTests: XCTestCase {

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
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowMinutes: minutes,
            staleness: staleness
        )
    }

    /// The bar answers "how close am I to a wall", so the fullest window speaks for a
    /// service — not the shortest one.
    ///
    /// Reporting the session window was wrong in a way that read as a broken app: a
    /// Codex account whose five-hour window had rolled over showed 0% in the bar while
    /// it had spent 7% of its week, and a 0% next to a service the user had been using
    /// all week looks like a monitor that has stopped working. It also assumed every
    /// account has a session window, which is not true — a Codex account on a credit
    /// plan reports one 30-day window and nothing shorter.
    func testShowsTheFullestWindowOfEachService() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.claude, label: "seven_day", percent: 90, minutes: 10_080),
                window(.claude, label: "five_hour", percent: 41, minutes: 300),
                window(.codex, account: "c", label: "secondary", percent: 7, minutes: 10_080),
                window(.codex, account: "c", label: "primary", percent: 0, minutes: 300)
            ],
            accountIDs: [.claude: "a", .codex: "c"]
        )

        XCTAssertEqual(summary.items.map(\.percent), [90, 7])
    }

    /// Ties go to the shorter window, so the reading is stable rather than dependent on
    /// the order the provider happened to return.
    func testBreaksATieOnTheShorterWindow() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.claude, label: "seven_day", percent: 30, minutes: 10_080),
                window(.claude, label: "five_hour", percent: 30, minutes: 300)
            ],
            accountIDs: [.claude: "a"]
        )

        XCTAssertEqual(summary.items.map(\.isLive), [true])
        XCTAssertEqual(summary.items.count, 1)
    }

    /// Claude first, matching the order of the panel's own service tabs — two surfaces
    /// naming the same two services in opposite orders is a way to misread the bar.
    func testOrdersClaudeBeforeCodex() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.codex, account: "c", label: "primary", percent: 68, minutes: 299),
                window(.claude, label: "five_hour", percent: 41, minutes: 300)
            ],
            accountIDs: [.claude: "a", .codex: "c"]
        )

        XCTAssertEqual(summary.items.map(\.source), [.claude, .codex])
    }

    /// The bar has room for one number per service, and the account it belongs to is the
    /// one new terminals inherit. Showing another account's number there would report a
    /// limit the next `claude` run is not going to be spending against.
    func testShowsOnlyTheAccountTheServiceIsStandingOn() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.claude, account: "work", label: "five_hour", percent: 12, minutes: 300),
                window(.claude, account: "personal", label: "five_hour", percent: 88, minutes: 300)
            ],
            accountIDs: [.claude: "personal"]
        )

        XCTAssertEqual(summary.items.map(\.percent), [88])
    }

    func testOmitsAServiceThatHasNoWindows() {
        let summary = MenuBarSummary.make(
            windows: [window(.claude, label: "five_hour", percent: 41, minutes: 300)],
            accountIDs: [.claude: "a", .codex: "c"]
        )

        XCTAssertEqual(summary.items.map(\.source), [.claude])
    }

    func testIsEmptyWhenNothingIsReporting() {
        XCTAssertTrue(MenuBarSummary.make(windows: [], accountIDs: [.claude: "a"]).isEmpty)
    }

    /// Codex numbers freeze while nothing is being prompted, and an estimated window is a
    /// guess from a log. The bar has to be able to say so rather than present either as
    /// a live reading.
    func testFlagsAWindowThatIsNotLive() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.claude, label: "five_hour", percent: 41, minutes: 300),
                window(.codex, account: "c", label: "primary", percent: 68, minutes: 300, staleness: .stale)
            ],
            accountIDs: [.claude: "a", .codex: "c"]
        )

        XCTAssertEqual(summary.items.map(\.isLive), [true, false])
    }

    /// The one number worth reacting to is the worst one, so the icon tracks the highest
    /// of the services on show rather than an average that hides a full window.
    func testPeakIsTheHighestOfTheServicesOnShow() {
        let summary = MenuBarSummary.make(
            windows: [
                window(.claude, label: "five_hour", percent: 41, minutes: 300),
                window(.codex, account: "c", label: "primary", percent: 92, minutes: 299)
            ],
            accountIDs: [.claude: "a", .codex: "c"]
        )

        XCTAssertEqual(summary.peakPercent, 92)
    }

    func testPeakIsNilWhenNothingIsReporting() {
        XCTAssertNil(MenuBarSummary.make(windows: [], accountIDs: [:]).peakPercent)
    }
}
