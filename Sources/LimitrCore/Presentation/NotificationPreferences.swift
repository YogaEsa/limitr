import Foundation

/// What the user wants to be told about, and when.
///
/// Deliberately small. The polling cadence is *not* here and should not be: the 180-second
/// Claude floor and its 429 backoff are correctness constraints, not taste, and a control
/// for them would only offer people a way to rate-limit themselves out of the data the app
/// exists to show.
public struct NotificationPreferences: Equatable, Sendable {

    /// Below 50 the alert fires on a window that has barely been touched; above 95 it
    /// arrives after the decision it was meant to inform. Neither end is a preference.
    public static let thresholdRange = 50...95

    /// The one "you are in the red" line. It drives the notification *and* the point at
    /// which the panel's bars turn red — the two must never disagree about what counts as
    /// trouble, which is why one number does both jobs.
    public let redThreshold: Int
    public let alertsOnRed: Bool
    public let alertsOnReset: Bool

    public init(redThreshold: Int = 85, alertsOnRed: Bool = true, alertsOnReset: Bool = true) {
        self.redThreshold = min(Self.thresholdRange.upperBound, max(Self.thresholdRange.lowerBound, redThreshold))
        self.alertsOnRed = alertsOnRed
        self.alertsOnReset = alertsOnReset
    }

    /// One changed setting, the rest carried over — and routed back through `init`, so
    /// editing a single field can never be a way around the clamp.
    public func with(redThreshold: Int? = nil, alertsOnRed: Bool? = nil, alertsOnReset: Bool? = nil) -> NotificationPreferences {
        NotificationPreferences(
            redThreshold: redThreshold ?? self.redThreshold,
            alertsOnRed: alertsOnRed ?? self.alertsOnRed,
            alertsOnReset: alertsOnReset ?? self.alertsOnReset
        )
    }

    private enum Key {
        static let threshold = "notificationRedThreshold"
        static let onRed = "notificationAlertsOnRed"
        static let onReset = "notificationAlertsOnReset"
    }

    /// Reads what is stored, falling back to the defaults for anything absent. The
    /// threshold is re-clamped on the way in: a value saved by a build with a different
    /// range must land inside this one rather than reinstating a setting the UI can no
    /// longer represent.
    public static func load(from defaults: UserDefaults = AppDefaultsDomain.store()) -> NotificationPreferences {
        NotificationPreferences(
            redThreshold: defaults.object(forKey: Key.threshold) as? Int ?? 85,
            alertsOnRed: defaults.object(forKey: Key.onRed) as? Bool ?? true,
            alertsOnReset: defaults.object(forKey: Key.onReset) as? Bool ?? true
        )
    }

    public func save(to defaults: UserDefaults = AppDefaultsDomain.store()) {
        defaults.set(redThreshold, forKey: Key.threshold)
        defaults.set(alertsOnRed, forKey: Key.onRed)
        defaults.set(alertsOnReset, forKey: Key.onReset)
    }
}
