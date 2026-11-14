import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.11a — parser timings and memory. Opt-in; run in Release:
//
//     KARU_PARSER_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter SyntaxParserBenchmark
//
// Report: `KARU_PARSER_BENCH_OUT` or `.build/m17-parser-bench.txt`.
// - 1000-line samples: full parse and keystroke update (median / p95);
//   retained tree bytes, malloc and phys_footprint deltas of holding it;
// - sliced builds as `DocumentAnalysis` runs them (`SyntaxAnalysis.stepUnits`
//   steps until a 4 ms deadline): slices, total, longest slice — for the
//   1000-line samples and a 10 MB Python / JS summary build, plus the
//   10 MB incremental summary update;
// - 10 MB: retained summary bytes, on-demand statement parse times;
// - a real `DocumentAnalysis` on the main run loop: its longest slice.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_PARSER_BENCH"] == "1"
private let benchRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }

private func percentile(_ values: [UInt64], _ p: Double) -> Double {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
    return ms(sorted[index])
}

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

/// Runs a build as `SyntaxAnalysis` does: steps until a 4 ms deadline per slice.
private func sliced(_ make: () -> SyntaxBuild, _ text: NSString) -> (slices: Int, total: Double, longest: Double, result: SyntaxContent?) {
    var build = make()
    var slices = 0
    var total: UInt64 = 0
    var longest: UInt64 = 0
    let budget = UInt64(AnalysisScheduler.sliceBudget * 1e9)
    var done = false
    while !done {
        let start = now()
        let deadline = start + budget
        repeat {
            done = build.step(text, budgetUnits: SyntaxAnalysis.stepUnits)
        } while !done && now() < deadline
        let elapsed = now() - start
        slices += 1
        total += elapsed
        longest = max(longest, elapsed)
    }
    return (slices, ms(total), ms(longest), build.result)
}

@MainActor
@Suite("Syntax parser benchmark", .serialized)
struct SyntaxParserBenchmarkTests {
    static func load(_ path: String) throws -> NSString {
        try String(contentsOf: benchRoot.appendingPathComponent(path), encoding: .utf8) as NSString
    }

    static func tenMegabytes(_ block: NSString) -> NSString {
        var out = ""
        let piece = (block as String) + "\n"
        while (out as NSString).length < 10 << 20 { out += piece }
        return out as NSString
    }

