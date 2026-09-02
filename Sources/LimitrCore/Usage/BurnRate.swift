import Foundation

/// One reading of how full a window was at a moment.
///
/// Carries the window's own reset instant rather than only its identity, because a window
/// keeps its id across a rollover: without the boundary, the readings from before a reset
/// and after it are indistinguishable, and averaging across them reads as a collapse in
/// usage that never happened.
public struct UsageSample: Codable, Equatable, Sendable {
    public let windowID: String
    public let boundary: Date
    public let at: Date
    public let percent: Double

    public init(windowID: String, boundary: Date, at: Date, percent: Double) {
        self.windowID = windowID
        self.boundary = boundary
        self.at = at
        self.percent = percent
    }
}

/// How fast a window is filling, and when it would be full at that pace.
///
/// The question `Pace` cannot answer. `Pace` compares spend against elapsed time and says
/// whether that ratio looks comfortable, which is enough to colour a card; it cannot say
/// *when*, and "you have about forty minutes" is the sentence that changes what someone
/// does next.
public struct BurnRate: Equatable, Sendable {
    public let percentPerHour: Double
    /// When the window would reach 100% at this rate. Always before the window's own
    /// reset — see `project`.
    public let exhaustedAt: Date

    /// The span a projection needs before it describes usage rather than the poll clock.
    ///
    /// Matches the trend chip's own floor, so the two cannot appear at different moments
    /// and imply they are measuring different things.
    static let minimumSpan: TimeInterval = 10 * 60

    /// - Returns: nil whenever the honest answer is silence — too little history, a window
    ///   that is not filling, one that is already full, or one whose capacity comes back
    ///   before the pace could use it up.
    public static func project(samples: [UsageSample], window: UsageWindow, now: Date) -> BurnRate? {
        let relevant = samples
            .filter { $0.windowID == window.id && $0.boundary == window.boundary }
            .sorted { $0.at < $1.at }
        guard let oldest = relevant.first, let newest = relevant.last else { return nil }

        let span = newest.at.timeIntervalSince(oldest.at)
        guard span >= minimumSpan else { return nil }

        let percentPerHour = (newest.percent - oldest.percent) / (span / 3_600)
        guard percentPerHour > 0 else { return nil }

        // From what the provider reports now, not from the newest sample: the reading is
        // the authority and a sample may be a poll behind it.
        let remaining = 100 - window.usedPercent
        guard remaining > 0 else { return nil }

        let exhaustedAt = now.addingTimeInterval(remaining / percentPerHour * 3_600)
        // Past the rollover the projection is describing capacity that comes back, so
        // there is no wall to count down to.
        guard exhaustedAt < window.resetsAt else { return nil }

        return BurnRate(percentPerHour: percentPerHour, exhaustedAt: exhaustedAt)
    }
}
