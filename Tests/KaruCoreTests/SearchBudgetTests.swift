import AppKit
import Testing
@testable import KaruCore

// Search budgets (R03): a time limit and a match cap on the interactive
// search, a time limit with all-or-nothing semantics on Replace All, and
// viewport-only match highlighting in the find bar.

/// A fake monotonic clock: the first reading (the start) is 0, every later
/// reading is far past any limit, so the first budget check times out.
private final class JumpingClock {
    private(set) var readings = 0
    func now() -> TimeInterval {
        defer { readings += 1 }
        return readings == 0 ? 0 : 1_000
    }
}

private let catastrophic = "^(a+)+$"
private let catastrophicText = String(repeating: "a", count: 40) + "!"
private let regexMode = SearchOptions(regex: true, caseSensitive: true)

@Suite("Search budget engine")
struct SearchBudgetEngineTests {
    @Test func catastrophicBacktrackingTimesOutOnTheRealClock() throws {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = try SearchEngine.search(in: catastrophicText, pattern: catastrophic,
                                              options: regexMode).get()
        let elapsed = clock.now - start
        #expect(outcome.truncation == .timedOut)
        #expect(outcome.ranges.isEmpty)
        #expect(elapsed < .milliseconds(300), "took \(elapsed)")
    }

    @Test func twoMegabytesOfOneCharacterStopsAtTheMatchCap() throws {
        let text = String(repeating: "x", count: 2 * 1024 * 1024)
        let outcome = try SearchEngine.search(in: text, pattern: "x",
                                              options: SearchOptions()).get()
        #expect(outcome.ranges.count == 50_000)
        #expect(outcome.truncation == .matchLimit)
        #expect(outcome.ranges.first == NSRange(location: 0, length: 1))
        #expect(outcome.ranges.last == NSRange(location: 49_999, length: 1))
        // The legacy wrapper returns the same capped list.
        #expect(try SearchEngine.matches(in: text, pattern: "x", options: SearchOptions()).get().count == 50_000)
    }

    @Test func injectedClockTimesOutOnTheMatchPathDeterministically() throws {
        let clock = JumpingClock()
        let text = String(repeating: "a", count: 5_000)
        let outcome = try SearchEngine.search(in: text, pattern: "a", options: SearchOptions(),
                                              limits: SearchLimits(timeLimit: 0.2, maxMatches: .max),
                                              clock: clock.now).get()
        #expect(outcome.truncation == .timedOut)
        // Stopped at the first clock check: one stride of matches, in order.
        #expect(outcome.ranges.count == SearchEngine.matchCheckStride)
        #expect(outcome.ranges.enumerated().allSatisfy { $0.element == NSRange(location: $0.offset, length: 1) })
        #expect(clock.readings == 2)
    }

    @Test func injectedClockTimesOutOnTheProgressPathDeterministically() throws {
        let clock = JumpingClock()
        let outcome = try SearchEngine.search(in: catastrophicText, pattern: catastrophic, options: regexMode,
                                              limits: .interactive, clock: clock.now).get()
        #expect(outcome == SearchOutcome(ranges: [], truncation: .timedOut))
        #expect(clock.readings == 2)
    }

    @Test func aScanThatFinishesInTimeIsComplete() throws {
        let outcome = try SearchEngine.search(in: "a1 22 333", pattern: "\\d+", options: regexMode,
                                              limits: SearchLimits(timeLimit: 10, maxMatches: 3)).get()
        #expect(outcome.ranges.count == 3)
        #expect(outcome.truncation == nil, "exactly maxMatches matches is not a truncation")

        let capped = try SearchEngine.search(in: "a1 22 333 4", pattern: "\\d+", options: regexMode,
                                             limits: SearchLimits(timeLimit: 10, maxMatches: 3)).get()
        #expect(capped.ranges.count == 3)
        #expect(capped.truncation == .matchLimit)
    }

    @Test func zeroLengthMatchesAreUnchanged() throws {
        for (pattern, text) in [("^", "one\ntwo\n\nthree"), ("a*", "baaac a"), ("(?=b)", "abcabc"), ("$", "x\ny")] {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
            let expected = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .map(\.range)
            let outcome = try SearchEngine.search(in: text, pattern: pattern,
                                                  options: SearchOptions(regex: true)).get()
            #expect(outcome.ranges == expected, "\(pattern)")
            #expect(outcome.truncation == nil)
        }
    }

