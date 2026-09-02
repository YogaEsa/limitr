import AppKit
import Foundation
import LimitrCore

enum ProfileLauncher {
    private static let terminalLaunchTimeout: TimeInterval = 10

    enum LauncherError: LocalizedError {
        case executableMissing(String)
        case terminalFailed

        var errorDescription: String? {
            switch self {
            case .executableMissing(let name): "\(name) CLI was not found. Install it, then reopen Limitr."
            case .terminalFailed: "Terminal could not be opened."
            }
        }
    }

    /// Files linked by reference into every new Claude config directory. Credentials and
    /// per-account history are deliberately absent: only shared tooling is linked, so a
    /// second account still has the user's plugins, skills, and memory.
    ///
    /// These are symlinks rather than copies on purpose — editing a skill or a setting
    /// once should take effect for every account.
    private static let sharedClaudeAssets = [
        "CLAUDE.md", "settings.json", "settings.local.json", "plugins", "skills",
        "agents", "commands", "output-styles"
    ]

    /// Codex assets that must be identical for every account. `config.toml` contains MCP
    /// servers and plugin settings; credentials and session history stay outside this list.
    private static let sharedCodexAssets = [
        "config.toml", "AGENTS.md", "skills", "plugins", "vendor_imports"
    ]

    static func connectClaude(_ profile: AccountProfile) throws {
        try runClaude(profile, arguments: ["auth", "login"], scriptName: "Connect Claude", closesOnSuccess: true)
    }

    static func disconnectClaude(_ profile: AccountProfile) throws {
        try runClaude(profile, arguments: ["auth", "logout"], scriptName: "Disconnect Claude", closesOnSuccess: true)
    }

    static func openClaude(_ profile: AccountProfile) throws {
        try runClaude(profile, arguments: [], scriptName: "Open Claude", closesOnSuccess: false)
    }

    static func openClaudeYolo(_ profile: AccountProfile) throws {
        try runClaude(profile, arguments: ["--dangerously-skip-permissions"], scriptName: "Open Claude YOLO", closesOnSuccess: false)
    }

    private static func runClaude(_ profile: AccountProfile, arguments: [String], scriptName: String, closesOnSuccess: Bool) throws {
        let executable = try executable(named: "claude")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Limitr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The default profile must run with no CLAUDE_CONFIG_DIR whatsoever. Exporting it —
        // even as ~/.claude — switches the CLI to a hashed Keychain name and orphans the
        // user's existing login. It has to be unset rather than merely omitted: Terminal
        // runs .command files through a login shell, which sources `~/.limitr/active.sh`
        // first, so omitting it signs the default profile into the active account's
        // directory instead.
        if let configPath = profile.claudeConfigPath {
            try prepareClaudeConfigDirectory(URL(fileURLWithPath: configPath))
        }
        let body = try scriptBody(
            executable: executable,
            arguments: arguments,
            variables: [LauncherScript.Variable(name: "CLAUDE_CONFIG_DIR", value: profile.claudeConfigPath)],
            closesOnSuccess: closesOnSuccess
        )
        // Unlike Codex, the default Claude profile has no folder of its own to scope
        // scripts into, so the account name keeps multiple accounts from colliding.
        let script = directory.appending(path: "\(scriptName) - \(safeFileName(profile.name)).command")
        try writeAndOpen(body, at: script)
    }

