import Foundation

/// What a new Claude account carries over from the default profile's `.claude.json`.
///
/// In Core rather than the launcher because the rule is one an isolated account cannot
/// survive being got wrong, and the wrong version shipped: only `mcpServers` was carried,
/// and `claude auth login` authenticates without marking onboarding complete. So a second
/// account ended up with a valid OAuth credential, a green row in Limitr, `auth status`
/// reporting `loggedIn: true` — and a first-run wizard the moment plain `claude` ran in a
/// new terminal, whose opening step is signing in. The account was never signed out; the
/// user simply never reached it.
public enum ClaudeConfigSeed {
    /// Carried in the order a reader would expect to find them, not that it matters to JSON.
    ///
    /// `mcpServers` so a second account keeps the user's own servers. The two onboarding
    /// keys because the isolated directory is Limitr's mechanism, not a fresh install of
    /// Claude Code: this user has already been through onboarding on this Mac, and
    /// re-running it is what hid a working login behind a sign-in prompt.
    public static let keys = ["mcpServers", "hasCompletedOnboarding", "lastOnboardingVersion"]

    /// Fills the gaps in one account's config from the default profile's.
    ///
    /// Per key, never all-or-nothing: an account created before the onboarding keys were
    /// carried already has `mcpServers`, and a check that stopped at the first key present
    /// would leave exactly that account broken forever.
    ///
    /// - Returns: the merged config, or nil when nothing was missing — so the caller can
    ///   leave the file untouched rather than rewriting it on every launch.
    public static func merge(origin: [String: Any], into existing: [String: Any]) -> [String: Any]? {
        var config = existing
        var changed = false
        for key in keys where config[key] == nil {
            guard let value = origin[key], !isEmpty(value) else { continue }
            config[key] = value
            changed = true
        }
        return changed ? config : nil
    }

    /// An empty container is not an opinion worth copying, and writing one would occupy the
    /// key and block the real value from ever being seeded later.
    private static func isEmpty(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        if let array = value as? [Any] { return array.isEmpty }
        return false
    }
}
