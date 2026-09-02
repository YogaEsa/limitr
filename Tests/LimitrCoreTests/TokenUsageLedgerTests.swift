import XCTest
@testable import LimitrCore

final class TokenUsageLedgerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Claude transcripts

    func testSumsClaudeAssistantUsageIntoToday() async throws {
        try write("projects/app/session.jsonl", [
            claudeLine(id: "req-1", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 120, output: 400, cacheWrite: 15_000, cacheRead: 900),
            claudeLine(id: "req-2", model: "claude-opus-5", at: "2026-08-12T08:30:00.000Z", input: 80, output: 600, cacheWrite: 0, cacheRead: 12_000)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 200)
        XCTAssertEqual(report.totals(for: .today).outputTokens, 1_000)
        XCTAssertEqual(report.totals(for: .today).cacheWriteTokens, 15_000)
        XCTAssertEqual(report.totals(for: .today).cacheReadTokens, 12_900)
        XCTAssertEqual(report.totals(for: .today).totalTokens, 29_100)
    }

    func testCountsARepeatedRequestOnlyOnce() async throws {
        // A resumed session replays earlier turns into a new transcript file. Counting the
        // replay would inflate every total the panel shows.
        try write("projects/app/first.jsonl", [
            claudeLine(id: "req-1", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 100, output: 200)
        ])
        try write("projects/app/resumed.jsonl", [
            claudeLine(id: "req-1", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 100, output: 200),
            claudeLine(id: "req-2", model: "claude-opus-5", at: "2026-08-12T07:05:00.000Z", input: 7, output: 3)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 107)
        XCTAssertEqual(report.totals(for: .today).outputTokens, 203)
    }

    func testSeparatesPeriodsByEntryTimestamp() async throws {
        try write("projects/app/session.jsonl", [
            claudeLine(id: "today", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 1, output: 0),
            claudeLine(id: "three-days", model: "claude-opus-5", at: "2026-08-09T07:00:00.000Z", input: 10, output: 0),
            claudeLine(id: "twenty-days", model: "claude-opus-5", at: "2026-07-23T07:00:00.000Z", input: 100, output: 0),
            claudeLine(id: "ancient", model: "claude-opus-5", at: "2026-05-01T07:00:00.000Z", input: 1_000, output: 0)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 1)
        XCTAssertEqual(report.totals(for: .sevenDays).inputTokens, 11)
        XCTAssertEqual(report.totals(for: .thisMonth).inputTokens, 11)
        XCTAssertEqual(report.totals(for: .thirtyDays).inputTokens, 111)
    }

    func testRanksModelsByShareOfTotalTokens() async throws {
        try write("projects/app/session.jsonl", [
            claudeLine(id: "a", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 750, output: 0),
            claudeLine(id: "b", model: "claude-haiku-4-5", at: "2026-08-12T07:01:00.000Z", input: 250, output: 0)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.models.map(\.model), ["opus-5", "haiku-4-5"])
        XCTAssertEqual(report.models[0].share, 0.75, accuracy: 0.0001)
        XCTAssertEqual(report.models[1].share, 0.25, accuracy: 0.0001)
    }

    func testSkipsSyntheticAssistantTurns() async throws {
        // Claude Code writes local-only turns with a `<synthetic>` model and no real spend.
        try write("projects/app/session.jsonl", [
            claudeLine(id: "real", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 5, output: 5),
            claudeLine(id: "fake", model: "<synthetic>", at: "2026-08-12T07:01:00.000Z", input: 999, output: 999)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).totalTokens, 10)
        XCTAssertEqual(report.models.map(\.model), ["opus-5"])
    }

    func testReportsLastActivity() async throws {
        try write("projects/app/session.jsonl", [
            claudeLine(id: "a", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 1, output: 1),
            claudeLine(id: "b", model: "claude-opus-5", at: "2026-08-12T08:12:00.000Z", input: 1, output: 1)
        ])

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.lastActivity, date("2026-08-12T08:12:00.000Z"))
    }

    func testEmptyRootProducesEmptyReport() async throws {
        try FileManager.default.createDirectory(at: root.appending(path: "projects"), withIntermediateDirectories: true)

        let report = await ledger(.claude, "projects").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertTrue(report.isEmpty)
        XCTAssertNil(report.lastActivity)
    }

    // MARK: - Incremental rescans

    func testPicksUpAppendedTurnsWithoutRecountingOldOnes() async throws {
        let path = "projects/app/session.jsonl"
        try write(path, [claudeLine(id: "a", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 100, output: 0)])
        let store = ledger(.claude, "projects")
        _ = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        try append(path, [claudeLine(id: "b", model: "claude-opus-5", at: "2026-08-12T07:30:00.000Z", input: 40, output: 0)])
        let report = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 140)
    }

    func testIgnoresAPartiallyWrittenTrailingLine() async throws {
        let path = "projects/app/session.jsonl"
        try write(path, [claudeLine(id: "a", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 100, output: 0)])
        // A live session leaves a half-flushed line at the end of the file.
        try append(path, [String(claudeLine(id: "b", model: "claude-opus-5", at: "2026-08-12T07:30:00.000Z", input: 40, output: 0).prefix(60))], terminated: false)
        let store = ledger(.claude, "projects")

        let torn = await store.report(now: date("2026-08-12T09:00:00.000Z"))
        XCTAssertEqual(torn.totals(for: .today).inputTokens, 100)

        // Once the rest of the line lands, the turn is counted exactly once.
        try append(path, [String(claudeLine(id: "b", model: "claude-opus-5", at: "2026-08-12T07:30:00.000Z", input: 40, output: 0).dropFirst(60))])

        let complete = await store.report(now: date("2026-08-12T09:00:00.000Z"))
        XCTAssertEqual(complete.totals(for: .today).inputTokens, 140)
    }

    func testRebuildsWhenATranscriptIsTruncated() async throws {
        let path = "projects/app/session.jsonl"
        try write(path, [
            claudeLine(id: "a", model: "claude-opus-5", at: "2026-08-12T07:00:00.000Z", input: 100, output: 0),
            claudeLine(id: "b", model: "claude-opus-5", at: "2026-08-12T07:30:00.000Z", input: 40, output: 0)
        ])
        let store = ledger(.claude, "projects")
        _ = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        try write(path, [claudeLine(id: "c", model: "claude-opus-5", at: "2026-08-12T08:00:00.000Z", input: 7, output: 0)])
        let report = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 7)
    }

    // MARK: - Codex rollouts

    func testSumsCodexTurnDeltasAndAttributesThemToTheTurnModel() async throws {
        // Codex reports cached input inside `input_tokens`; the ledger splits the two so a
        // Codex row means the same thing as a Claude row.
        try write("sessions/2026/08/12/rollout-a.jsonl", [
            codexTurnContext(model: "gpt-5.6-sol", at: "2026-08-12T07:00:00.000Z"),
            codexTokenCount(at: "2026-08-12T07:01:00.000Z", input: 1_000, cached: 900, cacheWrite: 20, output: 50),
            codexTokenCount(at: "2026-08-12T07:02:00.000Z", input: 500, cached: 100, cacheWrite: 0, output: 10)
        ])

        let report = await ledger(.codex, "sessions").report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 500)
        XCTAssertEqual(report.totals(for: .today).cacheReadTokens, 1_000)
        XCTAssertEqual(report.totals(for: .today).cacheWriteTokens, 20)
        XCTAssertEqual(report.totals(for: .today).outputTokens, 60)
        XCTAssertEqual(report.models.map(\.model), ["gpt-5.6-sol"])
    }

    func testKeepsTheCodexTurnModelAcrossAnIncrementalRescan() async throws {
        let path = "sessions/2026/08/12/rollout-a.jsonl"
        try write(path, [
            codexTurnContext(model: "gpt-5.6-sol", at: "2026-08-12T07:00:00.000Z"),
            codexTokenCount(at: "2026-08-12T07:01:00.000Z", input: 100, cached: 0, cacheWrite: 0, output: 10)
        ])
        let store = ledger(.codex, "sessions")
        _ = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        // The appended turn carries no `turn_context`; it still belongs to the same model.
        try append(path, [codexTokenCount(at: "2026-08-12T07:05:00.000Z", input: 40, cached: 0, cacheWrite: 0, output: 4)])
        let report = await store.report(now: date("2026-08-12T09:00:00.000Z"))

        XCTAssertEqual(report.totals(for: .today).inputTokens, 140)
        XCTAssertEqual(report.models.map(\.model), ["gpt-5.6-sol"])
    }

    // MARK: - Fixtures

    private func ledger(_ flavor: TokenUsageLedger.Flavor, _ subpath: String) -> TokenUsageLedger {
        TokenUsageLedger(flavor: flavor, root: root.appending(path: subpath), calendar: .utc)
    }

    private func write(_ path: String, _ lines: [String]) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    }

    private func append(_ path: String, _ lines: [String], terminated: Bool = true) throws {
        let url = root.appending(path: path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + (terminated ? "\n" : "") }.joined().utf8))
    }

    private func claudeLine(id: String, model: String, at timestamp: String, input: Int, output: Int, cacheWrite: Int = 0, cacheRead: Int = 0) -> String {
        """
        {"type":"assistant","requestId":"\(id)","timestamp":"\(timestamp)","message":{"id":"msg_\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":\(cacheWrite),"cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    private func codexTurnContext(model: String, at timestamp: String) -> String {
        // Mirrors the real record: tagged at the top level, with an untagged payload.
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"t1","cwd":"/tmp","model":"\#(model)"}}"#
    }

    private func codexTokenCount(at timestamp: String, input: Int, cached: Int, cacheWrite: Int, output: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":\#(cacheWrite),"output_tokens":\#(output),"total_tokens":\#(input + output)}}}}"#
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }
}

private extension Calendar {
    /// Day bucketing is calendar-relative. Pinning the tests to UTC keeps them from
    /// straddling a day boundary on machines west of Greenwich.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}
