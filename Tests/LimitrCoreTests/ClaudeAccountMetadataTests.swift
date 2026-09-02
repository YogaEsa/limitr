import XCTest
@testable import LimitrCore

final class ClaudeAccountMetadataTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testReadsEmailAndPlanFromConfigDirectory() throws {
        let directory = try makeDirectory()
        let json = #"{"oauthAccount":{"emailAddress":"dev@example.com","displayName":"Dev","organizationType":"claude_pro"}}"#
        try Data(json.utf8).write(to: directory.appending(path: ".claude.json"))

        XCTAssertEqual(
            ClaudeAccountMetadata.read(configDirectory: directory),
            ClaudeAccountMetadata(email: "dev@example.com", displayName: "Dev", planType: "claude_pro")
        )
    }

    func testPrefersConfigJSONOverClaudeJSON() throws {
        let directory = try makeDirectory()
        try Data(#"{"oauthAccount":{"emailAddress":"ignored@example.com"}}"#.utf8)
            .write(to: directory.appending(path: ".claude.json"))
        try Data(#"{"oauthAccount":{"emailAddress":"wins@example.com"}}"#.utf8)
            .write(to: directory.appending(path: ".config.json"))

        XCTAssertEqual(ClaudeAccountMetadata.read(configDirectory: directory)?.email, "wins@example.com")
    }

    func testReturnsNilForFreshlyBootstrappedConfigDirectory() throws {
        let directory = try makeDirectory()
        // Exactly the shape the CLI writes into a brand-new CLAUDE_CONFIG_DIR before login.
        let json = #"{"firstStartTime":"2026-08-12T02:44:09.225Z","migrationVersion":13,"seenNotifications":{}}"#
        try Data(json.utf8).write(to: directory.appending(path: ".claude.json"))

        XCTAssertNil(ClaudeAccountMetadata.read(configDirectory: directory))
    }

    func testReturnsNilForMissingOrMalformedFile() throws {
        let directory = try makeDirectory()
        XCTAssertNil(ClaudeAccountMetadata.read(configDirectory: directory))

        try Data("not json".utf8).write(to: directory.appending(path: ".claude.json"))
        XCTAssertNil(ClaudeAccountMetadata.read(configDirectory: directory))
    }

    func testDefaultProfileReadsClaudeJSONBesideTheHomeDirectory() throws {
        let home = try makeDirectory()
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"default@example.com"}}"#.utf8)
            .write(to: home.appending(path: ".claude.json"))

        let fileManager = StubHomeFileManager(home: home)
        XCTAssertEqual(
            ClaudeAccountMetadata.read(configDirectory: nil, fileManager: fileManager)?.email,
            "default@example.com"
        )
    }
}

/// Redirects `homeDirectoryForCurrentUser` so the default-profile path can be
/// exercised without touching the real home directory.
final class StubHomeFileManager: FileManager, @unchecked Sendable {
    private let home: URL

    init(home: URL) {
        self.home = home
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { home }
}
