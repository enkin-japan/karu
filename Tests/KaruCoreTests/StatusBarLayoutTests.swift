import AppKit
import Testing
@testable import KaruCore

/// The status bar keeps the caret position on the left and groups language,
/// line ending and count on the right; a narrow window drops the line ending
/// first, then the language.
@Suite("Status bar layout")
@MainActor
struct StatusBarLayoutTests {
    @Test func optionalFieldsHideInOrderAsTheBarNarrows() {
        func fits(_ width: CGFloat) -> (language: Bool, lineEnding: Bool) {
            StatusBarMetrics.optionalFields(width: width, position: 80, language: 60, lineEnding: 20,
                                            count: 70, inset: 10, spacing: 12)
        }
        // base = 20 + 80 + 12 + 70 = 182; + language 72 = 254; + line ending 32 = 286
        #expect(fits(400) == (true, true))
        #expect(fits(286) == (true, true))
        #expect(fits(285) == (true, false))
        #expect(fits(254) == (true, false))
        #expect(fits(253) == (false, false))
        #expect(fits(100) == (false, false))
    }

    private func makeBar(width: CGFloat) -> StatusBarView {
        let bar = StatusBarView()
        bar.updateCaret(line: 120, column: 14)
        bar.updateLanguage("typescriptreact")
        bar.updateLineEnding(.crlf)
        bar.updateCharacterCount(123_456)
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private func labels(_ bar: StatusBarView) -> [NSTextField] {
        func all(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(all)
        }
        return all(bar).filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The visible labels' alignment rectangles in the bar's coordinates (a
    /// label's frame is 2 pt wider than its text on each side).
    private func alignmentRects(_ bar: StatusBarView) -> [NSRect] {
        labels(bar).map { $0.superview!.convert($0.alignmentRect(forFrame: $0.frame), to: bar) }
    }

    @Test func wideBarShowsPositionLeftAndTheRestGroupedRight() {
        let bar = makeBar(width: 800)
        #expect(bar.showsLanguage && bar.showsLineEnding)
        let frames = alignmentRects(bar).sorted { $0.minX < $1.minX }
        #expect(frames.count == 4)
        // Position starts at the left margin; the other three end at the right
        // margin, 12 pt apart, with the slack between position and the group.
        #expect(abs(frames[0].minX - 10) < 1)
        #expect(abs(frames[3].maxX - 790) < 1)
        #expect(abs(frames[3].minX - frames[2].maxX - 12) < 1)
        #expect(abs(frames[2].minX - frames[1].maxX - 12) < 1)
        #expect(frames[1].minX > 400)
    }

    @Test func narrowBarDropsLineEndingThenLanguageButNeverPositionOrCount() {
        let wide = makeBar(width: 800)
        let needed = labels(wide).map { $0.intrinsicContentSize.width }
        let all = needed.reduce(0, +) + 20 + 36

        let medium = makeBar(width: all - 10)
        #expect(medium.showsLanguage && !medium.showsLineEnding)
        #expect(labels(medium).count == 3)

        let narrow = makeBar(width: 190)
        #expect(!narrow.showsLanguage && !narrow.showsLineEnding)
        #expect(labels(narrow).count == 2)

        // Widening brings them back.
        narrow.frame.size.width = 800
        narrow.needsLayout = true
        narrow.layoutSubtreeIfNeeded()
        #expect(narrow.showsLanguage && narrow.showsLineEnding)
    }

    @Test func aLongTransientNoteTruncatesInsteadOfPushingFieldsOut() {
        let bar = makeBar(width: 420)
        #expect(bar.showsLanguage && bar.showsLineEnding)
        bar.flashMessage(String(repeating: "long note ", count: 30))
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        #expect(bar.showsLanguage && bar.showsLineEnding)
        let frames = alignmentRects(bar)
        #expect(frames.allSatisfy { $0.minX >= 9 && $0.maxX <= 411 })
    }
}
