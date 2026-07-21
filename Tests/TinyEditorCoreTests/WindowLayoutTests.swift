import AppKit
import Testing
@testable import TinyEditorCore

/// Regression guard for the v0.2.0 blank-window report: after layout, the
/// editor's scroll view must occupy essentially the whole content area and the
/// text view must have a usable width.
@MainActor
@Test func editorWindowLayoutIsNotDegenerate() {
    let controller = EditorWindowController()
    guard let window = controller.window, let content = window.contentView else {
        Issue.record("window/contentView missing")
        return
    }
    window.layoutIfNeeded()

    func findScrollView(_ view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, sv.documentView is NSTextView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(sub) { return found }
        }
        return nil
    }

    guard let scrollView = findScrollView(content) else {
        Issue.record("editor scroll view not found in hierarchy")
        return
    }
    let textView = scrollView.documentView as! NSTextView

    #expect(content.frame.height > 0)
    #expect(scrollView.frame.height > 300,
            "scroll view collapsed: \(scrollView.frame) in content \(content.frame)")
    #expect(textView.frame.width > 300,
            "text view width degenerate: \(textView.frame)")
}
