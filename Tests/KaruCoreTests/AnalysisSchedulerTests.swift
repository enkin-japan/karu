import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.1 — main-thread time-sliced scheduler: slicing with yields,
// cancellation (stale owner / superseded version) and key-window priority.

/// A fake owner identity (the scheduler only compares identities).
private final class FakeOwner {}

/// Mutable cell a main-queue block can write to.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Busy-waits `micros` on the main thread (simulated work).
private func spin(micros: UInt64) {
    let end = DispatchTime.now().uptimeNanoseconds + micros * 1_000
    while DispatchTime.now().uptimeNanoseconds < end {}
}

/// Lets the main run loop turn until `done()` or the timeout.
@MainActor
private func waitUntil(timeout: TimeInterval = 3, _ done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
@Suite("AnalysisScheduler", .serialized)
struct AnalysisSchedulerTests {

    @Test func longJobYieldsBetweenSlicesAndStillCompletes() async {
        let scheduler = AnalysisScheduler()
        let owner = FakeOwner()
        let totalSteps = 40          // ≈ 1 ms each → about 10 slices of 4 ms
        let steps = Box(0)
        var completed = false
        let stepsWhenMainQueueRan = Box<Int?>(nil)

        let job = AnalysisJob(owner: ObjectIdentifier(owner), version: 1, step: { _ in
            if steps.value == 0 {
                // Enqueued during the first slice: it can only run if the
                // scheduler yields back to the run loop before finishing.
                DispatchQueue.main.async { stepsWhenMainQueueRan.value = steps.value }
            }
            spin(micros: 1_000)
            steps.value += 1
            return steps.value >= totalSteps
        }, completion: { completed = true })
        scheduler.schedule(job)
        await waitUntil { completed }

        #expect(completed)
        #expect(steps.value == totalSteps)
        #expect(scheduler.sliceCount >= 3, "ran in \(scheduler.sliceCount) slice(s)")
        // The run loop got control while the job was still unfinished.
        #expect((stepsWhenMainQueueRan.value ?? totalSteps) < totalSteps)
        #expect(scheduler.pendingJobCount == 0)
        _ = owner
    }

    @Test func respectsTheDeadlinePassedToSteps() async {
        let scheduler = AnalysisScheduler()
        let owner = FakeOwner()
        var deadlines: [UInt64] = []
        var completed = false
        let job = AnalysisJob(owner: ObjectIdentifier(owner), version: 1, step: { deadline in
            deadlines.append(deadline)
            // Work right up to the deadline, as a chunking scanner would.
            while DispatchTime.now().uptimeNanoseconds < deadline {}
            return deadlines.count == 3
        }, completion: { completed = true })
        scheduler.schedule(job)
        await waitUntil { completed }
        #expect(completed)
        // Each step got a fresh slice deadline ≈ 4 ms after the slice start.
        #expect(Set(deadlines).count == 3)
        #expect(scheduler.sliceCount == 3)
        _ = owner
    }

    @Test func cancelledOrSupersededJobsNeverComplete() async {
        let scheduler = AnalysisScheduler()
        let a = FakeOwner()
        let b = FakeOwner()
        var log: [String] = []

        // 1. Delayed job cancelled before it starts: never steps or completes.
        let delayed = AnalysisJob(owner: ObjectIdentifier(a), version: 1,
                                  step: { _ in log.append("a1 step"); return true },
                                  completion: { log.append("a1 done") })
        scheduler.schedule(delayed, after: 0.03)
        scheduler.cancel(owner: ObjectIdentifier(a))
        #expect(delayed.isCancelled)

        // 2. A newer version for the same owner supersedes the older one.
        let old = AnalysisJob(owner: ObjectIdentifier(b), version: 1,
                              step: { _ in log.append("b1 step"); return true },
                              completion: { log.append("b1 done") })
        let new = AnalysisJob(owner: ObjectIdentifier(b), version: 2,
                              step: { _ in log.append("b2 step"); return true },
                              completion: { log.append("b2 done") })
        scheduler.schedule(old, after: 0.01)
        scheduler.schedule(new, after: 0.02)
        #expect(old.isCancelled)

        await waitUntil { log.contains("b2 done") }
        try? await Task.sleep(nanoseconds: 80_000_000)   // past every delay
        #expect(log == ["b2 step", "b2 done"])
        _ = (a, b)
    }

    @Test func jobCancelledWhileRunningStopsWithoutCompletion() async {
        let scheduler = AnalysisScheduler()
        let owner = FakeOwner()
        var steps = 0
        var completed = false
        let job = AnalysisJob(owner: ObjectIdentifier(owner), version: 7, step: { _ in
            steps += 1
            if steps == 3 { scheduler.cancel(owner: ObjectIdentifier(owner)) }
            spin(micros: 2_000)
            return steps >= 10
        }, completion: { completed = true })
        scheduler.schedule(job)
        await waitUntil { scheduler.pendingJobCount == 0 && steps >= 3 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(steps == 3)
        #expect(!completed)
        #expect(job.isCancelled)
    }

    @Test func keyWindowOwnerRunsFirst() async {
        let scheduler = AnalysisScheduler()
        let background = FakeOwner()
        let key = FakeOwner()
        var order: [String] = []
        var finished = 0

        // Both are queued before the first slice runs; the background job was
        // queued first and needs several slices.
        var backgroundSteps = 0
        scheduler.schedule(AnalysisJob(owner: ObjectIdentifier(background), version: 1, step: { _ in
            order.append("bg")
            spin(micros: 3_000)
            backgroundSteps += 1
            return backgroundSteps == 4
        }, completion: { finished += 1 }, isInKeyWindow: { false }))
        var keySteps = 0
        scheduler.schedule(AnalysisJob(owner: ObjectIdentifier(key), version: 1, step: { _ in
            order.append("key")
            spin(micros: 3_000)
            keySteps += 1
            return keySteps == 3
        }, completion: { finished += 1 }, isInKeyWindow: { true }))

        await waitUntil { finished == 2 }
        #expect(finished == 2)
        #expect(order == ["key", "key", "key", "bg", "bg", "bg", "bg"])
        _ = (background, key)
    }
}
