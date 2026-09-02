import XCTest
@testable import LimitrCore

private let credentials = "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat-test\"}}"

private let usagePayload = """
{
  "five_hour":        { "utilization": 33.0, "resets_at": "2026-08-26T07:00:00Z" },
  "seven_day":        { "utilization": 13.0, "resets_at": "2026-09-01T00:59:59Z" },
  "seven_day_opus":   null,
  "seven_day_sonnet": { "utilization": 1.0,  "resets_at": "2026-08-31T03:00:00Z" },
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 100000,
    "used_credits": 25000.0,
    "utilization": 25.0
  }
}
"""


final class ClaudeProviderTests: XCTestCase {

    func testDefaultProfileUsesUnhashedKeychainService() {
        let provider = ClaudeProvider(accountID: "default", accountName: "Personal")

        XCTAssertEqual(provider.keychainServiceName, "Claude Code-credentials")
    }

    func testScopedProfileUsesHashedKeychainService() {
        let provider = ClaudeProvider(
            accountID: "work",
            accountName: "Work",
            configDirectory: "/tmp/limitr-test/Claude"
        )

        XCTAssertEqual(provider.keychainServiceName, "Claude Code-credentials-8fb4f5ef")
    }

    func testCredentialsFallbackResolvesInsideTheConfigDirectory() {
        let url = ClaudeProvider.credentialsFileURL(configDirectory: "/tmp/limitr-test/Claude")

        XCTAssertEqual(url.path, "/tmp/limitr-test/Claude/.credentials.json")
    }

    func testCredentialsFallbackResolvesInsideDotClaudeForTheDefaultProfile() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let url = ClaudeProvider.credentialsFileURL(
            configDirectory: nil,
            fileManager: StubHomeFileManager(home: home)
        )