    // MARK: Replace All

    @Test func replaceAllTimeoutFailsWithoutPartialText() {
        let clock = JumpingClock()
        let text = String(repeating: "a", count: 5_000)
        let result = SearchEngine.replaceAll(in: text, pattern: "a", options: SearchOptions(), template: "b",
                                             limits: .replaceAll, clock: clock.now)
        guard case .failure(let error) = result else {
            Issue.record("expected a timeout, got \(result)")
            return
        }
        #expect(error.isTimeout)
        #expect(error.kind == .timedOut)

        // On the real clock, a catastrophic pattern under a short limit.
        let real = SearchEngine.replaceAll(in: catastrophicText, pattern: catastrophic, options: regexMode,
                                           template: "x", limits: SearchLimits(timeLimit: 0.05, maxMatches: .max))
        #expect((try? real.get()) == nil)
        if case .failure(let error) = real { #expect(error.isTimeout) }
        // The legacy wrapper surfaces the same kind of failure.
        let legacy = SearchEngine.replaceAll(in: "abc", pattern: "(", options: regexMode, template: "x")
        if case .failure(let error) = legacy { #expect(!error.isTimeout) } else { Issue.record("expected failure") }
    }

    @Test func replaceAllPastTheSearchCapReplacesEverythingAndCounts() throws {
        let text = String(repeating: "ab", count: 120_000)
        let outcome = try SearchEngine.replaceAll(in: text, pattern: "a", options: SearchOptions(),
                                                  template: "xy", limits: .replaceAll).get()
        #expect(outcome.count == 120_000)
        #expect(outcome.text == String(repeating: "xyb", count: 120_000))
    }

    @Test func replaceAllFailsRatherThanStoppingAtAFiniteCap() {
        let result = SearchEngine.replaceAll(in: "aaaa", pattern: "a", options: SearchOptions(), template: "b",
                                             limits: SearchLimits(timeLimit: 10, maxMatches: 3))
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(!error.isTimeout)
    }

    @Test func replaceAllMatchesNSRegularExpressionReplaceMatches() throws {
        struct Case { let text: String; let pattern: String; let template: String; let options: SearchOptions }
        let cases: [Case] = [
            Case(text: "name: alice\nrole: admin", pattern: "(\\w+): (\\w+)", template: "$2=$1", options: regexMode),
            Case(text: "foo bar foo", pattern: "foo", template: "<$0>", options: regexMode),
            Case(text: "price A price B", pattern: "price", template: "$1 \\n $0", options: SearchOptions()),
            Case(text: "cost $5 and $6", pattern: "$", template: "USD$", options: SearchOptions()),
            Case(text: "one\ntwo\n\nthree", pattern: "^", template: "> ", options: regexMode),
            Case(text: "baaac a", pattern: "a*", template: "-", options: regexMode),
            Case(text: "abcabc", pattern: "(?=b)", template: "|", options: regexMode),
            Case(text: "x\ny\n", pattern: "$", template: ";", options: regexMode),
            Case(text: "héllo 👋🏽 wörld 👋🏽!", pattern: "👋🏽", template: "[$0]", options: regexMode),
            Case(text: "日本語の文章、日本語。", pattern: "(日本)語", template: "$1", options: regexMode),
            Case(text: "a😀b😀c", pattern: ".", template: "<$0>", options: regexMode),
            Case(text: "Cat cat CAT", pattern: "cat", template: "dog", options: SearchOptions()),
            Case(text: "no match here", pattern: "zzz", template: "x", options: SearchOptions()),
            Case(text: "", pattern: "a*", template: "x", options: regexMode),
            Case(text: "tail", pattern: "l", template: "L\\$1", options: regexMode),
        ]
        for c in cases {
            let effective = c.options.regex ? c.pattern : NSRegularExpression.escapedPattern(for: c.pattern)
            var flags: NSRegularExpression.Options = [.anchorsMatchLines]
            if !c.options.caseSensitive { flags.insert(.caseInsensitive) }
            let regex = try NSRegularExpression(pattern: effective, options: flags)
            let mutable = NSMutableString(string: c.text)
            let template = c.options.regex ? c.template : NSRegularExpression.escapedTemplate(for: c.template)
            let expectedCount = regex.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length),
                                                     withTemplate: template)
            let outcome = try SearchEngine.replaceAll(in: c.text, pattern: c.pattern, options: c.options,
                                                      template: c.template, limits: .replaceAll).get()
            #expect(outcome.text == mutable as String, "\(c.pattern) on \(c.text)")
            #expect(outcome.count == expectedCount, "\(c.pattern) on \(c.text)")
            #expect(try SearchEngine.replaceAll(in: c.text, pattern: c.pattern, options: c.options,
                                                template: c.template).get() == mutable as String)
        }
    }

    @Test func searchErrorKeepsItsLegacyInitializerAndEquality() {
        #expect(SearchError(description: "x") == SearchError(description: "x", kind: .invalid))
        #expect(SearchError(description: "x") != SearchError(description: "x", kind: .timedOut))
        #expect(!SearchError(description: "x").isTimeout)
    }
}

