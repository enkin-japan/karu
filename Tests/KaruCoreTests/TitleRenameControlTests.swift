import AppKit
import Testing
@testable import KaruCore

/// The centre title shows saved and untitled documents at the same place in
/// the same form; only a saved document's title offers the rename capsule.
@Suite("Title rename control")
@MainActor
struct TitleRenameControlTests {
    @Test func untitledAndSavedTitlesShareTheSameForm() {
        let control = TitleRenameControl()
        control.configure(fileName: "Untitled", hasFile: false, isDirty: false)
        #expect(!control.isHidden)
        let untitledSize = control.intrinsicContentSize
        #expect(untitledSize.width > 20)

        control.configure(fileName: "Untitled", hasFile: true, isDirty: false)
        #expect(!control.isHidden)
        #expect(control.intrinsicContentSize == untitledSize)
    }

    @Test func capsuleAppearsOnlyWhenHoveringASavedTitle() throws {
        let control = TitleRenameControl()
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

        control.configure(fileName: "notes.md", hasFile: true, isDirty: false)
        #expect(!control.showsCapsule)
        control.mouseEntered(with: event)
        #expect(control.showsCapsule)
        control.mouseExited(with: event)
        #expect(!control.showsCapsule)

        control.configure(fileName: "Untitled", hasFile: false, isDirty: false)
        control.mouseEntered(with: event)
        #expect(!control.showsCapsule)
        #expect(control.mouseDownCanMoveWindow)
        #expect(control.toolTip == nil)
    }

    @Test func unsavedMarkerPrecedesTheNameInAQuieterColour() {
        let clean = TitleRenameControl.title(fileName: "a.txt", isDirty: false, font: nil)
        #expect(clean.string == "a.txt")
        let dirty = TitleRenameControl.title(fileName: "a.txt", isDirty: true, font: nil)
        #expect(dirty.string == "● a.txt")
        #expect(dirty.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .secondaryLabelColor)
        #expect(dirty.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == .labelColor)
    }
    /// The first edit must refresh the toolbar title, not only the close
    /// button's dot: the title is where the unsaved marker lives.
    @Test func firstEditShowsTheUnsavedMarkerInTheToolbarTitle() throws {
        let defaults = UserDefaults(suiteName: "TitleRenameControlTests-\(UUID().uuidString)")!
        let controller = EditorWindowController()
        controller.sessionStore = SessionStore(defaults: defaults)
        controller.draftStore = DraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruTitleDrafts-\(UUID().uuidString)", isDirectory: true))
        defer { controller.close() }
        let window = try #require(controller.window)
        #expect(window.titleVisibility == .hidden)
        let title = try #require(window.toolbar?.items.compactMap { $0.view as? TitleRenameControl }.first)
        #expect(title.accessibilityLabel() == window.title)

        func find(_ view: NSView) -> EditorTextView? {
            (view as? EditorTextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let textView = try #require(window.contentView.flatMap(find))
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        #expect(window.isDocumentEdited)
        #expect(title.accessibilityLabel() == "● " + window.title)
    }
}
