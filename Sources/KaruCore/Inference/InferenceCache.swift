import Foundation

/// A least-recently-used cache bounded by both an approximate byte cost and
/// an entry count (plan §11: budgets limit entries *and* bytes, so long
/// names cannot slip past a count limit). Single-threaded (the owners are
/// main-actor objects). Amortised O(1): recency is an append-only key log
/// with lazy deletion, compacted when it grows past four times the live count.
final class ByteLRU<Key: Hashable, Value> {
    private struct Slot {
        var value: Value
        var cost: Int
        var tick: UInt64
    }

    let byteLimit: Int
    let countLimit: Int
    private var slots: [Key: Slot] = [:]
    private var log: [(key: Key, tick: UInt64)] = []
    private var logHead = 0
    private var tick: UInt64 = 0
    private(set) var bytes = 0
    private(set) var evictions = 0

    init(byteLimit: Int, countLimit: Int = 4_096) {
        self.byteLimit = byteLimit
        self.countLimit = countLimit
    }

    var count: Int { slots.count }
    var isEmpty: Bool { slots.isEmpty }

    /// The cached value (marks it recent).
    func value(for key: Key) -> Value? {
        guard var slot = slots[key] else { return nil }
        tick &+= 1
        slot.tick = tick
        slots[key] = slot
        log.append((key, tick))
        compactIfNeeded()
        return slot.value
    }

    /// Stores `value` with `cost` bytes; a value larger than the limit alone
    /// is not kept. Evicts the least recently used entries past the limits.
    func insert(_ value: Value, for key: Key, cost: Int) {
        if let old = slots.removeValue(forKey: key) { bytes -= old.cost }
        guard cost <= byteLimit else { return }
        tick &+= 1
        slots[key] = Slot(value: value, cost: cost, tick: tick)
        log.append((key, tick))
        bytes += cost
        while bytes > byteLimit || slots.count > countLimit, logHead < log.count {
            let (victim, stamp) = log[logHead]
            logHead += 1
            guard let slot = slots[victim], slot.tick == stamp else { continue }
            slots.removeValue(forKey: victim)
            bytes -= slot.cost
            evictions += 1
        }
        compactIfNeeded()
    }

    func removeAll() {
        slots = [:]
        log = []
        logHead = 0
        bytes = 0
    }

    /// Drops the entries whose key satisfies `predicate`.
    func removeAll(where predicate: (Key) -> Bool) {
        for key in slots.keys where predicate(key) {
            if let slot = slots.removeValue(forKey: key) { bytes -= slot.cost }
        }
        compactIfNeeded()
    }

    private func compactIfNeeded() {
        guard log.count - logHead > max(64, slots.count * 4) else { return }
        log = log[logHead...].filter { slots[$0.key]?.tick == $0.tick }
        logHead = 0
    }
}

/// A per-request budget (plan §8.3: inference runs synchronously inside a
/// completion request and must not block it). Exceeding the step count or
/// the deadline aborts the inference; the request then gets no inferred
/// members (the usage-evidence path), never a partial result.
struct InferenceBudget {
    static let defaultSteps = 200_000
    /// Inference part of the 50 ms keystroke-to-candidates budget.
    static let defaultMilliseconds = 25.0

    private(set) var steps = 0
    let maxSteps: Int
    let deadline: UInt64
    private(set) var exhausted = false

    init(maxSteps: Int = InferenceBudget.defaultSteps, milliseconds: Double = InferenceBudget.defaultMilliseconds) {
        self.maxSteps = maxSteps
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds * 1_000_000)
    }

    /// Counts one unit of work; false once the budget is spent.
    @inline(__always) mutating func tick() -> Bool {
        if exhausted { return false }
        steps += 1
        if steps >= maxSteps || (steps & 255 == 0 && DispatchTime.now().uptimeNanoseconds > deadline) {
            exhausted = true
        }
        return !exhausted
    }
}
