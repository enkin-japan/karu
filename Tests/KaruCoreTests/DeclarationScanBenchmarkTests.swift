import Foundation
import Testing
@testable import KaruCore

// M17 T17.4a — size and slicing measurements of the declaration scan on the
// 10 MB Python document of `scripts/mem-benchmark.sh` and a 10 MB JS
// document; T17.4b adds ~10 MB C, Java and Swift documents built by
// repeating the M17 fixtures. Opt-in (`KARU_DECL_BENCH=1 swift test --filter
// DeclarationScanBenchmark`); prints a report, asserts only sanity.
// Debug-build timings. The "legacy regex scan" row is the T17.1 regex pass
// (what these languages ran before their walkers).

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_DECL_BENCH"] == "1"

@Suite("DeclarationScanBenchmark", .enabled(if: benchEnabled), .serialized)
struct DeclarationScanBenchmarkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The mem-benchmark `large.py`: `yes "$py_block" | head -c 10 MiB`
    /// (the command substitution drops the heredoc's trailing blank line).
    private static func largePython() -> String {
        let block = """
        def sample_function(a, b, c):
            \"\"\"Auto-generated function for Karu memory benchmark.\"\"\"
            result = a + b + c
            for i in range(10):
                result += i
            return result
        """ + "\n"
        let target = 10 * 1024 * 1024
        var out = String(repeating: block, count: target / block.utf8.count + 1)
        out = String(out.utf8.prefix(target))!
        return out
    }

    private static func largeJavaScript() throws -> String {
        let fixtures = root.appendingPathComponent("Tests/Fixtures/M17")
        var block = try String(contentsOf: fixtures.appendingPathComponent("completion/scope/js_scope.js"),
                               encoding: .utf8)
        block += "\n" + (try String(contentsOf: fixtures.appendingPathComponent("highlight/javascript.js"),
                                    encoding: .utf8))
        block = block.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
        return String(repeating: block + "\n", count: (10 * 1024 * 1024) / block.utf8.count + 1)
    }

    /// ~10 MB of the language's M17 fixtures, repeated.
    private static func repeatedFixtures(_ paths: [String]) throws -> String {
        let fixtures = root.appendingPathComponent("Tests/Fixtures/M17")
        var block = ""
        for path in paths {
            block += try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8) + "\n"
        }
        block = block.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
        return String(repeating: block, count: (10 * 1024 * 1024) / block.utf8.count + 1)
    }

    private static func setBytes(_ set: Set<String>) -> Int {
        // Element storage (16-byte String + heap payload beyond 15 UTF-8 bytes)
        // at a ~75% load factor.
        set.reduce(0) { $0 + 16 + ($1.utf8.count > 15 ? $1.utf8.count + 32 : 0) } * 4 / 3
    }

    private static func bytes(_ scan: DeclarationScan) -> (total: Int, names: Int, decls: Int, outline: Int) {
        let storage = scan.compactStorageBytes
        let sets = setBytes(scan.table.functions) + setBytes(scan.table.types) + setBytes(scan.table.variables)
            + setBytes(scan.completionSymbols)
        return (storage.names + storage.declarations + storage.outline + sets,
                storage.names, storage.declarations, storage.outline)
    }

    /// The `DocumentAnalysis` slice loop: steps of `declarationStepUnits`
    /// until a 4 ms deadline per slice.
    private static func slices(_ text: String, _ language: String) -> (total: Double, longest: Double, count: Int) {
        let ns = text as NSString
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

    @Test func report() throws {
        var lines: [String] = []
        let only = ProcessInfo.processInfo.environment["KARU_DECL_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var documents: [(String, String, () throws -> String)] = [
            ("10 MB Python (mem-benchmark large.py)", "python", { Self.largePython() }),
            ("10 MB JavaScript", "javascript", { try Self.largeJavaScript() }),
            ("10 MB C (highlight/c.c + point.c)", "c",
             { try Self.repeatedFixtures(["highlight/c.c", "completion/explicit/point.c"]) }),
            ("10 MB Java (highlight/java.java + Invoice.java)", "java",
             { try Self.repeatedFixtures(["highlight/java.java", "completion/explicit/Invoice.java"]) }),
            ("10 MB Swift (highlight/swift.swift + account.swift)", "swift",
             { try Self.repeatedFixtures(["highlight/swift.swift", "completion/explicit/account.swift"]) }),
            // T17.8b: JSX reaches the walker as literals and interpolations.
            ("10 MB TSX (highlight/embedded/component.tsx)", "typescriptreact",
             { try Self.repeatedFixtures(["highlight/embedded/component.tsx"]) }),
        ]
        if let only { documents = documents.filter { only.contains($0.1) } }
        for (label, language, make) in documents {
            let text = try make()
            let ns = text as NSString
            let legacy = DeclarationScan.regexScan(ns, languageIdentifier: language)
            let start = Date()
            let scan = DeclarationScan.scan(text: text, languageIdentifier: language)
            let oneShot = Date().timeIntervalSince(start) * 1000
            let sliced = Self.slices(text, language)
            let new = Self.bytes(scan)
            let old = Self.bytes(legacy)
            lines.append("\(label): \(ns.length) units")
            lines.append("  legacy regex scan: \(old.total) B (names \(old.names), decls \(old.decls) B, \(legacy.locationCount) locations)")
            lines.append("  walker scan:       \(new.total) B (names \(new.names), decls \(new.decls) B, outline \(new.outline) B for \(scan.scopeCount) scopes, \(scan.declarations.count) declarations, \(scan.locationCount) listed locations)")
            lines.append("  growth: \(new.total - old.total) B")
            lines.append(String(format: "  one-shot %.0f ms; sliced: %d slices, total %.0f ms, longest slice %.2f ms",
                                oneShot, sliced.count, sliced.total, sliced.longest))
            #expect(scan.scopeCount > 1000)
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["KARU_DECL_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
