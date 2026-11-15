import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.16 — import-statement completion against plan §11 「按键提交到首批
// 候选可见 p95 ≤ 50 ms」: the main-thread time of a keystroke at an import
// position with warm listings, the queue time of the first (cold) listings,
// and the bytes the listings add to the import-summary LRU. A synthetic
// project: a venv with 2,000 packages, `node_modules` with 1,500 packages
// (300 of them scoped), a source directory with 400 files. Opt-in, run alone,
// ideally in release:
//
//     KARU_TYPE_TABLES=$PWD/assets/typetables KARU_T1716_BENCH=1 \
//       swift test -c release -Xswiftc -enable-testing --filter ImportCompletionBenchmark
//
// The report goes to `.build/m17-baseline/t1716-bench-<config>.txt`.

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1716_BENCH"] == "1"

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
}

private func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

@MainActor
@Suite("T17.16 import completion benchmark", .enabled(if: benchEnabled))
struct ImportCompletionBenchmarkTests {
    @Test func keystrokeAndListingCost() throws {
        #if DEBUG
        let config = "debug"
        #else
        let config = "release"
        #endif
        var lines: [String] = ["T17.16 import completion benchmark (\(config))"]
        func log(_ line: String) { lines.append(line); print(line) }

        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KaruT1716Bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        func write(_ relative: String, _ text: String = "\n") {
            let url = base.appendingPathComponent(relative)
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(text.utf8).write(to: url)
        }
        let site = ".venv/lib/python3.13/site-packages/"
        write(".venv/pyvenv.cfg", "home = /usr/bin\nversion_info = 3.13\n")
        for i in 0..<2_000 { write(site + "pkg\(i)_mod/__init__.py", "x = 1\n") }
        for i in 0..<1_200 { write("node_modules/lib\(i)-core/index.d.ts", "export declare const v: number;\n") }
        for i in 0..<300 { write("node_modules/@scope\(i % 10)/p\(i)/index.d.ts", "export declare const v: number;\n") }
        for i in 0..<400 { write("src/file\(i)_view.ts", "export const v = 1;\n") }
        write("app/main.py")
        let root = SystemImportFileSystem().realPath(base.path)

        let h = ImportHarness(projectRoot: root, interpreter: nil)
        let doc = root + "/app/main.py"
        let window = BenchWindow(h, path: doc, language: "python")
        defer { window.close() }

        // Cold: the first answer at each position (venv probe, listing on the queue).
        for (label, text) in [("python top", "import pk"), ("python package", "import xml.etree."),
                              ("python from-import", "from os import pa")] {
            window.set(text)
            let start = DispatchTime.now().uptimeNanoseconds
            window.request()
            var rounds = 0
            while h.service.waitForImports(), rounds < 8 { rounds += 1 }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            log("cold \(label): \(ms(elapsed)) ms to settled answer, \(window.count) candidates")
        }
        let scriptWindow = BenchWindow(h, path: root + "/src/main.ts", language: "typescript")
        defer { scriptWindow.close() }
        for (label, text) in [("node_modules", "import x from 'li"), ("relative", "import x from './fi")] {
            scriptWindow.set(text)
            let start = DispatchTime.now().uptimeNanoseconds
            scriptWindow.request()
            var rounds = 0
            while h.service.waitForImports(), rounds < 8 { rounds += 1 }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            log("cold \(label): \(ms(elapsed)) ms to settled answer, \(scriptWindow.count) candidates")
        }
        log("listing bytes in the summary LRU: \(h.service.retainedBytes / 1024) KB (\(h.service.cacheForTesting.count) entries)")

        // Warm: a keystroke's main-thread time from insertion to the refreshed popup.
        var shown = 0
        func keystrokes(_ w: BenchWindow, _ texts: [String]) -> [Double] {
            var samples: [Double] = []
            shown = 0
            // Warm-up: every listing / summary these texts need arrives first.
            for text in texts {
                w.set(String(text.dropLast()))
                w.type(String(text.last!))
                while h.service.waitForImports() {}
            }
            for _ in 0..<5 {
                for text in texts {
                    w.set(String(text.dropLast()))
                    let start = DispatchTime.now().uptimeNanoseconds
                    w.type(String(text.last!))
                    samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
                    if w.count > 0 { shown += 1 }
                }
            }
            return samples
        }
        // Every text ends with a trigger (a letter or `.` / `/`; digits do not open a popup).
        let python = keystrokes(window, ["import pk", "import ti", "import os.pa", "import xml.",
                                         "from os import pa", "from time import sl", "import xml.etree.",
                                         "import co", "import as", "import pkg1_m"] + (0..<30).map { "import pkg\($0)_m" })
        log("warm python keystroke: p50 \(ms(percentile(python, 0.5))) ms, p95 \(ms(percentile(python, 0.95))) ms, "
            + "max \(ms(python.max() ?? 0)) ms (n=\(python.count), popup shown \(shown))")
        let script = keystrokes(scriptWindow, ["import x from 'li", "import x from 'lib1-c", "import x from '@scope1/",
                                               "import x from './fi", "import x from './file1_v",
                                               "import { v } from './"] + (0..<30).map { "import x from 'lib\($0)-c" })
        log("warm js/ts keystroke: p50 \(ms(percentile(script, 0.5))) ms, p95 \(ms(percentile(script, 0.95))) ms, "
            + "max \(ms(script.max() ?? 0)) ms (n=\(script.count), popup shown \(shown))")

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/m17-baseline")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("t1716-bench-\(config).txt"),
                                                          atomically: true, encoding: .utf8)
        #expect(percentile(python, 0.95) < 0.05 && percentile(script, 0.95) < 0.05)
    }
}

/// A completion controller in a window (benchmark).
@MainActor
private final class BenchWindow {
    let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window: NSWindow
    let hub = TextStorageObserverHub()
    let controller: CompletionController

    init(_ h: ImportHarness, path: String, language: String) {
        let scroll = NSScrollView(frame: textView.frame)
        scroll.documentView = textView
        window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        textView.isRichText = false
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: h.modules, moduleCenter: h.center,
                                          scheduler: AnalysisScheduler(), importService: h.service)
        controller.documentURLProvider = { URL(fileURLWithPath: path) }
        hub.add(controller)
        textView.completionKeyHandler = controller
        controller.setLanguage(identifier: language)
        controller.indexDocument()
        window.makeFirstResponder(textView)
    }

    func set(_ text: String) {
        controller.dismissCompletion()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    func request() { controller.requestCompletion(manual: false) }

    func type(_ key: String) {
        textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textViewDidInsertKey(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: 0)!)
    }

    var count: Int { controller.currentCandidatesForTesting.count }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
    }
}
