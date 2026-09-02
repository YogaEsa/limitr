import CoreGraphics
import Foundation

/// How much of the notch layer is showing.
///
/// Shared vocabulary: `NotchGeometry` turns a state into a window frame, and
/// `NotchPresentation` decides which state we are in.
public enum NotchState: Equatable, Sendable {
    case hidden
    case ambient
    case expanded
}

/// One screen, measured.
///
/// Deliberately not an `NSScreen`: every rule below is arithmetic, and arithmetic that
/// takes an `NSScreen` can only be exercised on the Mac it was written on — which is
/// precisely the Mac whose geometry is least likely to be the broken one.
public struct ScreenMetrics: Equatable, Sendable {

    /// The usable menu-bar areas either side of the notch, by width.
    ///
    /// A named type rather than a tuple: a tuple cannot conform to a protocol, so a tuple
    /// property would silently block the synthesis of `Equatable` on `ScreenMetrics`.
    public struct Auxiliary: Equatable, Sendable {
        public let left: CGFloat
        public let right: CGFloat

        public init(left: CGFloat, right: CGFloat) {
            self.left = left
            self.right = right
        }
    }

    public let frame: CGRect
    /// `NSScreen.safeAreaInsets.top`. Zero on a screen with no notch.
    public let topInset: CGFloat
    /// Nil on a screen with no notch.
    public let auxiliary: Auxiliary?
    public let menuBarIsVisible: Bool

    public init(frame: CGRect, topInset: CGFloat, auxiliary: Auxiliary?, menuBarIsVisible: Bool) {
        self.frame = frame
        self.topInset = topInset
        self.auxiliary = auxiliary
        self.menuBarIsVisible = menuBarIsVisible
    }

    public var hasNotch: Bool { topInset > 0 && auxiliary != nil }
}

/// Where the notch panel goes — on a notched Mac, and on every other one.
public enum NotchGeometry {

    /// The width the readings are laid out around on a screen with no notch. Close enough
    /// to a real one that the same layout reads correctly, so the drawn result differs
    /// only in whether there is a physical hole behind the middle.
    public static let virtualPillWidth: CGFloat = 200
    /// The strip's height where there is no menu-bar height to match.
    public static let ambientHeight: CGFloat = 24
    /// How far one service's reading extends beyond the centre, on its own side.
    public static let readingWidth: CGFloat = 62
    /// The open panel's size.
    ///
    /// The width is the monitoring panel's own, so the open notch and the cards it hands
    /// off to are exactly as wide as each other and the click reads as the same surface
    /// growing rather than one being swapped for another. It is also what makes the
    /// opening *widen* visibly — from 303 points to 358 — instead of only dropping.
    ///
    /// The height is deliberately generous: the slab hugs its rows and leaves the rest of
    /// the window transparent, so height that goes unused costs nothing, while height that
    /// ran short would clip the hover region away from the last row.
    public static let expandedSize = CGSize(width: 358, height: 168)

    /// The height of the band the notch — or the pill standing in for it — occupies.
    ///
    /// The ambient strip is exactly this tall, and the open panel has to keep it clear:
    /// on a notched Mac the top of that band is a physical hole, so anything drawn there
    /// is not merely cramped, it is invisible. The open panel's first row was landing
    /// behind the notch for exactly this reason.
    public static func bandHeight(_ metrics: ScreenMetrics) -> CGFloat {
        max(ambientHeight, metrics.topInset)
    }

    /// The width of the notch itself, derived from the areas either side rather than from
    /// a table of models. A measured MacBook returned 646 and 645 against a 1470pt
    /// display — a 179pt notch, which is not a number worth trying to tabulate.
    public static func centerWidth(_ metrics: ScreenMetrics) -> CGFloat {
        guard let auxiliary = metrics.auxiliary else { return virtualPillWidth }
        let notch = metrics.frame.width - auxiliary.left - auxiliary.right
        return notch > 0 ? notch : virtualPillWidth
    }

    /// The panel's window frame: one rect, large enough for every state, held for the
    /// life of the layer.
    ///
    /// The window does not resize — only what is drawn inside it does. Animating an
    /// `NSWindow`'s frame is what made the panel read as dropping rather than growing: the
    /// window server steps the frame on its own timing while SwiftUI swaps the content on
    /// another, and the two never agreed. Given a constant window the whole gesture is one
    /// SwiftUI spring, and the unused area simply is not drawn — an unfilled window is
    /// transparent.
    public static func windowFrame(on metrics: ScreenMetrics) -> CGRect {
        frame(for: .ambient, on: metrics).union(frame(for: .expanded, on: metrics))
    }

    /// The window while the cards are open, for cards that asked for `cardsHeight`.
    ///
    /// The cards live in the same window as the strip — the growth is one SwiftUI spring on
    /// one slab, and two windows cannot be exchanged atomically against that spring — but
    /// they need a taller window than the strip does, and how much taller is the cards'
    /// own business: it depends on how many accounts are connected and what each is
    /// reporting. So the height is measured from the view and passed in.
    ///
    /// Never smaller than the open strip, and never taller than the screen. The floor is
    /// the invariant the whole gesture rests on: **the window is never smaller than what is
    /// drawn in it.** The growth starts at the open strip's footprint, so a window that
    /// began below it would clip the first frames of the spring — and unlike a window that
    /// is too large, which merely leaves transparent area behind, a window that is too
    /// small cuts the drawing off.
    public static func windowFrame(cardsHeight: CGFloat, on metrics: ScreenMetrics) -> CGRect {
        let open = frame(for: .expanded, on: metrics)
        let height = min(metrics.frame.height, max(cardsHeight, open.height))
        return CGRect(
            x: open.minX,
            y: metrics.frame.maxY - height,
            width: open.width,
            height: height
        )
    }

    /// What is *drawn* for a state, in screen coordinates (bottom-left origin), clamped so
    /// it never runs off a display narrower than it wants to be. This is the rect the
    /// pointer is tested against, and the size the slab animates to — no longer the
    /// window's own frame.
    public static func frame(for state: NotchState, on metrics: ScreenMetrics) -> CGRect {
        guard state != .hidden else { return .zero }

        let strip = centerWidth(metrics) + readingWidth * 2
        let width: CGFloat
        let height: CGFloat
        switch state {
        case .hidden:
            return .zero
        case .ambient:
            width = min(metrics.frame.width, strip)
            height = bandHeight(metrics)
        case .expanded:
            width = min(metrics.frame.width, max(expandedSize.width, strip))
            // The content's own height plus the band it must not draw into.
            height = expandedSize.height + bandHeight(metrics)
        }

        return CGRect(
            x: metrics.frame.minX + (metrics.frame.width - width) / 2,
            y: metrics.frame.maxY - height,
            width: width,
            height: height
        )
    }
}
