import Foundation
import CryptoKit

// Crash-draft checkpoints (R05): *when* a checkpoint fires, and *how* the
// background I/O for one window is queued. Both halves are free of AppKit so
// they can be unit-tested with an injected clock and a slow fake store.

// MARK: - Timing

/// A scheduled checkpoint that can be called off.
protocol CheckpointCancellable: AnyObject {
    func cancel()
}

extension DispatchWorkItem: CheckpointCancellable {}

/// The clock and timer behind `DraftCheckpointer`. Production uses the main
/// queue; tests inject a manual clock so 30 s of typing costs no real time.
@MainActor
protocol CheckpointScheduling: AnyObject {
    /// Monotonic seconds; only differences matter.
    var now: TimeInterval { get }
    /// Runs `action` on the main actor once `now` reaches `deadline`.
    func schedule(at deadline: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> CheckpointCancellable
}

/// One `DispatchWorkItem` on the main queue per scheduled deadline, on the same
/// monotonic clock `DispatchTime` uses (so `now` and the deadline agree).
@MainActor
final class MainQueueCheckpointScheduler: CheckpointScheduling {
    nonisolated init() {}

    var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func schedule(at deadline: TimeInterval,
                  _ action: @escaping @MainActor () -> Void) -> CheckpointCancellable {
        let work = DispatchWorkItem {
            // Scheduled on the main queue; the hop is a formality for the
            // isolation checker (same pattern as the status bar's flash timer).
            MainActor.assumeIsolated { action() }
        }
        let delay = max(0, deadline - now)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }
}

/// Decides when the next checkpoint fires: `debounce` after the last edit, but
/// never later than `maxInterval` after the first edit that has not been
/// checkpointed yet —
/// `deadline = min(lastEdit + debounce, firstUnflushedEdit + maxInterval)`.
/// So a pause writes promptly, and typing that never pauses long enough still
/// writes at least every `maxInterval`.
///
/// Holds at most one scheduled item, and only while an edit is unflushed: after
/// a checkpoint (or `cancel()`) nothing is scheduled (ARCHITECTURE.md §3.4).
@MainActor
final class DraftCheckpointer {
    nonisolated static let defaultDebounce: TimeInterval = 1.5
    nonisolated static let defaultMaxInterval: TimeInterval = 10

    var debounce: TimeInterval
    var maxInterval: TimeInterval
    var scheduler: any CheckpointScheduling

    /// What a checkpoint does. Called on the main actor, after the
    /// checkpointer has already forgotten the unflushed edits.
    private let action: @MainActor () -> Void

    /// Time of the first edit since the last checkpoint, `nil` when clean.
    private(set) var firstUnflushedEdit: TimeInterval?
    /// When the scheduled checkpoint fires, `nil` when nothing is scheduled.
    private(set) var deadline: TimeInterval?
    private var pending: CheckpointCancellable?

    init(debounce: TimeInterval = DraftCheckpointer.defaultDebounce,
         maxInterval: TimeInterval = DraftCheckpointer.defaultMaxInterval,
         scheduler: any CheckpointScheduling = MainQueueCheckpointScheduler(),
         action: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.maxInterval = maxInterval
        self.scheduler = scheduler
        self.action = action
    }

    deinit {
        pending?.cancel()
    }

    /// Whether a checkpoint is scheduled.
    var isScheduled: Bool { pending != nil }

    /// Records an edit and (re)schedules the checkpoint.
    func noteEdit() {
        let now = scheduler.now
        let first = firstUnflushedEdit ?? now
        firstUnflushedEdit = first
        let next = min(now + debounce, first + maxInterval)
        // Already pinned to the maximum: the item in place fires at that very
        // moment, so there is nothing to re-arm.
        if pending != nil, deadline == next { return }
        pending?.cancel()
        deadline = next
        pending = scheduler.schedule(at: next) { [weak self] in self?.fire() }
    }

    /// Forgets the unflushed edits and anything scheduled — after an explicit
    /// checkpoint, a removal, or at teardown.
    func cancel() {
        pending?.cancel()
        pending = nil
        deadline = nil
        firstUnflushedEdit = nil
    }

