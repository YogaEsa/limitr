import Foundation

/// One login the scanner found on disk.
public struct DetectedLogin: Identifiable, Equatable, Sendable {
    /// The literal `CLAUDE_CONFIG_DIR` / `CODEX_HOME` this login lives under, or nil when
    /// it is the CLI's own default home.
    ///
    /// The distinction matters more than it looks: a Claude account carrying a
    /// `CLAUDE_CONFIG_DIR` — even one spelling out `~/.claude` — makes the CLI hash that
    /// path into its Keychain service name, which orphans a default login.
    public let configPath: String?
    public let email: String?
    public let discoveredVia: Discovery

    public enum Discovery: String, Sendable {
        case defaultHome
        case environment
    }

    public var id: String { configPath ?? "default" }

    public init(configPath: String?, email: String?, discoveredVia: Discovery) {
        self.configPath = configPath
        self.email = email
        self.discoveredVia = discoveredVia
    }
}

/// What the scanner knows about one CLI.
public struct DetectedService: Identifiable, Equatable, Sendable {
    public let source: UsageSource
    /// nil when the CLI is not installed anywhere the launcher would find it.
    public let executablePath: String?
    public let logins: [DetectedLogin]

    public var id: String { source.rawValue }
    public var isInstalled: Bool { executablePath != nil }

    public init(source: UsageSource, executablePath: String?, logins: [DetectedLogin]) {
        self.source = source
        self.executablePath = executablePath
        self.logins = logins
    }
}

/// Reads variables out of the user's own login shell.
///
/// An app launched from Finder inherits launchd's environment, not a shell's, so a
/// `CLAUDE_CONFIG_DIR` exported from `.zshrc` is invisible to `ProcessInfo`. Asking the
/// shell itself is the only way to see it.
///
/// Note that the shell this starts will also source Limitr's own `active.sh` if the user
/// has the shell integration installed, so the values coming back may describe an account
/// Limitr already manages — `InstallationScanner` filters those out.
public enum LoginShellEnvironment {
    /// Blocking; call it off the main actor. Returns only the variables that came back with
    /// a non-empty value.
    public static func read(_ names: [String], timeout: TimeInterval = 5) -> [String: String] {
        // The names are constants in this codebase, but they are interpolated into a shell
        // script, so refuse anything that is not a plain variable name.
        let safe = names.filter { !$0.isEmpty && $0.allSatisfy { $0.isUppercase || $0 == "_" } }
        guard !safe.isEmpty else { return [:] }

        let box = ProcessBox()
        let output = Pipe()
        box.process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // `-i` as well as `-l`: zsh reads `.zshrc` only for interactive shells, and that is
        // where most people export things.
        box.process.arguments = ["-l", "-i", "-c", safe.map { "printf '\($0)=%s\\n' \"$\($0)\"" }.joined(separator: "; ")]
        box.process.standardOutput = output
        box.process.standardError = Pipe()
        // An interactive shell with a terminal on stdin can block waiting for one.
        box.process.standardInput = FileHandle.nullDevice

        guard (try? box.process.run()) != nil else { return [:] }
        let watchdog = DispatchWorkItem { box.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        box.process.waitUntilExit()
        watchdog.cancel()

        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard safe.contains(name), !value.isEmpty else { continue }
            values[name] = value
        }
        return values
    }

    /// `Process` is not `Sendable`, and the watchdog needs to reach it from another queue.
    /// It only ever asks whether the process is running and terminates it, both of which are
    /// safe off the launching thread.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
        func terminate() { if process.isRunning { process.terminate() } }
    }
}

/// Where the CLIs are usually installed, in the order the launcher tries them.
public enum CLILocator {
    public static func searchDirectories(home: URL) -> [URL] {
        [
            home.appending(path: ".local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin")
        ]
    }

