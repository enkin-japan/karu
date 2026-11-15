import AppKit
import Darwin
import Foundation
import Testing
@testable import KaruCore

// M17 T17.14 — cross-file latency, memory and index cost (plan §11). Opt-in,
// run alone, ideally in release:
//
//     KARU_T1714_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter CrossFileBenchmark
//
// On T17.12's synthetic 5,000-file tree: first index time and database size
// without and with the signature summaries; keystroke → first candidates
// (name completion with the index source); workspace-symbol search; the
// first result of a cross-file member lookup; phys_footprint added by these
// features with the index on (paired: the same process before and after).

private let benchEnabled = ProcessInfo.processInfo.environment["KARU_T1714_BENCH"] == "1"

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : -1
}

private func load() -> String {
    var loads = [Double](repeating: 0, count: 3)
    getloadavg(&loads, 3)
    return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
}

private func mb(_ bytes: Int) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }

@MainActor
@Suite("CrossFileBenchmark", .enabled(if: benchEnabled), .serialized)
struct CrossFileBenchmarkTests {
    /// Index time and size without / with signature summaries.
    @Test func indexCostOfSignatures() throws {
        var lines: [String] = []
        for rich in [false, true] {
            WorkspaceIndex.richSignatures = rich
            defer { WorkspaceIndex.richSignatures = true }
            let f = IndexFixture()
            try WorkspaceIndexBenchmarkTests.writeSynthetic(into: f.folder, files: 5_000)
            let index = f.makeIndex(latency: 0.3)
            index.start()
            let start = Date()
            index.addFolder(f.folder)
            #expect(index.waitUntilIdle(timeout: 600))
            let wall = Date().timeIntervalSince(start)
            let status = try #require(index.statuses().first)
            lines.append(String(format: "  signatures %@: %d files, wall %.2f s, database %@", rich ? "rich " : "names",
                                status.indexedFiles, wall, mb(Int(status.diskBytes))))
            f.modules.setEnabled(false, for: .crossFileIndex)
            _ = index.waitUntilIdle()
        }
        print("[T17.14] index cost (load \(load()))\n" + lines.joined(separator: "\n"))
    }

    @Test func latencyAndMemoryOnTheSyntheticTree() throws {
        let f = IndexFixture()
        try WorkspaceIndexBenchmarkTests.writeSynthetic(into: f.folder, files: 5_000)
        // Probe documents inside the folder (indexed too, excluded from their own lookups).
        let pythonProbe = f.write("pkg000/probe.py", "def run():\n    x = 1\n    \n")
        let swiftProbe = f.write("pkg000/probe.swift", "let it = Itemf3_0(count: 1)\nit.\n")
        let index = f.makeIndex(latency: 0.3)
        index.start()
        index.addFolder(f.folder)
        #expect(index.waitUntilIdle(timeout: 600))
        let crossFile = CrossFileTypeService(configuration: .init(workspace: index, moduleSettings: f.modules,
                                                                   center: f.center))
        usleep(300_000)
        let foot0 = footprint()

        // 1. Name completion: type `helper_f` + digits (index hits) in the Python
        // probe — first with a control controller without the index (the
        // completion popup's own cost), then with it (paired).
        @MainActor final class Session {
            let textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            let window: NSWindow
            let hub = TextStorageObserverHub()
            let controller: CompletionController
            init(_ f: IndexFixture, _ url: URL, text: String, index: WorkspaceIndex?, crossFile: CrossFileTypeService?) throws {
                let scroll = NSScrollView(frame: textView.frame)
                scroll.documentView = textView
                window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = scroll
                textView.string = text
                textView.textStorage?.delegate = hub
                controller = CompletionController(textView: textView, moduleSettings: f.modules, moduleCenter: f.center,
                                                  scheduler: AnalysisScheduler(), workspaceIndex: index,
                                                  crossFileTypes: crossFile)
                controller.documentURLProvider = { url }
                hub.add(controller)
                textView.completionKeyHandler = controller
                controller.setLanguage(identifier: "python")
                controller.indexDocument()
                window.makeFirstResponder(textView)
            }
        }
        func type(_ session: Session) -> (keys: [Double], queries: [Double], shown: Int) {
            let textView = session.textView, controller = session.controller
            let insertAt = (textView.string as NSString).length - 1
            var keystrokes: [Double] = []
            var queries: [Double] = []
            var shown = 0
            for round in 0..<40 {
                let word = "helper_f\(round * 37 % 4_000)_"
                textView.setSelectedRange(NSRange(location: insertAt, length: 0))
                for character in word { autoreleasepool {
                    // One event-loop turn per key (its autorelease pool drains, as in the app).
                    let s = String(character)
                    let start = DispatchTime.now().uptimeNanoseconds
                    textView.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: session.window.windowNumber, context: nil, characters: s,
                                                 charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0)!
                    let before = controller.workspaceQueryCount
                    controller.textViewDidInsertKey(event)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    if controller.isCompletionActive { keystrokes.append(elapsed) }
                    if controller.workspaceQueryCount > before {
                        queries.append(Double(controller.lastWorkspaceQueryNanoseconds) / 1e6)
                    }
                } }
                if controller.currentCandidatesForTesting.contains(where: { $0.source == .workspace }) { shown += 1 }
                autoreleasepool { controller.dismissCompletion() }
                let ns = textView.string as NSString
                textView.textStorage?.replaceCharacters(in: NSRange(location: insertAt, length: ns.length - 1 - insertAt),
                                                        with: "")
            }
            return (keystrokes, queries, shown)
        }
        // The same text in every session: a comment with 300 words sharing the
        // typed prefixes, so the control popup shows as many rows as the
        // indexed one (the popup's own cost is not the index's).
        var words = "# "
        for k in 0..<300 { words += "helper_f\(k * 13)_w " }
        let probeText = words + "\n" + (try String(contentsOf: pythonProbe, encoding: .utf8))
        let control = try Session(f, pythonProbe, text: probeText, index: nil, crossFile: nil)
        defer { control.window.close() }
        usleep(200_000)
        let footControl0 = footprint()
        let controlRun = type(control)
        usleep(200_000)
        let footControl1 = footprint()
        // A second control run (allocator / AppKit warm-up is not ours).
        let control2 = try Session(f, pythonProbe, text: probeText, index: nil, crossFile: nil)
        defer { control2.window.close() }
        usleep(200_000)
        let footControl2a = footprint()
        _ = type(control2)
        usleep(200_000)
        let footControl2b = footprint()
        print(String(format: "[T17.14] second control typing run: +%.2f MB", Double(footControl2b - footControl2a) / 1_048_576))
        let session = try Session(f, pythonProbe, text: probeText, index: index, crossFile: crossFile)
        defer { session.window.close() }
        usleep(200_000)
        let footWindow = footprint()
        let run = type(session)
        let keystrokes = run.keys, queries = run.queries, shownWorkspace = run.shown
        let controller = session.controller
        let textView = session.textView
        usleep(200_000)
        let footNames = footprint()
        // 2. Workspace-symbol search.
        var searches: [Double] = []
        let terms = ["helper", "Model", "compute_f12", "scld", "Srvf3", "build_f1234", "rnf", "Config", "area_f9", "x"]
        for round in 0..<50 {
            let term = terms[round % terms.count]
            let start = DispatchTime.now().uptimeNanoseconds
            _ = index.searchSymbols(term, inFolder: f.path, limit: 100)
            searches.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }

