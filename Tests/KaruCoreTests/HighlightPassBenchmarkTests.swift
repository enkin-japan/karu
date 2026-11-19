import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.7 — highlight pass timings on ~10 MB JavaScript and Python
// documents (debug build, main-thread wall clock). Opt-in:
//
//     KARU_T177_BENCH=1 swift test --filter HighlightPassBenchmark
//
// - "first jump": a fresh engine (declarations already scanned) scrolls to
//   90 % of the document and paints once — the lexical state is advanced from
//   offset 0 through new checkpoints.
// - "nearby repaint": afterwards, repaint passes (`appearanceDidChange`) at
//   small scroll offsets around that position; median / p95 / max.
// Prints a report; asserts only that something was painted.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T177_BENCH"] == "1"

@Suite("HighlightPassBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct HighlightPassBenchmarkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The mem-benchmark `large.py` block, repeated to 10 MiB.
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
        let out = String(repeating: block, count: target / block.utf8.count + 1)
        return String(out.utf8.prefix(target))!
    }

    /// The scope and highlight JS fixtures, repeated to ~10 MB.
    private static func largeJavaScript() throws -> String {
        let fixtures = root.appendingPathComponent("Tests/Fixtures/M17")
        var block = try String(contentsOf: fixtures.appendingPathComponent("completion/scope/js_scope.js"),
                               encoding: .utf8)
        block += "\n" + (try String(contentsOf: fixtures.appendingPathComponent("highlight/javascript.js"),
                                    encoding: .utf8))
        block = block.replacingOccurrences(of: "\u{27E8}\\d+\u{27E9}", with: "", options: .regularExpression)
        return String(repeating: block + "\n", count: (10 * 1024 * 1024) / block.utf8.count + 1)
    }

    private static func defaults() -> UserDefaults {
        let name = "HighlightPassBenchmark-\(UUID().uuidString)"
        let d = TestDefaults.make(name)
        d.removePersistentDomain(forName: name)
        return d
    }

    private static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    private func measure(_ label: String, text: String, language: String) -> String {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let scrollView = NSScrollView(frame: frame)
        let textView = EditorTextView(frame: frame)
        textView.isVerticallyResizable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainer?.containerSize = NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        textView.string = text
        let center = NotificationCenter()
        let engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: Self.defaults(), center: center),
                                     moduleCenter: center)
        let clock = ContinuousClock()
        let scan = clock.measure { engine.setLanguage(identifier: language) }
        let length = (text as NSString).length
        let target = length / 10 * 9
        textView.scrollRangeToVisible(NSRange(location: target, length: 0))
        let jump = clock.measure { engine.appearanceDidChange() }
        let painted = engine.paintedRange?.length ?? 0

        var nearby: [Double] = []
        let step = 2_000
        for i in 0..<40 {
            let offset = min(length - 1, target + (i % 2 == 0 ? 1 : -1) * (i / 2) * step)
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            nearby.append(Self.ms(clock.measure { engine.appearanceDidChange() }))
        }
        nearby.sort()
        let median = nearby[nearby.count / 2]
        var phases = ""
        if ProcessInfo.processInfo.environment["KARU_T177_PHASES"] == "1", let band = engine.paintedRange,
           let language = LanguageRegistry.definition(forIdentifier: language) {
            let ns = textView.textStorage!.mutableString
            var checkpoints = engine.analysis.checkpoints
            var tokens: [(range: NSRange, kind: TokenKind)] = []
            let tTokens = clock.measure {
                for _ in 0..<10 {
                    tokens = HighlightEngine.bandTokens(in: ns, range: band, language: language,
                                                        checkpoints: &checkpoints)
                }
            }
            var identifiers: [(range: NSRange, kind: TokenKind)] = []
            let table = engine.analysis.declarations?.scan.table
            let tIdent = clock.measure {
                for _ in 0..<10 {
                    var copy = tokens
                    identifiers = HighlightEngine.identifierTokens(in: ns, range: band, tokens: &copy, roles: [],
                                                                   table: table, policy: language.identifierPolicy)
                }
            }
            phases = String(format: "  phases (band %d): rule tokens %.2f ms (%d), identifiers %.2f ms (%d)\n",
                            band.length, Self.ms(tTokens) / 10, tokens.count, Self.ms(tIdent) / 10, identifiers.count)
        }
        let p95 = nearby[Int(Double(nearby.count - 1) * 0.95)]
        #expect(painted > 0, "\(label): nothing painted")
        return String(format: "%@: %d units; setLanguage (sync scan) %.0f ms; first jump %.1f ms (painted %d); "
                      + "nearby repaint median %.2f / p95 %.2f / max %.2f ms\n",
                      label, length, Self.ms(scan), Self.ms(jump), painted, median, p95, nearby.last ?? 0) + phases
    }

    @Test func tenMegabyteJavaScriptAndPython() throws {
        var report = "## Highlight pass (debug, 800×600)\n"
        report += measure("10 MB JavaScript", text: try Self.largeJavaScript(), language: "javascript")
        report += measure("10 MB Python", text: Self.largePython(), language: "python")
        print(report)
        let out = Self.root.appendingPathComponent(".build/t177-bench.txt")
        try? report.write(to: out, atomically: true, encoding: .utf8)
    }
}
