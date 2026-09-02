import Foundation

/// Answers "is this Claude account signed in", from the two pieces of evidence the CLI
/// leaves on disk.
///
/// Split out of the app so the rule can be exercised directly, because the rule is where
/// this went wrong. Connectivity used to be read from `oauthAccount` in `.claude.json`
/// alone — a field Claude Code writes at sign-in and never clears. An account whose
/// credential is gone therefore still reads as connected, and `watchConnectivity`, which
/// polls that same answer to decide a sign-in has landed, concluded on its first tick two
/// seconds after Terminal opened — minutes before the browser login it was waiting for.
/// The CLI probe it then took as its concluding reading said, correctly, "logged out";
/// nothing re-probes an account that reads as disconnected, so the row stayed pinned to a
/// Sign in button until Limitr was relaunched, and pressing it re-ran a login the user had
/// already completed.
///
/// The credential is the thing that actually appears at sign-in and disappears at logout,
/// so it is what the answer now turns on.
public enum ClaudeConnectivity {
    /// Whether this config directory has an OAuth credential, without decrypting one.
    ///
    /// Mirrors `ClaudeProvider.credentialsToken`'s resolution — every candidate service
    /// name, then the plaintext file — but asks only whether something is there, so it
    /// stays cheap enough for the snapshot loop and can never raise a Keychain prompt.
    ///
    /// - Parameter configDirectory: the literal `CLAUDE_CONFIG_DIR` this account exports,
    ///   or nil for the default `~/.claude` login. Claude hashes the raw string into its
    ///   service name, so it must not be resolved or canonicalized first.
    public static func credential(
        configDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        security: SecurityCLI = SecurityCLI()
    ) -> CredentialPresence {
        let account = ClaudeKeychain.account(environment: environment)
        let services = ClaudeKeychain.serviceNames(
            configDirectory: configDirectory,
            environment: environment,
            fileManager: fileManager
        )

        var unreadable = false
        for service in services {
            switch security.itemPresence(service: service, account: account) {
            case .present: return .present
            // `errSecItemNotFound` is Claude's own signal that this store is empty, so it
            // moves on to the next candidate rather than ending the search.
            case .absent: continue
            case .unknown: unreadable = true
            }
        }

        // There is no `.credentials.json` on macOS — Claude Code stores credentials in the
        // Keychain — so this catches other platforms and seeds left by hand, never the
        // ordinary case.
        let fallback = ClaudeProvider.credentialsFileURL(
            configDirectory: configDirectory,
            fileManager: fileManager
        )
        if fileManager.fileExists(atPath: fallback.path) { return .present }

        // Only a Keychain that answered may sign an account out. One that would not talk
        // leaves the question open for the config file to settle.
        return unreadable ? .unknown : .absent
    }

    /// Whether an account should be shown, and polled, as signed in.
    ///
    /// - Parameters:
    ///   - configNamesAccount: whether the config file carries an `oauthAccount`. Weak
    ///     evidence on its own — it outlives the login — but it is what supplies the email,
    ///     and a directory without one has never been signed in at all.
    ///   - credential: what the Keychain says. `.absent` is the only decisive negative.
    ///   - cliVerdict: the last thing `claude auth status` said, if anything. `.loggedOut`
    ///     still overrides a present credential, which is what catches a logout that left
    ///     its Keychain item behind; `.unknown` never signs an account out.
    public static func isSignedIn(
        configNamesAccount: Bool,
        credential: CredentialPresence,
        cliVerdict: ClaudeSignInState
    ) -> Bool {
        guard configNamesAccount, credential != .absent else { return false }
        return cliVerdict != .loggedOut
    }
}
