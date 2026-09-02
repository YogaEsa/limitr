import CryptoKit
import Foundation

/// Mirrors how the Claude Code CLI names its Keychain items so Limitr can read
/// the OAuth token belonging to one specific `CLAUDE_CONFIG_DIR`.
///
/// The CLI derives the service name as
/// `"Claude Code" + suffix + (configDirIsDefault ? "" : "-" + sha256(NFC(configDir)).hex[0..<8])`
/// and queries it as a generic-password item for the current user and service.
/// This naming is undocumented; callers must degrade gracefully if the lookup fails.
public enum ClaudeKeychain {
    private static let credentialsService = "Claude Code-credentials"

    /// Claude Code sources secure storage from this variable when it is *defined*,
    /// falling back to `CLAUDE_CONFIG_DIR` only when it is not.
    private static let secureStorageVariable = "CLAUDE_SECURESTORAGE_CONFIG_DIR"

    /// - Parameter configDirectory: the literal `CLAUDE_CONFIG_DIR` value that will be
    ///   exported for this account, or `nil` for the default `~/.claude` login. The CLI
    ///   hashes the raw string, so it must not be resolved or canonicalized first.
    public static func serviceName(configDirectory: String?) -> String {
        guard let configDirectory, !configDirectory.isEmpty else { return credentialsService }
        let normalized = configDirectory.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(credentialsService)-\(hex.prefix(8))"
    }

    /// Every Keychain service that may hold this profile's OAuth credential, in the
    /// order they should be tried.
    ///
    /// More than one name is needed for a single case: a `CLAUDE_CONFIG_DIR` that
    /// names the *default* profile. Claude hashes whatever the variable says, so it
    /// writes a suffixed item there — but someone who has always used the default
    /// profile may only ever have had the unsuffixed one, and which of the two holds
    /// the credential depends on history Limitr cannot see. Trying the hashed name
    /// first keeps the more specific answer winning.
    ///
    /// A defined `CLAUDE_SECURESTORAGE_CONFIG_DIR` gets no fallback: it names the only
    /// store Claude will read for this environment, so reaching into another one would
    /// report a credential Claude is not using.
    public static func serviceNames(
        configDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [String] {
        if let secureStorage = environment[secureStorageVariable] {
            return [serviceName(configDirectory: secureStorage.isEmpty ? nil : secureStorage)]
        }
        guard let configDirectory, !configDirectory.isEmpty else { return [credentialsService] }
        let hashed = serviceName(configDirectory: configDirectory)
        guard namesDefaultProfile(configDirectory, fileManager: fileManager) else { return [hashed] }
        return [hashed, credentialsService]
    }

    /// Whether a config directory resolves to the default `~/.claude`, symlinks and all.
    /// An unresolvable path answers `false`: treating an unknown profile as the default
    /// is what would license reading another account's credential.
    private static func namesDefaultProfile(_ configDirectory: String, fileManager: FileManager) -> Bool {
        let candidate = URL(fileURLWithPath: configDirectory).standardizedFileURL
        let `default` = fileManager.homeDirectoryForCurrentUser
            .appending(path: ".claude").standardizedFileURL
        if candidate.path == `default`.path { return true }
        guard let resolved = try? fileManager.destinationOfSymbolicLink(atPath: candidate.path)
        else { return false }
        return URL(fileURLWithPath: resolved, relativeTo: candidate.deletingLastPathComponent())
            .standardizedFileURL.path == `default`.path
    }

    /// The Keychain account name, mirroring Claude Code's `getUsername()`.
    ///
    /// Matching it exactly is the whole job: a divergent value keys a *different*
    /// Keychain item than the one the CLI wrote, which reads as a permanently
    /// signed-out account. So there is no character filter here — the CLI has none
    /// either, and a name only ever reaches `execve` as its own argument, where a
    /// shell metacharacter is data rather than syntax.
    public static func account(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osUserName: () -> String = { NSUserName() }
    ) -> String {
        if let user = environment["USER"], !user.isEmpty { return user }
        let name = osUserName()
        return name.isEmpty ? "claude-code-user" : name
    }
}
