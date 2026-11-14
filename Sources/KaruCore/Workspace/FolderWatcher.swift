import CoreServices
import Foundation

/// One FSEvents stream over a project folder (M17 T17.12): file-level events,
/// `latency` seconds of coalescing (≤ 0.3 s), delivered on a private serial
/// queue to `handler` as (absolute path, needs full rescan) pairs.
///
/// `stop()` stops and invalidates the stream; the handler box is released on
/// the delivery queue afterwards, so a callback already running finishes
/// against a live box and none arrives later.
final class FolderWatcher {
    typealias Handler = @Sendable ([(path: String, rescan: Bool)]) -> Void

    private final class Box {
        let handler: Handler
        init(_ handler: @escaping Handler) { self.handler = handler }
    }

    private var stream: FSEventStreamRef?
    private var box: Unmanaged<Box>?
    private let queue: DispatchQueue

    static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)

    /// Starts watching `path` (an existing directory). Returns nil when the
    /// stream cannot be created or started.
    init?(path: String, latency: TimeInterval, queue: DispatchQueue, handler: @escaping Handler) {
        self.queue = queue
        let box = Unmanaged.passRetained(Box(handler))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var events: [(String, Bool)] = []
            events.reserveCapacity(count)
            for i in 0..<count {
                guard let path = array[i] as? String else { continue }
                events.append((path, flags[i] & FolderWatcher.rescanFlags != 0))
            }
            box.handler(events)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            box.release()
            return nil
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            box.release()
            return nil
        }
        self.stream = stream
        self.box = box
    }

    var isRunning: Bool { stream != nil }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        if let box {
            self.box = nil
            queue.async { box.release() }
        }
    }

    deinit { stop() }
}
