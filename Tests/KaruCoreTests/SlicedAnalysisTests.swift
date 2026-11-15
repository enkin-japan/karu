import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.15d-A — the long main-thread stretches of T17.15b, asserted
// structurally (never on wall-clock time):
// - the declaration scan's tail (name table, categories, variable filter,
//   completion-symbol union) runs in bounded finishing steps, with native
//   name strings;
// - a large document's open-time scan publishes through the sliced job, and
//   the highlighter repaints names when it lands;
// - the checkpoint stores catch up to the document end in slices, re-confirm
//   their pending entries after an upstream edit instead of rescanning, and
//   a keystroke in a long line keeps the line's earlier checkpoints.

private func isolatedDefaults() -> UserDefaults {
    let name = "SlicedAnalysisTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Records the reasons an analysis notifies with.
@MainActor
private final class ReasonLog: DocumentAnalysisConsumer {
    var reasons: [DocumentAnalysis.ChangeReason] = []
    func documentAnalysisDidChange(_ analysis: DocumentAnalysis, reason: DocumentAnalysis.ChangeReason) {
        reasons.append(reason)
    }
}

/// An editor-window-like wiring on a private scheduler (driven by
/// `runPendingJobsForTesting`), isolated module settings.
@MainActor
private final class Editor {
    let center = NotificationCenter()
    let settings: ModuleSettings
    let scheduler = AnalysisScheduler()
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let analysis: DocumentAnalysis
    let engine: HighlightEngine
    let completion: CompletionController
    let log = ReasonLog()

    init(text: String) {
        settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.textStorage?.delegate = hub
        analysis = DocumentAnalysis(textView: textView, moduleSettings: settings,
                                    moduleCenter: center, scheduler: scheduler)
        hub.add(analysis)
        engine = HighlightEngine(textView: textView, scrollView: scrollView, moduleSettings: settings,
                                 moduleCenter: center, analysis: analysis)
        hub.add(engine)
        completion = CompletionController(textView: textView, moduleSettings: settings,
                                          moduleCenter: center, analysis: analysis)
        hub.add(completion)
        textView.completionKeyHandler = completion
        analysis.addConsumer(log)
        textView.string = text
    }

    var ns: NSString { textView.textStorage!.mutableString }

    /// Runs every scheduled analysis job (declarations, catch-up, …) in
    /// slices of `budget`.
    func drain(budget: TimeInterval = AnalysisScheduler.sliceBudget) {
        scheduler.runPendingJobsForTesting(budget: budget)
    }

    /// Foreground colour identity per UTF-16 unit of `range`.
    func colours(in range: NSRange) -> [ObjectIdentifier?] {
        (range.location..<NSMaxRange(range)).map { index in
            (textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                        effectiveRange: nil) as? NSColor).map { ObjectIdentifier($0) }
        }
    }

    func close() {
        completion.dismissCompletion()
        analysis.cancelPendingWork()
        window.close()
    }
}

/// Python with `count` distinct functions sharing a prefix (the T17.15b
/// same-prefix stress shape) and a call to the first one on top.
private func samePrefixPython(count: Int) -> String {
    var lines = ["result = handle_request_0000(1)", ""]
    for i in 0..<count {
        lines.append("HANDLE_LIMIT_\(i) = \(i)")
    }
    for i in 0..<count {
        let n = String(format: "%04d", i)
        lines += ["def handle_request_\(n)(handle_payload_\(n), handle_retries=3):",
                  "    handle_result_\(n) = handle_payload_\(n) + HANDLE_LIMIT_\(i)",
                  "    return handle_result_\(n)", ""]
    }
    return lines.joined(separator: "\n")
}

/// Pure value code: off the main actor, so it never holds up the main-actor
/// suites running in parallel.
@Suite("SlicedAnalysisScan")
struct SlicedAnalysisScanTests {

