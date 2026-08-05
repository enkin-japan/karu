import AppKit

/// Repaints the viewport band below a shrinking edit (T15.5).
///
/// After a multi-line delete the surviving text moves up — and the vacated band
/// below the new document end is not reliably marked dirty on macOS 26/27's
/// compositor, so the deleted lines' old pixels simply stay on screen as a
/// ghost (user screenshot: a wrapped line's fragment hovering below the last
/// line, surviving further select-and-delete and only cleared by unrelated
/// edits). The gap was pinned to *invalidation* rather than drawing by the
/// KARU_GHOSTTEST hook: a forced full re-render of the same post-delete state
/// is always clean, so nothing is wrong with what Karu draws — nothing ever
/// asked that band to be drawn again.
///
/// This observer asks. On every character edit that shrinks the text it marks
/// the visible rect from the top of the edited line downward as needing
/// display. Growth needs no help (new text dirties its own rect), and the cost
/// is one partial repaint per deletion — no state is kept, per the
/// resident-memory rule (ARCHITECTURE.md §3.4).
///
/// Shared by the editor window and the scratchpad: both register it on their
/// `TextStorageObserverHub` (which holds observers weakly — the owner retains).
final class ShrinkRepaintObserver: TextStorageObserving {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
    }

    func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                      editedRange: NSRange,
                                      changeInLength delta: Int,
                                      textStorage: NSTextStorage) {
        guard delta < 0, editedMask.contains(.editedCharacters),
              let textView else { return }

        let visible = textView.visibleRect
        guard !visible.isEmpty else { return }

        let length = (textView.string as NSString).length
        guard length > 0, editedRange.location < length,
              let layoutManager = textView.layoutManager else {
            // Document emptied (or edit at the very end): repaint the whole
            // viewport rather than reason about a line that no longer exists.
            textView.setNeedsDisplay(visible)
            return
        }

        // From the top of the line that received the edit down to the bottom of
        // the viewport: everything below the edit may have moved up.
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: editedRange.location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let top = fragment.minY + textView.textContainerOrigin.y
        let band = NSRect(x: visible.minX,
                          y: min(top, visible.maxY),
                          width: visible.width,
                          height: max(0, visible.maxY - min(top, visible.maxY)))
        if !band.isEmpty {
            textView.setNeedsDisplay(band)
        }
    }
}
