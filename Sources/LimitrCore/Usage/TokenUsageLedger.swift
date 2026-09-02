import Foundation

/// Reads token spend out of the CLIs' own on-disk transcripts.
///
/// Neither CLI exposes an API for historical token counts — the rate-limit endpoints only
/// report how full the current window is. Both do, however, write append-only JSONL as
/// they work, and that is the only place a "last 30 days" number can come from.
///
/// Scans are incremental. Each transcript keeps a byte cursor, so a refresh reads only
/// what was appended since the last one; the first scan of a well-used install is the
/// only expensive pass. Callers should keep one ledger per account for the app's lifetime
/// rather than building one per refresh, and must run `report` off the main actor.
public actor TokenUsageLedger {
    public enum Flavor: Sendable {
        /// `<CLAUDE_CONFIG_DIR>/projects/**/*.jsonl`, one file per session.
        case claude
        /// `<CODEX_HOME>/sessions/**/rollout-*.jsonl`, one file per session.
        case codex
    }

    private struct Cursor {
        var offset: UInt64 = 0
        /// Codex reports token counts without naming the model; the enclosing turn does.
        /// Carrying it on the cursor keeps the attribution correct when a later scan picks
        /// up turns appended after the `turn_context` line was already consumed.
        var model: String?
    }

    private let flavor: Flavor
    private let root: URL
    private let fileManager: FileManager
    private let calendar: Calendar
    private var ledger = TokenLedger()
    private var cursors: [URL: Cursor] = [:]

    private static let newline = UInt8(ascii: "\n")
    private let claudeMarker = Data(#""usage""#.utf8)
    private let codexUsageMarker = Data(#""token_count""#.utf8)
    private let codexTurnMarker = Data(#""turn_context""#.utf8)
    private let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSecondDates = ISO8601DateFormatter()

    public init(flavor: Flavor, root: URL, fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.flavor = flavor
        self.root = root
        self.fileManager = fileManager
        self.calendar = calendar
    }

    /// Ingests anything appended since the last call and reports the rolling windows.
    /// An unused or missing transcript directory is not an error — it reports empty.
    public func report(now: Date = .now) -> TokenUsageReport {
        scan(now: now)
        ledger.prune(now: now, calendar: calendar)
        return ledger.report(now: now, calendar: calendar)
    }

    // MARK: - Scanning

    private func scan(now: Date) {
        let files = transcripts(activeSince: calendar.date(byAdding: .day, value: -TokenLedger.retainedDays, to: now) ?? now)
        // A transcript that lost bytes was rewritten, not appended to, so every cursor's
        // idea of what it has already counted is suspect. Rebuilding is rare enough to be
        // worth the full rescan it costs.
        if files.contains(where: wasRewritten) {
            ledger = TokenLedger()
            cursors = [:]
        }
        for url in files { consume(url) }
    }

    private func wasRewritten(_ url: URL) -> Bool {
        guard let cursor = cursors[url], let size = fileSize(url) else { return false }
        return size < cursor.offset
    }

    private func consume(_ url: URL) {
        guard let size = fileSize(url), size > (cursors[url]?.offset ?? 0) else { return }
        var cursor = cursors[url] ?? Cursor()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: cursor.offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // The last line of a live session is often half-flushed. Stop at the final newline
        // and leave the remainder for the next scan, which is what keeps a torn line from
        // being dropped once it is complete.
        guard let terminator = data.lastIndex(of: Self.newline) else { return }
        let complete = data[data.startIndex...terminator]
        for line in complete.split(separator: Self.newline, omittingEmptySubsequences: true) {
            switch flavor {
            case .claude: ingestClaude(line)
            case .codex: ingestCodex(line, model: &cursor.model)
            }
        }
        cursor.offset += UInt64(complete.count)
        cursors[url] = cursor
    }

    private func transcripts(activeSince cutoff: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if flavor == .codex && !url.lastPathComponent.hasPrefix("rollout-") { continue }
            // A transcript untouched for longer than the retention window can only hold
            // entries that already fell out of every reported period.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { continue }
            urls.append(url.standardizedFileURL)
        }
        return urls
    }

    private func fileSize(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init)
    }

    // MARK: - Line parsing

    private func ingestClaude(_ line: Data) {
        guard line.range(of: claudeMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let timestamp = date(from: object["timestamp"]) else { return }
        // Local-only turns are recorded with a placeholder model such as `<synthetic>` and
        // never reached the API.
        guard let model = message["model"] as? String, !model.hasPrefix("<") else { return }
        let totals = TokenTotals(
            inputTokens: usage.count("input_tokens"),
            outputTokens: usage.count("output_tokens"),
            cacheWriteTokens: usage.count("cache_creation_input_tokens"),
            cacheReadTokens: usage.count("cache_read_input_tokens")
        )
        guard !totals.isEmpty else { return }
        // Resuming a session replays earlier turns into the new transcript verbatim, so the
        // same API request appears in more than one file.
        let key = [object["requestId"] as? String, message["id"] as? String]
            .compactMap { $0 }
            .joined(separator: "|")
        ledger.add(
            model: Self.displayName(for: model),
            totals: totals,
            at: timestamp,
            key: key.isEmpty ? nil : key,
            calendar: calendar
        )
    }

    private func ingestCodex(_ line: Data, model: inout String?) {
        // `turn_context` is tagged at the top level, while `token_count` is tagged inside
        // its payload — accept either so one schema shift does not silently lose a model.
        if line.range(of: codexTurnMarker) != nil,
           let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
           let payload = object["payload"] as? [String: Any],
           object["type"] as? String == "turn_context" || payload["type"] as? String == "turn_context",
           let name = payload["model"] as? String {
            model = name
            return
        }
        guard line.range(of: codexUsageMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              // The per-turn delta, not the session running total: summing deltas is what
              // puts a session that spans midnight on both days.
              let usage = info["last_token_usage"] as? [String: Any],
              let timestamp = date(from: object["timestamp"]) else { return }
        // Codex folds cache reads into `input_tokens`; splitting them here makes a Codex
        // row mean the same thing as a Claude row.
        let cached = usage.count("cached_input_tokens")
        let totals = TokenTotals(
            inputTokens: max(0, usage.count("input_tokens") - cached),
            outputTokens: usage.count("output_tokens"),
            cacheWriteTokens: usage.count("cache_write_input_tokens"),
            cacheReadTokens: cached
        )
        guard !totals.isEmpty else { return }
        // The byte cursor already guarantees each event is offered once, so no dedupe key.
        ledger.add(model: model ?? "codex", totals: totals, at: timestamp, key: nil, calendar: calendar)
    }

    private func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractionalDates.date(from: text) ?? wholeSecondDates.date(from: text)
    }

    /// `claude-opus-5` reads as `opus-5` in a column that is already headed by the service.
    static func displayName(for model: String) -> String {
        model.hasPrefix("claude-") ? String(model.dropFirst("claude-".count)) : model
    }
}

private extension [String: Any] {
    /// JSONSerialization hands back `NSNumber`, which bridges to `Int` for whole values and
    /// to `Double` for anything a transcript writes with a decimal point.
    func count(_ key: String) -> Int {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        return 0
    }
}
