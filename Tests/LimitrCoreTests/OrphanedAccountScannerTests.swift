import XCTest
@testable import LimitrCore

final class OrphanedAccountScannerTests: XCTestCase {
    private var root: URL!
    private var applicationSupport: URL!

    private let lost = UUID(uuidString: "68B33B79-F6C4-464F-A940-D283DC45520E")!
    private let known = UUID(uuidString: "5ECE7F54-DEAD-4A94-B0B4-F65C4C4D31D4")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        applicationSupport = root.appending(path: "Library/Application Support")
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Finding what the profile list lost

    func testFindsAnAccountDirectoryMissingFromTheProfileList() throws {
        try writeClaudeAccount(lost)

        let orphans = scan(knownIDs: [])

        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans[0].id, lost)
        XCTAssertEqual(orphans[0].service, .claude)
    }

    /// The property the whole feature turns on. Claude derives its Keychain service name
    /// from a hash of the literal `CLAUDE_CONFIG_DIR`, and that path contains the profile's
    /// identifier — so an adopted account only keeps its login if it comes back under the
    /// *same* identifier and the *same* path. Handing it a fresh UUID is what burns the
    /// credential and forces `claude auth login` again.
    func testKeepsTheOriginalIdentifierAndPathSoTheCredentialStillResolves() throws {
        let directory = try writeClaudeAccount(lost)

        let orphan = try XCTUnwrap(scan(knownIDs: []).first)

        XCTAssertEqual(orphan.id, lost)
        XCTAssertEqual(orphan.configPath, directory.path)
        XCTAssertEqual(
            ClaudeKeychain.serviceName(configDirectory: orphan.configPath),
            ClaudeKeychain.serviceName(configDirectory: directory.path)
        )
    }

    func testIgnoresAnAccountTheProfileListAlreadyHas() throws {
        try writeClaudeAccount(known)

        XCTAssertEqual(scan(knownIDs: [known]), [])
    }

    func testReportsOnlyTheAccountsMissingFromAListThatHasOthers() throws {
        try writeClaudeAccount(known)
        try writeClaudeAccount(lost)

        let orphans = scan(knownIDs: [known])

        XCTAssertEqual(orphans.map(\.id), [lost])
    }

    // MARK: - What counts as worth adopting

    /// An account directory that was never signed into holds nothing a fresh one would not
    /// also give, so offering it back just spends one of the three per-service slots.
    func testIgnoresAClaudeDirectoryThatWasNeverSignedIn() throws {
        try FileManager.default.createDirectory(
            at: accountsRoot().appending(path: "\(lost.uuidString)/Claude"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(scan(knownIDs: []), [])
    }

    func testIgnoresACodexDirectoryWhoseCredentialIsGone() throws {
        try FileManager.default.createDirectory(
            at: accountsRoot().appending(path: "\(lost.uuidString)/Codex/sessions"),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(scan(knownIDs: []), [])
    }

    func testFindsACodexAccountByItsAuthFile() throws {
        let directory = accountsRoot().appending(path: "\(lost.uuidString)/Codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: "auth.json"))

        let orphan = try XCTUnwrap(scan(knownIDs: []).first)

        XCTAssertEqual(orphan.service, .codex)
        XCTAssertEqual(orphan.configPath, directory.path)
    }

    /// One directory can hold both, because the two CLIs are scoped independently.
    func testReportsBothServicesLivingUnderOneIdentifier() throws {
        try writeClaudeAccount(lost)
        let codex = accountsRoot().appending(path: "\(lost.uuidString)/Codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codex.appending(path: "auth.json"))

        let orphans = scan(knownIDs: [])

        XCTAssertEqual(Set(orphans.map(\.service)), [.claude, .codex])
    }

    // MARK: - Where to look

    /// Accounts created before the rename still live under the old root, and deliberately
    /// stay there: Claude hashes the literal path, so moving them would log them all out.
    func testScansThePreRenameRootAsWell() throws {
        try writeClaudeAccount(lost, root: "Limiter")

        XCTAssertEqual(scan(knownIDs: []).map(\.id), [lost])
    }

    func testIgnoresDirectoryNamesThatAreNotIdentifiers() throws {
        let directory = accountsRoot().appending(path: "not-a-uuid/Claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: ".claude.json"))

        XCTAssertEqual(scan(knownIDs: []), [])
    }

    func testAnswersEmptyWhenLimitrHasNeverCreatedAnAccount() {
        XCTAssertEqual(scan(knownIDs: []), [])
    }

    // MARK: - Helpers

    private func scan(knownIDs: Set<UUID>) -> [OrphanedAccount] {
        OrphanedAccountScanner.scan(knownIDs: knownIDs, applicationSupport: applicationSupport)
            .sorted { $0.configPath < $1.configPath }
    }

    private func accountsRoot(_ name: String = "Limitr") -> URL {
        applicationSupport.appending(path: "\(name)/Accounts")
    }

    @discardableResult
    private func writeClaudeAccount(_ id: UUID, root name: String = "Limitr") throws -> URL {
        let directory = accountsRoot(name).appending(path: "\(id.uuidString)/Claude")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"dev@example.com"}}"#.utf8)
            .write(to: directory.appending(path: ".claude.json"))
        return directory
    }
}
