import AppKit
import Foundation
import Testing
@testable import KaruCore

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let name = "ScrollSmoothnessTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

// MARK: - LayoutMode threshold (T8.1 item 3)

@Test func layoutModeBelowThresholdIsContiguous() {
    // Small documents lay out eagerly (return false).
    #expect(LayoutMode.shouldUseNonContiguousLayout(utf16Length: 0) == false)
    #expect(LayoutMode.shouldUseNonContiguousLayout(
        utf16Length: LayoutMode.noncontiguousThreshold - 1) == false)
}

@Test func layoutModeExactlyAtThresholdIsNonContiguous() {
    // Exactly at the threshold counts as large → noncontiguous.
    #expect(LayoutMode.shouldUseNonContiguousLayout(
        utf16Length: LayoutMode.noncontiguousThreshold) == true)
}

@Test func layoutModeAboveThresholdIsNonContiguous() {
    #expect(LayoutMode.shouldUseNonContiguousLayout(
        utf16Length: LayoutMode.noncontiguousThreshold + 1) == true)
    // A 10 MB file must stay on the noncontiguous path (memory red line).
    #expect(LayoutMode.shouldUseNonContiguousLayout(utf16Length: 10 * 1024 * 1024) == true)
}

@MainActor
@Test func layoutModeControllerFlipsOnlyOnThresholdCrossing() {
    let storage = NSTextStorage(string: "")
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer()
    layoutManager.addTextContainer(container)

    // Empty → contiguous.
    let controller = LayoutModeController(layoutManager: layoutManager, initialLength: 0)
    #expect(controller.usesNonContiguousLayout == false)
    #expect(layoutManager.allowsNonContiguousLayout == false)

    // Below threshold: still contiguous.
    controller.setLength(LayoutMode.noncontiguousThreshold - 1)
    #expect(controller.usesNonContiguousLayout == false)

    // Cross up to the threshold: flips to noncontiguous.
    controller.setLength(LayoutMode.noncontiguousThreshold)
    #expect(controller.usesNonContiguousLayout == true)
    #expect(layoutManager.allowsNonContiguousLayout == true)

    // Shrink back below: flips back.
    controller.setLength(0)
    #expect(controller.usesNonContiguousLayout == false)
    #expect(layoutManager.allowsNonContiguousLayout == false)
}

@MainActor
@Test func layoutModeControllerReactsToEdits() {
    let storage = NSTextStorage(string: "")
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)
    let container = NSTextContainer()
    layoutManager.addTextContainer(container)

    let controller = LayoutModeController(layoutManager: layoutManager, initialLength: 0)

    // A character edit past the threshold flips the flag.
    let big = String(repeating: "a", count: LayoutMode.noncontiguousThreshold)
    controller.textStorageDidProcessEditing(
        editedMask: .editedCharacters,
        editedRange: NSRange(location: 0, length: big.utf16.count),
        changeInLength: big.utf16.count,
        textStorage: NSTextStorage(string: big))
    #expect(controller.usesNonContiguousLayout == true)

    // An attribute-only edit (no `.editedCharacters`) is ignored.
    controller.textStorageDidProcessEditing(
        editedMask: .editedAttributes,
        editedRange: NSRange(location: 0, length: 0),
        changeInLength: 0,
        textStorage: NSTextStorage(string: ""))
    #expect(controller.usesNonContiguousLayout == true)
}

// MARK: - Overscan whole-line clamp (T8.1 item 1)

@Test func wholeLineRangeClampsAtDocumentStart() {
    let ns = "line0\nline1\nline2\n" as NSString
    // A rect starting "above" the document yields a negative-ish raw location;
    // clamp must snap to the first line at 0.
    let r = HighlightEngine.wholeLineRange(clamping: NSRange(location: -100, length: 3), in: ns)
    #expect(r.location == 0)
    #expect(r.location + r.length <= ns.length)
    // Must cover whole first line "line0\n" (length 6) at minimum.
    #expect(r.length >= 6)
}

