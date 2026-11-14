import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.8a — highlight pass timings on ~10 MB documents with embedded
// languages (debug build, main-thread wall clock), next to 10 MB JavaScript
// and Python for comparison. Opt-in:
//
//     KARU_T178_BENCH=1 swift test --filter EmbeddedBenchmark
//
// - "first jump": a fresh engine scrolls to the middle of the document and
//   paints once — the lexical state is advanced from offset 0 through new
//   checkpoints.
// - "nearby repaint": afterwards, repaint passes (`appearanceDidChange`) at
//   small scroll offsets around that position; median / p95 / max.
// - checkpoints: entries, how many hold a frame / an embedded child state,
//   and the in-line size of an entry.
// Prints a report; asserts only that something was painted. Uses no T17.8a
// API, so it also runs against the previous scanner for A/B comparisons.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T178_BENCH"] == "1"

@Suite("EmbeddedBenchmark", .enabled(if: benchEnabled), .serialized)
@MainActor
struct EmbeddedBenchmarkTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let target = 10 * 1024 * 1024

    private static func repeated(_ block: String) -> String {
        let unit = block.hasSuffix("\n") ? block : block + "\n"
        return String(repeating: unit, count: target / unit.utf8.count + 1)
    }

    private static func fixture(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/M17/" + path), encoding: .utf8)
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

    private static func defaults() -> UserDefaults {
        let name = "EmbeddedBenchmark-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
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
        engine.setLanguage(identifier: language)
        let length = (text as NSString).length
        let middle = length / 2
        textView.scrollRangeToVisible(NSRange(location: middle, length: 0))
        let jump = clock.measure { engine.appearanceDidChange() }
        let painted = engine.paintedRange?.length ?? 0

        var nearby: [Double] = []
        let step = 2_000
        for i in 0..<40 {
            let offset = min(length - 1, middle + (i % 2 == 0 ? 1 : -1) * (i / 2) * step)
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            nearby.append(Self.ms(clock.measure { engine.appearanceDidChange() }))
        }
        nearby.sort()
        let median = nearby[nearby.count / 2]
        let p95 = nearby[Int(Double(nearby.count - 1) * 0.95)]

        // Checkpoints: entries holding a frame, and (T17.8a) a boxed child
        // state — read by reflection so this compiles against older scanners.
        let entries = engine.analysis.checkpoints.entries
        var withFrames = 0, withChild = 0, childFrames = 0
        for entry in entries {
            guard case .generic(let state) = entry.state else { continue }
            if !state.frames.isEmpty { withFrames += 1 }
            if let box = Mirror(reflecting: state).children.first(where: { $0.label == "box" })?.value,
               Mirror(reflecting: box).displayStyle == .optional,
               let boxed = Mirror(reflecting: box).children.first?.value {
                withChild += 1
                if let value = Mirror(reflecting: boxed).children.first(where: { $0.label == "value" })?.value,
                   let child = Mirror(reflecting: value).children.first(where: { $0.label == "state" })?.value
                    as? LexicalScanState {
                    childFrames += child.frames.count
                }
            }
        }
        #expect(painted > 0, "\(label): nothing painted")
        return String(format: "%@: %d units; first jump (middle) %.1f ms (painted %d); "
                      + "nearby repaint median %.2f / p95 %.2f / max %.2f ms; checkpoints %d (frames %d, child %d, "
                      + "child frames %d)\n",
                      label, length, Self.ms(jump), painted, median, p95, nearby.last ?? 0,
                      entries.count, withFrames, withChild, childFrames)
    }

    @Test func tenMegabyteEmbeddedDocuments() throws {
        var report = "## Embedded highlight pass (debug, 800×600)\n"
        report += String(format: "layout: LexicalScanState %d B, Frame stride %d B, LexicalState stride %d B, "
                         + "checkpoint entry stride %d B\n",
                         MemoryLayout<LexicalScanState>.size, MemoryLayout<LexicalScanState.Frame>.stride,
                         MemoryLayout<LexicalState>.stride, MemoryLayout<(offset: Int, state: LexicalState)>.stride)
        report += measure("10 MB HTML", text: Self.repeated(try Self.fixture("highlight/embedded/page.html")),
                          language: "html")
        report += measure("10 MB Markdown", text: Self.repeated(try Self.fixture("highlight/embedded/fences.md")),
                          language: "markdown")
        report += measure("10 MB JavaScript", text: try Self.largeJavaScript(), language: "javascript")
        report += measure("10 MB Python", text: Self.largePython(), language: "python")
        print(report)
        let out = Self.root.appendingPathComponent(".build/t178-bench.txt")
        try? report.write(to: out, atomically: true, encoding: .utf8)
    }
}
