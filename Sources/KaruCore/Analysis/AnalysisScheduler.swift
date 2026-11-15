import Foundation

/// One unit of schedulable analysis work (M17 T17.1, plan §3 "调度").
///
/// `step` is called repeatedly on the main thread with a deadline
/// (`DispatchTime` uptime nanoseconds); it should do work until roughly that
/// deadline and return `true` once the job is finished. `completion` runs once,
/// after the final step, unless the job was cancelled first.
@MainActor
public final class AnalysisJob {
    public let owner: ObjectIdentifier
    public let version: UInt64
    let step: (_ deadline: UInt64) -> Bool
    let completion: () -> Void
    /// Whether the owner's window is currently the key window. Evaluated each
    /// time the scheduler picks the next job, so focus changes take effect at
    /// the next pick.
    let isInKeyWindow: () -> Bool

    /// Set when the job is cancelled; a cancelled job never steps again and
    /// never calls `completion`.
    public internal(set) var isCancelled = false

    public init(owner: ObjectIdentifier,
                version: UInt64,
                step: @escaping (_ deadline: UInt64) -> Bool,
                completion: @escaping () -> Void,
                isInKeyWindow: @escaping () -> Bool = { false }) {
        self.owner = owner
        self.version = version
        self.step = step
        self.completion = completion
        self.isInKeyWindow = isInKeyWindow
    }
}

/// Main-thread, time-sliced runner for analysis jobs (plan §3, decision D).
///
/// - Each turn runs job steps until `sliceBudget` has elapsed, then yields to
///   the run loop (`DispatchQueue.main.async`) before the next slice, so input
///   and layout interleave with long work.
/// - Jobs whose owner's window is the key window run first.
/// - Scheduling a job cancels the owner's older jobs (pending, delayed or
///   running), so at most one job per owner is live: a new edit, a language
///   switch or closing the window supersedes stale work.
///
/// AppKit text and layout stay on the main thread; nothing here hops queues.
@MainActor
public final class AnalysisScheduler {
    /// Process-wide scheduler. `nonisolated` (the class is main-actor
    /// isolated, hence `Sendable`) so it can be a default argument.
    public nonisolated static let shared = AnalysisScheduler()

    /// Main-thread time per slice before yielding to the run loop.
    public nonisolated static let sliceBudget: TimeInterval = 0.004

    private var ready: [AnalysisJob] = []
    private var delayed: [(job: AnalysisJob, item: DispatchWorkItem)] = []
    private var running: AnalysisJob?
    private var sliceScheduled = false

    /// Number of slices run so far (tests).
    private(set) var sliceCount = 0

    /// Jobs waiting for their delay or for a slice (tests / diagnostics).
    var pendingJobCount: Int { ready.count + delayed.count }

    public nonisolated init() {}

    /// Queues `job` to start after `delay` seconds (0 = next slice). Cancels
    /// every older job of the same owner first.
    public func schedule(_ job: AnalysisJob, after delay: TimeInterval = 0) {
        cancel(owner: job.owner)
        guard delay > 0 else {
            ready.append(job)
            scheduleSlice()
            return
        }
        let item = DispatchWorkItem { [weak self, weak job] in
            MainActor.assumeIsolated {
                guard let self, let job else { return }
                self.promote(job)
            }
        }
        delayed.append((job, item))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Cancels the owner's pending, delayed and running jobs. None of them
    /// will call its completion.
    public func cancel(owner: ObjectIdentifier) {
        for entry in delayed where entry.job.owner == owner {
            entry.job.isCancelled = true
            entry.item.cancel()
        }
        delayed.removeAll { $0.job.owner == owner }
        for job in ready where job.owner == owner { job.isCancelled = true }
        ready.removeAll { $0.owner == owner }
        if let running, running.owner == owner { running.isCancelled = true }
    }

    private func promote(_ job: AnalysisJob) {
        delayed.removeAll { $0.job === job }
        guard !job.isCancelled else { return }
        ready.append(job)
        scheduleSlice()
    }

    private func scheduleSlice() {
        guard !sliceScheduled, !ready.isEmpty else { return }
        sliceScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.runSlice() }
        }
    }

    /// Runs every pending job to completion now, without the run loop: a
    /// delayed job is promoted without waiting for its delay, and each step
    /// gets a deadline `budget` from its start (0: one minimal step at a
    /// time). Jobs scheduled meanwhile (a completion publishing a snapshot
    /// schedules its follow-up work) run too. Deterministic for tests, where
    /// a timer-driven wait can starve behind other main-actor work.
    func runPendingJobsForTesting(budget: TimeInterval = AnalysisScheduler.sliceBudget) {
        while true {
            for entry in delayed {
                entry.item.cancel()
                if !entry.job.isCancelled { ready.append(entry.job) }
            }
            delayed.removeAll()
            guard !ready.isEmpty else { return }
            let index = ready.firstIndex { $0.isInKeyWindow() } ?? 0
            let job = ready[index]
            running = job
            let done = job.step(DispatchTime.now().uptimeNanoseconds + UInt64(budget * 1_000_000_000))
            running = nil
            if job.isCancelled {
                ready.removeAll { $0 === job }
            } else if done {
                ready.removeAll { $0 === job }
                job.completion()
            }
        }
    }

    /// Runs steps until the slice deadline passes, then yields if work remains.
    private func runSlice() {
        sliceScheduled = false
        guard !ready.isEmpty else { return }
        sliceCount += 1
        let budgetNs = UInt64(Self.sliceBudget * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds + budgetNs
        while !ready.isEmpty {
            let index = ready.firstIndex { $0.isInKeyWindow() } ?? 0
            let job = ready[index]
            running = job
            let done = job.step(deadline)
            running = nil
            if job.isCancelled {
                // Cancelled from inside its own step (e.g. superseded): drop it
                // without completing. `cancel` already removed it from `ready`.
                ready.removeAll { $0 === job }
            } else if done {
                ready.removeAll { $0 === job }
                job.completion()
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline { break }
        }
        scheduleSlice()
    }
}
