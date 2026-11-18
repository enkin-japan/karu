import AppKit
import Foundation
import Testing
@testable import KaruCore

// F7: a formatter that stops at one of its limits reports it through
// `FormatDispatch` and the window's Format Document action, and the document
// is left exactly as it was.

@Suite("Format limits through the dispatcher")
struct FormatLimitDispatchTests {

    private static func nested(_ open: String, _ close: String, _ depth: Int) -> String {
        String(repeating: open, count: depth) + String(repeating: close, count: depth)
    }

    @Test(arguments: ["json", "jsonl"])
    func jsonNestingPastTheLimitIsReportedWithItsLine(language: String) {
        let text = "\n" + Self.nested("[", "]", FormatLimits.standard.maxDepth + 1)
        let result = FormatDispatch.format(text: text, languageIdentifier: language, indentWidth: 2)
        #expect(result == .failure(.nestingTooDeep(line: 2, limit: FormatLimits.standard.maxDepth)))
    }

    @Test(arguments: ["xml", "plist"])
    func xmlNestingPastTheLimitIsReportedWithItsLine(language: String) {
        let text = "\n\n" + Self.nested("<a>", "</a>", FormatLimits.standard.maxDepth + 1)
        let result = FormatDispatch.format(text: text, languageIdentifier: language, indentWidth: 2)
        #expect(result == .failure(.nestingTooDeep(line: 3, limit: FormatLimits.standard.maxDepth)))
    }

    @Test func nestingAtTheLimitStillFormats() throws {
        let depth = FormatLimits.standard.maxDepth
        let json = FormatDispatch.format(text: Self.nested("[", "]", depth), languageIdentifier: "json", indentWidth: 2)
        let xml = FormatDispatch.format(text: Self.nested("<a>", "</a>", depth), languageIdentifier: "xml", indentWidth: 2)
        #expect((try? json.get()) != nil)
        #expect((try? xml.get()) != nil)
    }

    @Test func aResultThatWouldBeTooLargeIsRefused() {
        // 400 levels deep, then many small scalars: every one gets 800 spaces
        // of indentation, far past 8 × input + 1 MB.
        let depth = 400
        let scalars = Array(repeating: "1", count: 20_000).joined(separator: ",")
        let json = String(repeating: "[", count: depth) + scalars + String(repeating: "]", count: depth)
        let limit = FormatLimits.standard.maxOutputBytes(forInputBytes: json.utf8.count)
        #expect(FormatDispatch.format(text: json, languageIdentifier: "json", indentWidth: 2)
            == .failure(.outputTooLarge(limitBytes: limit)))

        let children = String(repeating: "<b/>", count: 20_000)
        let xml = String(repeating: "<a>", count: depth) + children + String(repeating: "</a>", count: depth)
        let xmlLimit = FormatLimits.standard.maxOutputBytes(forInputBytes: xml.utf8.count)
        #expect(FormatDispatch.format(text: xml, languageIdentifier: "xml", indentWidth: 2)
            == .failure(.outputTooLarge(limitBytes: xmlLimit)))
    }

    @Test func syntaxErrorsStillCarryTheirLineAndMessage() {
        let result = FormatDispatch.format(text: "{\n  \"a\": \n}", languageIdentifier: "json", indentWidth: 2)
        guard case .failure(.syntax(let line, let message)) = result else {
            Issue.record("expected a syntax error, got \(result)")
            return
        }
        #expect(line == 3)
        #expect(!message.isEmpty)
    }

    @Test func everyRefusalHasALocalizedMessageThatIsNotTheRawError() {
        for error in [FormatDispatchError.nestingTooDeep(line: 7, limit: 512),
                      .outputTooLarge(limitBytes: 9 * 1024 * 1024)] {
            let message = EditorWindowController.formatErrorMessage(error)
            #expect(message != nil)
            #expect(message?.contains("nestingTooDeep") == false)
            #expect(message?.contains("outputTooLarge") == false)
            #expect(message?.contains("limitBytes") == false)
        }
        #expect(EditorWindowController.formatErrorMessage(.nestingTooDeep(line: 7, limit: 512))?.contains("512") == true)
        #expect(EditorWindowController.formatErrorMessage(.unsupportedLanguage("x")) == nil)
    }
}

@MainActor
@Suite("Format limits in the window")
struct FormatLimitWindowTests {

    @MainActor
    final class Fixture {
        let directory: URL
        let file: URL
        let controller: EditorWindowController
        private(set) var errors: [FormatDispatchError] = []
        private let suite = "FormatLimitWindowTests-\(UUID().uuidString)"

        init(name: String, contents: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaruFormatLimit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = directory.appendingPathComponent(name)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            controller = EditorWindowController()
            controller.sessionStore = SessionStore(defaults: UserDefaults(suiteName: suite)!)
            controller.draftStore = DraftStore(directory: directory.appendingPathComponent("drafts", isDirectory: true))
            controller.load(url: file)
            controller.formatErrorObserver = { [unowned self] in self.errors.append($0) }
        }

        var textView: EditorTextView {
            func find(_ view: NSView) -> EditorTextView? {
                (view as? EditorTextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return controller.window!.contentView.flatMap(find)!
        }

        func cleanup() {
            controller.window?.close()
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test func aDocumentNestedTooDeepIsLeftUntouched() throws {
        let deep = String(repeating: "[", count: 30_000) + String(repeating: "]", count: 30_000)
        let f = try Fixture(name: "deep.json", contents: deep)
        defer { f.cleanup() }

        f.controller.formatDocument(nil)

        #expect(f.errors == [.nestingTooDeep(line: 1, limit: FormatLimits.standard.maxDepth)])
        #expect(f.textView.string == deep)
        #expect(f.controller.window?.isDocumentEdited == false)
        #expect(f.textView.undoManager?.canUndo == false)
    }

    @Test func aDeepXMLDocumentIsLeftUntouchedToo() throws {
        let deep = String(repeating: "<a>", count: 30_000) + String(repeating: "</a>", count: 30_000)
        let f = try Fixture(name: "deep.xml", contents: deep)
        defer { f.cleanup() }

        f.controller.formatDocument(nil)

        #expect(f.errors == [.nestingTooDeep(line: 1, limit: FormatLimits.standard.maxDepth)])
        #expect(f.textView.string == deep)
        #expect(f.controller.window?.isDocumentEdited == false)
    }

    @Test func aNormalDocumentStillFormatsAsOneUndoStep() throws {
        let f = try Fixture(name: "ok.json", contents: "{\"a\":[1,2]}")
        defer { f.cleanup() }

        f.controller.formatDocument(nil)

        #expect(f.errors.isEmpty)
        #expect(f.textView.string == "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
        f.textView.undoManager?.undo()
        #expect(f.textView.string == "{\"a\":[1,2]}")
    }
}
