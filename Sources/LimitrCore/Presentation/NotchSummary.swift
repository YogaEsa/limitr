import Foundation

/// What the notch draws when it is open: one row per service, for the account that
/// service is standing on.
///
/// It reaches the window through `WindowBinding`, which is the call the menu bar makes,
/// and it takes the `UsageHistory` rather than a pre-computed trend and projection —
/// `UsageHistory.minimumSpan` and `BurnRate.minimumSpan` are deliberately the same ten
/// minutes, and a caller assembling rows by hand is where those two would drift apart.
public struct NotchSummary: Equatable, Sendable {

    public struct Row: Equatable, Sendable, Identifiable {
        public let source: UsageSource
        public let window: UsageWindow
        /// Percentage points taken on since the oldest reading still held. Nil until
        /// there is enough history to mean anything.
        public let trend: Double?
        /// How fast it is filling and when it would be full, or nil wherever
        /// `BurnRate.project` decides silence is the honest answer.
        public let burn: BurnRate?
        public let isWorking: Bool

        public var id: UsageSource { source }

        public init(source: UsageSource, window: UsageWindow, trend: Double?, burn: BurnRate?, isWorking: Bool) {
            self.source = source
            self.window = window
            self.trend = trend
            self.burn = burn
            self.isWorking = isWorking
        }
    }

    public let rows: [Row]

    public var isEmpty: Bool { rows.isEmpty }

    /// Claude before Codex, matching the panel's service tabs.
    private static let order: [UsageSource] = [.claude, .codex]

    /// - Parameter accountIDs: the account each service is standing on. A service missing
    ///   from this map has nothing to report.
    public static func make(
        windows: [UsageWindow],
        accountIDs: [UsageSource: String],
        history: UsageHistory,
        activity: ActivityPulse,
        now: Date
    ) -> NotchSummary {
        NotchSummary(rows: order.compactMap { source in
            guard let accountID = accountIDs[source],
                  let window = WindowBinding.speaking(for: source, in: windows, accountID: accountID)
            else { return nil }
            return Row(
                source: source,
                window: window,
                trend: history.trend(for: window, now: now),
                burn: history.burnRate(for: window, now: now),
                // The service-level answer: this row is one bar, and any of that
                // service's accounts working is enough to light it.
                isWorking: activity.isActive(source: source, now: now)
            )
        })
    }
}
