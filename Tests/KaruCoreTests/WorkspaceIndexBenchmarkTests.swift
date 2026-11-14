import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.12 — first full index and incremental latency of the project-folder
// index (plan §11 "索引"). Opt-in, run alone, ideally in release:
//
//     KARU_T1712_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter WorkspaceIndexBenchmark
//
// Trees: (a) a copy of a local CPython stdlib (`KARU_T1712_CPYTHON`, default the
// uv-managed 3.13), (b) a synthetic 5,000-file mixed-language tree. Reports
// wall / CPU time (process getrusage delta), files/s, database size on disk,
// phys_footprint paired delta after indexing and the peak sampled every 5 ms
// during it, the delta after turning the module off, and save → query latency
// over 20 trials. Everything lives in a temporary directory.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1712_BENCH"] == "1"

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

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

private func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
}

private func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

/// Samples phys_footprint every 5 ms on its own thread until stopped.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var peak = 0
    private let done = DispatchSemaphore(value: 0)

    init() {
        Thread.detachNewThread { [self] in
            while true {
                let value = physFootprint()
                lock.lock()
                peak = max(peak, value)
                let keepGoing = running
                lock.unlock()
                if !keepGoing { break }
                usleep(5_000)
            }
            done.signal()
        }
    }

    func stop() -> Int {
        lock.lock()
        running = false
        lock.unlock()
        done.wait()
        return peak
    }
}

@Suite("WorkspaceIndexBenchmark", .enabled(if: benchEnabled), .serialized)
struct WorkspaceIndexBenchmarkTests {
    private func run(_ label: String, populate: (URL) throws -> Void, touch: String) throws {
        let f = IndexFixture()
        try populate(f.folder)
        let index = f.makeIndex(latency: 0.3)
        index.start()
        // Let allocator state settle before the paired reading.
        usleep(200_000)
        let footCold = physFootprint()
        // One-time process state the editor pays as soon as it scans a file of
        // each language or opens any database (lexical tables, SQLite): a tiny
        // warm-up index in another folder, then removed.
        let warm = IndexFixture()
        for ext in ["py", "ts", "js", "swift", "go", "rs", "java", "c", "cpp", "cs"] {
            warm.write("w.\(ext)", "x = 1\n")
        }
        let warmIndex = warm.makeIndex()
        warmIndex.start()
        warmIndex.addFolder(warm.folder)
        #expect(warmIndex.waitUntilIdle())
        warm.modules.setEnabled(false, for: .crossFileIndex)
        #expect(warmIndex.waitUntilIdle())
        usleep(200_000)
        let foot0 = physFootprint()
        let cpu0 = cpuSeconds()
        let sampler = PeakSampler()
        let t0 = Date()
        index.addFolder(f.folder)
        while !index.isIdle { usleep(20_000) }
        #expect(index.waitUntilIdle(timeout: 600))
        let wall = Date().timeIntervalSince(t0)
        let cpu = cpuSeconds() - cpu0
        let peak = sampler.stop()
        usleep(500_000)
        let foot1 = physFootprint()
        malloc_zone_pressure_relief(nil, 0)
        let foot1Relieved = physFootprint()
        let status = try #require(index.statuses().first)

        // Incremental: rewrite one file, poll the query.
        let file = f.folder.appendingPathComponent(touch)
        let original = try String(contentsOf: file, encoding: .utf8)
        var latencies: [Double] = []
        for trial in 0..<20 {
            let name = "bench_fn_\(trial)_\(UUID().uuidString.prefix(8).lowercased())"
            try (original + "\ndef \(name)(): pass\n").write(to: file, atomically: false, encoding: .utf8)
            let start = Date()
            while index.symbols(named: name, inFolder: f.path).isEmpty, Date().timeIntervalSince(start) < 5 {
                usleep(5_000)
            }
            latencies.append(Date().timeIntervalSince(start))
        }
        latencies.sort()

        f.modules.setEnabled(false, for: .crossFileIndex)
        #expect(index.waitUntilIdle())
        usleep(300_000)
        let foot2 = physFootprint()

        print("""
            [T17.12] \(label) (load avg \(loadAverage()))
              files indexed \(status.indexedFiles) (state \(status.state.rawValue)), writes \(index.writeCount)
              first full index: wall \(String(format: "%.2f", wall)) s, CPU \(String(format: "%.2f", cpu)) s, \
            \(String(format: "%.0f", Double(status.indexedFiles) / wall)) files/s
              database on disk \(mb(Int(status.diskBytes)))
              phys_footprint: one-time warm-up +\(mb(foot0 - footCold)); then after indexing +\(mb(foot1 - foot0)) \
            (after malloc pressure relief +\(mb(foot1Relieved - foot0))), peak during +\(mb(peak - foot0)), \
            after module off +\(mb(foot2 - foot0))
              save → query latency (20 trials): p50 \(String(format: "%.0f", latencies[10] * 1000)) ms, \
            max \(String(format: "%.0f", latencies.last! * 1000)) ms
            """)
        #expect(latencies.last! <= 1.0)
        #expect(status.diskBytes < 200 * 1_048_576)
    }

