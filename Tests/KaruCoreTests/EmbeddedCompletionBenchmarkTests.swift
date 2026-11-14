import Foundation
import Testing
@testable import KaruCore

// M17 T17.8c — declaration scans and hot completion queries on ~10 MB
// documents with embedded languages (debug build, main-thread wall clock),
// next to 10 MB JavaScript and Python. Opt-in:
//
//     KARU_T178C_BENCH=1 swift test --filter EmbeddedCompletionBenchmark
//
// - Declaration scan: one shot, and the `DocumentAnalysis` slice loop
//   (steps of `declarationStepUnits` until a `sliceBudget` deadline): total,
//   slice count, longest slice; the snapshot's retained bytes (names,
//   streams, table sets).
// - Hot query: `CandidateEngine.complete` at a caret inside a `<script>` /
//   a python fence in the middle of the document (cold, then 40 hot runs).
// - Child vocabularies: the bytes of the keyword / builtin lists the engine
//   caches per child language.
// Prints a report (and writes it to `KARU_T178C_BENCH_OUT` when set); asserts
// only sanity. Uses no T17.8c API, so it also runs on the previous tree.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T178C_BENCH"] == "1"

@Suite("EmbeddedCompletionBenchmark", .enabled(if: benchEnabled), .serialized)
struct EmbeddedCompletionBenchmarkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let target = 10 * 1024 * 1024

    private static func fixture(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/M17/" + path), encoding: .utf8)
    }

    private static func repeated(_ block: String) -> String {
        let unit = block.hasSuffix("\n") ? block : block + "\n"
        return String(repeating: unit, count: target / unit.utf8.count + 1)
    }

    /// page.html repeated (each copy a whole page: two JS scripts, a style).
    private static func largeHTML() throws -> String { repeated(try fixture("highlight/embedded/page.html")) }

    /// fences.md repeated, its unterminated last fence closed in each copy.
    private static func largeMarkdown() throws -> String {
        repeated(try fixture("highlight/embedded/fences.md") + "\n```\n")
    }

    private static func largePython() -> String {
        repeated("""
        def sample_function(a, b, c):
            \"\"\"Auto-generated function for Karu memory benchmark.\"\"\"
            result = a + b + c
            for i in range(10):
                result += i
            return result
        """)
    }

    private static func largeJavaScript() throws -> String {
        var block = try fixture("completion/scope/js_scope.js")
        block += "\n" + (try fixture("highlight/javascript.js"))
        block = block.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
        return repeated(block)
    }

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private static func heapInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    private static func setBytes(_ set: Set<String>) -> Int {
        set.reduce(0) { $0 + 16 + ($1.utf8.count > 15 ? $1.utf8.count + 32 : 0) } * 4 / 3
    }

    private static func bytes(_ scan: DeclarationScan) -> (total: Int, names: Int, decls: Int, outline: Int) {
        let storage = scan.compactStorageBytes
        let sets = setBytes(scan.table.functions) + setBytes(scan.table.types) + setBytes(scan.table.variables)
            + setBytes(scan.completionSymbols)
        return (storage.names + storage.declarations + storage.outline + sets,
                storage.names, storage.declarations, storage.outline)
    }

    private static func slices(_ ns: NSString, _ language: String) -> (total: Double, longest: Double, count: Int) {
        var scanner = DeclarationScanner(languageIdentifier: language)
        var total: UInt64 = 0
        var longest: UInt64 = 0
        var count = 0
        var done = false
        while !done {
            let start = DispatchTime.now().uptimeNanoseconds
            let deadline = start + UInt64(AnalysisScheduler.sliceBudget * 1e9)
            repeat {
                done = scanner.step(ns, budgetUnits: DocumentAnalysis.declarationStepUnits)
            } while !done && DispatchTime.now().uptimeNanoseconds < deadline
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            total += elapsed
            longest = max(longest, elapsed)
            count += 1
        }
        return (Double(total) / 1e6, Double(longest) / 1e6, count)
    }

    private static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    /// Hot queries at the caret after `marker`'s occurrence nearest the
    /// middle, typing `prefixes` there.
    private static func hotQuery(_ text: String, language: String, marker: String, prefixes: [String],
                                 scan: DeclarationScan) -> [String] {
        let ns = text as NSString
        let middle = ns.length / 2
        let hit = ns.range(of: marker, options: .literal, range: NSRange(location: middle, length: ns.length - middle))
        precondition(hit.location != NSNotFound)
        let caret = NSMaxRange(hit)
        let def = LanguageRegistry.definition(forIdentifier: language)
        let scanner = CandidateEngine.contextScanner(for: language, definition: def)
        let words = WordIndex(text: text, languageIdentifier: language)
        let clock = ContinuousClock()
        var out: [String] = []
        var checkpoints = CheckpointStore()
        for prefix in prefixes {
            let live = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: prefix) as NSString
            var request = CompletionRequest(text: live, caret: caret + prefix.utf16.count,
                                            languageIdentifier: language)
            request.keywords = def?.keywords ?? []
            request.builtins = def?.builtins ?? []
            request.snapshot = scan
            request.snapshotVersion = 1
            request.snapshotJournal.record(editedRange: NSRange(location: caret, length: prefix.utf16.count),
                                           changeInLength: prefix.utf16.count)
            request.words = words
            request.scanner = scanner
            var engine = CandidateEngine()
            var result: CompletionResult?
            let cold = ms(clock.measure { result = engine.complete(request, checkpoints: &checkpoints) })
            var hot: [Double] = []
            for _ in 0..<40 {
                hot.append(ms(clock.measure { _ = engine.complete(request, checkpoints: &checkpoints) }))
            }
            let top = result?.candidates.prefix(5).map(\.name).joined(separator: ",") ?? "-"
            out.append(String(format: "  %@ (%@): cold %.2f ms, hot p50 %.2f / p95 %.2f / max %.2f ms; top %@",
                              prefix, result?.context.languageIdentifier ?? "nil", cold,
                              percentile(hot, 0.5), percentile(hot, 0.95), hot.max() ?? 0, top))
        }
        return out
    }

    @Test func report() throws {
        var lines: [String] = []
        let documents: [(String, String, () throws -> String)] = [
            ("10 MB HTML (embedded/page.html)", "html", { try Self.largeHTML() }),
            ("10 MB Markdown (embedded/fences.md, closed)", "markdown", { try Self.largeMarkdown() }),
            ("10 MB JavaScript", "javascript", { try Self.largeJavaScript() }),
            ("10 MB Python (mem-benchmark block)", "python", { Self.largePython() }),
        ]
        let only = ProcessInfo.processInfo.environment["KARU_T178C_BENCH_ONLY"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        for (label, language, make) in documents where only?.contains(language) ?? true {
            let text = try make()
            let ns = text as NSString
            let clock = ContinuousClock()
            var scan: DeclarationScan!
            var heap = Self.heapInUse()
            let oneShot = Self.ms(clock.measure { scan = DeclarationScan.scan(text: text, languageIdentifier: language) })
            let scanHeap = Self.heapInUse() - heap
            let sliced = Self.slices(ns, language)
            let size = Self.bytes(scan)
            heap = Self.heapInUse()
            var index: DeclarationQueryIndex!
            let indexTime = Self.ms(clock.measure { index = DeclarationQueryIndex(scan: scan) })
            let indexHeap = Self.heapInUse() - heap
            lines.append("\(label): \(ns.length) units")
            lines.append("  snapshot: \(size.total) B (names \(size.names), decls \(size.decls), outline \(size.outline)); "
                         + "heap Δ \(scanHeap / 1024) KB; \(scan.scopeCount) scopes, \(scan.declarations.count) "
                         + "declarations, \(scan.locationCount) listed")
            lines.append(String(format: "  query index: build %.1f ms, heap Δ %d KB, module bindings %d",
                                indexTime, indexHeap / 1024, index.moduleBindingCount))
            lines.append(String(format: "  scan one-shot %.0f ms; sliced %d slices, total %.0f ms, longest %.2f ms",
                                oneShot, sliced.count, sliced.total, sliced.longest))
            switch language {
            case "html":
                lines += Self.hotQuery(text, language: language,
                                       marker: "app.innerHTML = html; ", prefixes: ["co", "re", "to", "zq"], scan: scan)
            case "markdown":
                lines += Self.hotQuery(text, language: language, marker: "def total(prices: list[float]) -> float:\n",
                                       prefixes: ["    re", "    pr", "    zq"], scan: scan)
            default:
                break
            }
        }
        // The child vocabularies the engine caches (keyword + builtin lists).
        for language in ["javascript", "python", "css"] {
            let def = LanguageRegistry.definition(forIdentifier: language)
            let words = (def?.keywords ?? []) + (def?.builtins ?? [])
            let bytes = words.reduce(32) { $0 + 16 + ($1.utf8.count > 15 ? $1.utf8.count + 32 : 0) }
            lines.append("vocabulary \(language): \(words.count) words, ~\(bytes) B")
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["KARU_T178C_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(!lines.isEmpty)
    }
}
