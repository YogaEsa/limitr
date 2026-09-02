import XCTest
@testable import LimitrCore

final class ActiveAccountShellTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ActiveAccountShellTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ contents: String, to name: String) throws {
        try Data(contents.utf8).write(to: home.appending(path: name))
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: home.appending(path: name), encoding: .utf8)
    }

    // MARK: - Where the line goes

    func testInstallsIntoZshenvSoNonInteractiveShellsSeeTheAccount() throws {
        // The reported bug: `.zprofile` is read by login shells and `.zshrc` by interactive
        // ones, so an IDE terminal, `zsh -c`, or a script inherited no CODEX_HOME, fell
        // back to `~/.codex`, and reported an account Limitr showed as signed in as
        // logged out. `.zshenv` is the only file all four kinds read.
        try ActiveAccountShell.install(home: home)

        XCTAssertEqual(read(".zshenv")?.contains(ActiveAccountShell.sourceLine), true)
    }

    func testInstallsLiveRefreshForAnAlreadyOpenZsh() throws {
        try ActiveAccountShell.install(home: home)

        let zshenv = try XCTUnwrap(read(".zshenv"))
        XCTAssertTrue(zshenv.contains("add-zsh-hook preexec _limitr_refresh_active_account"))
        XCTAssertTrue(zshenv.contains(#"builtin source "$HOME/.limitr/active.sh""#))
    }

    func testTheLiveRefreshLeavesNonInteractiveShellsAlone() throws {
        // zsh runs preexec in scripts as well as at an interactive prompt. An unguarded
        // hook therefore re-read the active account between a script's own `export
        // CLAUDE_CONFIG_DIR` and the command that needed it — including inside Limitr's
        // own launcher scripts, which is how a sign-in landed in the wrong account.
        try ActiveAccountShell.install(home: home)

        let zshenv = try XCTUnwrap(read(".zshenv"))
        XCTAssertTrue(zshenv.contains("[[ -o interactive ]] || return 0"))
    }

    func testRepairsAnUnguardedRefreshLeftByAnEarlierBuild() throws {
        // The broken block is already in real `.zshenv` files and its marker line is
        // unchanged, so a plain marker check would decide there was nothing to do.
        try write("""
        \(ActiveAccountShell.sourceLine)

        # Limitr: pick up account swaps before each command
        autoload -Uz add-zsh-hook
        _limitr_refresh_active_account() {
            [[ -f "$HOME/.limitr/active.sh" ]] && builtin source "$HOME/.limitr/active.sh"
        }
        add-zsh-hook preexec _limitr_refresh_active_account
        """, to: ".zshenv")

        try ActiveAccountShell.extendToAllShells(home: home)

        let zshenv = try XCTUnwrap(read(".zshenv"))
        XCTAssertTrue(zshenv.contains("[[ -o interactive ]] || return 0"))
        // Redefinition, not rewriting: the older block stays exactly where the user has it.
        XCTAssertEqual(zshenv.components(separatedBy: "_limitr_refresh_active_account() {").count - 1, 2)
    }

    func testRepairingTwiceAddsTheGuardOnce() throws {
        try ActiveAccountShell.install(home: home)
        try ActiveAccountShell.extendToAllShells(home: home)

        let zshenv = try XCTUnwrap(read(".zshenv"))
        XCTAssertEqual(zshenv.components(separatedBy: "[[ -o interactive ]] || return 0").count - 1, 1)
    }

    func testDoesNotRepeatTheLineAcrossZshProfiles() throws {
        // `.zshenv` already covers every shell `.zprofile` and `.zshrc` would, so writing
        // all three would only put the same line in the user's config three times.
        try write("# existing\n", to: ".zshrc")
        try write("# existing\n", to: ".zprofile")

        try ActiveAccountShell.install(home: home)

        XCTAssertEqual(read(".zshrc"), "# existing\n")
        XCTAssertEqual(read(".zprofile"), "# existing\n")
    }

    func testInstallsIntoBashProfileWhenTheUserHasOne() throws {
        try write("# existing\n", to: ".bash_profile")

        try ActiveAccountShell.install(home: home)

        XCTAssertEqual(read(".bash_profile")?.contains(ActiveAccountShell.sourceLine), true)
    }

    func testLeavesBashAloneWhenTheUserHasNoBashProfile() throws {
        try ActiveAccountShell.install(home: home)

        XCTAssertNil(read(".bash_profile"))
    }

    func testInstallingTwiceAddsTheLineOnce() throws {
        try ActiveAccountShell.install(home: home)
        try ActiveAccountShell.install(home: home)

        let occurrences = read(".zshenv")?.components(separatedBy: ActiveAccountShell.sourceLine).count
        XCTAssertEqual(occurrences, 2, "one separator means the line appears exactly once")
        let hooks = read(".zshenv")?.components(separatedBy: "# Limitr: pick up account swaps before each command").count
        XCTAssertEqual(hooks, 2, "one separator means the hook appears exactly once")
    }

    // MARK: - Repairing an install that predates .zshenv

    func testExtendsAnOlderInstallToZshenv() throws {
        // Shell integration was already accepted; earlier versions simply wrote it where
        // non-interactive shells never look. Repairing that is finishing what was agreed
        // to, so it happens without asking again.
        try write("# existing\n\(ActiveAccountShell.sourceLine)\n", to: ".zprofile")

        try ActiveAccountShell.extendToAllShells(home: home)

        XCTAssertEqual(read(".zshenv")?.contains(ActiveAccountShell.sourceLine), true)
        XCTAssertEqual(read(".zprofile"), "# existing\n\(ActiveAccountShell.sourceLine)\n")
    }

    func testDoesNotInstallForSomebodyWhoNeverOptedIn() throws {
        // Nothing to finish. Creating `.zshenv` here would be Limitr editing a shell
        // config the user never agreed to let it touch.
        try write("# existing\n", to: ".zshrc")

        try ActiveAccountShell.extendToAllShells(home: home)

        XCTAssertNil(read(".zshenv"))
    }

    func testExtendingIsIdempotent() throws {
        try write("\(ActiveAccountShell.sourceLine)\n", to: ".zprofile")

        try ActiveAccountShell.extendToAllShells(home: home)
        let after = read(".zshenv")
        try ActiveAccountShell.extendToAllShells(home: home)

        XCTAssertEqual(read(".zshenv"), after)
    }

    func testExtendsASourceOnlyZshenvWithLiveRefresh() throws {
        try write("\(ActiveAccountShell.sourceLine)\n", to: ".zshenv")

        try ActiveAccountShell.extendToAllShells(home: home)

        let zshenv = try XCTUnwrap(read(".zshenv"))
        XCTAssertTrue(zshenv.contains("add-zsh-hook preexec _limitr_refresh_active_account"))
        XCTAssertEqual(zshenv.components(separatedBy: ActiveAccountShell.sourceLine).count, 2)
    }

    // MARK: - isInstalled

    func testCountsAnOlderInstallAsInstalled() throws {
        // Deliberately "any file": an install predating `.zshenv` must not be re-offered
        // to the user, it must be repaired by `extendToAllShells`.
        try write("\(ActiveAccountShell.sourceLine)\n", to: ".zshrc")

        XCTAssertTrue(ActiveAccountShell.isInstalled(home: home))
    }

    func testReportsNotInstalledOnAnUntouchedHome() {
        XCTAssertFalse(ActiveAccountShell.isInstalled(home: home))
    }

    // MARK: - The published file

    func testUnsetsRatherThanExportingForTheDefaultProfile() throws {
        try ActiveAccountShell.write(codexHome: nil, claudeConfigPath: nil, home: home)

        let script = try String(contentsOf: ActiveAccountShell.scriptURL(home: home), encoding: .utf8)
        XCTAssertTrue(script.contains("unset CODEX_HOME"))
        XCTAssertTrue(script.contains("unset CLAUDE_CONFIG_DIR"))
    }

    func testQuotesPathsContainingAnApostrophe() throws {
        try ActiveAccountShell.write(
            codexHome: "/tmp/yoga's codex",
            claudeConfigPath: nil,
            home: home
        )

        let script = try String(contentsOf: ActiveAccountShell.scriptURL(home: home), encoding: .utf8)
        XCTAssertTrue(script.contains(#"export CODEX_HOME='/tmp/yoga'\''s codex'"#), script)
    }
}
