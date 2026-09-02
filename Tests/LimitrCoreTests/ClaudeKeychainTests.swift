import XCTest
@testable import LimitrCore

final class ClaudeKeychainTests: XCTestCase {
    func testUsesUnhashedServiceNameForDefaultLogin() {
        XCTAssertEqual(ClaudeKeychain.serviceName(configDirectory: nil), "Claude Code-credentials")
    }

    func testScopesServiceNameToConfigDirectory() {
        XCTAssertEqual(
            ClaudeKeychain.serviceName(configDirectory: "/tmp/limitr-test/Claude"),
            "Claude Code-credentials-8fb4f5ef"
        )
    }

    func testNormalizesConfigDirectoryToNFCBeforeHashing() {
        let composed = "/tmp/caf\u{00E9}/Claude"
        let decomposed = "/tmp/cafe\u{0301}/Claude"
        XCTAssertEqual(ClaudeKeychain.serviceName(configDirectory: composed), "Claude Code-credentials-24a15ef2")
        XCTAssertEqual(
            ClaudeKeychain.serviceName(configDirectory: decomposed),
            ClaudeKeychain.serviceName(configDirectory: composed)
        )
    }

    // MARK: - Account name

    func testUsesEnvironmentUserAsKeychainAccount() {
        XCTAssertEqual(ClaudeKeychain.account(environment: ["USER": "esa.dev-1"]), "esa.dev-1")
    }

    /// Claude Code's `getUsername()` applies no character filter, and the account name
    /// has to match it byte for byte or Limitr looks up an item the CLI never wrote.
    /// The name only ever reaches `execve` as its own argument, so a shell
    /// metacharacter in it is data rather than syntax.
    func testMirrorsClaudeCodeUsernameWithoutFiltering() {
        XCTAssertEqual(ClaudeKeychain.account(environment: ["USER": "bad user!"]), "bad user!")
        XCTAssertEqual(ClaudeKeychain.account(environment: ["USER": "esa;rm -rf"]), "esa;rm -rf")
    }

    func testFallsBackToPlaceholderOnlyWhenNoUsernameIsAvailable() {
        XCTAssertEqual(
            ClaudeKeychain.account(environment: ["USER": ""], osUserName: { "" }),
            "claude-code-user"
        )
    }

    func testFallsBackToTheOSUserNameWhenUserIsUnset() {
        XCTAssertEqual(ClaudeKeychain.account(environment: [:], osUserName: { "esa" }), "esa")
    }

    // MARK: - Service try-order

    func testServiceNamesResolveToTheHashedItemForAScopedProfile() {
        XCTAssertEqual(
            ClaudeKeychain.serviceNames(configDirectory: "/tmp/limitr-test/Claude", environment: [:]),
            ["Claude Code-credentials-8fb4f5ef"]
        )
    }

    /// Claude hashes whatever `CLAUDE_CONFIG_DIR` names, so a variable pointing at the
    /// default profile yields a *suffixed* item — but a long-time default user may only
    /// ever have had the unsuffixed one. Both are tried, hashed first.
    func testFallsBackToTheUnsuffixedItemWhenTheConfigDirectoryIsTheDefaultProfile() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let claude = home.appending(path: ".claude").path

        let names = ClaudeKeychain.serviceNames(
            configDirectory: claude,
            environment: [:],
            fileManager: StubHomeFileManager(home: home)
        )

        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(names.first, ClaudeKeychain.serviceName(configDirectory: claude))
        XCTAssertEqual(names.last, "Claude Code-credentials")
    }

    /// Claude Code sources secure storage from `CLAUDE_SECURESTORAGE_CONFIG_DIR` when it
    /// is defined, ignoring `CLAUDE_CONFIG_DIR` entirely.
    func testSecureStorageDirectoryOverridesTheConfigDirectory() {
        XCTAssertEqual(
            ClaudeKeychain.serviceNames(
                configDirectory: "/tmp/limitr-test/Claude",
                environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/other/Claude"]
            ),
            [ClaudeKeychain.serviceName(configDirectory: "/tmp/other/Claude")]
        )
    }

    /// Defined-but-empty selects the *default* secure store, whose item is unsuffixed.
    /// It names the only store Claude will read here, so there is no fallback: reaching
    /// into another one would report a credential Claude is not using.
    func testEmptySecureStorageDirectorySelectsTheDefaultStoreAlone() {
        XCTAssertEqual(
            ClaudeKeychain.serviceNames(
                configDirectory: "/tmp/limitr-test/Claude",
                environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]
            ),
            ["Claude Code-credentials"]
        )
    }

    func testDefaultProfileResolvesToTheUnsuffixedItemAlone() {
        XCTAssertEqual(
            ClaudeKeychain.serviceNames(configDirectory: nil, environment: [:]),
            ["Claude Code-credentials"]
        )
    }
}
