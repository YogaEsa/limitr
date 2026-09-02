import Foundation

/// What the menu bar itself shows, without opening the panel.
///
/// A monitor that has to be clicked before it reports anything has given up the one thing
/// its position on screen is for, so this is the whole reading condensed to what fits: one
/// number per service, for the account that service is standing on.
///
/// Pure and in Core rather than computed in the view, because the rules it encodes — which
/// window speaks for a service, which account speaks for it, what counts as live — are the
/// same rules the panel follows, and the two disagreeing is exactly the bug this is here
/// to prevent.
public struct MenuBarSummary: Equatable, Sendable {

    public struct Item: Equatable, Sendable, Identifiable {
        public let source: UsageSource
        public let percent: Double
        /// False for a window that is stale or estimated. The bar must not present either
        /// as a current reading.
        public let isLive: Bool

        public var id: UsageSource { source }

        public init(source: UsageSource, percent: Double, isLive: Bool) {
            self.source = source
            self.percent = percent
            self.isLive = isLive
        }
    }

    public let items: [Item]

    public var isEmpty: Bool { items.isEmpty }

    /// The fullest window on show, which is what the icon's colour tracks: an average
    /// would let one service sitting at 95% disappear behind another sitting at 5%.
    public var peakPercent: Double? { items.map(\.percent).max() }

    /// Claude before Codex, matching the panel's service tabs.
    private static let order: [UsageSource] = [.claude, .codex]

    /// - Parameter accountIDs: the account each service is standing on, keyed by service.
    ///   A service missing from this map has nothing to report.
    public static func make(windows: [UsageWindow], accountIDs: [UsageSource: String]) -> MenuBarSummary {
        MenuBarSummary(items: order.compactMap { source in
            guard let accountID = accountIDs[source] else { return nil }
            // See `WindowBinding.speaking` for which window that is, and why it is not
            // the session window. The notch asks the same function, which is what stops
            // the two surfaces from ever disagreeing about how full a service is.
            guard let binding = WindowBinding.speaking(for: source, in: windows, accountID: accountID)
            else { return nil }
            return Item(source: source, percent: binding.usedPercent, isLive: binding.staleness == .fresh)
        })
    }
}
