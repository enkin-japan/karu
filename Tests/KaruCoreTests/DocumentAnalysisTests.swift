import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.1 — `DocumentAnalysis`: one declaration scan per version shared by
// highlight / completion / navigator, the language-switch fix, release when
// every analysis module is off, and checkpoint-resumed Python highlighting
// that matches a fresh engine.

private func isolatedDefaults() -> UserDefaults {
    let name = "DocumentAnalysisTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// Lets the main run loop turn for `seconds`.
@MainActor
private func pump(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Lets the main run loop turn until `done` (at most `timeout` seconds), for
/// work that is expected to land: under a busy parallel test run the
/// debounced rescan may take longer than a fixed pump to get its main-thread
/// slice. Checks that something did *not* happen keep a fixed `pump`.
@MainActor
private func pump(until done: () -> Bool, timeout: TimeInterval = 3) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Records the reasons an analysis notifies with.
@MainActor
private final class ReasonLog: DocumentAnalysisConsumer {
    var reasons: [DocumentAnalysis.ChangeReason] = []
    func documentAnalysisDidChange(_ analysis: DocumentAnalysis, reason: DocumentAnalysis.ChangeReason) {
        reasons.append(reason)
    }
}

/// An editor-window-like wiring: one shared analysis registered on the hub
/// before the highlighter and completion, all on isolated module settings.
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
        // "Opening a document": the text arrives as an edit, then the language.
        textView.string = text
    }

    /// Simulates the keystroke-driven completion request for `key` with the
    /// caret at the end of the document (no text is inserted).
    func requestCompletion(key: String = "e") {
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: key, charactersIgnoringModifiers: key,
                                     isARepeat: false, keyCode: 0)!
        completion.textViewDidInsertKey(event)
    }

    func close() {
        completion.dismissCompletion()
        analysis.cancelPendingWork()
        window.close()
    }
}

@MainActor
@Suite("DocumentAnalysis", .serialized)
struct DocumentAnalysisTests {

    // MARK: (a) Language switch

    @Test func firstRequestAfterLanguageSwitchUsesNewLanguageSymbols() {
        // `zeta_name` is a Python declaration, `zetaAlpha` a JS one; each is a
        // plain document word under the other language. In dictionary order
        // `zeta_name` sorts first, so `zetaAlpha` leading proves it ranked as
        // a declared symbol.
        let editor = Editor(text: "def zeta_name():\n    pass\nfunction zetaAlpha() {}\nze")
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        editor.completion.indexDocument()
        editor.requestCompletion()
        #expect(editor.completion.currentSymbolsForTesting.contains("zeta_name"))
        #expect(!editor.completion.currentSymbolsForTesting.contains("zetaAlpha"))
        #expect(editor.completion.currentSuggestionsForTesting.first == "zeta_name")

        // Switch — no debounce wait before the next request.
        editor.analysis.setLanguage(identifier: "javascript")
        #expect(editor.engine.currentLanguageIdentifier == "javascript")
        #expect(editor.completion.currentSymbolsForTesting.contains("zetaAlpha"))
        #expect(!editor.completion.currentSymbolsForTesting.contains("zeta_name"))
        editor.requestCompletion()
        #expect(editor.completion.currentSuggestionsForTesting.first == "zetaAlpha")
        #expect(editor.completion.currentSuggestionsForTesting.contains("zeta_name"))  // still a word
    }

    @Test func standaloneControllerSwitchUsesNewLanguageSymbolsToo() {
        let textView = EditorTextView()
        textView.string = "def zeta_name():\n    pass\nfunction zetaAlpha() {}\n"
        let center = NotificationCenter()
        let controller = CompletionController(textView: textView,
                                              moduleSettings: ModuleSettings(defaults: isolatedDefaults(),
                                                                             center: center),
                                              moduleCenter: center)
        controller.setLanguage(identifier: "python")
        controller.indexDocument()
        #expect(controller.currentSymbolsForTesting.contains("zeta_name"))
        controller.setLanguage(fileExtension: "js")
        #expect(controller.currentSymbolsForTesting == ["zetaAlpha"])
    }

    // MARK: (b) One scan per version

