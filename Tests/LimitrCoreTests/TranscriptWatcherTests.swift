import XCTest
@testable import LimitrCore

/// A box for the "has the write happened yet" flag, so the watcher's callback and the
/// block that performs the write can share it. Both run on the same serial queue.
private final class Flag: @unchecked Sendable {
    var value = false
}

final class TranscriptWatcherTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "TranscriptWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    /// The regression test the deleted `DirectoryWatcher` never had, and the reason its
    /// failure was invisible for so long. Codex transcripts live three directories below
    /// the root that gets watched — `sessions/YYYY/MM/DD/rollout-*.jsonl` — and a vnode
    /// source on `sessions` cannot see a byte of it.
    func testFiresWhenAFileThreeDirectoriesBelowItsRootIsAppendedTo() throws {
        let nested = root.appending(path: "2026/08/31")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let transcript = nested.appending(path: "rollout-test.jsonl")
        try Data(#"{"first":true}"#.utf8).write(to: transcript)

        let fired = expectation(description: "the watcher reports the append")
        fired.assertForOverFulfill = false
        let queue = DispatchQueue(label: "TranscriptWatcherTests")
        // Only an event delivered *after* the append counts. Creating the directories
        // above stirs up events of its own, and a test that accepts any callback at all
        // would pass just as happily against a watcher blind to nested writes — which is
        // the exact failure this file exists to catch. Both closures run on the same
        // serial queue, so reading the flag from the callback needs no other guard.
        let appended = Flag()
        let watcher = TranscriptWatcher(root: root, queue: queue) { [appended] in
            if appended.value { fired.fulfill() }
        }
        XCTAssertNotNil(watcher)

        // The append also has to happen after the stream is running: the stream is created
        // with `kFSEventStreamEventIdSinceNow` and reports nothing that predates it.
        queue.asyncAfter(deadline: .now() + 1) { [appended] in
            guard let handle = try? FileHandle(forWritingTo: transcript) else { return }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(#"{"appended":true}"#.utf8))
            try? handle.close()
            appended.value = true
        }

        wait(for: [fired], timeout: 15)
        withExtendedLifetime(watcher) {}
    }

    func testFiresWhenANewNestedTranscriptIsCreated() throws {
        let fired = expectation(description: "the watcher reports the new file")
        fired.assertForOverFulfill = false
        let queue = DispatchQueue(label: "TranscriptWatcherTests.create")
        let created = Flag()
        let watcher = TranscriptWatcher(root: root, queue: queue) { [created] in
            if created.value { fired.fulfill() }
        }
        XCTAssertNotNil(watcher)

        let nested = root.appending(path: "2026/09/01")
        queue.asyncAfter(deadline: .now() + 1) { [created] in
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try? Data(#"{"new":true}"#.utf8).write(to: nested.appending(path: "rollout-new.jsonl"))
            created.value = true
        }

        wait(for: [fired], timeout: 15)
        withExtendedLifetime(watcher) {}
    }

    /// An account that has never been used has no transcript directory. That is an
    /// ordinary state, not an error, and the caller simply gets no watcher for it.
    func testRefusesARootThatDoesNotExist() {
        XCTAssertNil(TranscriptWatcher(root: root.appending(path: "absent")) {})
    }

    func testRefusesARootThatIsAFileRatherThanADirectory() throws {
        let file = root.appending(path: "not-a-directory")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(TranscriptWatcher(root: file) {})
    }
}
