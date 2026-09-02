import Foundation

/// What one model charges, per million tokens, in USD.
public struct ModelPricing: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public func cost(_ totals: TokenTotals) -> Double {
        (Double(totals.inputTokens) * input
            + Double(totals.outputTokens) * output
            + Double(totals.cacheWriteTokens) * cacheWrite
            + Double(totals.cacheReadTokens) * cacheRead) / 1_000_000
    }
}

/// List prices for the models the two CLIs actually route to.
///
/// The figure this produces is notional, and the UI has to say so: on a subscription
/// nothing here is billed per token. What it answers is "what would this month have cost
/// at API list prices", which is the only version of the question Limitr can answer from
/// a transcript.
///
/// Two deliberate limits. Cache writes are priced at the 5-minute rate (1.25x input),
/// because the transcripts record one `cache_creation_input_tokens` figure and do not say
/// which of the two durations it was; the 1-hour rate is 2x, so a heavy 1-hour user is
/// undercounted rather than overcounted. And promotional rates are ignored in favour of
/// list — a promotion expires on a date this table has no way to notice, and a price that
/// silently goes stale is worse than one that is knowingly conservative.
public enum ModelPrices {

    /// Anthropic: base input, output, 5-minute cache write (1.25x), cache hit (0.1x).
    /// OpenAI: input, output, and a cache hit at 0.1x — there is no separate charge for a
    /// cache write, so those tokens are priced as ordinary input.
    private static let table: [String: ModelPricing] = [
        "claude-fable-5":    ModelPricing(input: 10, output: 50, cacheWrite: 12.50, cacheRead: 1.00),
        "claude-mythos-5":   ModelPricing(input: 10, output: 50, cacheWrite: 12.50, cacheRead: 1.00),
        "claude-opus-5":     ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-8":   ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-7":   ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-6":   ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-5":   ModelPricing(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.50),
        "claude-opus-4-1":   ModelPricing(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-opus-4":     ModelPricing(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.50),
        "claude-sonnet-5":   ModelPricing(input: 2, output: 10, cacheWrite: 2.50, cacheRead: 0.20),
        "claude-sonnet-4-6": ModelPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4-5": ModelPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-sonnet-4":   ModelPricing(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.30),
        "claude-haiku-4-5":  ModelPricing(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.10),
        "claude-haiku-3-5":  ModelPricing(input: 0.80, output: 4, cacheWrite: 1.00, cacheRead: 0.08),
        "gpt-5.6-sol":       ModelPricing(input: 5, output: 30, cacheWrite: 5, cacheRead: 0.50),
        "gpt-5.6-terra":     ModelPricing(input: 2, output: 12, cacheWrite: 2, cacheRead: 0.20),
        "gpt-5.6-luna":      ModelPricing(input: 0.20, output: 1.20, cacheWrite: 0.20, cacheRead: 0.02)
    ]

    /// Longest first, so `claude-opus-4-8` is not answered by the `claude-opus-4` row — a
    /// retired model at three times the price.
    private static let keysByLength = table.keys.sorted { $0.count > $1.count }

    /// - Returns: nil for a model the table does not carry. Deliberately not zero: the
    ///   CLIs route to models Limitr has never heard of, and a silent zero understates a
    ///   total that is presented as money. The caller reports the unpriced share instead.
    public static func pricing(for model: String) -> ModelPricing? {
        // Platform prefixes (`anthropic.claude-opus-5`) and dated snapshots
        // (`claude-opus-4-5-20251101`) name the same model at the same price.
        let normalized = model.lowercased()
        return keysByLength.first { normalized.contains($0) }.map { table[$0]! }
    }

    public static func cost(model: String, totals: TokenTotals) -> Double? {
        pricing(for: model)?.cost(totals)
    }
}
