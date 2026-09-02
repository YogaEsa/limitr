import Foundation

/// Builds the shell scripts Limitr hands to Terminal.
///
/// Kept out of the app so both halves can be read and tested as text: the environment a
/// launched CLI sees, and the mechanism that closes the window afterwards, are the two
/// places where a multi-account launcher goes quietly wrong.
public enum LauncherScript {
    /// One environment variable a launched command needs. A nil `value` means the
    /// variable must be *absent*, which is not the same as unset-by-omission: Terminal
    /// runs `.command` files through a login shell, so whatever `~/.limitr/active.sh`
    /// exported for the active account is already in the environment. A default profile
    /// that emits nothing therefore inherits another account's `CLAUDE_CONFIG_DIR` and
    /// signs in to the wrong config directory.
    public struct Variable: Equatable, Sendable {
        public let name: String
        public let value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    public static let watcherFileName = "close-window.zsh"

    /// Detaches Limitr's own shell integration before this script touches the environment.
    ///
    /// `~/.zshenv` registers a `preexec` function that re-reads `~/.limitr/active.sh`, and
    /// zsh runs `preexec` in scripts as well as at an interactive prompt — a fact that is
    /// easy to get wrong, since `precmd` really is interactive-only. So the hook fired
    /// between the `export`/`unset` below and the CLI underneath it, and replaced both with
    /// whatever the *active* account had exported. Every launcher therefore ran against the
    /// active account rather than the one whose button was pressed: a sign-in started on the
    /// default profile wrote its OAuth credential into another account's Keychain item and
    /// overwrote the login already sitting there.
    ///
    /// Stripping the array here asks nothing of the user's config, which is the point — the
    /// unguarded hook is already installed in real homes and `install` never rewrites what
    /// it finds. Hooks are per-shell, so this affects only this window.
    private static let detachRefreshHook =
        "preexec_functions=(${preexec_functions:#_limitr_refresh_active_account})\n"

    /// Keeps each managed Codex account's credential inside its own `CODEX_HOME`.
    ///
    /// Codex can store authentication in the OS keyring instead of `auth.json`. That is a
    /// useful default for one account, but the keyring is process-global rather than scoped
    /// by Limitr's homes, so isolated accounts would overwrite or read one another there.
    /// The default `~/.codex` profile keeps the user's own storage choice; only managed
    /// homes force the documented file store.
    public static func codexArguments(
        _ arguments: [String],
        home: String,
        defaultHome: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    ) -> [String] {
        let requested = URL(fileURLWithPath: home).standardizedFileURL.path
        guard requested != defaultHome.standardizedFileURL.path else { return arguments }
        return ["-c", #"cli_auth_credentials_store="file""#] + arguments
    }

    /// The script Terminal runs in the new window.
    ///
    /// - Parameter watcherPath: when non-nil, the window closes itself on success by
    ///   handing off to `watcher` at this path. Interactive sessions pass nil and `exec`
    ///   the command instead, so the window is the session.
    public static func command(
        executable: String,
        arguments: [String],
        variables: [Variable],
        watcherPath: String?
    ) -> String {
        let environment = variables.map { variable in
            guard let value = variable.value else { return "unset \(variable.name)\n" }
            return "export \(variable.name)=\(quote(value))\n"
        }.joined()
        let invocation = ([quote(executable)] + arguments.map(quote)).joined(separator: " ")

        guard let watcherPath else {
            return "#!/bin/zsh\n\(detachRefreshHook)\(environment)exec \(invocation)\n"
        }

        // The tty is read here, in the foreground, and not inline in the `nohup` line:
        // zsh gives a background job /dev/null for stdin, so `$(tty)` evaluated there
        // yields nothing and the watcher is handed no window to close.
        return """
        #!/bin/zsh
        \(detachRefreshHook)\(environment)limitr_tty="$(tty)"
        \(invocation)
        limitr_status=$?
        if [ $limitr_status -eq 0 ]; then
            # Hand the window off to a process that outlives this shell — see `watcher`.
            /usr/bin/nohup \(quote(watcherPath)) "$limitr_tty" >/dev/null 2>&1 &!
        else
            print ""
            print "Command exited with status $limitr_status. This window stays open so you can read the error above."
        fi
        exit $limitr_status

        """
    }

    /// Closes the Terminal window on a given tty once that window's shell has exited.
    ///
    /// The launcher cannot do this itself, and that is not a style preference. Terminal
    /// performs an AppleScript `close` only after the process that sent it has finished,
    /// and drops the request — silently, with no error and no prompt — while the window
    /// still has a process running in it. A script asking to close its own window is
    /// therefore always refused, which is why every `closesOnSuccess` launch used to
    /// leave its window behind for the user to close by hand.
    ///
    /// Detaching with `nohup … &!` is what makes this work: the watcher is not part of
    /// the window's process tree by the time it asks, so Terminal sees an idle window and
    /// honours the close. It polls rather than sleeping a fixed amount because the shell
    /// exits on its own schedule, and it gives up rather than looping forever.
    public static func watcher() -> String {
        """
        #!/bin/zsh
        # Managed by Limitr. Closes the Terminal window whose tty is $1, once the shell
        # in that window has exited. Runs detached from the window it closes, because
        # Terminal ignores a close request for a window that still has a process in it.
        emulate -L zsh
        target=$1
        [[ -n $target ]] || exit 0

        for _ in {1..60}; do
            state=$(/usr/bin/osascript -e 'on run argv
            set wanted to item 1 of argv
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is wanted then
                            if busy of t then return "busy"
                            close w saving no
                            return "closing"
                        end if
                    end repeat
                end repeat
            end tell
            return "gone"
        end run' "$target" 2>/dev/null)
            [[ $state == gone ]] && exit 0
            /bin/sleep 0.25
        done

        """
    }

    /// POSIX single-quote escaping: close the quote, emit a quoted apostrophe, reopen.
    /// The sequence is `'"'"'` — a backslash here produces `'\\"'\\"'`, which substitutes
    /// double quotes for the apostrophe and corrupts any path containing one.
    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