    public static func executable(
        named name: String,
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        directories
            .map { $0.appending(path: name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

/// Finds Claude Code and Codex installs that already exist on this machine.
///
/// The point is a first run that costs nothing: someone who has been using either CLI for
/// months should see their real numbers immediately rather than be asked to sign in again.
/// Both default homes are checked, and so are `CLAUDE_CONFIG_DIR` / `CODEX_HOME` — which is
/// the only way to see a login someone deliberately moved elsewhere.
public struct InstallationScanner {
    private let home: URL
    private let applicationSupport: URL
    private let environment: [String: String]
    private let executableDirectories: [URL]
    private let fileManager: FileManager

    /// - Parameter environment: shell variables, already resolved. Empty is fine and simply
    ///   limits the scan to the default homes.
    public init(
        home: URL,
        applicationSupport: URL,
        environment: [String: String] = [:],
        executableDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.applicationSupport = applicationSupport
        self.environment = environment
        self.executableDirectories = executableDirectories ?? CLILocator.searchDirectories(home: home)
        self.fileManager = fileManager
    }

    public func scan() -> [DetectedService] {
        [claude(), codex()]
    }

    private func claude() -> DetectedService {
        DetectedService(
            source: .claude,
            executablePath: CLILocator.executable(named: "claude", in: executableDirectories, fileManager: fileManager)?.path,
            logins: candidates(variable: "CLAUDE_CONFIG_DIR", defaultHome: home.appending(path: ".claude"))
                .compactMap { candidate in
                    let file = ClaudeAccountMetadata.configFile(
                        configDirectory: candidate.directory,
                        home: home,
                        fileManager: fileManager
                    )
                    guard let metadata = ClaudeAccountMetadata.read(configFile: file) else { return nil }
                    return DetectedLogin(
                        configPath: candidate.directory?.path,
                        email: metadata.email,
                        discoveredVia: candidate.discovery
                    )
                }
        )
    }

    private func codex() -> DetectedService {
        DetectedService(
            source: .codex,
            executablePath: CLILocator.executable(named: "codex", in: executableDirectories, fileManager: fileManager)?.path,
            logins: candidates(variable: "CODEX_HOME", defaultHome: home.appending(path: ".codex"))
                .compactMap { candidate in
                    let directory = candidate.directory ?? home.appending(path: ".codex")
                    let auth = directory.appending(path: "auth.json")
                    guard fileManager.fileExists(atPath: auth.path) else { return nil }
                    return DetectedLogin(
                        configPath: candidate.directory?.path,
                        email: CodexAccountMetadata.read(from: auth)?.email,
                        discoveredVia: candidate.discovery
                    )
                }
        )
    }

    private struct Candidate {
        /// nil means the CLI's own default home, which must stay unconfigured.
        let directory: URL?
        let discovery: DetectedLogin.Discovery
    }

    /// The default home, plus whatever the environment points at when that is somewhere
    /// else the user actually keeps a login.
    private func candidates(variable: String, defaultHome: URL) -> [Candidate] {
        var candidates = [Candidate(directory: nil, discovery: .defaultHome)]
        guard let raw = environment[variable]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return candidates
        }
        let directory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        guard fileManager.fileExists(atPath: directory.path),
              directory != defaultHome.standardizedFileURL,
              !isManagedByLimitr(directory) else { return candidates }
        candidates.append(Candidate(directory: directory, discovery: .environment))
        return candidates
    }

    /// Limitr's own shell integration exports these variables for whichever account is
    /// active, so without this the scan rediscovers an account Limitr already manages and
    /// offers it back as if it were something the user set up themselves.
    private func isManagedByLimitr(_ directory: URL) -> Bool {
        // `Limiter` is the app's former name; accounts created before the rename still live
        // under it, because Claude hashes the literal path into its Keychain service name.
        ["Limitr", "Limiter"].contains { name in
            directory.path.hasPrefix(applicationSupport.appending(path: name).standardizedFileURL.path + "/")
        }
    }
}
