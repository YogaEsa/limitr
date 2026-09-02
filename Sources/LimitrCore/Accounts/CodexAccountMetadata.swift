import Foundation

public struct CodexAccountMetadata: Equatable, Sendable {
    public let email: String
    public let name: String?
    public let planType: String?

    public static func read(from authFile: URL) -> CodexAccountMetadata? {
        guard let data = try? Data(contentsOf: authFile),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let payload = decodeJWTPayload(auth.tokens.idToken),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              let email = claims.email, !email.isEmpty else { return nil }
        return CodexAccountMetadata(email: email, name: claims.name, planType: claims.auth?.planType)
    }

    private static func decodeJWTPayload(_ token: String) -> Data? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value)
    }
}

private struct AuthFile: Decodable {
    let tokens: Tokens
    struct Tokens: Decodable {
        let idToken: String
        enum CodingKeys: String, CodingKey { case idToken = "id_token" }
    }
}

private struct Claims: Decodable {
    let email: String?
    let name: String?
    let auth: AuthClaims?
    enum CodingKeys: String, CodingKey { case email, name; case auth = "https://api.openai.com/auth" }
}

private struct AuthClaims: Decodable {
    let planType: String?
    enum CodingKeys: String, CodingKey { case planType = "chatgpt_plan_type" }
}