    @Test func finishingThousandsOfNamesTakesManyBoundedSteps() {
        let text = samePrefixPython(count: 2_000) as NSString
        var scanner = DeclarationScanner(languageIdentifier: "python")
        var steps = 0
        while !scanner.step(text, budgetUnits: DocumentAnalysis.declarationStepUnits) { steps += 1 }
        let scan = try! #require(scanner.scan)
        // ~8 000 names; a finishing step handles at most `budget / 16` items,
        // and the union alone visits every name once.
        #expect(scan.names.count > 7_500)
        let perStep = DocumentAnalysis.declarationStepUnits / 16
        #expect(scanner.finishingSteps >= scan.names.count / perStep,
                "finished in \(scanner.finishingSteps) steps")
        // Same products as running to completion in one go.
        var whole = DeclarationScanner(languageIdentifier: "python")
        #expect(whole.finish(text) == scan)
        #expect(scan.table.functions.contains("handle_request_1999"))
        #expect(scan.table.variables.contains("HANDLE_LIMIT_1999"))
        #expect(scan.completionSymbols == scan.table.all)
    }

    @Test func nativeNamesEqualTheText() {
        var samples: [NSString] = ["value", "über_grö", "名前変数", "x\u{1F600}y",
                                   ("a" + String(repeating: "b", count: 100)) as NSString]
        // A lone surrogate keeps the bridged form (not U+FFFD).
        var lone: [unichar] = [0x6C, 0x6F, 0xD800]
        samples.append(NSString(characters: &lone, length: lone.count))
        for sample in samples {
            var units = [unichar](repeating: 32, count: sample.length + 4)
            units.withUnsafeMutableBufferPointer { buffer in
                sample.getCharacters(buffer.baseAddress! + 2, range: NSRange(location: 0, length: sample.length))
            }
            let text = NSString(characters: &units, length: units.count)
            let token = DeclToken(kind: .ident, start: 2, end: 2 + sample.length)
            let name = DeclarationBuilder.nativeName(text, token)
            #expect(name == text.substring(with: NSRange(location: 2, length: sample.length)))
            #expect((name as NSString).length == sample.length)
            #expect((name as NSString).isEqual(to: sample as String))
        }
    }
}

@MainActor
@Suite("SlicedAnalysis", .serialized)
struct SlicedAnalysisTests {

    // MARK: Open-time scan

    @Test func largeDocumentOpensWithASlicedDeclarationScan() throws {
        // JavaScript colours declared names (Python's module variables are
        // not coloured), so the first paint visibly lacks them.
        var lines: [String] = []
        for i in 0..<5_000 {
            lines.append("const handle_value_\(i) = handle_value_\(max(0, i - 1)) + compute_\(i % 50)(\(i));")
        }
        for i in 0..<50 { lines.append("function compute_\(i)(arg) { return arg + \(i); }") }
        let text = lines.joined(separator: "\n")
        #expect((text as NSString).length > DocumentAnalysis.synchronousScanLimit)
        let editor = Editor(text: text)
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "javascript")
        // Nothing scanned synchronously: the job is scheduled instead.
        #expect(editor.analysis.declarations == nil)
        #expect(editor.analysis.isDeclarationScanPending)
        #expect(editor.analysis.declarationScanCount == 0)
        // The word index does not finish it either.
        editor.completion.indexDocument()
        #expect(editor.analysis.declarations == nil)
        // The first paint goes without names.
        editor.engine.appearanceDidChange()
        let band = try #require(editor.engine.paintedRange)
        let before = editor.colours(in: band)

