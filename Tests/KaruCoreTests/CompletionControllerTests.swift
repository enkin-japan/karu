import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.5 — `CompletionController` on the engine: whole-identifier accept
// as one undo step, the stale-accept guard, recent accepts, dismissal in
// strings, the manual entry and the sliced word-index rebuild.

private func isolatedDefaults() -> UserDefaults {
    let name = "CompletionControllerTests-\(UUID().uuidString)"
    let d = TestDefaults.make(name)
    d.removePersistentDomain(forName: name)
    return d
}

@MainActor
private func pump(until done: () -> Bool, timeout: TimeInterval = 60) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// A window-like wiring: hub → controller (owning its analysis).
@MainActor
private final class Harness {
    let center = NotificationCenter()
    let settings: ModuleSettings
    let scheduler = AnalysisScheduler()
    let window: NSWindow
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let controller: CompletionController

    init(_ text: String, language: String) {
        settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.allowsUndo = true
        textView.isRichText = false
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                          scheduler: scheduler)
        hub.add(controller)
        textView.completionKeyHandler = controller
        window.makeFirstResponder(textView)
        controller.setLanguage(identifier: language)
        controller.indexDocument()
    }

    func type(_ string: String) {
        for ch in string {
            let key = String(ch)
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textViewDidInsertKey(event(key, keyCode: 0))
        }
    }

    func event(_ key: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                         keyCode: keyCode)!
    }

    func pressReturn() -> Bool { controller.handleCompletionKeyDown(event("\r", keyCode: 36)) }

    func caret(after marker: String) {
        let range = (textView.string as NSString).range(of: marker)
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
    }
}

@MainActor
@Suite("CompletionController", .serialized)
struct CompletionControllerTests {

    @Test func acceptIsItsOwnUndoStep() throws {
        let h = Harness("function badge(userCount) {\n  return \n}\n", language: "javascript")
        defer { h.close() }
        let undo = try #require(h.textView.undoManager)
        // One undo group per simulated event (the test never turns the run
        // loop, which would otherwise close the automatic groups).
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        h.caret(after: "return ")
        for key in ["u", "s", "e"] {
            undo.beginUndoGrouping()
            h.type(key)
            undo.endUndoGrouping()
        }
        #expect(h.controller.currentSuggestionsForTesting.first == "userCount")
        undo.beginUndoGrouping()
        #expect(h.pressReturn())
        undo.endUndoGrouping()
        #expect(h.textView.string == "function badge(userCount) {\n  return userCount\n}\n")
        #expect(h.controller.recentAcceptsForTesting.entries.first?.name == "userCount")
        #expect(!h.controller.isCompletionActive)
        // One undo reverts the completion only, back to the typed prefix.
        undo.undo()
        #expect(h.textView.string == "function badge(userCount) {\n  return use\n}\n")
    }

    @Test func acceptReplacesWholeIdentifierAroundTheCaret() {
        let h = Harness("function badge(userCount) {\n  return userCunt + 1;\n}\n", language: "javascript")
        defer { h.close() }
        h.caret(after: "return userC")
        h.type("o")   // "userCo│unt"
        #expect(h.controller.currentContextForTesting?.identifier == "userCount")
        #expect(h.pressReturn())
        #expect(h.textView.string == "function badge(userCount) {\n  return userCount + 1;\n}\n")
        #expect(h.textView.selectedRange().location
                == NSMaxRange((h.textView.string as NSString).range(of: "return userCount")))
    }

    @Test func staleAcceptDoesNotWrite() {
        let h = Harness("def f(alpha_beta):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("alp")
        #expect(h.controller.isCompletionActive)
        // The caret moves without a key event (programmatic change).
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = h.pressReturn()
        #expect(h.textView.string == "def f(alpha_beta):\n    alp\n")
    }

    @Test func autoPopupClosesInsideAString() {
        let h = Harness("def f(cart_note):\n    x = cart_note\n", language: "python")
        defer { h.close() }
        h.caret(after: "x = ")
        h.type("ca")
        #expect(h.controller.isCompletionActive)
        h.type(" + \"ca")
        #expect(!h.controller.isCompletionActive)
        // The manual entry works there (document words).
        h.controller.requestCompletion(manual: true)
        #expect(h.controller.isCompletionActive)
        #expect(h.controller.currentCandidatesForTesting.allSatisfy { $0.source == .documentWord })
    }

    @Test func dotOpensMembersWithEvidenceOnly() {
        let h = Harness("""
        class Client:
            def __init__(self):
                self.host = 1

            def connect(self, other):
                return 0
        """, language: "python")
        defer { h.close() }
        h.caret(after: "return ")
        h.type("self.")
        #expect(Set(h.controller.currentSuggestionsForTesting) == ["host", "connect", "__init__"])
        h.controller.dismissCompletion()
        h.type(" + other.")
        #expect(!h.controller.isCompletionActive)
    }

    @Test func wordIndexRebuildsInSlicesAfterAnEditPause() async {
        let h = Harness("def f(alpha):\n    pass\n", language: "python")
        defer { h.close() }
        #expect(h.controller.wordIndexForTesting?.words.contains("brand_new_word") == false)
        h.caret(after: "pass")
        h.type(" # brand_new_word")
        await pump(until: { h.controller.wordIndexForTesting?.words.contains("brand_new_word") == true })
        #expect(h.controller.wordIndexForTesting?.words.contains("brand_new_word") == true)
    }

    @Test func moduleOffReleasesEngineAndRecentState() {
        let h = Harness("def f(alpha_beta):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("alp")
        #expect(h.pressReturn())
        #expect(!h.controller.recentAcceptsForTesting.entries.isEmpty)
        h.settings.setEnabled(false, for: .completion)
        #expect(h.controller.isRuntimeStateReleased)
        #expect(h.controller.recentAcceptsForTesting.entries.isEmpty)
    }
}