    private func fire() {
        cancel()
        action()
    }
}

// MARK: - Background I/O

/// What the background job needs from a draft store. `DraftStore` is the only
/// production conformer; tests substitute a slow or failing fake.
protocol DraftStoring: Sendable {
    func write(id: UUID, content: String, originalPath: String?,
               base: DiskState?) -> Result<Void, Error>
    func remove(id: UUID)
}

extension DraftStore: DraftStoring {}

/// Everything a checkpoint needs, taken on the main thread as plain values:
/// the buffer text, where it belongs, and the baseline digest to compare it
/// against. The comparison itself — a whole-buffer SHA-256 — runs on the
/// background queue, not while the user types.
struct DraftSnapshot: Sendable {
    let id: UUID
    let content: String
    let originalPath: String?
    let base: DiskState?
    /// SHA-256 of the saved baseline (`DocumentController.baselineSHA256`).
    let baselineDigest: Data

    /// Whether `content` is byte-for-byte the baseline. Off the main thread.
    func matchesBaseline() -> Bool {
        var text = content
        let digest = text.withUTF8 { SHA256.hash(data: UnsafeRawBufferPointer($0)) }
        return Data(digest) == baselineDigest
    }
}

/// Per-window draft I/O that never queues more than one snapshot.
///
/// At any moment there is at most one job running and at most one waiting. A
/// newer request replaces the waiting one — a stale snapshot is useless once a
/// newer one exists, and on slow storage a queue of multi-megabyte copies is
/// exactly what must not build up. Because jobs run strictly in submission
/// order on a serial queue and only the waiting slot is ever replaced, a
/// `remove` can never be overtaken by an older write: it either runs after the
/// job in flight, or is itself replaced by something newer still.
final class DraftWriteQueue: @unchecked Sendable {

    enum Job: Sendable {
        /// Write the snapshot — or remove the draft if it equals the baseline.
        case checkpoint(DraftSnapshot, any DraftStoring)
        case remove(UUID, any DraftStoring)
    }

    enum Outcome: Sendable, Equatable {
        case written
        case removed
        case failed
    }

    private let queue: DispatchQueue
    /// Called on the I/O queue after each job, once its outcome is recorded.
    private let outcomeAvailable: @Sendable () -> Void

    private let lock = NSLock()
    private var waiting: Job?
    private var draining = false
    private var outcomes: [Outcome] = []

    /// `queue` must be serial; it may be shared by several windows.
    init(queue: DispatchQueue, outcomeAvailable: @escaping @Sendable () -> Void = {}) {
        self.queue = queue
        self.outcomeAvailable = outcomeAvailable
    }

    func submit(_ job: Job) {
        lock.lock()
        waiting = job
        let start = !draining
        draining = true
        lock.unlock()
        if start {
            queue.async { self.drain() }
        }
    }

    /// Number of jobs waiting behind the one in flight: 0 or 1, by construction.
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting == nil ? 0 : 1
    }

    /// Outcomes recorded since the last call, oldest first.
    func takeOutcomes() -> [Outcome] {
        lock.lock()
        defer { lock.unlock() }
        let taken = outcomes
        outcomes.removeAll()
        return taken
    }

    /// Blocks until every job submitted so far has run. The drain loop picks up
    /// a job submitted while it runs before it returns, so one barrier block on
    /// the serial queue is enough.
    func waitUntilIdle() {
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = waiting else {
                draining = false
                lock.unlock()
                return
            }
            waiting = nil
            lock.unlock()

            let outcome = Self.perform(job)
            lock.lock()
            outcomes.append(outcome)
            lock.unlock()
            outcomeAvailable()
        }
    }

    private static func perform(_ job: Job) -> Outcome {
        switch job {
        case .remove(let id, let store):
            store.remove(id: id)
            return .removed
        case .checkpoint(let snapshot, let store):
            // The arbitration rule (T14.11): a draft exists exactly while the
            // buffer differs from the saved baseline.
            if snapshot.matchesBaseline() {
                store.remove(id: snapshot.id)
                return .removed
            }
            switch store.write(id: snapshot.id, content: snapshot.content,
                               originalPath: snapshot.originalPath, base: snapshot.base) {
            case .success: return .written
            case .failure: return .failed
            }
        }
    }
}
