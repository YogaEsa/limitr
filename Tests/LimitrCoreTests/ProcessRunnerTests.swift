import XCTest
@testable import LimitrCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStandardOutputAndExitStatus() throws {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, "hello\n")
    }

    func testCapturesStandardErrorAndNonZeroStatus() throws {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo boom >&2; exit 7"],
            timeout: 5
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardError, "boom\n")
    }

    /// A locked login keychain can leave `security` waiting on an unlock prompt that
    /// never comes. Without this the poll loop would hang forever behind it.
    func testKillsTheProcessWhenItExceedsTheTimeout() {
        let started = Date.now

        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.4
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut(0.4))
        }

        XCTAssertLessThan(Date.now.timeIntervalSince(started), 5, "the runner waited for the child instead of killing it")
    }

    func testReportsAMissingExecutableRatherThanTrapping() {
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/limitr-does-not-exist"),
                arguments: [],
                timeout: 5
            )
        ) { error in
            guard case .spawnFailed = error as? ProcessRunnerError else {
                return XCTFail("expected .spawnFailed, got \(error)")
            }
        }
    }

    /// Arguments go straight to `execve`, so a value containing shell metacharacters is
    /// data rather than syntax. This is what lets the username be passed unfiltered.
    func testPassesArgumentsWithoutShellInterpretation() throws {
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["bad user!; rm -rf $HOME"],
            timeout: 5
        )

        XCTAssertEqual(result.standardOutput, "bad user!; rm -rf $HOME\n")
    }
}