@Test func wholeLineRangeClampsAtDocumentEnd() {
    let ns = "line0\nline1\nline2" as NSString
    // A raw range overshooting the end must clamp to ns.length, snapped to the
    // last whole line.
    let r = HighlightEngine.wholeLineRange(
        clamping: NSRange(location: ns.length - 1, length: 9999), in: ns)
    #expect(r.location + r.length == ns.length)
    #expect(r.location >= 0)
    // Starts at the last line boundary (after the 2nd newline, offset 12).
    #expect(r.location == 12)
}

@Test func wholeLineRangeExpandsToWholeLines() {
    let ns = "abcd\nefgh\nijkl\n" as NSString
    // A raw range in the middle of two lines expands out to their line bounds.
    let r = HighlightEngine.wholeLineRange(clamping: NSRange(location: 6, length: 2), in: ns)
    #expect(r.location == 5)          // start of "efgh\n"
    #expect(r.location + r.length == 10) // end of "efgh\n"
}

@Test func wholeLineRangeEmptyDocumentIsZero() {
    let ns = "" as NSString
    let r = HighlightEngine.wholeLineRange(clamping: NSRange(location: 0, length: 0), in: ns)
    #expect(r.length == 0)
}

// MARK: - paintedRange containment predicate (T8.1 item 2)

@Test func rangeContainsIsTrueWhenFullyInside() {
    let painted = NSRange(location: 10, length: 100)
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 20, length: 30)))
    // Boundary: viewport exactly equal to painted band is contained.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 10, length: 100)))
    // Boundary: touches the top edge.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 10, length: 5)))
    // Boundary: touches the bottom edge.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 105, length: 5)))
}

@Test func rangeContainsIsFalseWhenOverhanging() {
    let painted = NSRange(location: 10, length: 100)
    // Overhang above.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 5, length: 10)) == false)
    // Overhang below.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 100, length: 20)) == false)
    // Strictly larger.
    #expect(HighlightEngine.range(painted, contains: NSRange(location: 0, length: 200)) == false)
}

// MARK: - paintedRange invalidation (T8.1 item 2)

@MainActor
private func makeIdleEngine() -> (HighlightEngine, NotificationCenter, ModuleSettings) {
    let center = NotificationCenter()
    let defaults = isolatedDefaults()
    let settings = ModuleSettings(defaults: defaults, center: center)

    let scrollView = NSScrollView()
    let textView = EditorTextView()
    scrollView.documentView = textView

    let engine = HighlightEngine(textView: textView,
                                 scrollView: scrollView,
                                 moduleSettings: settings,
                                 moduleCenter: center)
    return (engine, center, settings)
}

@MainActor
@Test func setLanguageInvalidatesPaintedRange() {
    let (engine, _, _) = makeIdleEngine()

    // Seed a stale band, then a language change (by extension) must clear it.
    engine.paintedRange = NSRange(location: 0, length: 42)
    engine.setLanguage(fileExtension: "json")
    #expect(engine.paintedRange == nil)

    // ... and the identifier entry too.
    engine.paintedRange = NSRange(location: 0, length: 42)
    engine.setLanguage(identifier: "json")
    #expect(engine.paintedRange == nil)
}

@MainActor
@Test func editInvalidatesPaintedRange() {
    let (engine, _, _) = makeIdleEngine()
    engine.setLanguage(identifier: "json")

    engine.paintedRange = NSRange(location: 0, length: 42)
    engine.textStorageDidProcessEditing(
        editedMask: .editedCharacters,
        editedRange: NSRange(location: 0, length: 1),
        changeInLength: 1,
        textStorage: NSTextStorage(string: "x"))
    #expect(engine.paintedRange == nil)
}

@MainActor
@Test func disablingModuleInvalidatesPaintedRange() {
    let (engine, _, settings) = makeIdleEngine()
    engine.setLanguage(identifier: "json")

    engine.paintedRange = NSRange(location: 0, length: 42)
    settings.setEnabled(false, for: .highlight)   // tearDown → removeAllForegroundColour
    #expect(engine.paintedRange == nil)
}
