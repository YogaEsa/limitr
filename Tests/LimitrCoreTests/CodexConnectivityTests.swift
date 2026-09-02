import XCTest
@testable import LimitrCore

final class CodexConnectivityTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "CodexConnectivityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var authFile: URL { home.appending(path: "auth.json") }

    private func write(_ contents: String) throws {
        try Data(contents.utf8).write(to: authFile)
    }

    /// Shaped like a real `auth.json`, with every token replaced by a placeholder.
    private func authJSON(
        refreshToken: String? = "refresh-token-placeholder",
        apiKey: String? = nil
    ) -> String {
        let key = apiKey.map { "\"\($0)\"" } ?? "null"
        let refresh = refreshToken.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": \(key),
          "tokens": {
            "id_token": "id-token-placeholder",
            "access_token": "access-token-placeholder",
            "refresh_token": \(refresh),
            "account_id": "00000000-0000-0000-0000-000000000000"
          },
          "last_refresh": "2026-08-23T15:46:03.000Z"
        }
        """
    }

    func testReportsPresentForAChatGPTLogin() throws {
        try write(authJSON())

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .present)
    }

    func testReportsPresentForAnAPIKeyLogin() throws {
        try write(authJSON(refreshToken: nil, apiKey: "sk-placeholder"))

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .present)
    }

    func testReportsAbsentWithoutAnAuthFile() {
        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .absent)
    }

    func testReportsAbsentWhenTheFileNamesNoCredential() throws {
        // The reported bug. Connectivity was `fileExists` alone, so an `auth.json` left
        // behind with its tokens cleared read as a signed-in account while the CLI said
        // "Not logged in" — and, because the account looked connected, nothing prompted
        // the user to sign in again.
        try write(authJSON(refreshToken: nil, apiKey: nil))

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .absent)
    }

    func testTreatsAnEmptyStringTokenAsNoCredential() throws {
        try write(authJSON(refreshToken: "", apiKey: ""))

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .absent)
    }

    func testReportsUnknownForAFileItCannotParse() throws {
        // A half-written file is news about the read, not about the account. Signing an
        // account out over it would put a Sign in button on a working login — the same
        // distinction `ClaudeConnectivity` draws between `.absent` and `.unknown`.
        try write("{\"tokens\": {\"refresh_tok")

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .unknown)
    }

    func testReportsUnknownForAFileWhoseFieldsItDoesNotRecognise() throws {
        // Codex owns this format and can rename its fields. Reading a version this code
        // does not understand as "signed out" would put a Sign in button on every Codex
        // account at once, which is far worse than one stale row — so saying "signed out"
        // requires recognising the file well enough to be sure.
        try write(#"{"auth_mode": "chatgpt", "credentials": {"renamed": "value"}}"#)

        XCTAssertEqual(CodexConnectivity.credential(authFile: authFile), .unknown)
    }

    func testOnlyAbsenceSignsAnAccountOut() {
        XCTAssertTrue(CodexConnectivity.isSignedIn(credential: .present))
        XCTAssertTrue(CodexConnectivity.isSignedIn(credential: .unknown))
        XCTAssertFalse(CodexConnectivity.isSignedIn(credential: .absent))
    }
}
