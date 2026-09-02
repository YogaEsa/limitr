import XCTest
@testable import LimitrCore

final class BurnRateTests: XCTestCase {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(percent: Double, resetsInHours: Double, now: Date) -> UsageWindow {
        UsageWindow(
            source: .claude,
            accountID: "a",
            accountName: "a",
            label: "five_hour",
            usedPercent: percent,
            resetsAt: now.addingTimeInterval(resetsInHours * 3_600),
            windowMinutes: 300,
            staleness: .fresh
        )
    }

    private func samples(_ readings: [(minutesAgo: Double, percent: Double)], now: Date, boundary: Date) -> [UsageSample] {
        readings.map {
            UsageSample(
                windowID: "claude-a-five_hour",
                boundary: boundary,
                at: now.addingTimeInterval(-$0.minutesAgo * 60),
                percent: $0.percent
            )
        }
    }

    func testProjectsWhenTheWindowWillBeFull() throws {
        let now = origin
        // 20 points over an hour, with 40 left to spend: two more hours.
        let window = window(percent: 60, resetsInHours: 5, now: now)
        let readings = samples([(60, 40), (0, 60)], now: now, boundary: window.resetsAt)

        let rate = try XCTUnwrap(BurnRate.project(samples: readings, window: window, now: now))

        XCTAssertEqual(rate.percentPerHour, 20, accuracy: 0.001)
        XCTAssertEqual(rate.exhaustedAt.timeIntervalSince(now) / 3_600, 2, accuracy: 0.001)
    }

    /// A delta measured across two polls describes the polling interval, not the usage.
    /// The trend chip holds off for the same reason and by the same margin.
    func testSaysNothingUntilThereIsTenMinutesOfHistory() {
        let now = origin
        let window = window(percent: 60, resetsInHours: 5, now: now)
        let readings = samples([(6, 50), (0, 60)], now: now, boundary: window.resetsAt)

        XCTAssertNil(BurnRate.project(samples: readings, window: window, now: now))
    }

    func testSaysNothingFromASingleReading() {
        let now = origin
        let window = window(percent: 60, resetsInHours: 5, now: now)
        let readings = samples([(0, 60)], now: now, boundary: window.resetsAt)

        XCTAssertNil(BurnRate.project(samples: readings, window: window, now: now))
    }

    /// Nothing is being spent, so there is nothing to run out of.
    func testSaysNothingWhenTheWindowIsNotFilling() {
        let now = origin
        let window = window(percent: 60, resetsInHours: 5, now: now)
        let readings = samples([(60, 60), (0, 60)], now: now, boundary: window.resetsAt)

        XCTAssertNil(BurnRate.project(samples: readings, window: window, now: now))
    }

    /// The window rolls over first, so the capacity comes back before the pace could use
    /// it up. A countdown to a wall the user will never reach is a false alarm.
    func testSaysNothingWhenTheWindowResetsBeforeItWouldRunOut() {
        let now = origin
        // 10 points an hour with 40 to go is four hours away, but the window resets in one.
        let window = window(percent: 60, resetsInHours: 1, now: now)
        let readings = samples([(60, 50), (0, 60)], now: now, boundary: window.resetsAt)

        XCTAssertNil(BurnRate.project(samples: readings, window: window, now: now))
    }

    /// Samples taken before a rollover describe a window that no longer exists, and
    /// averaging across the boundary reads as a sudden collapse in usage.
    func testIgnoresSamplesFromTheWindowThisOneReplaced() {
        let now = origin
        let window = window(percent: 60, resetsInHours: 5, now: now)
        var readings = samples([(60, 40), (0, 60)], now: now, boundary: window.resetsAt)
        readings.insert(
            UsageSample(
                windowID: "claude-a-five_hour",
                boundary: window.resetsAt.addingTimeInterval(-86_400),
                at: now.addingTimeInterval(-7_200),
                percent: 95
            ),
            at: 0
        )

        let rate = try? XCTUnwrap(BurnRate.project(samples: readings, window: window, now: now))

        XCTAssertEqual(rate?.percentPerHour ?? 0, 20, accuracy: 0.001)
    }

    /// The projection starts from what the window reports now, not from the last sample —
    /// the provider's reading is the authority and a sample may be a minute behind it.
    func testProjectsFromTheWindowsCurrentFill() throws {
        let now = origin
        let window = window(percent: 80, resetsInHours: 5, now: now)
        let readings = samples([(60, 40), (0, 60)], now: now, boundary: window.resetsAt)

        let rate = try XCTUnwrap(BurnRate.project(samples: readings, window: window, now: now))

        // 20 left at 20 points an hour.
        XCTAssertEqual(rate.exhaustedAt.timeIntervalSince(now) / 3_600, 1, accuracy: 0.001)
    }

    func testSaysNothingWhenTheWindowIsAlreadyFull() {
        let now = origin
        let window = window(percent: 100, resetsInHours: 5, now: now)
        let readings = samples([(60, 80), (0, 100)], now: now, boundary: window.resetsAt)

        XCTAssertNil(BurnRate.project(samples: readings, window: window, now: now))
    }
}