    @Test func openPaintCompleteAndNavigateScanDeclarationsOnce() async {
        let source = "import os\n\ndef compute(alpha, beta):\n    total = alpha + beta\n"
            + "    return total\n\nclass Widget:\n    pass\n\nco"
        let editor = Editor(text: source)
        defer { editor.close() }
        #expect(editor.analysis.declarationScanCount == 0)   // the load edit only schedules

        // Open: language (synchronous scan), index, paint.
        editor.analysis.setLanguage(identifier: "python")
        editor.completion.indexDocument()
        editor.engine.appearanceDidChange()
        #expect(editor.engine.paintedRange != nil)
        // Completion request.
        editor.requestCompletion(key: "o")
        #expect(editor.completion.currentSuggestionsForTesting.first == "compute")
        // Navigator, exactly as `EditorWindowController.jumpToSymbol` does it.
        let navigator = SymbolNavigator(textView: editor.textView)
        navigator.present(locations: editor.analysis.ensureDeclarations().scan.locations)
        #expect(navigator.isVisible)
        navigator.perform(NSSelectorFromString("panelResignedKey"))
        #expect(editor.analysis.declarationScanCount == 1)

        // The load edit's debounced job was superseded by the language change.
        await pump(0.3)
        #expect(editor.analysis.declarationScanCount == 1)

        // One edit + debounce → exactly one more scan, shared by everyone.
        let end = (editor.textView.string as NSString).length
        editor.textView.textStorage!.replaceCharacters(in: NSRange(location: end, length: 0),
                                                       with: "\nfresh_name = 1\n")
        #expect(editor.analysis.declarations == nil)
        await pump(0.4)   // past the analysis (0.07 s) and completion (0.15 s) debounces
        await pump(until: { editor.completion.currentSymbolsForTesting.contains("fresh_name") })
        #expect(editor.analysis.declarationScanCount == 2)
        #expect(editor.analysis.declarations?.version == editor.analysis.version)
        #expect(editor.analysis.declarations?.scan.table.variables.contains("fresh_name") == true)
        #expect(editor.completion.currentSymbolsForTesting.contains("fresh_name"))
        _ = editor.analysis.ensureDeclarations()
        #expect(editor.analysis.declarationScanCount == 2)
    }

    @Test func burstOfEditsScansOnceAndStaleJobsAreDiscarded() async {
        let editor = Editor(text: "def one():\n    pass\n")
        defer { editor.close() }
        editor.analysis.setLanguage(identifier: "python")
        let log = ReasonLog()
        editor.analysis.addConsumer(log)
        let baseline = editor.analysis.declarationScanCount
        for name in ["a1", "a2", "a3"] {
            let end = (editor.textView.string as NSString).length
            editor.textView.textStorage!.replaceCharacters(in: NSRange(location: end, length: 0),
                                                           with: "\(name) = 1\n")
        }
        await pump(0.3)
        await pump(until: { editor.analysis.declarationScanCount > baseline && !log.reasons.isEmpty })
        #expect(editor.analysis.declarationScanCount == baseline + 1)
        #expect(log.reasons == [.declarations])

        // A language change while a rescan is pending supersedes it: the
        // stale job neither scans nor publishes.
        let end = (editor.textView.string as NSString).length
        editor.textView.textStorage!.replaceCharacters(in: NSRange(location: end, length: 0), with: "b = 2\n")
        editor.analysis.setLanguage(identifier: "javascript")
        let afterSwitch = editor.analysis.declarationScanCount
        await pump(0.3)
        #expect(editor.analysis.declarationScanCount == afterSwitch)
        #expect(log.reasons == [.declarations, .language])
    }

    @Test func windowLoadScansDeclarationsOnce() async throws {
        // The window uses the standard module defaults; only meaningful when
        // highlight and completion are on there (the shipped default).
        let modules = ModuleSettings()
        guard modules.isEnabled(.highlight), modules.isEnabled(.completion) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KaruAnalysis-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sample.py")
        try "def compute(a):\n    return a\n\nclass Widget:\n    pass\n".write(to: url, atomically: true,
                                                                            encoding: .utf8)
        let controller = EditorWindowController()
        controller.load(url: url)
        let analysis = try #require(controller.documentAnalysis)
        #expect(analysis.languageIdentifier == "python")
        #expect(analysis.declarationScanCount == 1)
        // What `jumpToSymbol` reads: the held snapshot, no rescan.
        #expect(analysis.ensureDeclarations().scan.locations.map(\.name).contains("compute"))
        await pump(0.3)   // load edit's job (superseded) and completion's debounce
        #expect(analysis.declarationScanCount == 1)
        analysis.cancelPendingWork()
    }

    // MARK: (c) Release

