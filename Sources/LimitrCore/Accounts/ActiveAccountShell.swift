import Foundation

/// Publishes the active account to newly opened shells.
///
/// Limitr owns exactly one file, `~/.limitr/active.sh`, and rewrites it whenever the
/// active account changes. The user's own shell config is touched once on first launch
/// to add the line that sources it.
///
/// In Core rather than the app because *which* files carry that line is a rule with a
/// wrong answer that looks right: it took `.zprofile` and `.zshrc` for years, and both
/// are read too narrowly to carry an environment variable.
public enum ActiveAccountShell {
    public enum ShellError: LocalizedError {
        case profileUnwritable(String)

        public var errorDescription: String? {
            switch self {
            case .profileUnwritable(let name): "Could not write to \(name). Add the line manually instead."
            }
        }
    }

    public static let sourceLine = #"[ -f "$HOME/.limitr/active.sh" ] && . "$HOME/.limitr/active.sh""#

    /// Reloads the active-account file immediately before an interactive zsh runs a
    /// command. A shell otherwise keeps the environment it read at startup forever, so a
    /// Limitr swap made while Terminal was already open did not reach the next `codex` or
    /// `claude` invocation in that window.
    private static let zshRefreshMarker = "# Limitr: pick up account swaps before each command"

    /// The line that makes the hook safe, and what an install is checked for.
    ///
    /// zsh runs `preexec` in scripts as well as at an interactive prompt — unlike `precmd`,
    /// which really is interactive-only. Without this guard the hook re-read the active
    /// account *between* a script's own `export CLAUDE_CONFIG_DIR` and the command that
    /// needed it, Limitr's own launcher scripts included: every launch ran against the
    /// active account instead of the one whose button was pressed, so a sign-in started on
    /// one account wrote its credential into another's Keychain item.
    private static let zshGuardLine = "[[ -o interactive ]] || return 0"
    private static let zshRefreshBlock = """
    \(zshRefreshMarker)
    autoload -Uz add-zsh-hook
    _limitr_refresh_active_account() {
        \(zshGuardLine)
        [[ -f "$HOME/.limitr/active.sh" ]] && builtin source "$HOME/.limitr/active.sh"
    }
    add-zsh-hook -d preexec _limitr_refresh_active_account 2>/dev/null || true
    add-zsh-hook preexec _limitr_refresh_active_account
    """

    /// Injectable so the file-writing paths can be exercised without touching a real home
    /// directory — `FileManager.homeDirectoryForCurrentUser` reads passwd, not `$HOME`,
    /// so redirecting the environment is not enough to make these safe to test.
    public static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func scriptURL(home: URL = defaultHome) -> URL {
        home.appending(path: ".limitr/active.sh")
    }

    /// The one file every zsh reads, and therefore the only correct home for this line.
    ///
    /// `.zprofile` is read by login shells and `.zshrc` by interactive ones. A shell that
    /// is neither — an IDE's integrated terminal, `zsh -c`, a script, a task runner, a
    /// git hook — reads neither, so it inherited no `CODEX_HOME`, fell back to `~/.codex`,
    /// and reported an account Limitr was showing as signed in as logged out. `.zshenv` is
    /// read by all four kinds, and an exported environment variable is exactly what it is
    /// for.
    public static func zshEnvironmentURL(home: URL = defaultHome) -> URL {
        home.appending(path: ".zshenv")
    }

    /// Every file that may carry the source line, newest convention first.
    ///
    /// `.zprofile` and `.zshrc` are still listed because earlier versions installed there
    /// and those lines are left exactly where they are — re-sourcing the file is
    /// idempotent, and rewriting a user's shell config to tidy up is not this code's
    /// business. Bash remains for users who changed the macOS default.
    public static func shellProfileURLs(home: URL = defaultHome) -> [URL] {
        [
            zshEnvironmentURL(home: home),
            home.appending(path: ".zprofile"),
            home.appending(path: ".zshrc"),
            home.appending(path: ".bash_profile")
        ]
    }

