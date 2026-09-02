import XCTest
@testable import LimitrCore

final class NotchGeometryTests: XCTestCase {

    /// The real measurements taken from a notched MacBook: a 1470pt-wide display, a
    /// 32pt menu bar, and auxiliary areas of 646 and 645 leaving 179pt of notch. 179 is
    /// not a number anyone would have guessed, which is the argument for deriving it.
    private func notched(width: CGFloat = 1470, originY: CGFloat = 0) -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: originY, width: width, height: 956),
            topInset: 32,
            auxiliary: ScreenMetrics.Auxiliary(left: 646, right: 645),
            menuBarIsVisible: true
        )
    }

    private func plain(width: CGFloat = 1920) -> ScreenMetrics {
        ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: width, height: 1080),
            topInset: 0,
            auxiliary: nil,
            menuBarIsVisible: true
        )
    }

    func testDerivesTheNotchWidthFromTheAreasEitherSideOfIt() {
        XCTAssertEqual(NotchGeometry.centerWidth(notched()), 179, accuracy: 0.001)
    }

    func testFallsBackToAVirtualPillOnAScreenWithNoNotch() {
        XCTAssertEqual(NotchGeometry.centerWidth(plain()), NotchGeometry.virtualPillWidth, accuracy: 0.001)
        XCTAssertFalse(plain().hasNotch)
        XCTAssertTrue(notched().hasNotch)
    }

    /// The ambient strip spans the notch plus one reading's width on each side, centred.
    func testCentresTheAmbientStripOverTheNotch() {
        let frame = NotchGeometry.frame(for: .ambient, on: notched())
        XCTAssertEqual(frame.width, 179 + NotchGeometry.readingWidth * 2, accuracy: 0.001)
        XCTAssertEqual(frame.midX, 735, accuracy: 0.001)
    }

    /// The strip is as tall as the menu bar it sits in, so the readings line up against
    /// it rather than against an invented height.
    func testMatchesTheMenuBarHeightWhenTheNotchIsTallerThanTheDefaultStrip() {
        XCTAssertEqual(NotchGeometry.frame(for: .ambient, on: notched()).height, 32, accuracy: 0.001)
        XCTAssertEqual(NotchGeometry.frame(for: .ambient, on: plain()).height,
                       NotchGeometry.ambientHeight, accuracy: 0.001)
    }

    /// Screen coordinates are bottom-left origin, so the top edge is `frame.maxY`. An
    /// external display is not at y = 0, which is what a hardcoded 0 would break.
    func testSitsFlushWithTheTopOfItsOwnScreen() {
        let metrics = notched(originY: 1080)
        let frame = NotchGeometry.frame(for: .ambient, on: metrics)
        XCTAssertEqual(frame.maxY, metrics.frame.maxY, accuracy: 0.001)
    }

    /// The band is the height of the menu bar, or the strip's own height where there is no
    /// notch to match.
    func testMeasuresTheBandTheNotchOccupies() {
        XCTAssertEqual(NotchGeometry.bandHeight(notched()), 32, accuracy: 0.001)
        XCTAssertEqual(NotchGeometry.bandHeight(plain()), NotchGeometry.ambientHeight, accuracy: 0.001)
    }

    /// The open panel is taller than its content by the band, because the top of that band
    /// is a hole in the display: a first row drawn there is invisible, not merely tight.
    func testGivesTheExpandedPanelItsContentPlusTheBandItMustNotDrawInto() {
        let frame = NotchGeometry.frame(for: .expanded, on: notched())
        XCTAssertEqual(frame.height, NotchGeometry.expandedSize.height + 32, accuracy: 0.001)
        XCTAssertEqual(frame.width, NotchGeometry.expandedSize.width, accuracy: 0.001)

        let plainFrame = NotchGeometry.frame(for: .expanded, on: plain())
        XCTAssertEqual(plainFrame.height,
                       NotchGeometry.expandedSize.height + NotchGeometry.ambientHeight,
                       accuracy: 0.001)
    }

    /// A projector or a small external display is narrower than the panel wants to be.
    /// Running off the edge is worse than being cramped.
    func testKeepsTheExpandedPanelInsideANarrowScreen() {
        let frame = NotchGeometry.frame(for: .expanded, on: plain(width: 300))
        XCTAssertEqual(frame.width, 300, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
    }

    /// The window never resizes; only what is drawn inside it does. Animating an
    /// `NSWindow`'s frame is what made the panel drop rather than grow — the window server
    /// steps the frame while SwiftUI swaps the content on its own clock, and the two do not
    /// agree. So the window is the union of every state's rect from the moment it appears,
    /// and the spring lives entirely in SwiftUI.
    func testGivesTheWindowOneFrameLargeEnoughForEveryState() {
        let metrics = notched()
        let window = NotchGeometry.windowFrame(on: metrics)

        for state: NotchState in [.ambient, .expanded] {
            XCTAssertTrue(window.contains(NotchGeometry.frame(for: state, on: metrics)),
                          "\(state) does not fit the window")
        }
        XCTAssertEqual(window.maxY, metrics.frame.maxY, accuracy: 0.001)
    }

    /// A screen narrower than the panel wants clamps the window too, or it would hang off
    /// the edge in every state at once.
    func testKeepsTheWindowInsideANarrowScreen() {
        let metrics = plain(width: 300)
        let window = NotchGeometry.windowFrame(on: metrics)

        XCTAssertEqual(window.width, 300, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(window.minX, 0)
    }

    /// The cards share the strip's window — two windows cannot be exchanged atomically
    /// against one SwiftUI spring, which is what put a blink in the middle of the gesture —
    /// so the window has to be told how tall the cards turned out to be.
    func testGivesTheCardsTheirOwnHeightInTheStripsColumn() {
        let metrics = notched()
        let open = NotchGeometry.frame(for: .expanded, on: metrics)
        let window = NotchGeometry.windowFrame(cardsHeight: 460, on: metrics)

        XCTAssertEqual(window.height, 460, accuracy: 0.001)
        XCTAssertEqual(window.maxY, metrics.frame.maxY, accuracy: 0.001)
        XCTAssertEqual(window.minX, open.minX, accuracy: 0.001)
        XCTAssertEqual(window.width, open.width, accuracy: 0.001)
    }

    /// The invariant the gesture rests on: the window is never smaller than what is drawn
    /// in it. The growth starts at the open strip's footprint, so a window that began below
    /// it would cut the first frames of the spring off — where a window that is too large
    /// only leaves transparent area behind.
    func testNeverGivesTheCardsAWindowSmallerThanTheOpenStrip() {
        let metrics = notched()
        let open = NotchGeometry.frame(for: .expanded, on: metrics)

        XCTAssertEqual(NotchGeometry.windowFrame(cardsHeight: 10, on: metrics).height,
                       open.height, accuracy: 0.001)
    }

    /// Nor taller than the screen it is drawn on.
    func testKeepsTheCardsWindowInsideTheScreen() {
        let metrics = notched()
        let window = NotchGeometry.windowFrame(cardsHeight: 4000, on: metrics)

        XCTAssertEqual(window.height, metrics.frame.height, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(window.minY, metrics.frame.minY)
    }

    func testHidesToAnEmptyFrame() {
        XCTAssertEqual(NotchGeometry.frame(for: .hidden, on: notched()), .zero)
    }
}
