import AppKit

public final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    public convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled"
        window.center()
        window.setFrameAutosaveName("EditorWindow")
        self.init(window: window)
        window.delegate = self
        window.contentView = Self.makeEditorView()
    }

    private static func makeEditorView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
