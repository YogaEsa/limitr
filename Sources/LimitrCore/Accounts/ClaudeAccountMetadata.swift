import Foundation

/// Reads the display identity of one Claude account from its config directory.
/// Sibling of `CodexAccountMetadata`; returns nil rather than throwing so the UI
/// can treat "unknown" and "not logged in" the same way.
public struct ClaudeAccountMetadata: Equatable, Sendable {
    public let email: String
    public let displayName: String?
    public let planType: String?

    public static func read(configDirectory: URL?, fileManager: FileManager = .default) -> ClaudeAccountMetadata? {
        read(configFile: configFile(configDirectory: configDirectory, fileManager: fileManager))
    }

    /// Mirrors the CLI's resolution: `<dir>/.config.json` wins when present, otherwise
    /// `<CLAUDE_CONFIG_DIR>/.claude.json`. Note the asymmetry for the default profile —
    /// its file is `~/.claude.json`, beside `~/.claude` rather than inside it.
    ///
    /// - Parameter home: injectable because `homeDirectoryForCurrentUser` reads passwd
    ///   rather than `$HOME`, so a test cannot redirect it through the environment.
    static func configFile(configDirectory: URL?, home: URL, fileManager: FileManager = .default) -> URL {
        let directory = configDirectory ?? home.appending(path: ".claude")
        let override = directory.appending(path: ".config.json")
        if fileManager.fileExists(atPath: override.path) { return override }
        return (configDirectory ?? home).appending(path: ".claude.json")
    }

    static func configFile(configDirectory: URL?, fileManager: FileManager = .default) -> URL {
        configFile(
            configDirectory: configDirectory,
            home: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
    }

    /// Reads an already-resolved config file, for callers that located it themselves.
    public static func read(configFile: URL) -> ClaudeAccountMetadata? {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data),
              let account = config.oauthAccount,
              let email = account.emailAddress, !email.isEmpty else { return nil }
        return ClaudeAccountMetadata(email: email, displayName: account.displayName, planType: account.organizationType)
    }
}

private struct ConfigFile: Decodable {
    let oauthAccount: Account?

    struct Account: Decodable {
        let emailAddress: String?
        let displayName: String?
        let organizationType: String?
    }
}
