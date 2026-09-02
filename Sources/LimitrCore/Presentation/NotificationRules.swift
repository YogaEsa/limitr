import Foundation

public enum UsageAlert: Sendable, Equatable {
    case threshold(UsageWindow, Int)
    case reset(UsageWindow)
}

public struct NotificationRules: Sendable {
    private var previousResets: [String: Date] = [:]
    private var delivered: Set<String> = []
    private let preferences: NotificationPreferences

    /// The threshold this instance fires at, and the same number the panel tints its bars
    /// red at — a notification should never disagree with what the panel is showing.
    /// Earlier warnings at 70% and a second one at 95% were dropped: three notices per
    /// window per cycle read as spam, and the two extra ones carried no decision the red
    /// one does not already carry. Which is why it is one adjustable line rather than a
    /// ladder.
    public var redThreshold: Int { preferences.redThreshold }

    /// The starting point, and the value every surface used before any of this was
    /// settable.
    public static let defaultRedThreshold = 85

    public init(preferences: NotificationPreferences = NotificationPreferences()) {
        self.preferences = preferences
    }

    /// Emits at most two notifications per window per cycle: one when it first goes red,
    /// and one when the window rolls over and capacity comes back.
    public mutating func evaluate(_ windows: [UsageWindow]) -> [UsageAlert] {
        windows.compactMap { window in
            let key = window.id
            let resets = window.boundary
            defer { previousResets[key] = resets }
            guard previousResets[key] != resets else { return redAlert(window) }
            delivered = delivered.filter { !$0.hasPrefix("\(key)-") }
            if previousResets[key] == nil { return redAlert(window) }
            // Switching the red alert off must not switch this one off with it: they are
            // the two halves of a cycle and people want them independently.
            return preferences.alertsOnReset ? .reset(window) : nil
        }
    }

    private mutating func redAlert(_ window: UsageWindow) -> UsageAlert? {
        // `UsageWindow.boundary`, not the raw instant: a raw one would make the dedupe key
        // differ on every poll and the alert would re-fire indefinitely.
        guard preferences.alertsOnRed else { return nil }
        let key = "\(window.id)-\(window.boundary.timeIntervalSince1970)-\(redThreshold)"
        guard window.usedPercent >= Double(redThreshold), delivered.insert(key).inserted else { return nil }
        return .threshold(window, redThreshold)
    }
}
