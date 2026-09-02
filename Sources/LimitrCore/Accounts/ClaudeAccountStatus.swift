import Foundation

/// What the CLI said about an account's login, including "it did not say".
public enum ClaudeSignInState: Sendable, Equatable {
    case loggedIn
    case loggedOut
    /// The CLI could not be run, did not answer in time, or answered something this
    /// code does not understand. Distinct from `.loggedOut` because the two demand
    /// opposite responses: one is news about the account, the other is news about the
    /// probe.
    case unknown
}

/// Authoritative answer to "is this Claude account logged in", from the CLI's own
/// `claude auth status --json`. Costs a subprocess (~215ms), so callers should cache
/// the result and rely on `ClaudeAccountMetadata` for anything render-frequency.
///
/// The probe exists for one job the config file cannot do: `claude auth logout` leaves
/// `oauthAccount` behind, so only the CLI knows the login is gone. That makes a negative
/// answer powerful — it overrides the file — and it is exactly why a *failed* probe must
/// never produce one. It used to: every spawn, exit-code, and parse failure returned
/// "logged out", the app cached it, and nothing re-read it after a sign-in, so a single
/// hiccup at the wrong instant left a fully signed-in account showing a Sign in button
/// until Limitr was restarted.
public struct ClaudeAccountStatus: Equatable, Sendable {
    public typealias Runner = @Sendable (URL, [String], [String: String]) throws -> ProcessResult

    public let state: ClaudeSignInState
    public let email: String?

    public static let loggedOut = ClaudeAccountStatus(state: .loggedOut, email: nil)
    public static let unknown = ClaudeAccountStatus(state: .unknown, email: nil)

    public init(state: ClaudeSignInState, email: String?) {
        self.state = state
        self.email = email
    }

    /// Whether this answer is a definite "no login here", and may therefore override the
    /// account's config file. The only caller that should read the raw state is a test.
    public var isDefinitelyLoggedOut: Bool { state == .loggedOut }

    /// Bounded so a wedged CLI cannot park a polling loop forever. Generous next to the
    /// ~215ms a healthy probe takes, because a cold start of the native binary is slower.
    public static let timeout: TimeInterval = 10

    /// Never throws: any failure to *ask* reads as `.unknown`, never as `.loggedOut`.
    public static func read(
        configDirectory: String?,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        run: Runner = ClaudeAccountStatus.spawn
    ) -> ClaudeAccountStatus {
        guard let executable = executableURL ?? findClaudeExecutable(environment: environment)
        else { return .unknown }

        var childEnvironment = environment
        if let configDirectory {
            childEnvironment["CLAUDE_CONFIG_DIR"] = configDirectory
        } else {
            // The default profile must run with no CLAUDE_CONFIG_DIR at all, even if
            // Limitr itself was launched with one inherited from a shell.
            childEnvironment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }

        guard let result = try? run(executable, ["auth", "status", "--json"], childEnvironment)
        else { return .unknown }
        // Parsed output beats the exit code: the CLI may well report a signed-out
        // account with a non-zero status, and the JSON is the more specific answer.
        return parse(Data(result.standardOutput.utf8))
    }

    public static func spawn(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws -> ProcessResult {
        try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: environment
        )
    }

    static func parse(_ data: Data) -> ClaudeAccountStatus {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return .unknown }
        return ClaudeAccountStatus(state: payload.loggedIn ? .loggedIn : .loggedOut, email: payload.email)
    }

    private static func findClaudeExecutable(environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        // A GUI app inherits launchd's PATH, not a shell's, so the well-known install
        // locations are not a nicety here — they are usually the only ones that hit.
        let fromPath = environment["PATH", default: ""]
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "claude") }
        let candidates = fromPath + [
            fileManager.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private struct Payload: Decodable {
        let loggedIn: Bool
        let email: String?
    }
}
