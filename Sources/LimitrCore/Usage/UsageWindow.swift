import Foundation

public enum UsageSource: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
}

public enum Staleness: String, Codable, Sendable {
    case fresh
    case stale
    case estimated
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int
    public let totalTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0, totalTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case totalTokens = "total_tokens"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try values.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cachedInputTokens = try values.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        totalTokens = try values.decodeIfPresent(Int.self, forKey: .totalTokens) ?? inputTokens + outputTokens
    }
}


/// Pay-as-you-go spend past the plan's included capacity, when the account has that
/// facility switched on.
///
/// Deliberately not a `UsageWindow`: the endpoint reports no reset instant for it, and a
/// window whose `resetsAt` had to be invented would put a countdown on the panel that
/// nothing backs. `utilization` is the only field with an unambiguous unit — the credit
/// figures are carried through for callers that know what to do with them, but Limitr's
/// own UI reads the percentage.
public struct ExtraUsage: Codable, Equatable, Sendable {
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    public init(monthlyLimit: Double?, usedCredits: Double?, utilization: Double?) {
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }

    enum CodingKeys: String, CodingKey {
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

public struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    public let source: UsageSource
    public let accountID: String
    public let accountName: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date
    public let windowMinutes: Int
    public let staleness: Staleness
    public let tokenUsage: TokenUsage?

    public var id: String { "\(source.rawValue)-\(accountID)-\(label)" }

    /// The reset instant, rounded to the minute — the unit in which two readings can be
    /// said to describe the same window.
    ///
    /// Providers do not report a stable instant: the Claude endpoint has been observed
    /// returning 07:00:00.322552Z and 06:59:59.855010Z for one boundary on consecutive
    /// polls. Compared exactly, every poll looks like a fresh window, which throws away
    /// notification state and sample history alike. Real rollovers move by hours.
    public var boundary: Date {
        Date(timeIntervalSince1970: (resetsAt.timeIntervalSince1970 / 60).rounded() * 60)
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public var displayLabel: String {
        switch (source, label) {
        case (.claude, "five_hour"): "5-hour session"
        case (.claude, "seven_day"): "Weekly limit"
        case (.claude, "seven_day_opus"): "Weekly Opus limit"
        case (.claude, "seven_day_sonnet"): "Weekly Sonnet limit"
        case (.codex, "primary"): windowMinutes <= 300 ? "5-hour session" : "Primary limit"
        case (.codex, "secondary"): windowMinutes >= 10_000 ? "Weekly limit" : "Secondary limit"
        default: label.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public init(source: UsageSource, accountID: String = "default", accountName: String = "Default", label: String, usedPercent: Double, resetsAt: Date, windowMinutes: Int, staleness: Staleness, tokenUsage: TokenUsage? = nil) {
        self.source = source
        self.accountID = accountID
        self.accountName = accountName
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.staleness = staleness
        self.tokenUsage = tokenUsage
    }

    public func withTokenUsage(_ tokenUsage: TokenUsage?) -> UsageWindow {
        UsageWindow(source: source, accountID: accountID, accountName: accountName, label: label,
                    usedPercent: usedPercent, resetsAt: resetsAt, windowMinutes: windowMinutes,
                    staleness: staleness, tokenUsage: tokenUsage)
    }
}

public struct UsageSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let windows: [UsageWindow]
    public let extraUsage: ExtraUsage?

    public init(generatedAt: Date = .now, windows: [UsageWindow], extraUsage: ExtraUsage? = nil) {
        self.generatedAt = generatedAt
        self.windows = windows.sorted { $0.id < $1.id }
        self.extraUsage = extraUsage
    }
}
