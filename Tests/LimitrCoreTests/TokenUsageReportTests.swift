import XCTest
@testable import LimitrCore

final class TokenUsageReportTests: XCTestCase {

    private let oneMillion = 1_000_000

    private func report(_ models: [String: TokenTotals]) -> TokenUsageReport {
        TokenUsageReport(periods: [.today: models], models: [], lastActivity: nil)
    }

    /// Each model is priced at its own rates and the results added. Pricing a period's
    /// combined totals at any single model's rates would be wrong by the ratio between
    /// them — nearly 3x between Opus and Sonnet.
    func testCostsAPeriodByPricingEachModelSeparately() {
        let usage = report([
            "claude-opus-5": TokenTotals(inputTokens: oneMillion, outputTokens: 0),
            "claude-sonnet-5": TokenTotals(inputTokens: oneMillion, outputTokens: 0)
        ])

        XCTAssertEqual(usage.estimatedCost(for: .today).dollars, 7, accuracy: 0.0001)
    }

    /// A model with no published price contributes its tokens to the unpriced count and
    /// nothing to the total, so the figure can be shown as the floor it is rather than
    /// passed off as complete.
    func testCountsTokensItCouldNotPriceInsteadOfCallingThemFree() {
        let usage = report([
            "claude-opus-5": TokenTotals(inputTokens: oneMillion, outputTokens: 0),
            "deepseek-v4-pro": TokenTotals(inputTokens: 500_000, outputTokens: 0)
        ])

        let cost = usage.estimatedCost(for: .today)

        XCTAssertEqual(cost.dollars, 5, accuracy: 0.0001)
        XCTAssertEqual(cost.unpricedTokens, 500_000)
        XCTAssertTrue(cost.isPartial)
    }

    func testIsNotPartialWhenEveryModelWasPriced() {
        let usage = report(["claude-opus-5": TokenTotals(inputTokens: oneMillion, outputTokens: 0)])

        XCTAssertFalse(usage.estimatedCost(for: .today).isPartial)
    }

    func testCostsNothingForAPeriodWithNoSpend() {
        let cost = TokenUsageReport.empty.estimatedCost(for: .today)

        XCTAssertEqual(cost.dollars, 0)
        XCTAssertFalse(cost.isPartial)
    }

    /// The period totals the card already shows must keep working, and they are now the
    /// sum across that period's models rather than a figure kept alongside them.
    func testStillReportsThePeriodsCombinedTotals() {
        let usage = report([
            "claude-opus-5": TokenTotals(inputTokens: 100, outputTokens: 10),
            "claude-sonnet-5": TokenTotals(inputTokens: 200, outputTokens: 20)
        ])

        XCTAssertEqual(usage.totals(for: .today).inputTokens, 300)
        XCTAssertEqual(usage.totals(for: .today).outputTokens, 30)
    }
}
