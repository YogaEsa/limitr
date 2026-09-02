import XCTest
@testable import LimitrCore

final class ModelPricingTests: XCTestCase {

    private let oneMillion = 1_000_000

    func testPricesOpusFiveAtItsPublishedRates() throws {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: oneMillion)

        let cost = try XCTUnwrap(ModelPrices.cost(model: "claude-opus-5", totals: totals))

        XCTAssertEqual(cost, 30, accuracy: 0.0001)
    }

    /// A cache write is 1.25x base input and a hit is 0.1x. Both are the majority of what
    /// a coding session spends, so pricing them as ordinary input would be wrong by more
    /// than the figure is worth.
    func testPricesCacheWritesAndHitsAtTheirOwnRates() throws {
        let totals = TokenTotals(cacheWriteTokens: oneMillion, cacheReadTokens: oneMillion)

        let cost = try XCTUnwrap(ModelPrices.cost(model: "claude-opus-5", totals: totals))

        XCTAssertEqual(cost, 6.25 + 0.50, accuracy: 0.0001)
    }

    func testPricesSonnetBelowOpus() throws {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: oneMillion)

        let opus = try XCTUnwrap(ModelPrices.cost(model: "claude-opus-5", totals: totals))
        let sonnet = try XCTUnwrap(ModelPrices.cost(model: "claude-sonnet-5", totals: totals))

        XCTAssertEqual(sonnet, 12, accuracy: 0.0001)
        XCTAssertLessThan(sonnet, opus)
    }

    func testPricesTheCodexModels() throws {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: oneMillion)

        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "gpt-5.6-sol", totals: totals)), 35, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "gpt-5.6-terra", totals: totals)), 14, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "gpt-5.6-luna", totals: totals)), 1.40, accuracy: 0.0001)
    }

    /// OpenAI bills a cache hit at a tenth of input and does not charge separately for the
    /// write, so those tokens are priced as ordinary input.
    func testPricesACodexCacheHitAtATenthOfInput() throws {
        let totals = TokenTotals(cacheReadTokens: oneMillion)

        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "gpt-5.6-sol", totals: totals)), 0.50, accuracy: 0.0001)
    }

    // MARK: - What it will not price

    /// The table can never be complete: the CLIs route to models Limitr has never heard of.
    /// Pricing an unknown model at zero would quietly understate the total, which is worse
    /// than saying nothing about it.
    func testRefusesToPriceAModelItDoesNotKnow() {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: oneMillion)

        XCTAssertNil(ModelPrices.cost(model: "deepseek-v4-pro", totals: totals))
    }

    /// Claude Code writes `<synthetic>` for turns it generated itself, which were never
    /// billed at all.
    func testRefusesToPriceSyntheticTurns() {
        XCTAssertNil(ModelPrices.cost(model: "<synthetic>", totals: TokenTotals(inputTokens: oneMillion, outputTokens: 0)))
    }

    /// Dated snapshots and platform prefixes name the same model at the same price, and a
    /// table keyed only on the bare id would drop every one of them as unknown.
    func testMatchesDatedSnapshotsAndPlatformPrefixes() throws {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: 0)
        let bare = try XCTUnwrap(ModelPrices.cost(model: "claude-opus-4-5", totals: totals))

        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "claude-opus-4-5-20251101", totals: totals)), bare)
        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "anthropic.claude-opus-4-5", totals: totals)), bare)
    }

    /// `claude-opus-4-8` must not be answered by the `claude-opus-4` row, which is a
    /// retired model at three times the price.
    func testPrefersTheLongestMatchingModelName() throws {
        let totals = TokenTotals(inputTokens: oneMillion, outputTokens: 0)

        XCTAssertEqual(try XCTUnwrap(ModelPrices.cost(model: "claude-opus-4-8", totals: totals)), 5, accuracy: 0.0001)
    }
}