        editor.drain()
        let snapshot = try #require(editor.analysis.declarations)
        #expect(editor.analysis.slicedDeclarationScans == 1)
        #expect(editor.analysis.lastScanSlices > 1, "one slice: \(editor.analysis.lastScanSlices)")
        #expect(editor.log.reasons.contains(.declarations))
        var whole = DeclarationScanner(languageIdentifier: "javascript")
        #expect(snapshot.scan == whole.finish(text as NSString))
        // The landing snapshot repainted the band (no forced repaint here):
        // it now equals an engine that had the declarations at its first paint.
        let after = editor.colours(in: band)
        #expect(after != before, "the band was not repainted with the declarations")
        #expect(editor.engine.paintedPasses >= 2)
        let reference = Editor(text: text)
        defer { reference.close() }
        reference.analysis.setLanguage(identifier: "javascript")
        reference.analysis.finishPendingDeclarationScanForTesting()
        reference.engine.appearanceDidChange()
        #expect(reference.colours(in: band) == after)
    }

    @Test func aDataFileIsNotRepaintedWhenItsSlicedScanLands() throws {
        // 400 K units of JSON: no declarations, so the landing snapshot changes no
        // colour and the painted band stays (no second redraw of an idle
        // window, which cost ~7 MB of graphics memory in mem-benchmark).
        var json = "["
        var i = 0
        while (json as NSString).length < 400_000 {
            json += (i == 0 ? "" : ",\n") + #"  {"id": \#(i), "name": "item \#(i)", "ok": true}"#
            i += 1
        }
        json += "]"
        let editor = Editor(text: json)
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "json")
        #expect(editor.analysis.isDeclarationScanPending)
        editor.engine.appearanceDidChange()
        let band = try #require(editor.engine.paintedRange)
        let passes = editor.engine.paintedPasses
        let colours = editor.colours(in: band)
        editor.drain()
        #expect(editor.analysis.declarations != nil)
        #expect(editor.engine.paintedPasses == passes, "repainted although no colour changed")
        #expect(editor.engine.paintedRange == band)
        #expect(editor.colours(in: band) == colours)
    }

    @Test func smallDocumentStillScansOnTheLanguageChange() {
        let editor = Editor(text: samePrefixPython(count: 50))
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        #expect(editor.analysis.declarations != nil)
        #expect(!editor.analysis.isDeclarationScanPending)
        #expect(editor.analysis.slicedDeclarationScans == 0)
    }

    @Test func aSynchronousRequestFinishesTheOpenTimeScan() {
        let editor = Editor(text: samePrefixPython(count: 2_000))
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        #expect(editor.analysis.declarations == nil)
        // The navigator (or inference) still gets a complete scan at once.
        let snapshot = editor.analysis.ensureDeclarations()
        #expect(snapshot.version == editor.analysis.version)
        #expect(editor.analysis.declarations != nil)
        editor.drain()
        #expect(editor.analysis.declarationScanCount == 1)
    }

    // MARK: Checkpoint catch-up

    private func largePython() -> String {
        var out = ""
        var i = 0
        while (out as NSString).length < 400_000 {
            out += "def func_\(i)(a, b=\(i)):\n    '''Doc \(i)\n    more'''\n    return f\"{a} {b}\" + 'x'\n\n"
            i += 1
        }
        return out
    }

    @Test func checkpointsCatchUpToTheEndInSlices() {
        let editor = Editor(text: largePython())
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        #expect(editor.analysis.highlightCheckpointAdvancer != nil)
        #expect(editor.analysis.contextCheckpointAdvancer != nil)
        editor.drain(budget: 0.001)
        let length = editor.ns.length
        let spacing = CheckpointStore.spacing
        #expect(editor.analysis.checkpointCatchUps >= 1)
        #expect(editor.analysis.lastCatchUpSlices > 1, "one slice: \(editor.analysis.lastCatchUpSlices)")
        // Both stores reach the end: a pass or request there resumes nearby.
        #expect((editor.analysis.checkpoints.nearest(atOrBefore: length)?.offset ?? 0) > length - 2 * spacing)
        #expect((editor.analysis.contextCheckpoints.nearest(atOrBefore: length)?.offset ?? 0) > length - 2 * spacing)
    }

    @Test func anUpstreamEditIsReconfirmedNotRescanned() {
        let editor = Editor(text: largePython())
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        editor.drain(budget: 0.001)
        let built = editor.analysis.checkpoints.entries.count
        let contextBuilt = editor.analysis.contextCheckpoints.entries.count
        #expect(built >= 5)
        // A same-state edit near the top.
        editor.textView.textStorage!.replaceCharacters(in: NSRange(location: 10, length: 0), with: "z")
        #expect(editor.analysis.checkpoints.entries.count < 2)
        #expect(!editor.analysis.checkpoints.pending.isEmpty)
        editor.drain(budget: 0.001)
        #expect(editor.analysis.checkpoints.pending.isEmpty)
        #expect(editor.analysis.checkpoints.entries.count >= built - 1)
        #expect(editor.analysis.contextCheckpoints.entries.count >= contextBuilt - 1)
        // Re-confirming took a slice or two, not a rescan of 400 KB.
        #expect(editor.analysis.lastCatchUpSlices <= 3, "\(editor.analysis.lastCatchUpSlices) slices")
        // The states are the ones a fresh walk gives.
        let language = PythonLanguage.make()
        for entry in editor.analysis.checkpoints.entries {
            let fresh = PythonTokenizer.state(in: editor.ns, before: entry.offset, language: language)
            #expect(entry.state == .python(fresh), "entry \(entry.offset)")
        }
    }

    @Test func aKeystrokeInALongLineKeepsItsEarlierCheckpoints() {
        // One 400 000-unit JSON line (the single-line stress shape).
        var json = "["
        var i = 0
        while (json as NSString).length < 400_000 {
            json += (i == 0 ? "" : ",") + #"{"id":\#(i),"name":"item \#(i)","ok":true}"#
            i += 1
        }
        json += "]"
        let editor = Editor(text: json)
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "json")
        editor.drain(budget: 0.001)
        let length = editor.ns.length
        #expect(editor.analysis.checkpoints.entries.count >= 6)
        // A newline typed at the end of the line, as the text view does it:
        // `didProcessEditing` reports the whole paragraph, the checkpoints use
        // the exact range from `willProcessEditing`.
        editor.textView.setSelectedRange(NSRange(location: length, length: 0))
        editor.textView.insertText("\n", replacementRange: NSRange(location: length, length: 0))
        let kept = editor.analysis.checkpoints.entries
        #expect(kept.count >= 5)
        #expect(kept.allSatisfy { $0.offset < length - CheckpointStore.editMargin })
        #expect((kept.last?.offset ?? 0) > length - CheckpointStore.editMargin - 2 * CheckpointStore.spacing)
    }
}
