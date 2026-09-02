import XCTest
@testable import LimitrCore

final class CodexAccountMetadataTests: XCTestCase {
    func testReadsSafeClaimsFromIDToken() throws {
        let claims = #"{"email":"dev@example.com","name":"Dev","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#
        let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let auth = #"{"tokens":{"id_token":"header.\#(payload).signature"}}"#
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(auth.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(CodexAccountMetadata.read(from: file), CodexAccountMetadata(email: "dev@example.com", name: "Dev", planType: "plus"))
    }
}
