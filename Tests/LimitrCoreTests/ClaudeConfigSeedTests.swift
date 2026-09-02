import XCTest
@testable import LimitrCore

final class ClaudeConfigSeedTests: XCTestCase {
    func testCarriesTheOnboardingFlagsIntoANewAccount() {
        // The reported bug. `claude auth login` authenticates without marking onboarding
        // complete, so a second account had a valid credential and still met the first-run
        // wizard — whose opening step is signing in — the moment `claude` was run in a
        // plain terminal.
        let merged = ClaudeConfigSeed.merge(
            origin: ["hasCompletedOnboarding": true, "lastOnboardingVersion": "2.1.232"],
            into: ["oauthAccount": ["emailAddress": "someone@example.com"]]
        )
        XCTAssertEqual(merged?["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual(merged?["lastOnboardingVersion"] as? String, "2.1.232")
    }

    func testKeepsWhatTheAccountAlreadyDecidedForItself() {
        // Seeding fills gaps; it never restates the default profile's opinion over an
        // answer this account has already given.
        let merged = ClaudeConfigSeed.merge(
            origin: ["hasCompletedOnboarding": true, "mcpServers": ["a": ["command": "x"]]],
            into: ["hasCompletedOnboarding": false, "mcpServers": [:]]
        )
        XCTAssertNil(merged, "nothing was missing, so the file must not be rewritten")
    }

    func testLeavesTheAccountsOwnKeysAlone() {
        let merged = ClaudeConfigSeed.merge(
            origin: ["hasCompletedOnboarding": true],
            into: ["userID": "abc", "numStartups": 3]
        )
        XCTAssertEqual(merged?["userID"] as? String, "abc")
        XCTAssertEqual(merged?["numStartups"] as? Int, 3)
    }

    func testSkipsAnEmptyValueRatherThanSeedingNothing() {
        // A default profile with no MCP servers must not write an empty `mcpServers` that
        // then blocks a later seed — the original code's reason for checking emptiness.
        let merged = ClaudeConfigSeed.merge(
            origin: ["mcpServers": [:]],
            into: [:]
        )
        XCTAssertNil(merged)
    }

    func testIgnoresKeysTheDefaultProfileDoesNotHave() {
        let merged = ClaudeConfigSeed.merge(
            origin: ["hasCompletedOnboarding": true],
            into: [:]
        )
        XCTAssertEqual(merged?["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertNil(merged?["lastOnboardingVersion"])
    }

    func testCarriesMCPServersAsItAlwaysDid() {
        let merged = ClaudeConfigSeed.merge(
            origin: ["mcpServers": ["ledger": ["command": "run"]]],
            into: [:]
        )
        XCTAssertNotNil(merged?["mcpServers"] as? [String: Any])
    }

    func testFillsAGapEvenWhenAnotherSeededKeyIsAlreadyThere() {
        // The account created before this existed: it has the seeded `mcpServers` and is
        // missing only the onboarding flags. An all-or-nothing check would leave it broken
        // forever, which is exactly the account that reported the bug.
        let merged = ClaudeConfigSeed.merge(
            origin: ["mcpServers": ["ledger": ["command": "run"]], "hasCompletedOnboarding": true],
            into: ["mcpServers": ["ledger": ["command": "run"]]]
        )
        XCTAssertEqual(merged?["hasCompletedOnboarding"] as? Bool, true)
    }
}
