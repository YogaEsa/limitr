import XCTest
@testable import LimitrCore

final class NotchPresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let preferences = NotificationPreferences()

    private func window(percent: Double = 90) -> UsageWindow {
        UsageWindow(
            source: .claude,
            accountID: "a",
            accountName: "a",
            label: "five_hour",
            usedPercent: percent,
            resetsAt: Date(timeIntervalSince1970: 1_800_010_000),
            windowMinutes: 300,
            staleness: .fresh
        )
    }

    private func send(
        _ events: [NotchPresentation.Event],
        from state: NotchState = .ambient,
        preferences: NotificationPreferences? = nil
    ) -> NotchState {
        var presentation = NotchPresentation(state: state)
        for event in events {
            presentation.handle(event, now: now, preferences: preferences ?? self.preferences)
        }
        return presentation.state
    }

    /// Hover is the whole gesture: the pointer arriving opens the panel and the pointer
    /// leaving closes it. There is no intermediate reading to click through, because the
    /// click is spent on the thing the panel deliberately leaves out — the cards.
    func testOpensWhenThePointerArrivesAndClosesWhenItLeaves() {
        XCTAssertEqual(send([.pointerEntered]), .expanded)
        XCTAssertEqual(send([.pointerEntered, .pointerExited]), .ambient)
    }

    /// A click asks for the cards, and the notch gets out of their way: the panel they
    /// open hangs from the same screen edge, and two slabs stacked there is not a reading.
    func testCollapsesOnAClickSoTheCardsCanTakeTheEdge() {
        XCTAssertEqual(send([.pointerEntered, .clicked]), .ambient)
    }

    /// Auto-expanding on the alert is what makes this a status surface rather than a
    /// decoration: it arrives at the moment the number matters.
    func testExpandsWhenAWindowGoesRed() {
        XCTAssertEqual(send([.alert(.threshold(window(), 85))]), .expanded)
    }

    func testExpandsWhenCapacityComesBack() {
        XCTAssertEqual(send([.alert(.reset(window(percent: 0)))]), .expanded)
    }

    /// Someone who switched the red alert off must not be handed a panel dropping out of
    /// the ceiling instead of the notification they declined. The two switches govern
    /// their own halves independently, exactly as they do for notifications.
    func testDoesNotAutoExpandForAnAlertTheUserSwitchedOff() {
        let quiet = NotificationPreferences(redThreshold: 85, alertsOnRed: false, alertsOnReset: true)
        XCTAssertEqual(send([.alert(.threshold(window(), 85))], preferences: quiet), .ambient)
        XCTAssertEqual(send([.alert(.reset(window(percent: 0)))], preferences: quiet), .expanded)
    }

    func testCollapsesFourSecondsAfterAnAutoExpansion() {
        var presentation = NotchPresentation(state: .ambient)
        presentation.handle(.alert(.threshold(window(), 85)), now: now, preferences: preferences)
        let soon = now.addingTimeInterval(3)
        presentation.handle(.tick(soon), now: soon, preferences: preferences)
        XCTAssertEqual(presentation.state, .expanded)
        let due = now.addingTimeInterval(4)
        presentation.handle(.tick(due), now: due, preferences: preferences)
        XCTAssertEqual(presentation.state, .ambient)
    }

    /// A panel the user is hovering has no deadline — they close it by moving away.
    func testDoesNotCollapseAHoverExpansionOnATick() {
        var presentation = NotchPresentation(state: .ambient)
        presentation.handle(.pointerEntered, now: now, preferences: preferences)
        let later = now.addingTimeInterval(60)
        presentation.handle(.tick(later), now: later, preferences: preferences)
        XCTAssertEqual(presentation.state, .expanded)
    }

    /// The pointer is nowhere near the notch when an alert opens it, and every mouse move
    /// anywhere else on screen arrives here as `pointerExited`. Letting that close the
    /// panel would make an alert expansion last exactly until the user twitched the mouse.
    func testKeepsAnAlertExpansionOpenWhileThePointerMovesElsewhere() {
        XCTAssertEqual(send([.alert(.threshold(window(), 85)), .pointerExited]), .expanded)
    }

    /// A fullscreen app asked for the screen back. Nothing draws over it, and no stray
    /// pointer event may reopen the strip while it is gone.
    func testHidesWhileTheMenuBarIsHiddenAndIgnoresEventsUntilItReturns() {
        XCTAssertEqual(send([.menuBarVisibilityChanged(false)], from: .expanded), .hidden)
        XCTAssertEqual(send([.menuBarVisibilityChanged(false), .pointerEntered]), .hidden)
        XCTAssertEqual(send([.menuBarVisibilityChanged(false), .clicked]), .hidden)
        XCTAssertEqual(send([.menuBarVisibilityChanged(false), .alert(.threshold(window(), 85))]), .hidden)
        XCTAssertEqual(send([.menuBarVisibilityChanged(false), .menuBarVisibilityChanged(true)]), .ambient)
    }
}
