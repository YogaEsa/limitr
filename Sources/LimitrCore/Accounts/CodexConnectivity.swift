import Foundation

/// Answers "is this Codex account signed in", from the credential file the CLI keeps.
///
/// Sibling of `ClaudeConnectivity`, and it exists for the same reason: connectivity used
/// to be `FileManager.fileExists(atPath:)` on `auth.json` and nothing more. The file's
/// presence is not the login — `auth.json` also holds `auth_mode`, an account id and a
/// `last_refresh` stamp, so one left behind with its tokens cleared still exists. Limitr
/// read that as a signed-in account while `codex login status` said "Not logged in", and
/// because the row looked connected nothing ever suggested signing in again.
///
/// Unlike Claude this needs no Keychain and no subprocess: Codex keeps the credential in
/// a file Limitr can already read. What it borrows is the three-valued answer, and for
/// the same reason — a file that will not parse is news about the read, not about the
/// account, and must not put a Sign in button on a working login.
public enum CodexConnectivity {
    /// Whether this Codex home holds a usable credential.
    ///
    /// - Parameter authFile: `<CODEX_HOME>/auth.json`.
    public static func credential(authFile: URL, fileManager: FileManager = .default) -> CredentialPresence {
        guard fileManager.fileExists(atPath: authFile.path) else { return .absent }
        guard let data = try? Data(contentsOf: authFile),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }

        // Either credential is enough on its own: an API-key login carries no tokens, and
        // a ChatGPT login carries no API key. The refresh token is the one that matters
        // for the latter — access and id tokens expire hourly and are reissued from it,
        // so their age says nothing about whether the account is still signed in.
        if let key = auth[apiKeyField] as? String, !key.isEmpty { return .present }
        let tokens = auth[tokensField] as? [String: Any]
        if let refresh = tokens?[refreshTokenField] as? String, !refresh.isEmpty { return .present }

        // Saying "signed out" means recognising the file well enough to be sure. Codex
        // owns this format and can change it; a version that renamed both fields would
        // otherwise sign every Codex account out at once, which is a far worse failure
        // than showing one stale row. Absence of a *known* field is the evidence.
        guard auth.keys.contains(apiKeyField) || auth.keys.contains(tokensField) else { return .unknown }
        return .absent
    }

    private static let apiKeyField = "OPENAI_API_KEY"
    private static let tokensField = "tokens"
    private static let refreshTokenField = "refresh_token"

    /// Whether an account should be shown, and polled, as signed in.
    ///
    /// Only `.absent` may sign an account out, matching `ClaudeConnectivity.isSignedIn`:
    /// a file Limitr could not read is a reason to say nothing, not a reason to claim the
    /// login is gone.
    public static func isSignedIn(credential: CredentialPresence) -> Bool {
        credential != .absent
    }
}
