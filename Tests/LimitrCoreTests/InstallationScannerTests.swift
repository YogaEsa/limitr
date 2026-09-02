import XCTest
@testable import LimitrCore

final class InstallationScannerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var applicationSupport: URL!
    private var binaries: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        home = root.appending(path: "home")
        applicationSupport = root.appending(path: "home/Library/Application Support")
        binaries = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Default homes

    func testFindsTheDefaultClaudeLogin() throws {
        try writeClaudeConfig(at: home, email: "dev@example.com")

        let claude = try XCTUnwrap(scan().first { $0.source == .claude })

        XCTAssertEqual(claude.logins.count, 1)
        XCTAssertNil(claude.logins[0].configPath, "the CLI's own home must stay unconfigured")
        XCTAssertEqual(claude.logins[0].email, "dev@example.com")
        XCTAssertEqual(claude.logins[0].discoveredVia, .defaultHome)
    }

    func testFindsTheDefaultCodexLogin() throws {
        try writeCodexAuth(at: home.appending(path: ".codex"), email: "dev@example.com")

        let codex = try XCTUnwrap(scan().first { $0.source == .codex })

        XCTAssertEqual(codex.logins.count, 1)
        XCTAssertNil(codex.logins[0].configPath)
        XCTAssertEqual(codex.logins[0].email, "dev@example.com")
    }

    func testReportsNoLoginWhenTheConfigHasNoAccount() throws {
        try Data(#"{"autoUpdates":true}"#.utf8).write(to: home.appending(path: ".claude.json"))

        XCTAssertEqual(scan().first { $0.source == .claude }?.logins.count, 0)
    }

    // MARK: - Custom locations

    func testFindsALoginBehindACustomConfigDirectory() throws {
        let custom = root.appending(path: "work-claude")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try writeClaudeConfig(at: custom, email: "work@example.com")

        let claude = try XCTUnwrap(scan(environment: ["CLAUDE_CONFIG_DIR": custom.path]).first { $0.source == .claude })

        XCTAssertEqual(claude.logins.count, 1)
        XCTAssertEqual(claude.logins[0].configPath, custom.path)
        XCTAssertEqual(claude.logins[0].email, "work@example.com")
        XCTAssertEqual(claude.logins[0].discoveredVia, .environment)
    }

    func testFindsACodexHomeBehindAnEnvironmentVariable() throws {
        let custom = root.appending(path: "work-codex")
        try writeCodexAuth(at: custom, email: "work@example.com")

        let codex = try XCTUnwrap(scan(environment: ["CODEX_HOME": custom.path]).first { $0.source == .codex })

        XCTAssertEqual(codex.logins.map(\.configPath), [custom.path])
        XCTAssertEqual(codex.logins[0].discoveredVia, .environment)
    }

    func testTreatsAnEnvironmentVariablePointingAtTheDefaultHomeAsTheDefault() throws {
        // Reporting `~/.claude` as a custom directory would hand the account a
        // `CLAUDE_CONFIG_DIR` export, which switches the CLI to a hashed Keychain name and
        // orphans the very login that was just found.
        try writeClaudeConfig(at: home, email: "dev@example.com")

        let claude = try XCTUnwrap(scan(environment: ["CLAUDE_CONFIG_DIR": home.appending(path: ".claude").path]).first { $0.source == .claude })

        XCTAssertEqual(claude.logins.count, 1)
        XCTAssertNil(claude.logins[0].configPath)
        XCTAssertEqual(claude.logins[0].discoveredVia, .defaultHome)
    }

    func testIgnoresConfigDirectoriesLimitrManagesItself() throws {
        // Limitr's own shell integration exports these variables for whichever account is
        // active. Without this the scanner rediscovers Limitr's managed account and offers
        // it back to the user as a pre-existing install.
        let managed = applicationSupport.appending(path: "Limitr/Accounts/\(UUID().uuidString)/Claude")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        try writeClaudeConfig(at: managed, email: "managed@example.com")

        let claude = try XCTUnwrap(scan(environment: ["CLAUDE_CONFIG_DIR": managed.path]).first { $0.source == .claude })

        XCTAssertEqual(claude.logins.count, 0)
    }

    func testIgnoresDirectoriesManagedUnderTheLegacyName() throws {
        let managed = applicationSupport.appending(path: "Limiter/Accounts/\(UUID().uuidString)/Codex")
        try writeCodexAuth(at: managed, email: "managed@example.com")

        let codex = try XCTUnwrap(scan(environment: ["CODEX_HOME": managed.path]).first { $0.source == .codex })

        XCTAssertEqual(codex.logins.count, 0)
    }

    func testIgnoresAnEnvironmentVariableThatPointsNowhere() throws {
        let claude = try XCTUnwrap(scan(environment: ["CLAUDE_CONFIG_DIR": root.appending(path: "gone").path]).first { $0.source == .claude })

        XCTAssertEqual(claude.logins.count, 0)
    }

    // MARK: - Executables

    func testReportsTheExecutableItFound() throws {
        try writeExecutable("claude")

        XCTAssertEqual(scan().first { $0.source == .claude }?.executablePath, binaries.appending(path: "claude").path)
        XCTAssertNil(scan().first { $0.source == .codex }?.executablePath)
    }

    func testReportsAnInstalledCLIThatIsNotSignedIn() throws {
        try writeExecutable("codex")

        let codex = try XCTUnwrap(scan().first { $0.source == .codex })

        XCTAssertTrue(codex.isInstalled)
        XCTAssertTrue(codex.logins.isEmpty)
    }

    func testAlwaysReportsBothServices() {
        XCTAssertEqual(scan().map(\.source), [.claude, .codex])
    }

    // MARK: - Fixtures

    private func scan(environment: [String: String] = [:]) -> [DetectedService] {
        InstallationScanner(
            home: home,
            applicationSupport: applicationSupport,
            environment: environment,
            executableDirectories: [binaries]
        ).scan()
    }

    /// The default profile's config sits beside `~/.claude` as `~/.claude.json`; a custom
    /// profile's sits inside its own directory under the same name.
    private func writeClaudeConfig(at directory: URL, email: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"\#(email)"}}"#.utf8)
            .write(to: directory.appending(path: ".claude.json"))
    }

    private func writeCodexAuth(at home: URL, email: String) throws {
        let claims = #"{"email":"\#(email)"}"#
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"id_token":"header.\#(payload).signature"}}"#.utf8)
            .write(to: home.appending(path: "auth.json"))
    }

    private func writeExecutable(_ name: String) throws {
        let url = binaries.appending(path: name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
