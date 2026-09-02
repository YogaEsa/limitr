import XCTest
@testable import LimitrCore

final class ClaudeAccountStatusTests: XCTestCase {
    private func stub(
        status: Int32 = 0,
        stdout: String = "",
        error: Error? = nil
    ) -> ClaudeAccountStatus.Runner {
        { _, _, _ in
            if let error { throw error }
            return ProcessResult(status: status, standardOutput: stdout, standardError: "")
        }
    }

    // MARK: - Parsing

    func testParsesLoggedInStatus() {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"dev@example.com","orgName":"Dev Org","subscriptionType":"pro"}"#

        XCTAssertEqual(
            ClaudeAccountStatus.parse(Data(json.utf8)),
            ClaudeAccountStatus(state: .loggedIn, email: "dev@example.com")
        )
    }

    func testParsesLoggedOutStatus() {
        let json = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#

        XCTAssertEqual(ClaudeAccountStatus.parse(Data(json.utf8)), .loggedOut)
    }

    /// The regression this file exists for. Output that cannot be parsed means the CLI
    /// was not understood, not that the account is signed out — and the two used to be
    /// the same value, which is what pinned a freshly signed-in account to "Sign in"
    /// until Limitr was restarted.
    func testTreatsUnparseableOutputAsUnknownRatherThanLoggedOut() {
        XCTAssertEqual(ClaudeAccountStatus.parse(Data("Claude configuration file not found".utf8)), .unknown)
        XCTAssertEqual(ClaudeAccountStatus.parse(Data()), .unknown)
    }

    // MARK: - Only a definite answer may override the config file

    func testOnlyACLIAnswerCountsAsDefinitelyLoggedOut() {
        XCTAssertTrue(ClaudeAccountStatus.loggedOut.isDefinitelyLoggedOut)

        XCTAssertFalse(ClaudeAccountStatus.unknown.isDefinitelyLoggedOut)
        XCTAssertFalse(ClaudeAccountStatus(state: .loggedIn, email: "dev@example.com").isDefinitelyLoggedOut)
    }

    // MARK: - Reading

    func testReportsUnknownWhenTheExecutableIsMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent/claude")

        XCTAssertEqual(ClaudeAccountStatus.read(configDirectory: nil, executableURL: missing), .unknown)
    }

    func testReportsUnknownWhenTheProcessCannotBeRun() {
        let status = ClaudeAccountStatus.read(
            configDirectory: nil,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            run: stub(error: ProcessRunnerError.spawnFailed("nope"))
        )

        XCTAssertEqual(status, .unknown)
    }

    /// A locked or wedged CLI must not read as a signed-out account either.
    func testReportsUnknownWhenTheProcessTimesOut() {
        let status = ClaudeAccountStatus.read(
            configDirectory: nil,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            run: stub(error: ProcessRunnerError.timedOut(10))
        )

        XCTAssertEqual(status, .unknown)
    }

    func testReadsADefiniteAnswerFromTheCLI() {
        let status = ClaudeAccountStatus.read(
            configDirectory: nil,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            run: stub(stdout: #"{"loggedIn":true,"email":"dev@example.com"}"#)
        )

        XCTAssertEqual(status, ClaudeAccountStatus(state: .loggedIn, email: "dev@example.com"))
    }

    /// Trusted over the exit code: `claude auth status` may well report a signed-out
    /// account with a non-zero exit, and the JSON is the more specific answer.
    func testTrustsParsedOutputEvenWithANonZeroExit() {
        let status = ClaudeAccountStatus.read(
            configDirectory: nil,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            run: stub(status: 1, stdout: #"{"loggedIn":false}"#)
        )

        XCTAssertEqual(status, .loggedOut)
    }

    // MARK: - Environment

    func testScopesTheProbeToTheAccountConfigDirectory() {
        let captured = EnvironmentBox()
        _ = ClaudeAccountStatus.read(
            configDirectory: "/tmp/limitr-test/Claude",
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            run: { _, arguments, environment in
                captured.record(environment, arguments: arguments)
                return ProcessResult(status: 0, standardOutput: #"{"loggedIn":true}"#, standardError: "")
            }
        )

        XCTAssertEqual(captured.environment?["CLAUDE_CONFIG_DIR"], "/tmp/limitr-test/Claude")
        XCTAssertEqual(captured.arguments, ["auth", "status", "--json"])
    }

    /// Exporting `CLAUDE_CONFIG_DIR` at all — even as `~/.claude` — switches the CLI to a
    /// hashed Keychain name, so the default profile must be probed with the variable
    /// removed rather than merely left unset by the caller.
    func testUnsetsTheConfigDirectoryForTheDefaultProfile() {
        let captured = EnvironmentBox()
        _ = ClaudeAccountStatus.read(
            configDirectory: nil,
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            environment: ["CLAUDE_CONFIG_DIR": "/inherited/from/a/shell", "HOME": "/Users/dev"],
            run: { _, arguments, environment in
                captured.record(environment, arguments: arguments)
                return ProcessResult(status: 0, standardOutput: #"{"loggedIn":true}"#, standardError: "")
            }
        )

        XCTAssertNil(captured.environment?["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(captured.environment?["HOME"], "/Users/dev")
    }
}

/// Captures the environment and arguments a stubbed probe was invoked with.
private final class EnvironmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEnvironment: [String: String]?
    private var storedArguments: [String] = []

    func record(_ environment: [String: String], arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        storedEnvironment = environment
        storedArguments = arguments
    }

    var environment: [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return storedEnvironment
    }

    var arguments: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedArguments
    }
}
