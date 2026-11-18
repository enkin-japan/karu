import Foundation
import CryptoKit
import Testing
@testable import KaruCore

// R05 — crash-draft checkpoints: the timing policy (debounce plus a maximum
// interval) against an injected clock, and the per-window I/O queue that keeps
// at most one snapshot waiting, against a slow fake store.

// MARK: - Manual clock

/// A clock that only moves when told to. `advance(to:)` fires every scheduled
/// action whose deadline has come, in deadline order, with `now` set to that
/// deadline. Shared with the window controller and scratchpad tests.
@MainActor
final class ManualCheckpointScheduler: CheckpointScheduling {
    final class Token: CheckpointCancellable {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        var fired = false
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private var tokens: [Token] = []

    func schedule(at deadline: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> CheckpointCancellable {
        let token = Token(deadline: deadline, action: action)
        tokens.append(token)
        return token
    }

    /// Scheduled actions that neither fired nor were cancelled.
    var liveCount: Int { tokens.filter { !$0.cancelled && !$0.fired }.count }

    func advance(to target: TimeInterval) {
        while let next = tokens
            .filter({ !$0.cancelled && !$0.fired && $0.deadline <= target })
            .min(by: { $0.deadline < $1.deadline }) {
            now = max(now, next.deadline)
            next.fired = true
            next.action()
        }
        now = max(now, target)
        tokens.removeAll { $0.cancelled || $0.fired }
    }

    func advance(by delta: TimeInterval) {
        advance(to: now + delta)
    }
}

// MARK: - Slow fake store

/// Records every write/remove and keeps a fake "directory" of draft contents.
/// With `blockFirstWrite`, the first write waits on `release()` after
/// signalling `started`, so a test can submit more while it is in flight.
final class FakeDraftStore: DraftStoring, @unchecked Sendable {
    enum Event: Equatable {
        case write(String)
        case remove
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _files: [UUID: String] = [:]
    private var gateArmed: Bool
    private let gate = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)

    init(blockFirstWrite: Bool = false) {
        gateArmed = blockFirstWrite
    }

    var events: [Event] { lock.withLock { _events } }
    var files: [UUID: String] { lock.withLock { _files } }
    var writeCount: Int { events.filter { if case .write = $0 { true } else { false } }.count }

    func release() { gate.signal() }

    func write(id: UUID, content: String, originalPath: String?,
               base: DiskState?) -> Result<Void, Error> {
        let block = lock.withLock { () -> Bool in
            let armed = gateArmed
            gateArmed = false
            return armed
        }
        if block {
            started.signal()
            gate.wait()
        }
        lock.withLock {
            _events.append(.write(content))
            _files[id] = content
        }
        return .success(())
    }

    func remove(id: UUID) {
        lock.withLock {
            _events.append(.remove)
            _files[id] = nil
        }
    }
}

private func digest(_ text: String) -> Data {
    Data(SHA256.hash(data: Data(text.utf8)))
}

private func snapshot(_ id: UUID, _ content: String, baseline: String = "") -> DraftSnapshot {
    DraftSnapshot(id: id, content: content, originalPath: nil, base: nil,
                  baselineDigest: digest(baseline))
}

private func makeQueue() -> DispatchQueue {
    DispatchQueue(label: "DraftCheckpointerTests-\(UUID().uuidString)")
}

@MainActor
struct DraftCheckpointerTests {

    // MARK: Timing

    @Test func continuousTypingStillCheckpointsAtLeastEveryMaxInterval() {
        let clock = ManualCheckpointScheduler()
        var fires: [TimeInterval] = []
        let checkpointer = DraftCheckpointer(scheduler: clock) { fires.append(clock.now) }

        // An edit every 0.5 s for 30 s: never a pause as long as the debounce.
        var t: TimeInterval = 0
        while t <= 30 {
            clock.advance(to: t)
            checkpointer.noteEdit()
            t += 0.5
        }
        let lastEdit = clock.now
        clock.advance(to: 60)

        #expect(fires.count >= 3)
        // From the first edit on, never more than 10 s without a checkpoint.
        var previous: TimeInterval = 0
        for fire in fires {
            #expect(fire - previous <= DraftCheckpointer.defaultMaxInterval + 1e-9)
            previous = fire
        }
        // Once the typing stops, the last one waits for the debounce — no
        // earlier, no later.
        #expect(abs(fires.last! - (lastEdit + DraftCheckpointer.defaultDebounce)) < 1e-9)
        #expect(!checkpointer.isScheduled)
        #expect(clock.liveCount == 0)
    }

