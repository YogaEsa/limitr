import XCTest
@testable import LimitrCore

final class LauncherScriptTests: XCTestCase {
    func testManagedCodexHomeForcesFileBackedCredentials() {
        let arguments = LauncherScript.codexArguments(
            ["login"],
            home: "/tmp/Limitr/Account/Codex",
            defaultHome: URL(fileURLWithPath: "/Users/dev/.codex")
        )

        XCTAssertEqual(arguments, ["-c", #"cli_auth_credentials_store="file""#, "login"])
    }

    func testDefaultCodexHomeKeepsTheUsersCredentialStore() {
        let arguments = LauncherScript.codexArguments(
            ["login"],
            home: "/Users/dev/.codex",
            defaultHome: URL(fileURLWithPath: "/Users/dev/.codex")
        )

        XCTAssertEqual(arguments, ["login"])
    }

    func testUnsetsAVariableWithNoValue() {
        // Terminal runs .command files through a login shell, so the active account's
        // CLAUDE_CONFIG_DIR is already exported. Emitting nothing is what let a default
        // profile sign in to another account's config directory.
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: ["auth", "login"],
            variables: [LauncherScript.Variable(name: "CLAUDE_CONFIG_DIR", value: nil)],
            watcherPath: "/tmp/close-window.zsh"
        )
        XCTAssertTrue(script.contains("unset CLAUDE_CONFIG_DIR"))
        XCTAssertFalse(script.contains("export CLAUDE_CONFIG_DIR"))
    }

    func testDetachesLimitrsOwnPreexecHookBeforeSettingTheEnvironment() {
        // The reported bug. Limitr's shell integration installs a preexec hook that
        // re-reads ~/.limitr/active.sh, and zsh runs preexec in scripts too, not only in
        // interactive shells — so the hook fired between this script's own `unset` and the
        // CLI below it, handing the launcher the *active* account's CLAUDE_CONFIG_DIR. A
        // sign-in launched on the default profile wrote its OAuth credential into another
        // account's Keychain item and overwrote the login already there.
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: ["auth", "login"],
            variables: [LauncherScript.Variable(name: "CLAUDE_CONFIG_DIR", value: nil)],
            watcherPath: "/tmp/close-window.zsh"
        )

        let detach = script.range(of: "preexec_functions=(${preexec_functions:#_limitr_refresh_active_account})")
        let unset = script.range(of: "unset CLAUDE_CONFIG_DIR")
        XCTAssertNotNil(detach)
        XCTAssertNotNil(unset)
        if let detach, let unset { XCTAssertTrue(detach.upperBound < unset.lowerBound) }
    }

    func testDetachesThePreexecHookForInteractiveSessionsToo() {
        // `exec` is a command like any other, so preexec fires before it as well.
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: [],
            variables: [LauncherScript.Variable(name: "CLAUDE_CONFIG_DIR", value: "/tmp/Claude")],
            watcherPath: nil
        )

        let detach = script.range(of: "preexec_functions=(${preexec_functions:#_limitr_refresh_active_account})")
        let export = script.range(of: "export CLAUDE_CONFIG_DIR")
        XCTAssertNotNil(detach)
        if let detach, let export { XCTAssertTrue(detach.upperBound < export.lowerBound) }
    }

    func testExportsAVariableThatHasAValue() {
        let script = LauncherScript.command(
            executable: "/usr/local/bin/codex",
            arguments: ["login"],
            variables: [LauncherScript.Variable(name: "CODEX_HOME", value: "/tmp/Codex Home")],
            watcherPath: nil
        )
        XCTAssertTrue(script.contains("export CODEX_HOME='/tmp/Codex Home'"))
    }

    func testQuotesPathsContainingAnApostrophe() {
        let script = LauncherScript.command(
            executable: "/tmp/Yoga's Tools/claude",
            arguments: [],
            variables: [LauncherScript.Variable(name: "CLAUDE_CONFIG_DIR", value: "/tmp/Yoga's/Claude")],
            watcherPath: nil
        )
        XCTAssertTrue(script.contains(#"export CLAUDE_CONFIG_DIR='/tmp/Yoga'"'"'s/Claude'"#))
        XCTAssertTrue(script.contains(#"exec '/tmp/Yoga'"'"'s Tools/claude'"#))
    }

    func testInteractiveSessionsExecTheCommandAndNeverHandOffToTheWatcher() {
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: [],
            variables: [],
            watcherPath: nil
        )
        XCTAssertTrue(script.contains("exec '/usr/local/bin/claude'"))
        XCTAssertFalse(script.contains("nohup"))
    }

    func testTransactionalCommandsHandTheWindowToTheDetachedWatcherOnSuccess() {
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: ["auth", "login"],
            variables: [],
            watcherPath: "/tmp/limitr/close-window.zsh"
        )
        XCTAssertTrue(script.contains(#"/usr/bin/nohup '/tmp/limitr/close-window.zsh' "$limitr_tty" >/dev/null 2>&1 &!"#))
        XCTAssertTrue(script.contains("if [ $limitr_status -eq 0 ]; then"))
    }

    func testReadsTheTtyInTheForegroundRatherThanInsideTheBackgroundJob() {
        // zsh hands a background job /dev/null for stdin, so `$(tty)` evaluated there
        // returns nothing and the watcher is given no window to close.
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: ["auth", "login"],
            variables: [],
            watcherPath: "/tmp/close-window.zsh"
        )
        XCTAssertTrue(script.contains(#"limitr_tty="$(tty)""#))
        XCTAssertFalse(script.contains(#"nohup '/tmp/close-window.zsh' "$(tty)""#))
    }

    func testAFailedCommandLeavesTheWindowOpenWithItsError() {
        let script = LauncherScript.command(
            executable: "/usr/local/bin/claude",
            arguments: ["auth", "login"],
            variables: [],
            watcherPath: "/tmp/close-window.zsh"
        )
        XCTAssertTrue(script.contains("This window stays open so you can read the error above."))
        XCTAssertTrue(script.contains("exit $limitr_status"))
    }

    func testWatcherTakesTheTtyAsItsArgumentAndGivesUp() {
        let watcher = LauncherScript.watcher()
        XCTAssertTrue(watcher.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(watcher.contains("target=$1"))
        XCTAssertTrue(watcher.contains("for _ in {1..60}; do"))
        // Only an idle window may be closed; asking while a process is running is the
        // request Terminal drops without a word.
        XCTAssertTrue(watcher.contains("if busy of t then return \"busy\""))
        XCTAssertTrue(watcher.contains("close w saving no"))
    }
}