    @Test(.enabled(if: benchEnabled)) func benchmark() async throws {
        var lines: [String] = []
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        lines.append(String(format: "load average %.2f %.2f %.2f; %@", load[0], load[1], load[2],
                            ProcessInfo.processInfo.operatingSystemVersionString))
        var rng = SystemRandomNumberGenerator()

        let samples: [(String, String, SyntaxDialect)] = [
            ("sample_1000.py", "Tests/Fixtures/M17/inference/sample_1000.py", .python),
            ("sample_1000.ts", "Tests/Fixtures/M17/inference/sample_1000.ts", .typescript),
        ]
        for (name, path, dialect) in samples {
            let text = try Self.load(path)
            // Warm up.
            _ = SyntaxBuild.parse(text, dialect: dialect)
            var full: [UInt64] = []
            for _ in 0..<50 {
                let start = now()
                _ = SyntaxBuild.parse(text, dialect: dialect)
                full.append(now() - start)
            }
            let tree = SyntaxBuild.parse(text, dialect: dialect)
            // Keystroke: one character typed at a random line start + 4 in the
            // middle half, incremental update of the previous tree.
            var updates: [UInt64] = []
            var reparsed: [Int] = []
            for _ in 0..<200 {
                var at = Int.random(in: text.length / 4..<(3 * text.length / 4), using: &rng)
                at = text.lineRange(for: NSRange(location: at, length: 0)).location
                at = min(text.length, at + 4)
                let edited = text.replacingCharacters(in: NSRange(location: at, length: 0), with: ".") as NSString
                let start = now()
                var build = SyntaxBuild(updating: .tree(tree), edit: SyntaxEdit(start: at, oldLength: 0, newLength: 1),
                                        text: edited)
                _ = build.finish(edited)
                updates.append(now() - start)
                reparsed.append(build.reparsedStatements)
            }
            lines.append(String(format: "%@ (%d units, %d nodes, %d statements): full parse median %.3f ms p95 %.3f ms; keystroke update median %.4f ms p95 %.4f ms (reparsed statements median %d)",
                                name, text.length, tree.nodes.count, tree.topLevelStatements.count,
                                percentile(full, 0.5), percentile(full, 0.95),
                                percentile(updates, 0.5), percentile(updates, 0.95),
                                reparsed.sorted()[reparsed.count / 2]))
            let s = sliced({ SyntaxBuild(dialect: dialect, text: text) }, text)
            lines.append(String(format: "  sliced build: %d slices, total %.3f ms, longest slice %.3f ms", s.slices, s.total, s.longest))
            // Memory of holding the tree (paired: before / after, held).
            let m0 = mallocInUse(), f0 = footprint()
            var held: SyntaxTree? = SyntaxBuild.parse(text, dialect: dialect)
            let m1 = mallocInUse(), f1 = footprint()
            lines.append(String(format: "  retained tree %d bytes (%.2f MB); malloc delta %.2f MB, phys_footprint delta %.2f MB",
                                held!.retainedBytes, Double(held!.retainedBytes) / 1e6,
                                Double(m1 - m0) / 1e6, Double(f1 - f0) / 1e6))
            held = nil
            _ = held
        }

        // 10 MB documents: summary build, incremental update, on-demand statements.
        let tenMB: [(String, String, SyntaxDialect)] = [
            ("10 MB Python", "Tests/Fixtures/M17/inference/sample_1000.py", .python),
            ("10 MB JavaScript", "Tests/Fixtures/M17/parser-corpus/javascript-grammar.js", .javascript),
            ("10 MB TypeScript", "Tests/Fixtures/M17/inference/sample_1000.ts", .typescript),
        ]
        for (name, path, dialect) in tenMB {
            let text = Self.tenMegabytes(try Self.load(path))
            let m0 = mallocInUse(), f0 = footprint()
            let s = sliced({ SyntaxBuild(dialect: dialect, text: text) }, text)
            let summary = s.result!.summary!
            let m1 = mallocInUse(), f1 = footprint()
            lines.append(String(format: "%@ (%d units): summary build %d slices, total %.1f ms, longest slice %.3f ms; %d statements, summary %d bytes (%.2f MB); malloc delta %.2f MB, footprint delta %.2f MB; LRU cap %.1f MB",
                                name, text.length, s.slices, s.total, s.longest, summary.statements.count,
                                summary.retainedBytes, Double(summary.retainedBytes) / 1e6,
                                Double(m1 - m0) / 1e6, Double(f1 - f0) / 1e6,
                                Double(SyntaxSubtreeCache.defaultByteLimit) / 1e6))
            lines.append(String(format: "  summary arrays: %d entries × %d B (capacity %d), %d name offsets (capacity %d), %d sync starts (capacity %d)",
                                summary.statements.count, MemoryLayout<ModuleSummary.Statement>.stride,
                                summary.statements.capacity, summary.nameRanges.count, summary.nameRanges.capacity,
                                summary.syncStarts.count, summary.syncStarts.capacity))
            // Incremental summary update after a keystroke in the middle.
            let at = text.lineRange(for: NSRange(location: text.length / 2, length: 0)).location + 4
            let edited = text.replacingCharacters(in: NSRange(location: at, length: 0), with: ".") as NSString
            let u = sliced({ SyntaxBuild(updating: .summary(summary), edit: SyntaxEdit(start: at, oldLength: 0, newLength: 1),
                                         text: edited) }, edited)
            lines.append(String(format: "  keystroke summary update: %d slices, total %.3f ms, longest slice %.3f ms", u.slices, u.total, u.longest))
            // On-demand statement parses.
            var parses: [UInt64] = []
            var largest = 0
            for _ in 0..<200 {
                let k = Int.random(in: 0..<summary.statements.count, using: &rng)
                let start = now()
                let tree = summary.parseStatement(k, in: text)
                parses.append(now() - start)
                largest = max(largest, tree.retainedBytes)
            }
            lines.append(String(format: "  on-demand statement parse median %.4f ms p95 %.4f ms max %.4f ms (largest subtree %d bytes)",
                                percentile(parses, 0.5), percentile(parses, 0.95), percentile(parses, 1.0), largest))
        }

        // A real DocumentAnalysis on the main run loop.
        for (name, path, language, repeats) in [("sample_1000.py", "Tests/Fixtures/M17/inference/sample_1000.py", "python", 1),
                                                ("10 MB Python", "Tests/Fixtures/M17/inference/sample_1000.py", "python", 0)] {
            let block = try Self.load(path)
            let text = repeats == 1 ? block : Self.tenMegabytes(block)
            let settings = ModuleSettings(defaults: UserDefaults(suiteName: "SyntaxBench-\(UUID())")!, center: NotificationCenter())
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let hub = TextStorageObserverHub()
            textView.textStorage?.delegate = hub
            let analysis = DocumentAnalysis(textView: textView, moduleSettings: settings,
                                            moduleCenter: NotificationCenter(), scheduler: AnalysisScheduler())
            hub.add(analysis)
            textView.string = text as String
            analysis.setLanguage(identifier: language)
            let deadline = Date().addingTimeInterval(60)
            while analysis.syntax == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
            let stats = analysis.syntaxAnalysis.lastBuildStats
            lines.append(String(format: "DocumentAnalysis %@: %d slices, total %.1f ms, longest slice %.3f ms; analysis-owned syntax bytes %d (%.2f MB)",
                                name, stats.slices, ms(stats.totalNanoseconds), ms(stats.longestSliceNanoseconds),
                                analysis.syntaxRetainedBytes, Double(analysis.syntaxRetainedBytes) / 1e6))
            // Keystroke in the middle: incremental rebuild through the scheduler.
            let at = (text as NSString).lineRange(for: NSRange(location: text.length / 2, length: 0)).location + 4
            textView.textStorage!.replaceCharacters(in: NSRange(location: at, length: 0), with: ".")
            while analysis.syntax == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
            let after = analysis.syntaxAnalysis.lastBuildStats
            // On-demand statement through the analysis (summary mode: LRU).
            let q0 = now()
            _ = analysis.syntaxStatement(at: at)
            let q1 = now()
            lines.append(String(format: "  after a keystroke: incremental %@, %d slices, total %.3f ms, longest slice %.3f ms; syntaxStatement(at:) %.3f ms; LRU %d bytes",
                                after.incremental ? "yes" : "no", after.slices, ms(after.totalNanoseconds),
                                ms(after.longestSliceNanoseconds), ms(q1 - q0), analysis.syntaxAnalysis.cache.bytes))
            analysis.cancelPendingWork()
        }

        let report = lines.joined(separator: "\n") + "\n"
        let out = ProcessInfo.processInfo.environment["KARU_PARSER_BENCH_OUT"]
            ?? benchRoot.appendingPathComponent(".build/m17-parser-bench.txt").path
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print(report)
    }
}
