import Foundation

/// How much of the notch layer is showing, and what moves it.
///
/// A pure state machine for the same reason `NotificationRules` is one: every rule here is
/// a decision about when to put something in front of someone, and those are worth being
/// able to test without a screen, a pointer, or a four-second wait.
public struct NotchPresentation: Equatable, Sendable {

    /// How long an alert holds the panel open. Long enough to read two rows, short enough
    /// that it is gone before it becomes something to dismiss.
    public static let alertHold: TimeInterval = 4

    public private(set) var state: NotchState
    /// Set only for an expansion the app decided on. A hover carries no deadline — the
    /// pointer opened it and the pointer closes it — and it is also what tells
    /// `pointerExited` which of the two kinds of expansion it is looking at.
    private var autoCollapseAt: Date?
    private var menuBarIsVisible = true

    public enum Event: Equatable, Sendable {
        case pointerEntered
        case pointerExited
        case clicked
        case alert(UsageAlert)
        case menuBarVisibilityChanged(Bool)
        case tick(Date)
    }

    public init(state: NotchState = .ambient) {
        self.state = state
    }

    public mutating func handle(_ event: Event, now: Date, preferences: NotificationPreferences) {
        if case .menuBarVisibilityChanged(let visible) = event {
            menuBarIsVisible = visible
            state = visible ? .ambient : .hidden
            autoCollapseAt = nil
            return
        }

        // While a fullscreen app has the screen, nothing here draws and nothing here
        // listens. A pointer crossing the top edge of a fullscreen video is not a request
        // to put a panel over it.
        guard menuBarIsVisible else { return }

        switch event {
        case .pointerEntered:
            if state == .ambient { state = .expanded }
        case .pointerExited:
            // Only a hover expansion answers to the pointer. The pointer is nowhere near
            // the notch when an alert opens it, and every mouse move anywhere else on
            // screen arrives here as `pointerExited` — so closing on it indiscriminately
            // would make an alert expansion last until the user twitched the mouse.
            if state == .expanded, autoCollapseAt == nil { state = .ambient }
        case .clicked:
            state = .ambient
            autoCollapseAt = nil
        case .alert(let alert):
            guard wants(alert, preferences) else { return }
            state = .expanded
            autoCollapseAt = now.addingTimeInterval(Self.alertHold)
        case .tick(let at):
            guard let deadline = autoCollapseAt, at >= deadline else { return }
            state = .ambient
            autoCollapseAt = nil
        case .menuBarVisibilityChanged:
            break   // handled above
        }
    }

    /// The two switches govern their own halves independently — they are the two ends of a
    /// cycle and people want them separately, which is why `NotificationRules` reads them
    /// separately too. Someone who declined a notification must not be handed a panel
    /// dropping out of the ceiling in its place.
    private func wants(_ alert: UsageAlert, _ preferences: NotificationPreferences) -> Bool {
        switch alert {
        case .threshold: preferences.alertsOnRed
        case .reset: preferences.alertsOnReset
        }
    }
}
