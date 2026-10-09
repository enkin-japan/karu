import AppKit
import Testing
@testable import KaruCore

@Suite("Maintenance regressions 2026-10", .serialized)
@MainActor
struct MaintenanceRegressionTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    @Test func formatCRLFAndReportOriginalLine() throws {
        #expect(try JSONFormatter.prettyPrint("{\r\n\"x\":1\r\n}") == "{\n  \"x\": 1\n}")
        #expect(try JSONFormatter.formatJSONL("{\"a\":1}\r\n\r\n{\"b\":2}\r\n") == "{\"a\":1}\n{\"b\":2}")
        do {
            _ = try JSONFormatter.formatJSONL("{}\r\n\r\ninvalid")
            Issue.record("Invalid JSONL accepted")
        } catch let error as JSONFormatError { #expect(error.line == 3) }
        #expect(try XMLFormatter.prettyPrint("<root>\r\n<a/>\r\n</root>\r\n") == "<root>\r\n<a/>\r\n</root>")
    }

    @Test func XMLPreservesPlistValuesAndMixedContent() throws {
        for value in ["  hello  ", " \t ", "\n hello\n", "😀 中"] {
            let xml = "<plist version=\"1.0\"><dict><key>text</key><string>\(value)</string></dict></plist>"
            let output = try XMLFormatter.prettyPrint(xml)
            let parsed = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: String]
            #expect(parsed?["text"] == value)
            #expect(try XMLFormatter.prettyPrint(output) == output)
        }
        for xml in ["<p> a <b>bold</b> c </p>",
                    "<p xml:space='preserve'> <a><b/></a> </p>",
                    "<p> \n </p>", "<p><![CDATA[x]]><b/> y</p>",
                    "<p><b>a</b> <b>b</b></p>", "<p><b>a</b>\n<b>b</b></p>"] {
            #expect(try XMLFormatter.prettyPrint(xml) == xml)
        }
    }

    @Test func lineIndexEditsMatchFoundationAcrossCRLFBoundaries() {
        // Every insertion/deletion/replacement around both halves of CRLF;
        // expected starts come from Foundation's line enumerator, not our scanner.
        let originals = ["a\rb\rc", "a\r\nb\r\nc\r\n", "\r\n\r\n", "a\n\rb", "", "中\r\nx"]
        for original in originals {
            let ns = original as NSString
            for start in 0...ns.length {
                for count in 0...(ns.length - start) {
                    for replacement in ["", "x", "\r", "\n", "\r\n", "😀\r\nx"] {
                        let index = LineIndex(text: original)
                        let updated = ns.replacingCharacters(in: NSRange(location: start, length: count), with: replacement)
                        index.update(text: updated, editedRange: NSRange(location: start, length: (replacement as NSString).length),
                                     changeInLength: (replacement as NSString).length - count)
                        let result = updated as NSString
                        var expected = [0]
                        var cursor = 0
                        while cursor < result.length {
                            var end = 0, contentsEnd = 0
                            result.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                                                for: NSRange(location: cursor, length: 0))
                            if end > contentsEnd { expected.append(end) }
                            cursor = end
                        }
                        #expect(index.starts == expected, "\(original.debugDescription) at \(start),\(count) -> \(replacement.debugDescription)")
                        #expect(LineIndex(text: updated).starts == expected)
                    }
                }
            }
        }
    }

    @Test func CRLFCopyAndMarkdownFolds() throws {
        let text = "a\r\nb\r\n"
        for operation in [LineOperations.copyLinesDown, LineOperations.copyLinesUp] {
            let edit = try #require(operation(text, NSRange(location: 0, length: 0)))
            #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "a\r\na\r\nb\r\n")
        }
        let lf = "# A\n```python\npass\n```\n# B\ntext\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let regions = FoldScanner.regions(text: crlf, lineIndex: LineIndex(text: crlf), language: "markdown")
        #expect(regions == FoldScanner.regions(text: lf, lineIndex: LineIndex(text: lf), language: "markdown"))
        #expect(regions.contains { $0.startLine == 2 && $0.endLine == 3 })
    }

    @Test func staleSearchRangeReturnsFailureAndRegexKeepsContext() throws {
        for range in [NSRange(location: 100, length: 6), NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 10)] {
            if case .success = SearchEngine.replacementText(for: range, in: "a", pattern: "target", options: SearchOptions(), template: "(") {
                Issue.record("Invalid range accepted")
            }
        }
        #expect(try SearchEngine.replacementText(for: NSRange(location: 3, length: 3), in: "foobar!", pattern: "(?<=foo)bar(?=!)", options: SearchOptions(regex: true), template: "X").get() == "X")
    }

    @Test func findReplaceRefreshesAndInsertsLiteralTextWithUndo() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tv = EditorTextView(frame: window.contentView!.bounds)
        tv.isRichText = false
        tv.allowsUndo = true
        window.contentView = tv
        tv.string = "foo"
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        let bar = FindBarController(textView: tv, lineIndex: LineIndex(text: tv.string))
        bar.show()
        let field = try #require(views(bar.barView).compactMap { $0 as? NSTextField }.first { $0.isEditable && !($0 is NSSearchField) })
        let button = try #require(views(bar.barView).compactMap { $0 as? NSButton }.first { $0.action == Selector(("replaceTapped")) })
        field.stringValue = "("
        let undo = try #require(tv.undoManager)
        undo.beginUndoGrouping()
        button.performClick(nil)
        undo.endUndoGrouping()
        #expect(tv.string == "(")
        undo.undo()
        #expect(tv.string == "foo")
        undo.redo()
        #expect(tv.string == "(")
        // Set up a stale match, then replace without didChangeText: actions must
        // defensively consult live content even if a caller omitted notification.
        tv.string = String(repeating: "x", count: 100) + "target"
        tv.setSelectedRange(NSRange(location: 100, length: 6))
        bar.show()
        tv.string = "a"
        button.performClick(nil)
        #expect(tv.string == "a")
    }

    @Test func languageSwitchClearsPreviouslyPaintedText() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tv = EditorTextView(frame: scroll.bounds)
        scroll.documentView = tv
        tv.string = "def hello():\n    return 42\n"
        let engine = HighlightEngine(textView: tv, scrollView: scroll)
        for plain in ["", "unknown-language"] {
            engine.setLanguage(identifier: "python")
            #expect(tv.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
            engine.setLanguage(identifier: plain)
            #expect(tv.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        }
    }

    @Test func wordHighlightSurvivesDeletionAtDocumentEnd() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tv = EditorTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.string = String(repeating: "word word word\n", count: 2000)
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 2, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
        let hub = TextStorageObserverHub()
        tv.textStorage!.delegate = hub
        let highlighter = WordOccurrenceHighlighter(textView: tv)
        hub.add(highlighter)
        highlighter.selectionChanged()
        try await Task.sleep(for: .milliseconds(300))
        let nearEnd = (tv.string as NSString).length - 3
        #expect(tv.layoutManager!.temporaryAttribute(.backgroundColor, atCharacterIndex: nearEnd, effectiveRange: nil) != nil)
        for _ in 0..<60 {
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            tv.deleteBackward(nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect((tv.string as NSString).length == 29940)
        highlighter.cancel()
    }

    @Test func scratchFailureKeepsBufferBlocksQuitAndCanRetry() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KaruFailure-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let controller = ScratchpadController(store: ScratchpadStore(directory: blocked))
        var failures = 0
        controller.persistenceErrorHandler = { _ in failures += 1 }
        controller.show()
        controller.diagnosticTextView!.string = "unsaved scratch text"
        controller.hide()
        #expect(controller.diagnosticTextView?.string == "unsaved scratch text")
        #expect(failures == 1)
        let app = AppDelegate()
        app.scratchpadController = controller
        #expect(app.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!app.isTerminating)
        try FileManager.default.removeItem(at: blocked)
        controller.hide()
        #expect(controller.diagnosticPanel == nil)
        #expect(controller.store.read() == "unsaved scratch text")
    }

    @Test(arguments: [true, false]) func explicitOpenStillRecoversCrashDrafts(finder: Bool) throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KaruLaunch-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "KaruLaunch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
        let delegate = AppDelegate()
        delegate.sessionStore = SessionStore(defaults: defaults)
        delegate.draftStore = DraftStore(directory: dir.appendingPathComponent("drafts"))
        let content = "recovered-\(UUID())"
        delegate.draftStore.write(id: UUID(), content: content, originalPath: nil)
        let file = dir.appendingPathComponent("opened.txt")
        try Data("disk".utf8).write(to: file)
        if finder { delegate.openFromFinder(file) }
        delegate.openStartupDocuments(fileURLs: [file], restoring: true)
        let controllers = NSApplication.shared.windows.compactMap { $0.windowController as? EditorWindowController }
        let matching = controllers.filter { $0.currentFileURL == file }
        let recovered = controllers.filter { controller in
            controller.window?.contentView.map { views($0).compactMap { $0 as? EditorTextView }.contains { $0.string == content } } ?? false
        }
        #expect(matching.count == 1)
        #expect(recovered.count == 1)
        for controller in matching + recovered { controller.window?.close() }
    }
}
