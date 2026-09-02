import Foundation

/// An account directory Limitr created and then lost track of.
///
/// "Lost track of" is not a hypothetical. An account's identity is a UUID that lives in
/// exactly one mutable place — the saved profile list — while the login it names lives in
/// two durable ones: the directory under Application Support, and a Keychain item whose
/// service name Claude derives from a hash of that directory's literal path. Lose the
/// profile row and both survive, addressable only through an identifier nothing holds any
/// more. Adding the account again mints a fresh UUID, which is a different path, which is
/// a different hash — so a login that is still perfectly valid has to be done from
/// scratch.
///
/// The directory name *is* the identifier, which is what makes recovery possible at all:
/// the one piece of state that went missing is still written down, in the only place the
/// credential cares about.
public struct OrphanedAccount: Equatable, Sendable, Identifiable {
    /// The identifier the account had, recovered from its directory name. Adopting it
    /// under any other value defeats the purpose.
    public let id: UUID
    public let service: UsageSource
    /// The literal `CLAUDE_CONFIG_DIR` / `CODEX_HOME` this account exports. Must be
    /// carried across unmodified — Claude hashes the raw string.
    public let configPath: String
    /// The email the account was signed in as, when it can be read without decrypting
    /// anything. Display only; it is what makes an orphan recognisable to the user.
    public let email: String?

    public init(id: UUID, service: UsageSource, configPath: String, email: String?) {
        self.id = id
        self.service = service
        self.configPath = configPath
        self.email = email
    }
}

/// Finds account directories that no saved profile points at any more.
///
/// Deliberately separate from `InstallationScanner`, which refuses to look inside
/// Application Support at all. That refusal is right for what it does: it reads
/// `CLAUDE_CONFIG_DIR` out of a login shell, and Limitr's own shell integration exports
/// that variable for the active account, so without the filter the scan re-offers an
/// account Limitr already manages as if the user had set it up by hand.
///
/// This asks a different question — "which of *my own* accounts has fallen out of the
/// list" — and answers it by identifier rather than by environment, so the same directory
/// can never be offered twice.
public enum OrphanedAccountScanner {
    private static let roots = ["Limitr", "Limiter"]

    /// - Parameters:
    ///   - knownIDs: every identifier the saved profile list holds, archived rows included.
    ///     An archived account is still tracked, so re-offering it would duplicate it.
    ///   - applicationSupport: the user's Application Support directory.
    public static func scan(
        knownIDs: Set<UUID>,
        applicationSupport: URL,
        fileManager: FileManager = .default
    ) -> [OrphanedAccount] {
        roots.flatMap { root -> [OrphanedAccount] in
            let accounts = applicationSupport.appending(path: "\(root)/Accounts")
            // Names, not URLs. `contentsOfDirectory(at:)` hands back paths with their
            // symlinks resolved, and the path is the one thing here that must survive
            // untouched: Claude hashes the literal `CLAUDE_CONFIG_DIR` string into its
            // Keychain service name, so a directory reported as `/private/var/…` when the
            // profile exported `/var/…` addresses a different item and reads as signed out
            // — the exact failure this scanner exists to undo.
            let names = (try? fileManager.contentsOfDirectory(atPath: accounts.path)) ?? []
            return names.flatMap { name -> [OrphanedAccount] in
                // The directory name carries the identifier. Anything else under here was
                // not put there by Limitr and is not ours to adopt.
                guard let id = UUID(uuidString: name), !knownIDs.contains(id) else { return [] }
                let directory = accounts.appending(path: name)
                return [claude(id: id, in: directory, fileManager: fileManager),
                        codex(id: id, in: directory, fileManager: fileManager)].compactMap { $0 }
            }
        }
    }

    /// A Claude directory counts once it has a config file naming an account: that is what
    /// `ClaudeConnectivity` needs to call it signed in, and a directory without one holds
    /// nothing a freshly created account would not also hold.
    private static func claude(id: UUID, in directory: URL, fileManager: FileManager) -> OrphanedAccount? {
        let config = directory.appending(path: "Claude")
        guard let metadata = ClaudeAccountMetadata.read(
            configDirectory: config,
            fileManager: fileManager
        ) else { return nil }
        return OrphanedAccount(id: id, service: .claude, configPath: config.path, email: metadata.email)
    }

    /// Codex keeps its credential in a file rather than the Keychain, so the file itself is
    /// the test — and unlike Claude, an account whose `auth.json` is gone really has
    /// nothing left to preserve.
    private static func codex(id: UUID, in directory: URL, fileManager: FileManager) -> OrphanedAccount? {
        let home = directory.appending(path: "Codex")
        let auth = home.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: auth.path) else { return nil }
        return OrphanedAccount(
            id: id,
            service: .codex,
            configPath: home.path,
            email: CodexAccountMetadata.read(from: auth)?.email
        )
    }
}