    @Test func cpythonStdlib() throws {
        let source = ProcessInfo.processInfo.environment["KARU_T1712_CPYTHON"]
            ?? NSHomeDirectory() + "/.local/share/uv/python/cpython-3.13-macos-aarch64-none/lib/python3.13"
        guard FileManager.default.fileExists(atPath: source) else {
            print("[T17.12] CPython stdlib not found at \(source); skipped")
            return
        }
        try run("CPython 3.13 stdlib copy", populate: { folder in
            let target = folder.appendingPathComponent("python3.13")
            try FileManager.default.copyItem(atPath: source, toPath: target.path)
        }, touch: "python3.13/json/decoder.py")
    }

    @Test func synthetic5000() throws {
        try run("synthetic 5,000 files", populate: { folder in
            try Self.writeSynthetic(into: folder, files: 5_000)
        }, touch: "pkg000/mod000.py")
    }

    /// 5,000 files over 50 packages, ten languages round-robin, ~120 lines
    /// each, distinct names per file.
    static func writeSynthetic(into folder: URL, files: Int) throws {
        let extensions = ["py", "ts", "js", "swift", "go", "rs", "java", "c", "cpp", "cs"]
        for i in 0..<files {
            let package = String(format: "pkg%03d", i / 100)
            let ext = i % 10 == 0 ? "py" : extensions[i % extensions.count]
            let name = String(format: "mod%03d", i % 100)
            let directory = folder.appendingPathComponent(package)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var text = ""
            for k in 0..<12 {
                let id = "f\(i)_\(k)"
                switch ext {
                case "py":
                    text += "class Model\(id):\n    def __init__(self, value_\(k), extra):\n        self.value = value_\(k)\n"
                    text += "    def compute_\(id)(self, x, y):\n        total = x + y\n        return total\n\n"
                    text += "def helper_\(id)(a, b=1):\n    result = a * b\n    return result\n\nCONSTANT_\(id) = \(k)\n"
                case "ts", "js":
                    let annotation = ext == "ts" ? ": number" : ""
                    text += "export class Widget\(id) {\n  size\(annotation) = 1\n  render_\(id)(x\(annotation), y\(annotation)) { const t = x + y; return t }\n}\n"
                    text += "export function build_\(id)(opts\(annotation)) { let z = opts; return z }\n"
                    text += "export const value_\(id) = \(k)\n"
                case "swift":
                    text += "struct Item\(id) {\n    var count: Int\n    func scaled_\(id)(by factor: Int) -> Int { let r = count * factor; return r }\n}\n"
                    text += "func make_\(id)(_ n: Int) -> Item\(id) { Item\(id)(count: n) }\nlet shared_\(id) = 1\n"
                case "go":
                    if k == 0 { text += "package \(package)\n\n" }
                    text += "type Server\(id) struct {\n\tAddr string\n}\n\nfunc (s *Server\(id)) Start_\(id)(port int) error {\n\tx := port\n\t_ = x\n\treturn nil\n}\n\n"
                    text += "func New_\(id)(addr string) *Server\(id) { return nil }\n\nvar Default_\(id) = 1\n"
                case "rs":
                    text += "pub struct Config\(id) { pub name: String }\nimpl Config\(id) { pub fn new_\(id)(name: String) -> Self { Config\(id) { name } } }\n"
                    text += "pub fn run_\(id)(cfg: &Config\(id)) { let c = 1; }\n"
                case "java":
                    text += "class Service\(id) { private int count; public void handle_\(id)(int n) { int k = n; } }\n"
                case "c":
                    text += "struct point\(id) { int x; int y; };\nstatic int counter_\(id) = 0;\nint add_\(id)(int a, int b) { int s = a + b; return s; }\n"
                case "cpp":
                    text += "namespace ns\(id) { class Shape { public: double area_\(id)() const; int sides; }; }\ndouble total_\(id)(double a, double b) { return a + b; }\n"
                default:
                    text += "namespace App\(id) { public class Program { public int Count { get; set; } public void Run_\(id)(string arg) { var x = 1; } } }\n"
                }
            }
            try Data(text.utf8).write(to: directory.appendingPathComponent("\(name).\(ext)"))
        }
    }
}