    @Test func allAnalysisModulesOffReleasesEverythingAndRebuildsLazily() async {
        let editor = Editor(text: "def compute(a):\n    return a\n\nco")
        defer { editor.close() }
        let log = ReasonLog()
        editor.analysis.addConsumer(log)
        editor.analysis.setLanguage(identifier: "python")
        editor.completion.indexDocument()
        editor.analysis.checkpoints.record(offset: 0, state: .python(PythonTokenizer.State()))
        #expect(!editor.analysis.isRuntimeStateReleased)
        #expect(!editor.engine.isRuntimeStateReleased)
        #expect(!editor.completion.isRuntimeStateReleased)

        for module in [FeatureModule.highlight, .completion, .typeInference] {
            editor.settings.setEnabled(false, for: module)
        }
        #expect(!log.reasons.contains(.released))
        editor.settings.setEnabled(false, for: .crossFileIndex)
        #expect(log.reasons.last == .released)
        #expect(editor.analysis.isRuntimeStateReleased)
        #expect(editor.analysis.declarations == nil)
        #expect(editor.analysis.checkpoints.entries.isEmpty)
        #expect(editor.engine.isRuntimeStateReleased)
        #expect(editor.completion.isRuntimeStateReleased)

        // Edits while everything is off schedule nothing.
        let scans = editor.analysis.declarationScanCount
        editor.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# x\n")
        await pump(0.2)
        #expect(editor.analysis.declarationScanCount == scans)
        #expect(editor.analysis.isRuntimeStateReleased)

        // Navigator-only use while released stays transient.
        #expect(editor.analysis.ensureDeclarations().scan.table.functions.contains("compute"))
        #expect(editor.analysis.isRuntimeStateReleased)

        // Turning one consumer back on rebuilds (lazily, on its own first use).
        editor.settings.setEnabled(true, for: .completion)
        #expect(!editor.completion.isRuntimeStateReleased)
        #expect(!editor.analysis.isRuntimeStateReleased)
        #expect(editor.completion.currentSymbolsForTesting.contains("compute"))
        editor.settings.setEnabled(true, for: .highlight)
        #expect(!editor.engine.isRuntimeStateReleased)

        // typeInference alone keeps nothing either (it gates nothing yet).
        editor.settings.setEnabled(false, for: .highlight)
        editor.settings.setEnabled(false, for: .completion)
        editor.settings.setEnabled(true, for: .typeInference)
        #expect(editor.analysis.isRuntimeStateReleased)
    }

    // MARK: (d) Checkpoint-resumed Python highlighting

    /// ~1 MB of Python with triple-quoted strings (both quote kinds), f-strings
    /// with nested fields, escapes, raw/bytes prefixes and quote-bearing
    /// comments.
    private static func largePython() -> String {
        var out = ""
        var i = 0
        while (out as NSString).length < 1_000_000 {
            out += "def func_\(i)(a, b=\(i)):\n"
            out += "    '''Docstring \(i) with \"quotes\" and {braces}\n"
            out += "    spanning lines'''\n"
            out += "    name_\(i) = f\"value {a!r:>10} and {b + \(i)} {{literal}}\"\n"
            out += "    other = f'''multi\n{a}\n  line {b['k']:{i}}'''\n"
            out += "    # comment with \"\"\" fake triple\n"
            out += "    s = \"plain \\\" escaped\" + 'it\\'s'\n"
            out += "    r = rb'raw\\d+' + u\"x\"\n"
            out += "    return name_\(i)\n\n"
            out += "class Klass\(i):\n    x = \"\"\"\n    triple \(i)\n    \"\"\"\n\n"
            i += 1
        }
        return out
    }

    /// A standalone engine (private analysis) on its own text view.
    @MainActor
    private final class Painter {
        let center = NotificationCenter()
        let scrollView: NSScrollView
        let textView: EditorTextView
        let hub = TextStorageObserverHub()
        let engine: HighlightEngine

        init(text: String) {
            let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            scrollView = NSScrollView(frame: frame)
            textView = EditorTextView(frame: frame)
            textView.isVerticallyResizable = true
            textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutManager?.allowsNonContiguousLayout = true
            scrollView.documentView = textView
            textView.string = text
            engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                     moduleSettings: ModuleSettings(defaults: isolatedDefaults(), center: center),
                                     moduleCenter: center)
            hub.add(engine)
            textView.textStorage?.delegate = hub
            engine.setLanguage(identifier: "python")
        }

        var length: Int { (textView.string as NSString).length }

        /// Scrolls `offset` into view and repaints synchronously.
        func paint(at offset: Int) {
            textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            engine.appearanceDidChange()
        }

        func paint(fraction: Double) { paint(at: Int(Double(length) * fraction)) }

