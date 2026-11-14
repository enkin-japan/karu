import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.10 — type-table cold query time and decoded memory. Opt-in, run
// alone so the process-wide memory readings are not disturbed:
//
//     KARU_T1710_BENCH=1 swift test --filter TypeTableBenchmark
//
// - cold first query: a fresh store per run (mmap + header + index search +
//   one decode); the file stays in the OS page cache after the first run.
// - decoded bytes: the store's LRU estimate, next to `malloc_zone_statistics`
//   (bytes in use) and `phys_footprint` deltas for the same work, measured
//   while the store is alive.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1710_BENCH"] == "1"

private func physFootprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

private func kb(_ bytes: Int) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }

@Suite("TypeTableBenchmark", .enabled(if: benchEnabled), .serialized)
struct TypeTableBenchmarkTests {
    @Test func coldFirstQuery() {
        var lines: [String] = []
        func measure(_ label: String, _ query: (TypeTableStore) -> Bool) {
            var ms: [Double] = []
            for _ in 0..<41 {
                let store = TypeTableStore(cacheByteLimit: 64 << 20)
                let t0 = DispatchTime.now().uptimeNanoseconds
                let ok = query(store)
                let t1 = DispatchTime.now().uptimeNanoseconds
                precondition(ok, label)
                ms.append(Double(t1 - t0) / 1e6)
            }
            lines.append(String(format: "%@: first %.3f ms, p50 %.3f ms, p95 %.3f ms (41 runs)",
                                label, ms[0], percentile(ms, 0.5), percentile(ms, 0.95)))
        }
        measure("py builtins") { $0.pythonModule("builtins") != nil }
        measure("py typing") { $0.pythonModule("typing") != nil }
        measure("py os") { $0.pythonModule("os") != nil }
        measure("ts Array") { $0.tsSymbol("Array") != nil }
        measure("ts HTMLElement") { $0.tsSymbol("HTMLElement") != nil }
        print("[T17.10] cold first query (debug build):\n  " + lines.joined(separator: "\n  "))
    }

    @Test func decodedMemory() {
        func run(_ label: String, _ work: (TypeTableStore) -> Void) {
            let store = TypeTableStore(cacheByteLimit: 64 << 20)
            let foot0 = physFootprint(), heap0 = mallocInUse()
            work(store)
            let foot1 = physFootprint(), heap1 = mallocInUse()
            let stats = store.statistics
            print("[T17.10] \(label): entries \(stats.cachedEntries), LRU estimate \(kb(stats.cachedBytes)), "
                  + "malloc in use +\(kb(heap1 - heap0)), phys_footprint +\(kb(foot1 - foot0))")
            withExtendedLifetime(store) {}
        }
        // phys_footprint moves in pages and freed heap is reused, so only the
        // first measurement of a process is meaningful; KARU_T1710_BENCH_TS_FIRST=1
        // measures the TypeScript set first.
        let python = ["builtins", "typing", "os", "pathlib", "collections", "re", "json"]
        let ts = { run("ts common set") { s in
            ["Array", "Promise", "Map", "document", "HTMLElement"].forEach { _ = s.tsSymbol($0) }
        } }
        let tsFirst = ProcessInfo.processInfo.environment["KARU_T1710_BENCH_TS_FIRST"] == "1"
        if tsFirst { ts() }
        run("python common set") { s in python.forEach { _ = s.pythonModule($0) } }
        if !tsFirst { ts() }
        for module in python {
            run("python \(module)") { _ = $0.pythonModule(module) }
        }
    }
}
