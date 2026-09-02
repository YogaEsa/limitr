import Foundation

/// Decides which of a service's accounts is the one Limitr acts as: the account the
/// menu-bar title summarises and the one new shells inherit.
///
/// Split out of the app so the rule can be exercised directly. The rule it encodes is
/// that a choice made by hand outranks connectivity — but only for as long as that choice
/// can actually be acted on, which is the correction this went through twice.
///
/// The first version preferred whichever account was already signed in. An account reads
/// as disconnected for the whole of its sign-in, so picking an account and then signing
/// into it bounced the selection back a second or two later. The second version fixed that
/// with a permanent per-service "the user has chosen" bit, which overshot in the other
/// direction: one click on the star, ever, and the service would stand on that account
/// even after it was signed out. `publishActiveAccount` writes the active account's
/// `CLAUDE_CONFIG_DIR` into `~/.limitr/active.sh`, so the account with no credential
/// became the one every new terminal inherited, and `claude` in a fresh window asked for a
/// login the user had already completed on the other account.
///
/// What distinguishes the two cases is not whether the choice was explicit. It is whether
/// the account is *reachable*: signed in, or with its sign-in still out in Terminal. So
/// `settling` carries the sign-in window that the explicit bit was standing in for, and
/// the choice itself is remembered by identity — stood down while its account has no
/// login, handed back the moment it has one again.
public enum ActiveAccountResolver {
    /// - Parameters:
    ///   - candidates: every visible account of one service, in display order.
    ///   - connected: the subset that currently has a login on disk.
    ///   - active: the account presently marked active, if it is still among the candidates.
    ///   - chosen: the account the user picked by hand for this service, if any. Survives
    ///     being stood down, so the pick is not lost to a poll between choosing an account
    ///     and signing into it.
    ///   - settling: accounts whose sign-in or sign-out is still out in Terminal. These
    ///     read as disconnected without being unreachable, so they keep the default.
    /// - Returns: the account to act as, or nil when the service has no accounts at all.
    public static func resolve(
        candidates: [UUID],
        connected: Set<UUID>,
        active: UUID?,
        chosen: UUID?,
        settling: Set<UUID> = []
    ) -> UUID? {
        guard let fallback = candidates.first else { return nil }
        let firstConnected = candidates.first(where: connected.contains)

        /// Reachable enough to hand new terminals to: signed in, still signing in, or the
        /// only thing on offer.
        func holds(_ account: UUID) -> Bool {
            connected.contains(account) || settling.contains(account) || firstConnected == nil
        }

        if let chosen, candidates.contains(chosen) {
            // Standing the choice down is deliberately not the same as forgetting it: the
            // caller keeps `chosen` on disk, so this reverses itself as soon as the
            // account the user actually wants has a login again.
            return holds(chosen) ? chosen : firstConnected
        }

        guard let active, candidates.contains(active) else {
            // No standing choice, or the one there was has been removed: prefer a login.
            return firstConnected ?? fallback
        }
        // Nothing was ever chosen by hand and the standing default has no login of its
        // own, so the first account to sign in takes over without the user picking it.
        return holds(active) ? active : firstConnected
    }
}
