import Foundation
import LimitrCore

/// One-time migration from the app's former name, "Limiter".
///
/// The rename moved three separate pieces of user state, and all three have to
/// travel together or a previously working install comes up empty:
///
/// 1. The stored profiles in the old `UserDefaults` domain.
/// 2. `~/.limiter/active.sh` plus the line in the user's shell profile that
///    sources it. That line is one Limitr wrote and owns, so repairing it here is
///    the same promise as before — touch the profile once, on the user's behalf.
///    Leaving it would both break new shells and make `ActiveAccountShell.install`
///    append a second, duplicate line.
///
/// Changing the bundle identifier also moved the `UserDefaults` domain, so the
/// saved account list is read back out of the old domain first.
///
/// Existing account directories deliberately stay under `Application Support/Limiter`.
/// Claude hashes the literal config path into its Keychain service name, so renaming those
/// directories would log every scoped Claude account out. New accounts use the new
/// `Application Support/Limitr` path; old paths are harmless compatibility state.
///
/// Every step is guarded on its own preconditions rather than a single "did I run"
/// flag, so an interrupted run finishes on the next launch and a completed run
/// costs a few `stat` calls.
enum LegacyNameMigration {
    /// The `UserDefaults` domain the app wrote to before the rename.
    static let legacyBundleIdentifier = "com.yogaesamahendra.limiter"
    private static let accountsKey = "accounts"
    private static let legacyScriptFragment = ".limiter/active.sh"
    private static let scriptFragment = ".limitr/active.sh"

    static func run(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = AppDefaultsDomain.store()
    ) {
        adoptLegacyDefaults(into: defaults)
        move(home.appending(path: ".limiter"), to: home.appending(path: ".limitr"))
        rewriteShellProfiles(home: home)
    }

    /// Copies the account list out of the pre-rename domain, but only when the
    /// current one has nothing — a real save always wins over the old snapshot.
    private static func adoptLegacyDefaults(into defaults: UserDefaults) {
        guard defaults.data(forKey: accountsKey) == nil,
              let legacy = UserDefaults(suiteName: legacyBundleIdentifier),
              let data = legacy.data(forKey: accountsKey) else { return }
        defaults.set(data, forKey: accountsKey)
    }

    /// Refuses to overwrite anything already at the destination, so a half-migrated
    /// install never loses the newer copy.
    private static func move(_ source: URL, to destination: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path),
              !fileManager.fileExists(atPath: destination.path) else { return }
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.moveItem(at: source, to: destination)
    }

    /// Retargets our own source line in place, leaving the rest of the profile
    /// untouched.
    private static func rewriteShellProfiles(home: URL) {
        for url in ActiveAccountShell.shellProfileURLs(home: home) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(legacyScriptFragment) else { continue }
            let updated = text
                .replacingOccurrences(of: legacyScriptFragment, with: scriptFragment)
                .replacingOccurrences(of: "# Limiter: use the active account", with: "# Limitr: use the active account")
            try? Data(updated.utf8).write(to: url, options: .atomic)
        }
    }
}
