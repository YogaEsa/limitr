import Foundation

/// Which single window speaks for a service, and for which account.
///
/// Extracted from `MenuBarSummary` because it now has three callers — the menu bar, the
/// notch, and whatever comes after. The rule and its reasoning belong in one place: two
/// surfaces disagreeing about how full a service is reads as a broken app, and the only
/// reliable defence is that they cannot disagree, because they ask the same function.
public enum WindowBinding {

    /// The fullest window, ties going to the shorter one so the answer never depends on
    /// provider ordering.
    ///
    /// Not the session window. One that has just rolled over reports 0% while the week
    /// behind it is half spent, and a 0% beside a service in daily use reads as a monitor
    /// that has stopped working rather than as capacity. It also assumed every account has
    /// a session window, which is false — a Codex account on a credit plan reports a
    /// single 30-day window and nothing shorter.
    public static func speaking(
        for source: UsageSource,
        in windows: [UsageWindow],
        accountID: String
    ) -> UsageWindow? {
        windows
            .filter { $0.source == source && $0.accountID == accountID }
            .max { ($0.usedPercent, -Double($0.windowMinutes)) < ($1.usedPercent, -Double($1.windowMinutes)) }
    }
}