        usleep(200_000)
        let footSearch = footprint()
        // 3. Cross-file member: first result (request → queue → refreshed answer).
        let swiftView = EditorTextView(frame: textView.frame)
        let swiftHub = TextStorageObserverHub()
        swiftView.string = try String(contentsOf: swiftProbe, encoding: .utf8)
        swiftView.textStorage?.delegate = swiftHub
        let analysis = DocumentAnalysis(textView: swiftView, moduleSettings: f.modules, moduleCenter: NotificationCenter(),
                                        scheduler: AnalysisScheduler())
        analysis.setLanguage(identifier: "swift")
        swiftHub.add(analysis)
        var firstResults: [Double] = []
        var queueTimes: [Double] = []
        for _ in 0..<10 {
            crossFile.release()
            let inference = TypeInferenceService(tables: .shared, crossFile: crossFile)
            let text = swiftView.textStorage!.mutableString
            let dot = (text as String as NSString).range(of: "it.").location + 2
            let start = DispatchTime.now().uptimeNanoseconds
            var members = inference.memberCandidates(analysis: analysis, text: text, dot: dot, documentPath: swiftProbe.path)
            var rounds = 0
            while members == nil, inference.lastRequestPendingCrossFile, rounds < 8 {
                crossFile.waitForTypes()
                members = inference.memberCandidates(analysis: analysis, text: text, dot: dot, documentPath: swiftProbe.path)
                rounds += 1
            }
            firstResults.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            queueTimes.append(crossFile.statistics.lastJobMilliseconds)
            #expect(members?.contains { $0.name == "scaled_f3_0" } == true)
        }
        usleep(300_000)
        let foot1 = footprint()
        let held = crossFile.retainedBytes
        crossFile.release()
        usleep(200_000)
        let foot2 = footprint()

        print("""
            [T17.14] synthetic 5,000 files (load \(load()))
              control (no index) keystroke → candidates: p50 \(String(format: "%.2f", percentile(controlRun.keys, 0.5))) ms, \
            p95 \(String(format: "%.2f", percentile(controlRun.keys, 0.95))) ms; typing loop footprint +\(mb(footControl1 - footControl0))
              name completion keystroke → candidates: p50 \(String(format: "%.2f", percentile(keystrokes, 0.5))) ms, \
            p95 \(String(format: "%.2f", percentile(keystrokes, 0.95))) ms, max \(String(format: "%.2f", keystrokes.max() ?? 0)) ms \
            (n=\(keystrokes.count), words with index names \(shownWorkspace)/40)
                of which the index query (main thread): p50 \(String(format: "%.3f", percentile(queries, 0.5))) ms, \
            p95 \(String(format: "%.3f", percentile(queries, 0.95))) ms, max \(String(format: "%.3f", queries.max() ?? 0)) ms
              workspace symbol search (off main in the app): p50 \(String(format: "%.1f", percentile(searches, 0.5))) ms, \
            p95 \(String(format: "%.1f", percentile(searches, 0.95))) ms, max \(String(format: "%.1f", searches.max() ?? 0)) ms (n=50)
              cross-file member first result: p50 \(String(format: "%.1f", percentile(firstResults, 0.5))) ms, \
            p95 \(String(format: "%.1f", percentile(firstResults, 0.95))) ms (queue job p50 \(String(format: "%.1f", percentile(queueTimes, 0.5))) ms)
              phys_footprint (index on, paired from after indexing): control window + typing \
            +\(mb(footControl1 - foot0)); second window +\(mb(footWindow - footControl1)); \
            typing with index names +\(mb(footNames - footWindow)); workspace search +\(mb(footSearch - footNames)); \
            cross-file members +\(mb(foot1 - footSearch)) (summaries held \(held) B); total +\(mb(foot1 - foot0)), \
            after releasing the summaries +\(mb(foot2 - foot0))
            """)
        #expect(percentile(keystrokes, 0.95) <= 50)
        controller.dismissCompletion()
        withExtendedLifetime(swiftHub) {}
    }
}
