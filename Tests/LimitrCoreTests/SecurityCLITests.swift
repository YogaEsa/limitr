import XCTest
@testable import LimitrCore

final class SecurityCLITests: XCTestCase {
    private func recording(
        status: Int32 = 0,
        stdout: String = "",
        stderr: String = ""
    ) -> (SecurityCLI, () -> [[String]]) {
        let box = ArgumentBox()
        let cli = SecurityCLI { arguments in
            box.record(arguments)
            return ProcessResult(status: status, standardOutput: stdout, standardError: stderr)
        }
        return (cli, { box.recorded })
    }

    /// The whole point of shelling out: `/usr/bin/security` is on every Claude Code
    /// keychain item's ACL because the CLI created it there, so reads stay silent.
    /// Resolving through `PATH` would let an attacker-planted `security` intercept
    /// the token, so the path is pinned.
    func testPinsTheAbsoluteSystemBinary() {
        XCTAssertEqual(SecurityCLI.executable.path, "/usr/bin/security")
    }

    func testReadsAPasswordByServiceAndAccount() throws {
        let (cli, arguments) = recording(stdout: "{\"accessToken\":\"t\"}\n")

        let lookup = try cli.password(service: "Claude Code-credentials", account: "esa")

        XCTAssertEqual(lookup, .found("{\"accessToken\":\"t\"}"))
        XCTAssertEqual(
            arguments(),
            [["find-generic-password", "-a", "esa", "-w", "-s", "Claude Code-credentials"]]
        )
    }

    /// `-w` prints the value plus exactly one newline. Stripping more would corrupt a
    /// payload that legitimately ends in whitespace.
    func testStripsExactlyOneTrailingNewline() throws {
        let (cli, _) = recording(stdout: "value\n\n")

        XCTAssertEqual(try cli.password(service: "s", account: "a"), .found("value\n"))
    }

    /// rc 44 is `errSecItemNotFound`. Claude Code itself treats it as "read the file
    /// instead", so it must not be confused with a keychain that refused to answer.
    func testTreatsExitCode44AsNotFound() throws {
        let (cli, _) = recording(status: 44, stderr: "The specified item could not be found")

        XCTAssertEqual(try cli.password(service: "s", account: "a"), .notFound)
    }

    func testThrowsWhenTheKeychainRefusesRatherThanReportingAMiss() {
        let (cli, _) = recording(status: 36, stderr: "User interaction is not allowed.")

        XCTAssertThrowsError(try cli.password(service: "s", account: "a")) { error in
            XCTAssertEqual(
                error as? SecurityCLIError,
                .failed(status: 36, message: "User interaction is not allowed.")
            )
        }
    }

    func testSurfacesRunnerFailuresAsUnavailable() {
        let cli = SecurityCLI { _ in throw ProcessRunnerError.timedOut(5) }

        XCTAssertThrowsError(try cli.password(service: "s", account: "a")) { error in
            guard case .unavailable = error as? SecurityCLIError else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }

    /// An attribute-only lookup never decrypts, so it cannot raise a keychain prompt
    /// even for an item this app is not on the ACL of. Passing `-w` here would.
    func testItemExistsNeverAsksForTheSecret() {
        let (cli, arguments) = recording(status: 0)

        XCTAssertTrue(cli.itemExists(service: "Claude Code-credentials", account: "esa"))
        XCTAssertEqual(
            arguments(),
            [["find-generic-password", "-a", "esa", "-s", "Claude Code-credentials"]]
        )
        XCTAssertFalse(arguments()[0].contains("-w"))
    }

    /// Callers use this for a cheap "is anything stored here" signal, never to decide
    /// access, so an unreadable keychain answers "no" instead of throwing.
    func testItemExistsIsFalseWhenTheLookupFails() {
        let (missing, _) = recording(status: 44)
        XCTAssertFalse(missing.itemExists(service: "s", account: "a"))

        let refusing = SecurityCLI { _ in throw ProcessRunnerError.timedOut(5) }
        XCTAssertFalse(refusing.itemExists(service: "s", account: "a"))
    }
}

/// Collects the argument vectors a stubbed runner was called with.
private final class ArgumentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    func record(_ arguments: [String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(arguments)
    }

    var recorded: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