        XCTAssertEqual(url.path, home.appending(path: ".claude/.credentials.json").path)
    }

    // MARK: - Reading the token

    func testReadsTheTokenThroughTheSecurityTool() throws {
        let token = try ClaudeProvider.credentialsToken(
            serviceNames: ["Claude Code-credentials"],
            account: "esa",
            fallback: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            security: SecurityCLI { _ in ProcessResult(status: 0, standardOutput: credentials + "\n", standardError: "") }
        )

        XCTAssertEqual(token, "sk-ant-oat-test")
    }

    /// The hashed name is asked first; an empty store there moves on rather than
    /// ending the search, which is what covers a default profile reached through an
    /// explicit `CLAUDE_CONFIG_DIR`.
    func testTriesEveryCandidateServiceInOrder() throws {
        let asked = Asked()
        let security = SecurityCLI { arguments in
            let service = arguments.last ?? ""
            asked.record(service)
            guard service == "Claude Code-credentials" else {
                return ProcessResult(status: 44, standardOutput: "", standardError: "not found")
            }
            return ProcessResult(status: 0, standardOutput: credentials + "\n", standardError: "")
        }

        let token = try ClaudeProvider.credentialsToken(
            serviceNames: ["Claude Code-credentials-8fb4f5ef", "Claude Code-credentials"],
            account: "esa",
            fallback: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
            security: security
        )

        XCTAssertEqual(token, "sk-ant-oat-test")
        XCTAssertEqual(asked.services, ["Claude Code-credentials-8fb4f5ef", "Claude Code-credentials"])
    }

    /// A locked or denied Keychain is not an absent login. Reporting it as
    /// `.credentialsMissing` tells the user to run `claude login`, which fixes nothing.
    func testReportsAKeychainRefusalSeparatelyFromAMissingCredential() {
        let security = SecurityCLI { _ in
            ProcessResult(status: 36, standardOutput: "", standardError: "User interaction is not allowed.")
        }

        XCTAssertThrowsError(
            try ClaudeProvider.credentialsToken(
                serviceNames: ["Claude Code-credentials"],
                account: "esa",
                fallback: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
                security: security
            )
        ) { error in
            guard case .keychainUnavailable = error as? ClaudeProviderError else {
                return XCTFail("expected .keychainUnavailable, got \(error)")
            }
        }
    }

    func testReportsMissingCredentialsWhenTheStoreIsGenuinelyEmpty() {
        let security = SecurityCLI { _ in ProcessResult(status: 44, standardOutput: "", standardError: "") }

        XCTAssertThrowsError(
            try ClaudeProvider.credentialsToken(
                serviceNames: ["Claude Code-credentials"],
                account: "esa",
                fallback: URL(fileURLWithPath: "/nonexistent/.credentials.json"),
                security: security
            )
        ) { error in
            XCTAssertEqual(
                (error as? ClaudeProviderError)?.errorDescription,
                ClaudeProviderError.credentialsMissing.errorDescription
            )
        }
    }

    func testFallsBackToTheCredentialsFileWhenNoKeychainItemExists() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: ".credentials.json")
        try credentials.write(to: file, atomically: true, encoding: .utf8)

        let token = try ClaudeProvider.credentialsToken(
            serviceNames: ["Claude Code-credentials"],
            account: "esa",
            fallback: file,
            security: SecurityCLI { _ in ProcessResult(status: 44, standardOutput: "", standardError: "") }
        )

        XCTAssertEqual(token, "sk-ant-oat-test")
    }


    // MARK: - Reading the payload

    func testDecodesEveryWindowThePayloadReports() throws {
        let usage = try ClaudeProvider.usage(from: Data(usagePayload.utf8), accountID: "work", accountName: "Work")

        XCTAssertEqual(usage.windows.map(\.label), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertEqual(usage.windows.first?.usedPercent, 33)
        XCTAssertEqual(usage.windows.first?.windowMinutes, 300)
        XCTAssertEqual(usage.windows.first?.accountID, "work")
        XCTAssertEqual(usage.windows.last?.windowMinutes, 10_080)
    }

    func testSurfacesTheExtraUsageMeterWhenTheAccountHasOne() throws {
        let usage = try ClaudeProvider.usage(from: Data(usagePayload.utf8), accountID: "work", accountName: "Work")

        XCTAssertEqual(usage.extraUsage?.utilization, 25)
        XCTAssertEqual(usage.extraUsage?.usedCredits, 25_000)
        XCTAssertEqual(usage.extraUsage?.monthlyLimit, 100_000)
    }

    /// Most accounts never switch extra usage on, and a meter for a facility nobody is
    /// spending from is a row that only takes up room.
    func testOmitsTheExtraUsageMeterWhenTheAccountHasItSwitchedOff() throws {
        let payload = usagePayload.replacingOccurrences(of: "\"is_enabled\": true", with: "\"is_enabled\": false")

        let usage = try ClaudeProvider.usage(from: Data(payload.utf8), accountID: "work", accountName: "Work")

        XCTAssertNil(usage.extraUsage)
    }

    func testOmitsTheExtraUsageMeterWhenThePayloadCarriesNone() throws {
        let usage = try ClaudeProvider.usage(
            from: Data(#"{"five_hour": {"utilization": 4.0, "resets_at": "2026-08-26T07:00:00Z"}}"#.utf8),
            accountID: "work",
            accountName: "Work"
        )

        XCTAssertNil(usage.extraUsage)
        XCTAssertEqual(usage.windows.count, 1)
    }

    /// A window with no reset instant cannot be counted down, so it is dropped rather
    /// than shown with an invented one.
    func testSkipsAWindowThatCarriesNoResetInstant() throws {
        let usage = try ClaudeProvider.usage(
            from: Data(#"{"five_hour": {"utilization": 4.0}, "seven_day": {"utilization": 9.0, "resets_at": "2026-09-01T00:59:59Z"}}"#.utf8),
            accountID: "work",
            accountName: "Work"
        )

        XCTAssertEqual(usage.windows.map(\.label), ["seven_day"])
    }

    func testRejectsAPayloadWithNoUsableWindow() {
        XCTAssertThrowsError(
            try ClaudeProvider.usage(
                from: Data(#"{"five_hour": null, "seven_day": null}"#.utf8),
                accountID: "work",
                accountName: "Work"
            )
        ) { error in
            XCTAssertEqual(
                (error as? ClaudeProviderError)?.errorDescription,
                ClaudeProviderError.responseInvalid.errorDescription
            )
        }
    }

    // MARK: - Failure classification

    /// Everything reachable before the request is assembled costs no rate-limit budget,
    /// so the app is free to retry it quickly. Everything after it is not.
    func testClassifiesPreRequestFailuresAsLocal() {
        XCTAssertTrue(ClaudeProviderError.credentialsMissing.isLocal)
        XCTAssertTrue(ClaudeProviderError.invalidCredentials.isLocal)
        XCTAssertTrue(ClaudeProviderError.keychainUnavailable("locked").isLocal)

        XCTAssertFalse(ClaudeProviderError.loginRequired.isLocal)
        XCTAssertFalse(ClaudeProviderError.rateLimited.isLocal)
        XCTAssertFalse(ClaudeProviderError.requestFailed(500).isLocal)
        XCTAssertFalse(ClaudeProviderError.responseInvalid.isLocal)
    }
}

/// Records the service name each stubbed `security` invocation asked for.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ service: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(service)
    }

    var services: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
