import XCTest
@testable import LimitrCore

final class ActivityPulseTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testMarksAServiceActiveWhenItsTranscriptIsWrittenTo() {
        var pulse = ActivityPulse()
        pulse.tick(source: .claude, accountID: "a", at: start)
        XCTAssertTrue(pulse.isActive(source: .claude, accountID: "a", now: start))
    }

    func testSaysNothingIsActiveBeforeAnythingHasBeenWritten() {
        let pulse = ActivityPulse()
        XCTAssertFalse(pulse.isActive(source: .claude, accountID: "a", now: start))
        XCTAssertTrue(pulse.isQuiet)
    }

    /// The decay is the whole claim this type makes. Both CLIs append per completed turn,
    /// so gaps inside a working session are normal; thirty seconds covers them and still
    /// goes quiet promptly once the user stops.
    func testGoesQuietThirtySecondsAfterTheLastWrite() {
        var pulse = ActivityPulse()
        pulse.tick(source: .claude, accountID: "a", at: start)
        XCTAssertTrue(pulse.isActive(source: .claude, accountID: "a", now: start.addingTimeInterval(29)))
        XCTAssertFalse(pulse.isActive(source: .claude, accountID: "a", now: start.addingTimeInterval(30)))
    }

    func testAWriteDuringTheDecayExtendsIt() {
        var pulse = ActivityPulse()
        pulse.tick(source: .claude, accountID: "a", at: start)
        pulse.tick(source: .claude, accountID: "a", at: start.addingTimeInterval(20))
        XCTAssertTrue(pulse.isActive(source: .claude, accountID: "a", now: start.addingTimeInterval(45)))
        XCTAssertFalse(pulse.isActive(source: .claude, accountID: "a", now: start.addingTimeInterval(50)))
    }

    /// Two accounts of one service are two different sessions. One going quiet says
    /// nothing about the other.
    func testTwoAccountsOfOneServiceDecayIndependently() {
        var pulse = ActivityPulse()
        pulse.tick(source: .claude, accountID: "work", at: start)
        pulse.tick(source: .claude, accountID: "personal", at: start.addingTimeInterval(25))
        let later = start.addingTimeInterval(40)
        XCTAssertFalse(pulse.isActive(source: .claude, accountID: "work", now: later))
        XCTAssertTrue(pulse.isActive(source: .claude, accountID: "personal", now: later))
    }

    /// The notch draws one bar per service, so the service-level answer is "any account".
    func testAServiceIsActiveWhileAnyOfItsAccountsIs() {
        var pulse = ActivityPulse()
        pulse.tick(source: .codex, accountID: "second", at: start)
        XCTAssertTrue(pulse.isActive(source: .codex, now: start.addingTimeInterval(5)))
        XCTAssertFalse(pulse.isActive(source: .claude, now: start.addingTimeInterval(5)))
    }

    /// Without pruning, a long-running app keeps one entry per account it has ever seen.
    func testPruneDropsTicksThatCanNoLongerMakeAnythingActive() {
        var pulse = ActivityPulse()
        pulse.tick(source: .claude, accountID: "a", at: start)
        pulse.prune(now: start.addingTimeInterval(10))
        XCTAssertFalse(pulse.isQuiet)
        pulse.prune(now: start.addingTimeInterval(31))
        XCTAssertTrue(pulse.isQuiet)
    }

    // MARK: - Turn markers

    /// The reason this exists. Measured across 39 Codex transcripts, a turn falls silent
    /// for tens of seconds while the model thinks or a tool runs — so the 30-second decay
    /// went dark in the middle of the very work the bar is there to show. An open turn is
    /// the CLI saying it is still working, and it outlasts that silence.
    func testKeepsAnOpenTurnWorkingThroughSilenceTheDecayWouldHaveEnded() {
        var pulse = ActivityPulse()
        let start = Date()
        pulse.note(.started, source: .codex, accountID: "a", at: start)

        let quiet = start.addingTimeInterval(ActivityPulse.decay + 60)
        XCTAssertTrue(pulse.isActive(source: .codex, accountID: "a", now: quiet))
        XCTAssertTrue(pulse.isActive(source: .codex, now: quiet))
    }

    /// But not forever. Eight of the 102 turns measured never wrote `task_complete` at
    /// all, because Codex was stopped mid-turn: their transcripts end saying a turn is
    /// still running, and without a cap the bar would shimmer until the app was quit.
    func testStopsBelievingATurnNobodyHasHeardFrom() {
        var pulse = ActivityPulse()
        let start = Date()
        pulse.note(.started, source: .codex, accountID: "a", at: start)

        let abandoned = start.addingTimeInterval(ActivityPulse.turnCap + 1)
        XCTAssertFalse(pulse.isActive(source: .codex, accountID: "a", now: abandoned))
    }

    /// Finishing clears the account rather than letting it decay: the CLI has just said it
    /// is done, and thirty more seconds of shimmer would claim something known to be false.
    func testGoesDarkAtOnceWhenTheTurnFinishes() {
        var pulse = ActivityPulse()
        let now = Date()
        pulse.tick(source: .codex, accountID: "a", at: now)
        XCTAssertTrue(pulse.isActive(source: .codex, accountID: "a", now: now))

        pulse.note(.finished, source: .codex, accountID: "a", at: now)
        XCTAssertFalse(pulse.isActive(source: .codex, accountID: "a", now: now))
    }

    /// A transcript with no markers is an ordinary state — Claude's have none — so it must
    /// leave the write-and-decay heuristic exactly as it found it.
    func testLeavesTheWriteHeuristicAloneWhenThereIsNoMarker() {
        var pulse = ActivityPulse()
        let now = Date()
        pulse.tick(source: .claude, accountID: "a", at: now)
        pulse.note(.absent, source: .claude, accountID: "a", at: now)

        XCTAssertTrue(pulse.isActive(source: .claude, accountID: "a", now: now.addingTimeInterval(10)))
        XCTAssertFalse(pulse.isActive(source: .claude, accountID: "a",
                                      now: now.addingTimeInterval(ActivityPulse.decay + 1)))
    }

    /// A turn that ends returns the account to the ordinary rule rather than leaving it on
    /// the longer one.
    func testReturnsToTheDecayRuleAfterATurnCloses() {
        var pulse = ActivityPulse()
        let start = Date()
        pulse.note(.started, source: .codex, accountID: "a", at: start)
        pulse.note(.absent, source: .codex, accountID: "a", at: start)
        pulse.tick(source: .codex, accountID: "a", at: start)

        XCTAssertFalse(pulse.isActive(source: .codex, accountID: "a",
                                      now: start.addingTimeInterval(ActivityPulse.decay + 1)))
    }

    /// Pruning must not throw away an account that is only quiet because its turn is still
    /// open — that would undo the whole point of the marker one second later.
    func testPruneKeepsAnOpenTurnItsSilence() {
        var pulse = ActivityPulse()
        let start = Date()
        pulse.note(.started, source: .codex, accountID: "a", at: start)

        pulse.prune(now: start.addingTimeInterval(ActivityPulse.decay + 30))
        XCTAssertFalse(pulse.isQuiet)

        pulse.prune(now: start.addingTimeInterval(ActivityPulse.turnCap + 1))
        XCTAssertTrue(pulse.isQuiet)
    }
}
