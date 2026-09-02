import XCTest
@testable import LimitrCore

final class UsageHistoryTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(
        _ label: String = "five_hour",
        percent: Double,
        resetsInHours: Double = 5,
        now: Date
    ) -> UsageWindow {
        UsageWindow(
            source: .claude,
            accountID: "a",
            accountName: "a",
            label: label,
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsInHours * 3_600),
            windowMinutes: 300,
            staleness: .fresh
        )
    }

    // MARK: - Recording

    func testKeepsOneSamplePerWindowPerRecording() {
        var history = UsageHistory()
        let first = window(percent: 10, now: origin)
        let second = window("seven_day", percent: 3, now: origin)

        history.record([first, second], now: origin)

        XCTAssertEqual(history.samples(for: first).count, 1)
        XCTAssertEqual(history.samples(for: second).count, 1)
    }

    func testDoesNotLetOneWindowsSamplesReachAnother() {
        var history = UsageHistory()
        let session = window(percent: 10, now: origin)
        let weekly = window("seven_day", percent: 3, now: origin)

        history.record([session, weekly], now: origin)

        XCTAssertEqual(history.samples(for: session).map(\.percent), [10])
    }

    func testForgetsSamplesOlderThanItsMemory() {
        var history = UsageHistory()
        let window = window(percent: 10, now: origin)

        history.record([window], now: origin.addingTimeInterval(-3 * 3_600))
        history.record([window], now: origin)

        XCTAssertEqual(history.samples(for: window).count, 1)
    }

    /// A rollover makes every earlier sample describe a window that no longer exists.
    /// Keeping them would read as a sudden collapse in usage.
    func testForgetsSamplesTakenBeforeTheWindowRolledOver() {
        var history = UsageHistory()
        let before = window(percent: 90, resetsInHours: 0.5, now: origin)
        let after = window(percent: 2, resetsInHours: 5, now: origin)

        history.record([before], now: origin)
        history.record([after], now: origin.addingTimeInterval(60))

        XCTAssertEqual(history.samples(for: after).map(\.percent), [2])
    }

    /// Providers jitter the reset instant by fractions of a second, so an exact comparison
    /// would call every poll a fresh window and throw the history away each time.
    func testTreatsAJitteredResetInstantAsTheSameWindow() {
        var history = UsageHistory()
        let first = window(percent: 10, now: origin)
        let jittered = UsageWindow(
            source: .claude, accountID: "a", accountName: "a", label: "five_hour",
            usedPercent: 12, resetsAt: first.resetsAt.addingTimeInterval(0.4),
            windowMinutes: 300, staleness: .fresh
        )

        history.record([first], now: origin)
        history.record([jittered], now: origin.addingTimeInterval(180))

        XCTAssertEqual(history.samples(for: jittered).count, 2)
    }

    // MARK: - Trend

    func testTrendReportsWhatTheWindowHasAddedSinceTheOldestSample() {
        var history = UsageHistory()
        let start = window(percent: 40, now: origin)
        let later = window(percent: 55, now: origin)

        history.record([start], now: origin)
        history.record([later], now: origin.addingTimeInterval(20 * 60))

        XCTAssertEqual(history.trend(for: later, now: origin.addingTimeInterval(20 * 60)) ?? 0, 15, accuracy: 0.001)
    }

    /// A delta across two polls describes the polling interval rather than the usage.
    func testTrendSaysNothingUntilThereIsTenMinutesOfHistory() {
        var history = UsageHistory()
        let start = window(percent: 40, now: origin)
        let later = window(percent: 55, now: origin)

        history.record([start], now: origin)
        history.record([later], now: origin.addingTimeInterval(5 * 60))

        XCTAssertNil(history.trend(for: later, now: origin.addingTimeInterval(5 * 60)))
    }

    func testTrendSaysNothingAboutAChangeTooSmallToMeanAnything() {
        var history = UsageHistory()
        let start = window(percent: 40, now: origin)
        let later = window(percent: 40.2, now: origin)

        history.record([start], now: origin)
        history.record([later], now: origin.addingTimeInterval(20 * 60))

        XCTAssertNil(history.trend(for: later, now: origin.addingTimeInterval(20 * 60)))
    }

    // MARK: - Surviving a restart

    /// The point of persisting at all: a trend and a projection that are on screen at
    /// launch rather than ten minutes into it.
    func testReloadsItsSamplesFromDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var history = UsageHistory()
        let start = window(percent: 40, now: origin)
        history.record([start], now: origin)
        history.record([window(percent: 55, now: origin)], now: origin.addingTimeInterval(20 * 60))

        try UsageHistoryStore.save(history, to: url)
        let reloaded = UsageHistoryStore.load(from: url)

        XCTAssertEqual(reloaded.samples(for: start).map(\.percent), [40, 55])
    }

    func testStartsEmptyWhenThereIsNothingSavedYet() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")

        XCTAssertTrue(UsageHistoryStore.load(from: url).isEmpty)
    }

    /// A file that will not parse is news about the read, not a reason to refuse to start.
    func testStartsEmptyWhenTheSavedFileIsUnreadable() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        XCTAssertTrue(UsageHistoryStore.load(from: url).isEmpty)
    }

    /// Samples for windows that have since rolled over are dead weight, and the file is
    /// rewritten on every poll.
    func testDoesNotSaveSamplesItHasAlreadyForgotten() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var history = UsageHistory()
        let window = window(percent: 10, now: origin)
        history.record([window], now: origin.addingTimeInterval(-3 * 3_600))
        history.record([window], now: origin)

        try UsageHistoryStore.save(history, to: url)

        XCTAssertEqual(UsageHistoryStore.load(from: url).samples(for: window).count, 1)
    }
}
