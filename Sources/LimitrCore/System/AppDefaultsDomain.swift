import Foundation

/// Which `UserDefaults` domain Limitr's saved state belongs in.
///
/// `UserDefaults.standard` resolves to the main bundle's identifier — except that an
/// executable with no bundle has none, and Foundation quietly falls back to the process
/// name instead. `swift run LimitrApp` is exactly that case, so a development build reads
/// and writes a domain called `LimitrApp` while the packaged app uses
/// `com.yogaesamahendra.limitr`. Two builds of the same app, two separate account lists,
/// no error either way.
///
/// The cost is not that the development build starts empty. It is that an empty account
/// list is indistinguishable from a first run, and the account directories the missing
/// profiles named are still on disk holding live logins — Claude's keyed to a Keychain
/// item whose service name is a hash of the directory path, and that path contains the
/// profile's identifier. So the identifier is the credential's only address, the list was
/// the only copy of it, and adding the account back mints a new one. `OrphanedAccountScanner`
/// exists to recover from that; this exists so it happens less.
public enum AppDefaultsDomain {
    /// The packaged app's bundle identifier, and therefore the domain that holds the real
    /// account list.
    public static let name = "com.yogaesamahendra.limitr"

    /// The domain to use instead of `UserDefaults.standard`, or nil when `standard` is
    /// already right.
    ///
    /// Only an unbundled build is redirected. A bundled one keeps whatever identifier it
    /// was built with: for the packaged app that is `name` itself — and asking
    /// `UserDefaults(suiteName:)` for your own bundle identifier is explicitly undefined —
    /// while for a sandbox build the separate identifier *is* the isolation, and overriding
    /// it would empty the sandbox straight into the real accounts.
    public static func override(bundleIdentifier: String?) -> String? {
        bundleIdentifier == nil ? name : nil
    }

    /// The store to read and write.
    ///
    /// A function rather than a stored global because `UserDefaults` is not `Sendable`;
    /// the instances it hands back share one backing store, so calling it per access costs
    /// nothing that matters.
    public static func store() -> UserDefaults {
        guard let domain = override(bundleIdentifier: Bundle.main.bundleIdentifier),
              let suite = UserDefaults(suiteName: domain) else { return .standard }
        return suite
    }
}
