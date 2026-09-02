import CoreServices
import Foundation

/// Watches one transcript directory, and everything below it, for writes.
///
/// This replaces a `DispatchSource` vnode watcher that could not do the job. A vnode
/// source on a directory reports changes to that directory's own entries and nothing
/// else, while both CLIs write their transcripts several directories down —
/// `<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl` and
/// `<CLAUDE_CONFIG_DIR>/projects/<project>/*.jsonl`. The old watcher therefore fired when
/// a new year directory appeared and at no other time, and nothing noticed because the
/// sixty-second poll timer covered for it.
///
/// `kFSEventStreamCreateFlagFileEvents` is the flag that makes nested file modifications
/// visible, and is the entire reason this type exists.
///
/// The watcher stops when it is deallocated, so a caller that does not hold it gets
/// nothing.
public final class TranscriptWatcher: @unchecked Sendable {

    /// Carries the callback across the C boundary. A separate object rather than `self`,
    /// because the stream has to be created before `self` is fully initialized and
    /// `Unmanaged.passUnretained(self)` is not available until it is.
    private final class Sink {
        let run: @Sendable () -> Void
        init(_ run: @escaping @Sendable () -> Void) { self.run = run }
    }

    private let sink: Sink
    private let stream: FSEventStreamRef

    /// - Parameters:
    ///   - root: the directory to watch, recursively. A path that does not exist or is not
    ///     a directory yields nil — an account that has never been used is an ordinary
    ///     state, not a failure.
    ///   - queue: where `changed` is delivered. Defaults to the main queue.
    public init?(root: URL, queue: DispatchQueue = .main, changed: @escaping @Sendable () -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let sink = Sink(changed)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue().run()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }

        self.sink = sink
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
