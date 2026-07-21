import AppKit

/// Decides whether TextKit lays a document out lazily (noncontiguous) or
/// eagerly (contiguous), trading resident memory against scroll smoothness.
///
/// - **Small documents** get eager / contiguous layout: every glyph and line
///   fragment is laid out up front, so a region scrolling into view is already
///   laid out and never lags behind a fast scroll.
/// - **Large documents** keep noncontiguous (lazy) layout to hold the 10 MB /
///   65 MB memory red line — laying a 10 MB file out eagerly blew the budget
///   (97 MB measured vs the 50 MB ceiling; see scripts/mem-benchmark.sh).
enum LayoutMode {
    /// UTF-16 length at (and above) which noncontiguous / lazy layout is used.
    /// 512 KiB in UTF-16 units.
    static let noncontiguousThreshold = 512 * 1024

    /// `true` when the document is large enough to warrant lazy (noncontiguous)
    /// layout; `false` for small documents that are laid out in full. A length
    /// exactly equal to the threshold counts as large.
    static func shouldUseNonContiguousLayout(utf16Length: Int) -> Bool {
        utf16Length >= noncontiguousThreshold
    }
}

/// Keeps a layout manager's `allowsNonContiguousLayout` flag in step with the
/// document's size as it is edited, flipping it only when an edit actually
/// crosses `LayoutMode.noncontiguousThreshold` — so the common keystroke does an
/// O(1) length compare and never touches the layout manager.
@MainActor
final class LayoutModeController: TextStorageObserving {
    private weak var layoutManager: NSLayoutManager?
    private var noncontiguous: Bool

    /// Current mode (exposed for tests / diagnostics).
    var usesNonContiguousLayout: Bool { noncontiguous }

    init(layoutManager: NSLayoutManager, initialLength: Int) {
        self.layoutManager = layoutManager
        self.noncontiguous = LayoutMode.shouldUseNonContiguousLayout(utf16Length: initialLength)
        layoutManager.allowsNonContiguousLayout = noncontiguous
    }

    /// Applies the mode implied by `utf16Length`, writing the layout-manager
    /// property only when the mode changes. Called on load (before the text is
    /// inserted) and from each edit.
    func setLength(_ utf16Length: Int) {
        let want = LayoutMode.shouldUseNonContiguousLayout(utf16Length: utf16Length)
        guard want != noncontiguous else { return }
        noncontiguous = want
        layoutManager?.allowsNonContiguousLayout = want
    }

    func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                      editedRange: NSRange,
                                      changeInLength delta: Int,
                                      textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        // `NSTextStorage.length` is O(1); the mode compare is O(1) too, so this
        // stays cheap on every keystroke.
        setLength(textStorage.length)
    }
}
