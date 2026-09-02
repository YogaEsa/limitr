import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let standardOutput: String
    public let standardError: String

    public init(status: Int32, standardOutput: String, standardError: String) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum ProcessRunnerError: LocalizedError, Equatable {
    case spawnFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let reason): "Could not start the process: \(reason)."
        case .timedOut(let seconds): "The process did not answer within \(Int(seconds))s."
        }
    }
}

/// Runs a short-lived child process to completion under a deadline.
///
/// Every call site here is on a polling loop, so "waits forever" is not an available
/// failure mode: a locked login keychain leaves `security` parked on an unlock prompt
/// that never comes, and `waitUntilExit()` behind it would take the loop with it.
public enum ProcessRunner {
    /// How long to let a terminated child clean up before escalating to `SIGKILL`.
    private static let terminationGrace: TimeInterval = 1

    /// - Parameter environment: replaces the child's environment entirely; nil inherits
    ///   this process's. Note that a GUI app inherits launchd's, not a shell's.
    public static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        // A child that reads stdin would otherwise inherit the parent's and block.
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Spawn before draining: if `run()` throws nothing was ever started, and a
        // reader waiting on a pipe whose write end only this process holds would
        // never see EOF.
        do { try process.run() } catch {
            throw ProcessRunnerError.spawnFailed(error.localizedDescription)
        }

        // Drain both pipes while the child runs. Waiting first and reading after
        // deadlocks the moment a child writes more than one pipe buffer.
        let output = DataBuffer()
        let errorOutput = DataBuffer()
        let draining = DispatchGroup()
        let queue = DispatchQueue(label: "com.limitr.process-runner", attributes: .concurrent)
        for (pipe, buffer) in [(outputPipe, output), (errorPipe, errorOutput)] {
            queue.async(group: draining) {
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
            _ = draining.wait(timeout: .now() + terminationGrace)
            throw ProcessRunnerError.timedOut(timeout)
        }
        _ = draining.wait(timeout: .now() + terminationGrace)

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: output.text,
            standardError: errorOutput.text
        )
    }
}

/// Accumulates one pipe's bytes from the draining queue for the caller to read back.
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        storage.append(data)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}