        /// Foreground colour identity per UTF-16 unit of `range`.
        func colours(in range: NSRange) -> [ObjectIdentifier?] {
            let lm = textView.layoutManager!
            var out: [ObjectIdentifier?] = []
            out.reserveCapacity(range.length)
            var index = range.location
            while index < NSMaxRange(range) {
                var effective = NSRange(location: 0, length: 0)
                let colour = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                                   longestEffectiveRange: &effective, in: range)
                let id = (colour as? NSColor).map { ObjectIdentifier($0) }
                let end = max(index + 1, NSMaxRange(effective))
                out += Array(repeating: id, count: end - index)
                index = end
            }
            return out
        }

        var checkpointOffsets: [Int] { engine.analysis.checkpoints.entries.map(\.offset) }
    }

    /// Paints the same viewport in a fresh engine over the same text and
    /// expects identical colours over the overlap of the two painted bands.
    @MainActor
    private func expectMatchesFreshEngine(_ painter: Painter, at offset: Int,
                                          _ label: String) {
        painter.paint(at: offset)
        let fresh = Painter(text: painter.textView.string)
        fresh.paint(at: offset)
        guard let a = painter.engine.paintedRange, let b = fresh.engine.paintedRange else {
            Issue.record("\(label): nothing painted")
            return
        }
        let overlap = NSIntersectionRange(a, b)
        #expect(overlap.length > 1_000, "\(label): overlap \(overlap) of \(a) / \(b)")
        #expect(NSLocationInRange(offset, overlap), "\(label): target \(offset) not in \(overlap)")
        let mine = painter.colours(in: overlap)
        let theirs = fresh.colours(in: overlap)
        let firstDiff = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(firstDiff == nil,
                "\(label): colours differ at \(overlap.location + (firstDiff ?? 0))")
        // The band really contains Python string colouring.
        let stringColour = HighlightTheme().color(for: .string).map { ObjectIdentifier($0) }
        #expect(mine.contains(stringColour), "\(label): no string colour in band")
    }

    @Test func checkpointResumedPythonHighlightMatchesFreshEngine() async {
        let text = Self.largePython()
        let spacing = CheckpointStore.spacing

        // (a) Top to bottom.
        let a = Painter(text: text)
        for fraction in [0.0, 0.2, 0.4, 0.6] { a.paint(fraction: fraction) }
        expectMatchesFreshEngine(a, at: Int(Double(a.length) * 0.8), "top-to-bottom")
        let offsetsA = a.checkpointOffsets
        #expect(offsetsA.count >= 10)
        #expect(zip(offsetsA, offsetsA.dropFirst()).allSatisfy { $1 - $0 >= spacing / 2 })
        let ns = a.textView.string as NSString
        #expect(offsetsA.allSatisfy { $0 == 0 || ns.character(at: $0 - 1) == 10 }, "not at line starts")

        // (b) Jump to the middle first, then back up to 30 %.
        let b = Painter(text: text)
        b.paint(fraction: 0.5)
        #expect(b.checkpointOffsets.count >= 6)
        expectMatchesFreshEngine(b, at: Int(Double(b.length) * 0.3), "jump-middle-then-back")

        // (c) Edit near the end: checkpoints before the edit survive.
        let beforeEdit = a.checkpointOffsets
        let endLine = ns.lineRange(for: NSRange(location: Int(Double(ns.length) * 0.95), length: 0)).location
        a.textView.textStorage!.replaceCharacters(in: NSRange(location: endLine, length: 0),
                                                  with: "late = f\"{x!s}\" + '''open\nstill'''\n")
        #expect(a.checkpointOffsets == beforeEdit)
        await pump(0.3)   // the edit's declaration rescan lands
        await pump(until: { a.engine.analysis.declarations != nil })
        #expect(a.engine.analysis.declarations != nil)
        expectMatchesFreshEngine(a, at: Int(Double(a.length) * 0.97), "edit-near-end")
        #expect(Array(a.checkpointOffsets.prefix(beforeEdit.count)) == beforeEdit)
        #expect(a.checkpointOffsets.count > beforeEdit.count)

        // (d) Edit near the start: an unclosed triple quote re-pairs the quotes
        // below it (until the sample's pattern resynchronises) and shifts every
        // offset, so every checkpoint must go. Resuming from stale checkpoints
        // makes the back-up check below fail.
        #expect(!b.checkpointOffsets.isEmpty)
        b.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                  with: "opened = \"\"\"\n")
        #expect(b.checkpointOffsets.isEmpty)
        await pump(0.3)
        expectMatchesFreshEngine(b, at: Int(Double(b.length) * 0.6), "edit-near-start")
        // …and back towards the top after resuming from the new checkpoints.
        expectMatchesFreshEngine(b, at: Int(Double(b.length) * 0.1), "edit-near-start-back")
    }
}