    /// Rewrites the exported environment. Passing nil for a service clears its export.
    ///
    /// A default profile exports nothing: `CLAUDE_CONFIG_DIR` set to `~/.claude` would
    /// switch the CLI to a hashed Keychain name and orphan the existing login, and
    /// `CODEX_HOME` set to `~/.codex` is just noise. Absence is what "use the default"
    /// means to both CLIs.
    public static func write(codexHome: String?, claudeConfigPath: String?, home: URL = defaultHome) throws {
        var lines = [
            "# Managed by Limitr — rewritten whenever the active account changes.",
            "# Edits here will be lost. Remove the line sourcing this file from your",
            "# shell profile to opt out.",
            ""
        ]
        lines.append(codexHome.map { "export CODEX_HOME=\(shellQuote($0))" } ?? "unset CODEX_HOME")
        lines.append(claudeConfigPath.map { "export CLAUDE_CONFIG_DIR=\(shellQuote($0))" } ?? "unset CLAUDE_CONFIG_DIR")
        lines.append("")

        let url = scriptURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    /// Whether any shell profile already sources the file.
    ///
    /// Installation is offered rather than assumed, so the offer has to know when it has
    /// already been taken — including by a build of Limitr that installed it automatically.
    /// Deliberately "any", not "`.zshenv`": an install that predates `.zshenv` has already
    /// been consented to and is repaired by `extendToAllShells`, not by asking again.
    public static func isInstalled(home: URL = defaultHome) -> Bool {
        shellProfileURLs(home: home).contains { contains(sourceLine, in: $0) }
    }

    /// Adds the line to `.zshenv` for an install that already has it somewhere else.
    ///
    /// Not a decision made on the user's behalf: shell integration was already accepted,
    /// and earlier versions simply wrote it to files that non-interactive shells never
    /// read. Repairing that is finishing what was agreed to, not starting something new —
    /// so unlike `install` this runs unprompted, and does nothing at all when the line is
    /// nowhere to be found.
    public static func extendToAllShells(home: URL = defaultHome) throws {
        let zshenv = zshEnvironmentURL(home: home)
        guard isInstalled(home: home) else { return }
        try installZshIntegration(at: zshenv)
    }

    /// Appends the source line to `.zshenv`, plus any bash profile that exists.
    ///
    /// `.zprofile` and `.zshrc` are not written: `.zshenv` already covers every shell they
    /// would, so adding them would only put the same line in the user's config three
    /// times. Lines an earlier version left there are still honoured by `isInstalled`.
    public static func install(home: URL = defaultHome) throws {
        try installZshIntegration(at: zshEnvironmentURL(home: home))

        let bash = home.appending(path: ".bash_profile")
        if FileManager.default.fileExists(atPath: bash.path), !contains(sourceLine, in: bash) {
            try append(sourceLine, to: bash)
        }
    }

    /// Installs the startup read and the live refresh independently. Builds predating live
    /// swaps already have the first line in `.zshenv`; they need only the hook appended,
    /// not a duplicate source line.
    ///
    /// What is looked for is the *guard*, not the block's marker comment, because the
    /// unguarded first version of the hook carries that same marker and is already sitting
    /// in real `.zshenv` files, where it silently redirects every launcher to the active
    /// account. Appending the corrected block is enough to repair one: zsh reads the file
    /// top to bottom, so the later definition of `_limitr_refresh_active_account` is the one
    /// that survives, and `add-zsh-hook` keys on the function name and so never registers it
    /// twice. That keeps the promise the rest of this file makes — nothing the user already
    /// has is rewritten or reordered.
    private static func installZshIntegration(at url: URL) throws {
        if !contains(sourceLine, in: url) { try append(sourceLine, to: url) }
        if !contains(zshGuardLine, in: url) { try append(zshRefreshBlock, to: url) }
    }

    /// Appends to a file that may not exist yet, creating it if so. Never rewrites or
    /// reorders what is already there.
    private static func append(_ contents: String, to url: URL) throws {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let addition = "\(separator)\n\(contents)\n"
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            guard (try? Data((existing + addition).utf8).write(to: url, options: .atomic)) != nil else {
                throw ShellError.profileUnwritable(url.lastPathComponent)
            }
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(addition.utf8))
    }

    private static func contains(_ line: String, in url: URL) -> Bool {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains(line)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