    @Test func aSingleEditFiresAfterTheDebounce() {
        let clock = ManualCheckpointScheduler()
        var fires: [TimeInterval] = []
        let checkpointer = DraftCheckpointer(scheduler: clock) { fires.append(clock.now) }

        checkpointer.noteEdit()
        clock.advance(to: 1.49)
        #expect(fires.isEmpty)
        clock.advance(to: 1.5)
        #expect(fires == [1.5])
    }

    @Test func afterACheckpointWithNoFurtherEditsNothingIsScheduled() {
        let clock = ManualCheckpointScheduler()
        var count = 0
        let checkpointer = DraftCheckpointer(scheduler: clock) { count += 1 }

        checkpointer.noteEdit()
        clock.advance(to: 2)
        #expect(count == 1)
        #expect(!checkpointer.isScheduled)
        #expect(checkpointer.firstUnflushedEdit == nil)
        #expect(clock.liveCount == 0)
        clock.advance(to: 100)
        #expect(count == 1)

        // An explicit checkpoint (cancel) also leaves nothing behind.
        checkpointer.noteEdit()
        #expect(clock.liveCount == 1)
        checkpointer.cancel()
        #expect(clock.liveCount == 0)
        clock.advance(to: 200)
        #expect(count == 1)
    }

    @Test func theMaximumCountsFromTheFirstUnflushedEditNotTheLatest() {
        let clock = ManualCheckpointScheduler()
        var fires: [TimeInterval] = []
        let checkpointer = DraftCheckpointer(debounce: 1.5, maxInterval: 10,
                                             scheduler: clock) { fires.append(clock.now) }
        checkpointer.noteEdit()                        // t = 0
        clock.advance(to: 5)                           // 0 → 1.5 fired already
        #expect(fires == [1.5])
        checkpointer.noteEdit()                        // t = 5: a new run starts
        #expect(checkpointer.firstUnflushedEdit == 5)
        for step in 1...20 {                           // edits every 0.5 s to t = 15
            clock.advance(to: 5 + Double(step) * 0.5)
            checkpointer.noteEdit()
        }
        #expect(fires == [1.5, 15])
    }

    // MARK: Snapshot queue

    @Test func aSlowStoreKeepsOnlyTheNewestSnapshotWaiting() {
        let store = FakeDraftStore(blockFirstWrite: true)
        let writer = DraftWriteQueue(queue: makeQueue())
        let id = UUID()

        writer.submit(.checkpoint(snapshot(id, "v0"), store))
        store.started.wait()                           // v0 is in flight, blocked
        for n in 1...5 {
            writer.submit(.checkpoint(snapshot(id, "v\(n)"), store))
            #expect(writer.waitingCount <= 1)
        }
        #expect(writer.waitingCount == 1)
        store.release()
        writer.waitUntilIdle()

        #expect(store.events == [.write("v0"), .write("v5")])
        #expect(store.writeCount == 2)
        #expect(store.files[id] == "v5")
        #expect(writer.waitingCount == 0)
        #expect(writer.takeOutcomes() == [.written, .written])
    }

    @Test func aRemoveIsNeverOvertakenByAnOlderWrite() {
        let store = FakeDraftStore(blockFirstWrite: true)
        let writer = DraftWriteQueue(queue: makeQueue())
        let id = UUID()

        writer.submit(.checkpoint(snapshot(id, "in flight"), store))
        store.started.wait()
        writer.submit(.checkpoint(snapshot(id, "waiting"), store))
        writer.submit(.remove(id, store))
        store.release()
        writer.waitUntilIdle()

        #expect(store.files[id] == nil)
        #expect(store.events == [.write("in flight"), .remove])
    }

    @Test func aSnapshotBackAtTheBaselineRemovesInsteadOfWriting() {
        let store = FakeDraftStore()
        let writer = DraftWriteQueue(queue: makeQueue())
        let id = UUID()

        writer.submit(.checkpoint(snapshot(id, "edited", baseline: "saved"), store))
        writer.waitUntilIdle()
        #expect(store.files[id] == "edited")

        // The job, not the caller, compares the text with the baseline digest.
        writer.submit(.checkpoint(snapshot(id, "saved", baseline: "saved"), store))
        writer.waitUntilIdle()
        #expect(store.files[id] == nil)
        #expect(store.events == [.write("edited"), .remove])
        #expect(writer.takeOutcomes() == [.written, .removed])
    }

    @Test func snapshotBaselineComparisonHandlesNonASCIIText() {
        let text = "日本語と中文\nwith ascii\n"
        #expect(snapshot(UUID(), text, baseline: text).matchesBaseline())
        #expect(!snapshot(UUID(), text + " ", baseline: text).matchesBaseline())
        #expect(snapshot(UUID(), "", baseline: "").matchesBaseline())
    }
}
