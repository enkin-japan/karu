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
        let defaults = TestDefaults.make("TitleRenameControlTests-\(UUID().uuidString)")
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

    /// Indent width is set per language in Settings only: the editor toolbar
    /// carries no indent control, just the language and module popups.
    @Test func editorToolbarHasNoIndentControl() throws {
        let defaults = TestDefaults.make("TitleRenameControlTests-\(UUID().uuidString)")
        let controller = EditorWindowController()
        controller.sessionStore = SessionStore(defaults: defaults)
        controller.draftStore = DraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruTitleDrafts-\(UUID().uuidString)", isDirectory: true))
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)
        let ids = toolbar.items.map(\.itemIdentifier.rawValue)
        #expect(!ids.contains { $0.contains("indent") })
        #expect(ids.first == "dev.enkin.toolbar.language")
        #expect(ids.dropFirst().first == "dev.enkin.toolbar.format")
        let popups = toolbar.items.compactMap { ($0.view as? NSPopUpButton) ?? ($0.view?.subviews.first as? NSPopUpButton) }
        #expect(popups.count == 2)
    }

    /// Language, Format and Run are drawn at 90% of the toolbar size and each
    /// is followed by a gap; the right-hand items are not.
    @Test func leftToolbarControlsAreCompactAndSpaced() throws {
        let defaults = TestDefaults.make("TitleRenameControlTests-\(UUID().uuidString)")
        let controller = EditorWindowController()
        controller.sessionStore = SessionStore(defaults: defaults)
        controller.draftStore = DraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruTitleDrafts-\(UUID().uuidString)", isDirectory: true))
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)
        let left = toolbar.items.filter {
            ["dev.enkin.toolbar.language", "dev.enkin.toolbar.format", "dev.enkin.toolbar.run"]
                .contains($0.itemIdentifier.rawValue)
        }
        #expect(left.count >= 2)
        let scale = EditorToolbarController.compactScale, gap = EditorToolbarController.compactGap
        #expect(scale == 0.9)
        for item in left {
            let container = try #require(item.view as? ScaledToolbarItemView)
            let natural = container.naturalSize
            let size = container.intrinsicContentSize
            let inset = container.horizontalInset
            #expect(size.width == ceil((natural.width - 2 * inset) * scale) + gap)
            #expect(size.height == ceil(natural.height * scale))
            // Laid out at its announced size: the bounds are scaled, and the
            // control keeps its natural size inside them, starting at the left.
            container.frame = NSRect(origin: .zero, size: size)
            container.layout()
            #expect(abs(container.bounds.width - size.width / scale) < 0.01)
            #expect(container.control.frame.size == natural)
            #expect(container.control.frame.minX == -inset)
            // On screen the control (less its trimmed margin) ends `gap`
            // before the container does.
            let onScreen = container.convert(container.control.frame.insetBy(dx: inset, dy: 0), to: container.superview)
            #expect(abs(onScreen.minX) < 0.01)
            #expect(abs(size.width - onScreen.maxX - gap) < 1.01)
        }
        // Clicks land on the control through the scale: the centre of the
        // container (in its superview's coordinates) hits the control.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        let probe = ScaledToolbarItemView(control: NSButton(title: "Probe", target: nil, action: nil),
                                          scale: scale, trailingGap: gap)
        probe.frame = NSRect(origin: NSPoint(x: 20, y: 10), size: probe.intrinsicContentSize)
        host.addSubview(probe)
        probe.layout()
        let centre = NSPoint(x: probe.frame.midX - gap / 2, y: probe.frame.midY)
        #expect(host.hitTest(centre)?.isDescendant(of: probe.control) == true)

        // A longer title is picked up.
        let run = try #require(left.last?.view as? ScaledToolbarItemView)
        let before = run.intrinsicContentSize.width
        (run.control as? NSButton)?.title += " longer title"
        run.controlDidChange()
        #expect(run.intrinsicContentSize.width > before)
        // Modules and Settings keep the system size (no container).
        let modules = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "dev.enkin.toolbar.modules" })
        #expect(modules.view is NSPopUpButton)
    }
}