    private static func prepareClaudeConfigDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = fileManager.homeDirectoryForCurrentUser.appending(path: ".claude")
        for asset in sharedClaudeAssets {
            let origin = source.appending(path: asset)
            let link = directory.appending(path: asset)
            // attributesOfItem does not follow symlinks, so a broken link counts as present.
            let alreadyPresent = (try? fileManager.attributesOfItem(atPath: link.path)) != nil
            guard fileManager.fileExists(atPath: origin.path), !alreadyPresent else { continue }
            try? fileManager.createSymbolicLink(at: link, withDestinationURL: origin)
        }
        seedClaudeConfig(into: directory)
    }

    /// Carries the shared parts of `.claude.json` over to a Claude account of its own.
    ///
    /// Claude Code keeps them in the same file that holds the account's identity and
    /// history, so unlike skills and settings this cannot be a symlink and has to merge
    /// rather than overwrite. `ClaudeConfigSeed` owns which keys travel and why;
    /// `oauthAccount` and per-account history are deliberately not among them.
    ///
    /// Per key and only while absent, so a user who removes a server from one account —
    /// or deliberately restarts its onboarding — does not have it reinstated behind them.
    private static func seedClaudeConfig(into directory: URL) {
        let fileManager = FileManager.default
        let origin = fileManager.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        guard let originData = try? Data(contentsOf: origin),
              let originJSON = try? JSONSerialization.jsonObject(with: originData) as? [String: Any]
        else { return }

        let destination = directory.appending(path: ".claude.json")
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: destination),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = decoded
        }

        guard let config = ClaudeConfigSeed.merge(origin: originJSON, into: existing),
              let merged = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? merged.write(to: destination, options: .atomic)
    }

    /// Brings one Claude account's shared configuration up to date, as
    /// `synchronizeCodexSettings` does for Codex.
    ///
    /// Called at launch and not only from a launcher, because the account that needs it
    /// most is one already sitting on disk: it was created before the onboarding keys were
    /// carried, and the terminal it fails in is a plain one the user opens themselves,
    /// which never runs a Limitr script. The default profile is skipped — it has no
    /// directory of Limitr's to repair, and `~/.claude` is not ours to write into.
    static func synchronizeClaudeSettings(_ profile: AccountProfile) {
        guard let path = profile.claudeConfigPath else { return }
        try? prepareClaudeConfigDirectory(URL(fileURLWithPath: path))
    }

    /// Links shared Codex configuration into every isolated home. Existing copied assets are
    /// retained as `.limitr-backup` before the link replaces them, so upgrading Limitr never
    /// discards an account's prior local configuration.
    private static func prepareCodexHome(_ home: URL) {
        let fileManager = FileManager.default
        let source = fileManager.homeDirectoryForCurrentUser.appending(path: ".codex")
        guard home.standardizedFileURL != source.standardizedFileURL else { return }
        for name in sharedCodexAssets {
            let origin = source.appending(path: name)
            let destination = home.appending(path: name)
            guard fileManager.fileExists(atPath: origin.path) else { continue }

            let destinationExists = (try? fileManager.attributesOfItem(atPath: destination.path)) != nil
            if destinationExists,
               let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
               attributes[.type] as? FileAttributeType != .typeSymbolicLink {
                let backup = destination.appendingPathExtension("limitr-backup")
                guard (try? fileManager.attributesOfItem(atPath: backup.path)) == nil else { continue }
                try? fileManager.moveItem(at: destination, to: backup)
            }

            guard (try? fileManager.attributesOfItem(atPath: destination.path)) == nil else { continue }
            try? fileManager.createSymbolicLink(at: destination, withDestinationURL: origin)
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Account" : cleaned
    }

    static func connectCodex(_ profile: AccountProfile) throws {
        try openCodex(profile, arguments: ["login"], scriptName: "Connect Codex.command", closesOnSuccess: true)
    }

    static func disconnectCodex(_ profile: AccountProfile) throws {
        try openCodex(profile, arguments: ["logout"], scriptName: "Disconnect Codex.command", closesOnSuccess: true)
    }

    static func openCodex(_ profile: AccountProfile) throws {
        try openCodex(profile, arguments: [], scriptName: "Open Codex.command", closesOnSuccess: false)
    }

    static func openCodexYolo(_ profile: AccountProfile) throws {
        try openCodex(profile, arguments: ["--dangerously-bypass-approvals-and-sandbox"], scriptName: "Open Codex YOLO.command", closesOnSuccess: false)
    }

    static func synchronizeCodexSettings(_ profile: AccountProfile) {
        guard let home = profile.codexHomePath else { return }
        prepareCodexHome(URL(fileURLWithPath: home))
    }

    private static func openCodex(_ profile: AccountProfile, arguments: [String], scriptName: String, closesOnSuccess: Bool) throws {
        guard let home = profile.codexHomePath else { return }
        let executable = try executable(named: "codex")
        let homeDirectory = URL(fileURLWithPath: home)
        let profileDirectory = homeDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectory.appending(path: "sessions"), withIntermediateDirectories: true)
        synchronizeCodexSettings(profile)
        let script = profileDirectory.appending(path: scriptName)
        let body = try scriptBody(
            executable: executable,
            arguments: LauncherScript.codexArguments(arguments, home: home),
            variables: [LauncherScript.Variable(name: "CODEX_HOME", value: home)],
            closesOnSuccess: closesOnSuccess
        )
        try writeAndOpen(body, at: script)
    }

    /// Builds the body of a launcher script.
    ///
    /// `closesOnSuccess` is for the transactional commands (login, logout): the Terminal
    /// window is only a carrier for the browser hand-off, so it closes itself once the
    /// command succeeds. On failure it deliberately stays open — that window is the only
    /// place the error is visible. Interactive sessions never self-close.
    ///
    /// The closing is delegated to a detached watcher rather than done in this script,
    /// because Terminal refuses — silently — to close a window that still has a process
    /// running in it. See `LauncherScript.watcher()`.
    private static func scriptBody(
        executable: URL,
        arguments: [String],
        variables: [LauncherScript.Variable],
        closesOnSuccess: Bool
    ) throws -> String {
        LauncherScript.command(
            executable: executable.path,
            arguments: arguments,
            variables: variables,
            watcherPath: closesOnSuccess ? try installedWatcher().path : nil
        )
    }

    /// Writes the window-closing watcher next to the launcher scripts and returns it.
    ///
    /// Rewritten on every launch rather than only when missing, so an upgrade that
    /// changes the watcher takes effect without the user noticing there was one.
    private static func installedWatcher() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Limitr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let watcher = directory.appending(path: LauncherScript.watcherFileName)
        try Data(LauncherScript.watcher().utf8).write(to: watcher, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: watcher.path)
        return watcher
    }

    private static func writeAndOpen(_ body: String, at script: URL) throws {
        try Data(body.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let result = try ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-a", "Terminal", script.path],
            timeout: terminalLaunchTimeout
        )
        guard result.status == 0 else { throw LauncherError.terminalFailed }
    }

    private static func executable(named name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)")
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw LauncherError.executableMissing(name.capitalized)
        }
        return executable
    }
}
