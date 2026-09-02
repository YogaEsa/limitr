import XCTest
@testable import LimitrCore

final class ClaudeConnectivityTests: XCTestCase {
    private static let configDirectory = "/tmp/limitr-tests/Work/Claude"
    private let environment = ["USER": "esa"]

    /// Answers a keychain lookup per service name. The argument vector is
    /// `["find-generic-password", "-a", account, "-s", service]`, so the service is last.
    private func security(_ answer: @escaping @Sendable (String) -> Int32) -> SecurityCLI {
        SecurityCLI { arguments in
            ProcessResult(status: answer(arguments.last ?? ""), standardOutput: "", standardError: "")
        }
    }

    func testPresentWhenTheKeychainHoldsThisProfilesItem() {
        let hashed = ClaudeKeychain.serviceName(configDirectory: Self.configDirectory)

        let credential = ClaudeConnectivity.credential(
            configDirectory: Self.configDirectory,
            environment: environment,
            security: security { $0 == hashed ? 0 : 44 }
        )

        XCTAssertEqual(credential, .present)
    }

    /// `errSecItemNotFound` from every candidate name, with no plaintext file to fall
    /// back to, is the one answer that may sign an account out.
    func testAbsentWhenNoCandidateServiceHoldsAnything() {
        let credential = ClaudeConnectivity.credential(
            configDirectory: Self.configDirectory,
            environment: environment,
            security: security { _ in 44 }
        )

        XCTAssertEqual(credential, .absent)
    }

    /// A locked or refusing Keychain is news about the reader, not about the account.
    /// Collapsing it into `.absent` would put a Sign in button on every row at once.
    func testUnknownWhenTheKeychainCouldNotBeAsked() {
        let unreachable = SecurityCLI { _ in throw ProcessRunnerError.timedOut(5) }

        let credential = ClaudeConnectivity.credential(
            configDirectory: Self.configDirectory,
            environment: environment,
            security: unreachable
        )

        XCTAssertEqual(credential, .unknown)

        let refusing = ClaudeConnectivity.credential(
            configDirectory: Self.configDirectory,
            environment: environment,
            security: security { _ in 36 }
        )

        XCTAssertEqual(refusing, .unknown)
    }

    /// There is no `.credentials.json` on macOS — Claude Code uses the Keychain — so this
    /// catches other platforms and seeds left by hand, never the ordinary case.
    func testFallsBackToThePlaintextCredentialsFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "limitr-credential-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appending(path: ".credentials.json"))

        let credential = ClaudeConnectivity.credential(
            configDirectory: directory.path,
            environment: environment,
            security: security { _ in 44 }
        )

        XCTAssertEqual(credential, .present)
    }

    /// The bug this rule exists for: `claude auth logout` and a wiped Keychain both leave
    /// `oauthAccount` in the config file, so the file alone reports a signed-out account
    /// as connected. A sign-in watch that trusts it concludes before the login has landed.
    func testAConfigFileAloneIsNotASignIn() {
        XCTAssertFalse(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: true,
                credential: .absent,
                cliVerdict: .unknown
            )
        )
    }

    func testACredentialAndAConfigAccountIsASignIn() {
        XCTAssertTrue(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: true,
                credential: .present,
                cliVerdict: .unknown
            )
        )
    }

    /// An unreadable Keychain leaves the config file's verdict standing, matching how an
    /// indeterminate CLI probe is treated.
    func testAnUnreadableKeychainLeavesTheConfigFilesVerdictStanding() {
        XCTAssertTrue(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: true,
                credential: .unknown,
                cliVerdict: .unknown
            )
        )
        XCTAssertFalse(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: false,
                credential: .unknown,
                cliVerdict: .unknown
            )
        )
    }

    /// The CLI saying so still outranks both, which is what catches a logout that left
    /// its Keychain item behind.
    func testADefiniteCLILogoutOverridesAPresentCredential() {
        XCTAssertFalse(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: true,
                credential: .present,
                cliVerdict: .loggedOut
            )
        )
    }

    func testAnIndeterminateProbeNeverSignsAnAccountOut() {
        XCTAssertTrue(
            ClaudeConnectivity.isSignedIn(
                configNamesAccount: true,
                credential: .present,
                cliVerdict: .unknown
            )
        )
    }
}
