import Foundation

public enum CodexLiveProviderError: LocalizedError {
    case homeMissing(URL)
    case executableMissing
    case launchFailed(String)
    case timedOut
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .homeMissing(let url): "Codex home was not found: \(url.path)"
        case .executableMissing: "Codex CLI was not found. Install it, then reopen Limitr."
        case .launchFailed(let message): "Codex usage could not be read: \(message)"
        case .timedOut: "Codex usage timed out."
        case .invalidResponse: "Codex returned an invalid usage response."
        case .server(let message): "Codex usage could not be read: \(message)"
        }
    }
}

public struct CodexLiveProvider: Sendable {
    public let codexHome: URL
    public let accountID: String
    public let accountName: String
    private let executableURL: URL?

    public init(codexHome: URL, accountID: String = "default", accountName: String = "Default", executableURL: URL? = nil) {
        self.codexHome = codexHome
        self.accountID = accountID
        self.accountName = accountName
        self.executableURL = executableURL ?? Self.findCodexExecutable()
    }

    public func fetch(timeout: TimeInterval = 8) async throws -> [UsageWindow] {
        try await Task.detached(priority: .utility) {
            try fetchSynchronously(timeout: timeout)
        }.value
    }

    private func fetchSynchronously(timeout: TimeInterval) throws -> [UsageWindow] {
        guard FileManager.default.fileExists(atPath: codexHome.path) else {
            throw CodexLiveProviderError.homeMissing(codexHome)
        }
        guard let executableURL else { throw CodexLiveProviderError.executableMissing }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        let responseCollector = RPCOutputCollector(requestID: 2)
        let errorCollector = RPCOutputCollector()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        output.fileHandleForReading.readabilityHandler = { responseCollector.append($0.availableData) }
        errorOutput.fileHandleForReading.readabilityHandler = { errorCollector.append($0.availableData) }

        do {
            try process.run()
            let messages = [
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"limitr","title":"Limitr","version":"0.1.0"}}}"#,
                #"{"method":"initialized"}"#,
                #"{"id":2,"method":"account/rateLimits/read"}"#
            ].joined(separator: "\n") + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            throw CodexLiveProviderError.launchFailed(error.localizedDescription)
        }

        let completed = responseCollector.wait(timeout: timeout)
        stop(process, input: input, output: output, errorOutput: errorOutput)
        guard completed else {
            let message = String(decoding: errorCollector.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { throw CodexLiveProviderError.launchFailed(message) }
            throw CodexLiveProviderError.timedOut
        }
        return try Self.windows(from: responseCollector.data, accountID: accountID, accountName: accountName)
    }

    private func stop(_ process: Process, input: Pipe, output: Pipe, errorOutput: Pipe) {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil
    }

    static func windows(from data: Data, accountID: String, accountName: String) throws -> [UsageWindow] {
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A) {
            guard let response = try? decoder.decode(RateLimitsRPCResponse.self, from: Data(line)), response.id == 2 else { continue }
            if let error = response.error { throw CodexLiveProviderError.server(error.message) }
            guard let snapshot = response.result?.rateLimitsByLimitID?["codex"] ?? response.result?.rateLimits else {
                throw CodexLiveProviderError.invalidResponse
            }
            let limits = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
            let windows = limits.compactMap { label, limit -> UsageWindow? in
                guard let limit, let resetTimestamp = limit.resetsAt else { return nil }
                return UsageWindow(
                    source: .codex,
                    accountID: accountID,
                    accountName: accountName,
                    label: label,
                    usedPercent: limit.usedPercent,
                    resetsAt: Date(timeIntervalSince1970: resetTimestamp),
                    windowMinutes: limit.windowDurationMinutes ?? 0,
                    staleness: .fresh
                )
            }
            guard !windows.isEmpty else { throw CodexLiveProviderError.invalidResponse }
            return windows
        }
        throw CodexLiveProviderError.invalidResponse
    }

    private static func findCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let fromPath = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "codex") }
        let candidates = fromPath + [
            fileManager.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private final class RPCOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let requestID: Int?
    private var storage = Data()
    private var hasSignaled = false

    init(requestID: Int? = nil) {
        self.requestID = requestID
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        let shouldSignal = !hasSignaled && requestID.map { Self.containsResponse($0, in: storage) } == true
        if shouldSignal { hasSignaled = true }
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    private static func containsResponse(_ requestID: Int, in data: Data) -> Bool {
        data.split(separator: 0x0A).contains { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? NSNumber else { return false }
            return id.intValue == requestID
        }
    }
}

private struct RateLimitsRPCResponse: Decodable {
    let id: Int
    let result: RateLimitsResult?
    let error: RPCError?
}

private struct RPCError: Decodable {
    let message: String
}

private struct RateLimitsResult: Decodable {
    let rateLimits: LiveRateLimitSnapshot
    let rateLimitsByLimitID: [String: LiveRateLimitSnapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }
}

private struct LiveRateLimitSnapshot: Decodable {
    let primary: LiveRateLimitWindow?
    let secondary: LiveRateLimitWindow?
}

private struct LiveRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowDurationMinutes = "windowDurationMins"
        case resetsAt
    }
}