// MARK: - Find bar

/// A windowed bar over a scrolling text view, the way both hosts build it.
@MainActor
private func makeScrollingBar(text: String,
                              height: CGFloat = 300) -> (FindBarController, NSTextView, NSScrollView, NSWindow) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
    scroll.hasVerticalScroller = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    scroll.documentView = textView
    textView.string = text
    let bar = FindBarController(textView: textView, lineIndex: LineIndex(text: textView.string))
    let stack = NSStackView(views: [bar.barView, scroll])
    stack.orientation = .vertical
    stack.spacing = 0
    window.contentView = stack
    bar.barView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    stack.layoutSubtreeIfNeeded()
    return (bar, textView, scroll, window)
}

@MainActor
private func search(_ bar: FindBarController, _ pattern: String) {
    bar.searchField.stringValue = pattern
    bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
}

@MainActor
private func isPainted(_ textView: NSTextView, _ index: Int) -> Bool {
    textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index,
                                               effectiveRange: nil) != nil
}

@Suite("Find bar search budgets")
@MainActor
struct FindBarBudgetTests {
    @Test func statusShowsThePlusFormWhenTheMatchCapIsHit() {
        let (bar, _, _, window) = makeScrollingBar(text: String(repeating: "x", count: 10))
        defer { window.close() }
        bar.searchLimits = SearchLimits(timeLimit: 10, maxMatches: 5)
        bar.show()
        search(bar, "x")
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPositionMore, 1, 5))
        #expect(bar.countLabel.stringValue.hasSuffix("+"))
        #expect(bar.countLabel.toolTip?.contains(L10n.t(.findIncompleteMatchLimit, 5)) == true)
        #expect(bar.countLabel.toolTip?.contains(L10n.t(.findMatchLineTooltip, 1)) == true)
        bar.findNext()
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPositionMore, 2, 5))
        // Navigation wraps within the capped list.
        for _ in 0..<4 { bar.findNext() }
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPositionMore, 1, 5))
    }

    @Test func statusShowsTimedOutWithZeroMatchesAndIncompleteOtherwise() {
        let (bar, _, _, window) = makeScrollingBar(text: catastrophicText)
        defer { window.close() }
        bar.searchLimits = SearchLimits(timeLimit: 0.05, maxMatches: 50_000)
        bar.show()
        bar.regexToggle.performClick(nil)
        search(bar, catastrophic)
        #expect(bar.countLabel.stringValue == L10n.t(.findTimedOut))
        #expect(bar.countLabel.toolTip == L10n.t(.findTimedOutTooltip))
        #expect(bar.countLabel.stringValue != L10n.t(.findNoResults))

        // A complete, empty search still says "No results".
        search(bar, "zzz")
        #expect(bar.countLabel.stringValue == L10n.t(.findNoResults))
    }

    @Test func replaceAllTimeoutLeavesTheDocumentAndUndoStackUntouched() throws {
        let (bar, textView, _, window) = makeScrollingBar(text: catastrophicText)
        defer { window.close() }
        let undo = try #require(textView.undoManager)
        undo.removeAllActions()
        bar.searchLimits = SearchLimits(timeLimit: 0.02, maxMatches: 50_000)
        bar.replaceLimits = SearchLimits(timeLimit: 0.05, maxMatches: .max)
        bar.showReplace()
        bar.regexToggle.performClick(nil)
        search(bar, catastrophic)
        bar.replaceField.stringValue = "x"
        bar.replaceAllButton.performClick(nil)
        #expect(textView.string == catastrophicText)
        #expect(!undo.canUndo)
        #expect(bar.countLabel.stringValue == L10n.t(.findTimedOut))
        #expect(bar.countLabel.toolTip == L10n.t(.findReplaceTimedOutTooltip))
        #expect(bar.countLabel.textColor == .systemRed)
    }

    @Test func replaceAllPastTheSearchCapReportsTheTrueCount() throws {
        let (bar, textView, _, window) = makeScrollingBar(text: String(repeating: "ab\n", count: 120_000))
        defer { window.close() }
        bar.showReplace()
        search(bar, "a")
        #expect(bar.countLabel.stringValue.hasSuffix("+"), "the search itself is capped at 50 000")
        bar.replaceField.stringValue = "z"
        bar.replaceAllButton.performClick(nil)
        #expect(textView.string == String(repeating: "zb\n", count: 120_000))
        #expect(bar.countLabel.stringValue == L10n.t(.findReplacedCount, 120_000))
        let undo = try #require(textView.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(textView.string == String(repeating: "ab\n", count: 120_000))
    }

    @Test func onlyVisibleMatchesArePaintedAndScrollingPaintsNewOnes() async throws {
        let line = "match here\n"
        let lineLength = (line as NSString).length
        let lines = 5_000
        let (bar, textView, scroll, window) = makeScrollingBar(text: String(repeating: line, count: lines))
        defer { window.close() }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        bar.show()
        #expect(bar.isObservingViewport)
        search(bar, "match")

        // The viewport (top of the document) is painted; far matches are not.
        #expect(isPainted(textView, 0))
        #expect(!isPainted(textView, 2_500 * lineLength))
        #expect(!isPainted(textView, (lines - 1) * lineLength))
        let painted = (0..<lines).filter { isPainted(textView, $0 * lineLength) }.count
        #expect(painted > 0 && painted < 200, "painted \(painted) of \(lines)")

        // Navigating to a far match scrolls and paints it synchronously.
        bar.findPrevious()   // wraps to the last match
        #expect(isPainted(textView, (lines - 1) * lineLength))
        #expect(!isPainted(textView, 2_500 * lineLength))

        // A plain scroll paints the newly exposed matches on the next turn.
        let target = textView.layoutManager!.boundingRect(
            forGlyphRange: textView.layoutManager!.glyphRange(
                forCharacterRange: NSRange(location: 2_500 * lineLength, length: 1), actualCharacterRange: nil),
            in: textView.textContainer!)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(isPainted(textView, 2_500 * lineLength))
        #expect(!isPainted(textView, 1_000 * lineLength))

        // Hiding clears everything and drops the observation.
        bar.hide()
        #expect(!bar.isObservingViewport)
        #expect(!isPainted(textView, 2_500 * lineLength))
        #expect(!isPainted(textView, (lines - 1) * lineLength))
        bar.show()
        #expect(bar.isObservingViewport)
        bar.hide()
    }

    @Test func paintMatchesPaintsExactlyTheIntersectingMatches() {
        let (bar, textView, _, window) = makeScrollingBar(text: "aa bb aa bb aa bb aa")
        defer { window.close() }
        bar.show()
        search(bar, "aa")   // the whole short document is visible
        #expect([0, 6, 12, 18].allSatisfy { isPainted(textView, $0) })
        // Wipe, then paint a range that only touches the second and third.
        textView.layoutManager!.removeTemporaryAttribute(.backgroundColor,
                                                          forCharacterRange: NSRange(location: 0, length: 20))
        bar.paintMatches(in: NSRange(location: 7, length: 6))
        #expect(!isPainted(textView, 0))
        #expect(isPainted(textView, 6) && isPainted(textView, 7))
        #expect(isPainted(textView, 12))
        #expect(!isPainted(textView, 18))
        #expect(!isPainted(textView, 3))
    }

    /// Timing probe for the report: a 2 MB, one-character document searched
    /// for that character through the bar (search + viewport painting).
    @Test func twoMegabyteSearchThroughTheBarIsBounded() {
        let text = String(repeating: String(repeating: "x", count: 63) + "\n", count: 32_768)
        let (bar, textView, _, window) = makeScrollingBar(text: text)
        defer { window.close() }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        bar.show()
        let clock = ContinuousClock()
        let start = clock.now
        search(bar, "x")
        let elapsed = clock.now - start
        print("[SearchBudget] 2 MB / 50 000-match search + viewport paint: \(elapsed)")
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPositionMore, 1, 50_000))
        #expect(isPainted(textView, 0))
        #expect(!isPainted(textView, 49_000))
        #expect(elapsed < .seconds(1))
    }
}
