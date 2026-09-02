import Foundation

/// Which service is working right now, and how long that claim survives.
///
/// Neither CLI announces that it is busy. Both append to their own transcript as each
/// assistant turn completes, so a write is the one honest signal available — and it is a
/// signal about the recent past, not about a request in flight. Everything downstream has
/// to stay inside that: the notch says a service is *working*, which means it wrote
/// something in the last half minute.
/// What a transcript's last turn marker says, for a CLI that brackets its work.
///
/// Codex writes `task_started` when it takes a turn and `task_complete` when it finishes,
/// which is a far better answer than "it wrote something recently" — it is the CLI saying
/// so itself. Claude Code has no equivalent, so `.absent` is an ordinary answer and leaves
/// the write-and-decay heuristic in charge rather than being treated as a failure.
public enum TurnMarker: Equatable, Sendable {
    case started
    case finished
    case absent
}

public struct ActivityPulse: Equatable, Sendable {

    /// How long a write keeps a service marked as working.
    ///
    /// A long tool loop writes in bursts with gaps between them, so a window shorter than
    /// the gaps would strobe through a single session. Thirty seconds covers the gaps and
    /// still goes quiet within half a minute of the user stopping — which matters more,
    /// because a bar still shimmering after the work has finished is claiming something
    /// untrue about right now.
    public static let decay: TimeInterval = 30

    /// The longest an *open* turn is believed without another word from the transcript.
    ///
    /// A turn that is open says the CLI is working even while it is silent, which is the
    /// whole point — measured across 39 Codex transcripts, silences inside a turn reach
    /// 24 seconds at the 99th percentile, and the 30-second decay was going dark in the
    /// middle of exactly the work it exists to show. But the claim cannot be open-ended:
    /// 8 of those 102 turns never wrote `task_complete` at all, because Codex was stopped
    /// mid-turn, and their transcripts end saying a turn is still running. This is what
    /// bounds that — five minutes of silence is twelve times the p99, and a turn nobody
    /// has heard from for that long is not something to keep claiming.
    public static let turnCap: TimeInterval = 300

    private struct Key: Hashable, Sendable {
        let source: UsageSource
        let accountID: String
    }

    private var lastTick: [Key: Date] = [:]
    /// The accounts whose transcript says a turn is open. Membership does not make an
    /// account active on its own — it only lengthens how much silence is tolerated, so
    /// everything still hangs off a write that actually happened.
    private var openTurns: Set<Key> = []

    public init() {}

    /// True when nothing can be active at any time from now on. The app's activity timer
    /// stops on this rather than on a count, so an idle Mac runs no timer at all.
    public var isQuiet: Bool { lastTick.isEmpty }

    public mutating func tick(source: UsageSource, accountID: String, at: Date) {
        lastTick[Key(source: source, accountID: accountID)] = at
    }

    /// Takes what the transcript says about the turn itself.
    ///
    /// `.finished` clears the account outright rather than letting it decay: the CLI has
    /// said it is done, and thirty more seconds of a shimmering bar would be claiming
    /// something we have just been told is untrue. `.absent` leaves the write-and-decay
    /// heuristic exactly as it was, since a transcript with no markers — Claude's, or a
    /// Codex log too old to carry them — is an ordinary state and not a failure.
    public mutating func note(_ marker: TurnMarker, source: UsageSource, accountID: String, at: Date) {
        let key = Key(source: source, accountID: accountID)
        switch marker {
        case .started:
            lastTick[key] = at
            openTurns.insert(key)
        case .finished:
            lastTick[key] = nil
            openTurns.remove(key)
        case .absent:
            openTurns.remove(key)
        }
    }

    /// How much silence this account is allowed before it stops counting as working.
    private func tolerance(_ key: Key) -> TimeInterval {
        openTurns.contains(key) ? Self.turnCap : Self.decay
    }

    public func isActive(source: UsageSource, accountID: String, now: Date) -> Bool {
        let key = Key(source: source, accountID: accountID)
        guard let at = lastTick[key] else { return false }
        return now.timeIntervalSince(at) < tolerance(key)
    }

    /// The service-level answer, which is what the notch draws: one bar per service, lit
    /// while any of that service's accounts is working.
    public func isActive(source: UsageSource, now: Date) -> Bool {
        lastTick.contains { source == $0.key.source && now.timeIntervalSince($0.value) < tolerance($0.key) }
    }

    /// Drops ticks too old to make anything active, so the dictionary does not grow one
    /// entry per account for the lifetime of the app.
    public mutating func prune(now: Date) {
        lastTick = lastTick.filter { now.timeIntervalSince($0.value) < tolerance($0.key) }
        // An open turn with no tick left behind it can never light anything again.
        openTurns = openTurns.filter { lastTick[$0] != nil }
    }
}
