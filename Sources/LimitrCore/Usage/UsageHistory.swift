import Foundation

/// Recent readings per window, so the panel can say which way a window is moving and how
/// fast it is getting there.
///
/// A value type held by the app rather than an actor, because the panel asks for a trend
/// from inside `body` — once a second, under its `TimelineView`. Making that call `await`
/// would put the answer a frame behind the countdown it sits beside. The file it is loaded
/// from and saved to is `UsageHistoryStore`'s job, and that part is off the main thread.
///
/// The memory is short on purpose. Nothing here is a usage log: the only questions it
/// answers are "how much has this window taken on lately" and "when would it be full at
/// that rate", and both are about the last hour or so. Keeping more would mean rewriting a
/// steadily larger file on every poll to answer the same two questions.
public struct UsageHistory: Equatable, Sendable, Codable {

    /// How far back readings are kept. Long enough to steady a rate against one slow hour,
    /// short enough that yesterday's pace never colours today's.
    public static let memory: TimeInterval = 90 * 60

    /// The span a trend needs before it describes usage rather than the poll clock. Shared
    /// with `BurnRate` so the chip and the projection appear together.
    private static let minimumSpan = BurnRate.minimumSpan

    private var storage: [String: [UsageSample]] = [:]

    public init() {}

    public var isEmpty: Bool { storage.values.allSatisfy(\.isEmpty) }

    public func samples(for window: UsageWindow) -> [UsageSample] {
        (storage[window.id] ?? []).filter { $0.boundary == window.boundary }
    }

    /// Adds one reading per window and forgets everything that has aged out or belongs to
    /// a window that has since rolled over.
    public mutating func record(_ windows: [UsageWindow], now: Date) {
        let cutoff = now.addingTimeInterval(-Self.memory)
        for window in windows {
            let boundary = window.boundary
            var kept = (storage[window.id] ?? []).filter { $0.boundary == boundary && $0.at >= cutoff }
            kept.append(UsageSample(windowID: window.id, boundary: boundary, at: now, percent: window.usedPercent))
            storage[window.id] = kept
        }
    }

    /// Percentage points the window has taken on since the oldest reading still held.
    ///
    /// - Returns: nil before there is enough history to mean anything, and for a change too
    ///   small to be worth a chip.
    public func trend(for window: UsageWindow, now: Date) -> Double? {
        let kept = samples(for: window).sorted { $0.at < $1.at }
        guard let oldest = kept.first, now.timeIntervalSince(oldest.at) >= Self.minimumSpan else { return nil }
        let change = window.usedPercent - oldest.percent
        return abs(change) < 0.5 ? nil : change
    }

    /// How fast the window is filling and when it would be full, or nil when the honest
    /// answer is silence. See `BurnRate`.
    public func burnRate(for window: UsageWindow, now: Date) -> BurnRate? {
        BurnRate.project(samples: samples(for: window), window: window, now: now)
    }
}

/// Where a `UsageHistory` lives between launches.
///
/// Separate from the history itself so the file work can be done off the main thread while
/// the panel keeps reading the value type synchronously.
public enum UsageHistoryStore {

    /// - Returns: an empty history for anything that cannot be read or parsed. A history
    ///   file is a convenience, never a reason to refuse to start — the worst case is the
    ///   trend chip waiting ten minutes, exactly as it did before any of this was saved.
    public static func load(from url: URL) -> UsageHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder.history.decode(UsageHistory.self, from: data) else {
            return UsageHistory()
        }
        return history
    }

    public static func save(_ history: UsageHistory, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: the file is rewritten on every poll, and a half-written one read at the
        // next launch would throw the history away for no reason.
        try JSONEncoder.history.encode(history).write(to: url, options: .atomic)
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
