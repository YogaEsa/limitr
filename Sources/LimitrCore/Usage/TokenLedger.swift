import Foundation

/// One bucket of token spend, split the way both CLIs bill it: fresh input, generated
/// output, and the two halves of the prompt cache.
public struct TokenTotals: Equatable, Sendable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheWriteTokens: Int
    public var cacheReadTokens: Int

    public static let zero = TokenTotals()

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var cacheTokens: Int { cacheWriteTokens + cacheReadTokens }
    public var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
    public var isEmpty: Bool { totalTokens == 0 }

    public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    public static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }
}

public enum TokenPeriod: String, CaseIterable, Sendable, Codable {
    case today
    case sevenDays
    case thisMonth
    case thirtyDays

    public var title: String {
        switch self {
        case .today: "Today"
        case .sevenDays: "Last 7 days"
        case .thisMonth: "This month"
        case .thirtyDays: "Last 30 days"
        }
    }
}

public struct PeriodTotals: Identifiable, Equatable, Sendable {
    public let period: TokenPeriod
    public let totals: TokenTotals
    public var id: TokenPeriod { period }
}

/// One model's slice of the trailing 30 days.
public struct ModelShare: Identifiable, Equatable, Sendable {
    public let model: String
    public let totals: TokenTotals
    /// 0...1 of the 30-day total.
    public let share: Double
    public var id: String { model }

    public init(model: String, totals: TokenTotals, share: Double) {
        self.model = model
        self.totals = totals
        self.share = share
    }
}

/// What a period's spend would have cost at list prices, and how much of it could not be
/// priced at all.
public struct EstimatedCost: Equatable, Sendable {
    public let dollars: Double
    /// Tokens spent on models `ModelPrices` does not carry. Non-zero means `dollars` is a
    /// floor rather than a total, and the UI has to say so — quietly rolling these in at
    /// zero would present an undercount as a complete figure.
    public let unpricedTokens: Int

    public var isPartial: Bool { unpricedTokens > 0 }

    public init(dollars: Double, unpricedTokens: Int) {
        self.dollars = dollars
        self.unpricedTokens = unpricedTokens
    }
}

public struct TokenUsageReport: Equatable, Sendable {
    /// Per model, per period. Kept split rather than pre-summed because pricing needs the
    /// split: a period's combined totals priced at any one model's rates would be wrong by
    /// the ratio between them, which is nearly 3x between Opus and Sonnet.
    private let periods: [TokenPeriod: [String: TokenTotals]]
    public let models: [ModelShare]
    public let lastActivity: Date?

    public init(periods: [TokenPeriod: [String: TokenTotals]], models: [ModelShare], lastActivity: Date?) {
        self.periods = periods
        self.models = models
        self.lastActivity = lastActivity
    }

    public static let empty = TokenUsageReport(periods: [:], models: [], lastActivity: nil)

    public func totals(for period: TokenPeriod) -> TokenTotals {
        (periods[period] ?? [:]).values.reduce(TokenTotals.zero, +)
    }

    public func estimatedCost(for period: TokenPeriod) -> EstimatedCost {
        var dollars = 0.0
        var unpriced = 0
        for (model, totals) in periods[period] ?? [:] {
            if let cost = ModelPrices.cost(model: model, totals: totals) { dollars += cost }
            else { unpriced += totals.totalTokens }
        }
        return EstimatedCost(dollars: dollars, unpricedTokens: unpriced)
    }

    public var rows: [PeriodTotals] {
        TokenPeriod.allCases.map { PeriodTotals(period: $0, totals: totals(for: $0)) }
    }

    public var isEmpty: Bool { totals(for: .thirtyDays).isEmpty }
}

/// Day-bucketed token spend, keyed by calendar day and then by model.
///
/// Buckets rather than raw entries because every period the panel shows is a rolling
/// window over whole days: keeping days means a rescan never has to re-read a transcript
/// it has already consumed, and memory stays proportional to `retainedDays` instead of to
/// how much the user has used the CLIs.
struct TokenLedger: Equatable, Sendable {
    /// Days kept in memory. Longer than the 30-day report window so `thisMonth` is still
    /// complete on the 31st of a month, with slack for transcripts whose clocks disagree.
    static let retainedDays = 40

    private var days: [Date: [String: TokenTotals]] = [:]
    /// Dedupe keys per day. Held alongside the buckets so pruning a day drops its keys too,
    /// which is what stops the set from growing without bound.
    private var seen: [Date: Set<String>] = [:]
    private(set) var lastActivity: Date?

    /// - Parameter key: a stable identifier for the turn, or nil when the caller already
    ///   guarantees each entry is offered exactly once.
    mutating func add(model: String, totals: TokenTotals, at timestamp: Date, key: String?, calendar: Calendar) {
        let day = calendar.startOfDay(for: timestamp)
        if let key, !seen[day, default: []].insert(key).inserted { return }
        days[day, default: [:]][model, default: .zero] += totals
        if let current = lastActivity { lastActivity = max(current, timestamp) } else { lastActivity = timestamp }
    }

    mutating func prune(now: Date, calendar: Calendar) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retainedDays, to: calendar.startOfDay(for: now)) else { return }
        days = days.filter { $0.key >= cutoff }
        seen = seen.filter { $0.key >= cutoff }
    }

    func report(now: Date, calendar: Calendar) -> TokenUsageReport {
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
        let starts: [TokenPeriod: Date] = [
            .today: today,
            .sevenDays: calendar.date(byAdding: .day, value: -6, to: today) ?? today,
            .thisMonth: monthStart,
            .thirtyDays: calendar.date(byAdding: .day, value: -29, to: today) ?? today
        ]

        var periods: [TokenPeriod: [String: TokenTotals]] = [:]
        var byModel: [String: TokenTotals] = [:]
        for (day, models) in days {
            for (period, start) in starts where day >= start {
                for (model, totals) in models { periods[period, default: [:]][model, default: .zero] += totals }
            }
            guard let thirtyDayStart = starts[.thirtyDays], day >= thirtyDayStart else { continue }
            for (model, totals) in models { byModel[model, default: .zero] += totals }
        }

        let overall = Double((periods[.thirtyDays] ?? [:]).values.reduce(TokenTotals.zero, +).totalTokens)
        let models = byModel
            .map { ModelShare(model: $0.key, totals: $0.value, share: overall > 0 ? Double($0.value.totalTokens) / overall : 0) }
            .sorted {
                $0.totals.totalTokens == $1.totals.totalTokens
                    ? $0.model < $1.model
                    : $0.totals.totalTokens > $1.totals.totalTokens
            }

        return TokenUsageReport(periods: periods, models: models, lastActivity: lastActivity)
    }
}
