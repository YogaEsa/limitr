import Foundation

public enum CodexProviderError: LocalizedError {
    case sessionsDirectoryMissing(URL)
    case noSessionLog
    case noRateLimits(URL)

    public var errorDescription: String? {
        switch self {
        case .sessionsDirectoryMissing(let url): "Codex sessions directory not found: \(url.path)"
        case .noSessionLog: "No Codex rollout log was found. Send a Codex prompt first."
        case .noRateLimits(let url): "No rate-limit event was found in \(url.lastPathComponent)."
        }
    }
}

public struct CodexProvider {
    public let sessionsDirectory: URL
    public let accountID: String
    public let accountName: String
    private let fileManager: FileManager

    public init(sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions"), accountID: String = "default", accountName: String = "Default", fileManager: FileManager = .default) {
        self.sessionsDirectory = sessionsDirectory
        self.accountID = accountID
        self.accountName = accountName
        self.fileManager = fileManager
    }

    public func fetch(now: Date = .now) throws -> [UsageWindow] {
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            throw CodexProviderError.sessionsDirectoryMissing(sessionsDirectory)
        }
        let logs = rolloutLogsByModificationDate()
        guard !logs.isEmpty else { throw CodexProviderError.noSessionLog }
        for log in logs {
            guard let data = try? tailData(from: log),
                  let event = lastRateLimitEvent(in: data, at: log) else { continue }
            let staleness: Staleness = now.timeIntervalSince(event.timestamp) > 30 * 60 ? .stale : .fresh
            let windows = event.limits.compactMap { label, limit -> UsageWindow? in
                guard let used = limit.usedPercent else { return nil }
                let reset = limit.resetsAt.map(Date.init(timeIntervalSince1970:)) ?? limit.resetsInSeconds.map(event.timestamp.addingTimeInterval)
                guard let resetsAt = reset else { return nil }
                return UsageWindow(source: .codex, accountID: accountID, accountName: accountName, label: label, usedPercent: used, resetsAt: resetsAt,
                                   windowMinutes: limit.windowMinutes ?? Int(resetsAt.timeIntervalSince(event.timestamp) / 60), staleness: staleness,
                                   tokenUsage: event.tokenUsage)
            }
            if !windows.isEmpty { return windows }
        }
        throw CodexProviderError.noRateLimits(logs[0])
    }

    /// What the newest transcript says about whether a turn is running right now.
    ///
    /// Only the newest log is asked. Two Codex sessions can share a home, and the one that
    /// wrote last is the one the reading is about; an older log's dangling `task_started`
    /// would otherwise keep the bar lit for a session that ended hours ago.
    public func turn() -> TurnMarker {
        guard let newest = rolloutLogsByModificationDate().first,
              let data = try? tailData(from: newest) else { return .absent }
        return Self.turnMarker(inTail: data)
    }

    /// The last turn marker in a chunk of transcript, read backwards.
    ///
    /// Parsed rather than searched for as text: `task_started` appearing inside a message
    /// the user or the model wrote is not a marker, and a substring match cannot tell the
    /// difference. The tail begins mid-line as often as not, and that line simply fails to
    /// decode and is skipped — which is also why this reads from the end rather than
    /// folding over the whole chunk.
    public static func turnMarker(inTail data: Data) -> TurnMarker {
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let record = try? JSONDecoder().decode(CodexTurnRecord.self, from: Data(line)) else { continue }
            switch record.payload?.type {
            case "task_started": return .started
            case "task_complete": return .finished
            default: continue
            }
        }
        return .absent
    }

    private func rolloutLogsByModificationDate() -> [URL] {
        guard let enumerator = fileManager.enumerator(at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var logs: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            logs.append((url, modified))
        }
        return logs.sorted { $0.modified > $1.modified }.map(\.url)
    }

    private func lastRateLimitEvent(in data: Data, at url: URL) -> RateLimitEvent? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let decoded = try? JSONDecoder.codex.decode(CodexLogEvent.self, from: Data(line.utf8)),
                  let rateLimits = decoded.payload?.rateLimits,
                  let limits = rateLimits.limits, !limits.isEmpty else { continue }
            return RateLimitEvent(timestamp: decoded.timestamp ?? fileModificationDate(url) ?? .now,
                                  limits: limits, tokenUsage: decoded.payload?.info?.totalTokenUsage)
        }
        return nil
    }

    private func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func tailData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        return try handle.readToEnd() ?? Data()
    }
}

private struct RateLimitEvent {
    let timestamp: Date
    let limits: [(String, CodexRateLimit)]
    let tokenUsage: TokenUsage?
}

private struct CodexLogEvent: Decodable {
    let timestamp: Date?
    let payload: Payload?
    struct Payload: Decodable {
        let rateLimits: CodexRateLimits?
        let info: Info?
        enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits"; case info }

        struct Info: Decodable {
            let totalTokenUsage: TokenUsage?
            enum CodingKeys: String, CodingKey { case totalTokenUsage = "total_token_usage" }
        }
    }
}

private struct CodexRateLimits: Decodable {
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
    var limits: [(String, CodexRateLimit)]? {
        let values = [("primary", primary), ("secondary", secondary)].compactMap { label, limit in limit.map { (label, $0) } }
        return values.isEmpty ? nil : values
    }
}

private struct CodexRateLimit: Decodable {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsInSeconds: TimeInterval?
    let resetsAt: TimeInterval?
    enum CodingKeys: String, CodingKey { case usedPercent = "used_percent", windowMinutes = "window_minutes", resetsInSeconds = "resets_in_seconds", resetsAt = "resets_at" }
}

private extension JSONDecoder {
    static var codex: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }
}


/// Just enough of a transcript line to find a turn marker. The rate-limit reader decodes
/// the same lines for different fields, and keeping the two apart means neither has to
/// carry the other's optionals.
private struct CodexTurnRecord: Decodable {
    struct Payload: Decodable {
        let type: String?
    }
    let payload: Payload?
}
