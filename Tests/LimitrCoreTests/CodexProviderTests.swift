import XCTest
@testable import LimitrCore

final class CodexProviderTests: XCTestCase {
    func testReadsLiveWeeklyUsage() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":8,"windowDurationMins":10080,"resetsAt":1787000000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1787025591}}}}}"#

        let windows = try CodexLiveProvider.windows(from: Data(response.utf8), accountID: "personal", accountName: "Personal")

        XCTAssertEqual(windows.first?.usedPercent, 60)
        XCTAssertEqual(windows.first?.remainingPercent, 40)
        XCTAssertEqual(windows.first?.windowMinutes, 10_080)
        XCTAssertEqual(windows.first?.staleness, .fresh)
    }

    func testReadsLatestRateLimitEvent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let log = root.appending(path: "2026/08/11/rollout-test.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-08-11T07:27:21Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5200,"cached_input_tokens":1200,"output_tokens":14,"total_tokens":5214}},"rate_limits":{"primary":{"used_percent":12.5,"window_minutes":299,"resets_in_seconds":17940},"secondary":{"used_percent":22,"window_minutes":10079,"resets_in_seconds":351406}}}}"#
        try Data((line + "\n").utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: root) }

        let windows = try CodexProvider(sessionsDirectory: root, accountID: "profile-a", accountName: "Work").fetch(now: ISO8601DateFormatter().date(from: "2026-08-11T07:30:00Z")!)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.first { $0.label == "primary" }?.usedPercent, 12.5)
        XCTAssertEqual(windows.first { $0.label == "primary" }?.staleness, .fresh)
        XCTAssertEqual(windows.first?.accountID, "profile-a")
        XCTAssertEqual(windows.first?.accountName, "Work")
        XCTAssertEqual(windows.first?.tokenUsage, TokenUsage(inputTokens: 5_200, outputTokens: 14, cachedInputTokens: 1_200, totalTokens: 5_214))
    }

    func testMarksOldEventsStale() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let log = root.appending(path: "rollout-test.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"timestamp":"2026-08-11T07:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":1,"resets_in_seconds":100}}}}"#.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = ISO8601DateFormatter().date(from: "2026-08-11T08:00:01Z")!
        XCTAssertEqual(try CodexProvider(sessionsDirectory: root).fetch(now: now).first?.staleness, .stale)
    }

    func testReadsUnixResetAndFractionalTimestamp() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let log = root.appending(path: "rollout-test.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"timestamp":"2026-08-11T07:27:21.415Z","payload":{"rate_limits":{"primary":{"used_percent":1,"window_minutes":10080,"resets_at":1780000000}}}}"#.utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try CodexProvider(sessionsDirectory: root).fetch().first?.resetsAt.timeIntervalSince1970, 1_780_000_000)
    }

    // MARK: - Turn markers

    private func tail(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    func testReadsATurnInProgressFromTheLastMarker() {
        let data = tail([
            #"{"timestamp":"2026-09-01T07:33:58.842Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
            #"{"timestamp":"2026-09-01T07:35:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-09-01T07:35:04.000Z","type":"response_item","payload":{"type":"reasoning"}}"#
        ])
        XCTAssertEqual(CodexProvider.turnMarker(inTail: data), .started)
    }

    func testReadsAFinishedTurnFromTheLastMarker() {
        let data = tail([
            #"{"payload":{"type":"task_started"}}"#,
            #"{"payload":{"type":"custom_tool_call"}}"#,
            #"{"payload":{"type":"task_complete"}}"#
        ])
        XCTAssertEqual(CodexProvider.turnMarker(inTail: data), .finished)
    }

    /// Claude's transcripts carry nothing of the sort, and so do Codex logs written before
    /// these markers existed. Absent is an ordinary answer, not a failure.
    func testReportsNoMarkerWhenTheTranscriptCarriesNone() {
        let data = tail([#"{"payload":{"type":"reasoning"}}"#, #"{"payload":{"type":"message"}}"#])
        XCTAssertEqual(CodexProvider.turnMarker(inTail: data), .absent)
    }

    /// The reason the lines are decoded rather than searched as text: a turn marker named
    /// inside something the user or the model wrote is not a turn marker, and a substring
    /// match cannot tell the two apart.
    func testDoesNotMistakeAMarkerNamedInsideAMessage() {
        let data = tail([
            #"{"payload":{"type":"task_complete"}}"#,
            #"{"payload":{"type":"message","content":"why is task_started not firing?"}}"#
        ])
        XCTAssertEqual(CodexProvider.turnMarker(inTail: data), .finished)
    }

    /// The tail is read from a byte offset, so its first line is usually cut in half. That
    /// line cannot be decoded and must simply be skipped.
    func testSkipsThePartialLineTheTailBeginsWith() {
        let data = tail([
            #"ype":"task_complete"}}"#,
            #"{"payload":{"type":"task_started"}}"#
        ])
        XCTAssertEqual(CodexProvider.turnMarker(inTail: data), .started)
    }
}
