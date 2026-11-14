import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.2 — consistency of the lexical state (plan §13 highlight acceptance):
// split invariance of the generic scanner over the pilot fixtures, the
// four-way check (head-to-tail, jump into the middle, upstream edit, undo)
// on the pure band-token path, the same through a real text view, and the
// off-screen colour cleanup.

// MARK: - Helpers

private let highlightFixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // KaruCoreTests
    .deletingLastPathComponent()   // Tests
    .appendingPathComponent("Fixtures/M17/highlight", isDirectory: true)

private func fixture(_ name: String) throws -> String {
    try String(contentsOf: highlightFixtures.appendingPathComponent(name), encoding: .utf8)
}

/// `text` repeated until it is longer than `minimum` UTF-16 units.
private func repeated(_ text: String, longerThan minimum: Int) -> String {
    let unit = text.hasSuffix("\n") ? text : text + "\n"
    let copies = minimum / (unit as NSString).length + 1
    return String(repeating: unit, count: copies)
}

/// Deterministic generator (SplitMix64) so failures reproduce.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func isWordUnit(_ u: unichar) -> Bool {
    u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u)
}

/// A split point the scanner guarantees to be invariant for (see
/// `LexicalScanner`): a line start; after a space or tab (unless a `'` atom
/// starts there); or inside a word whose neighbours cannot make it part of an
/// opener, closer, prefix or atom (not after `'` or `"`, not before `"`, `'`
/// or `#`) — and never in `interiors` (see `tokenInteriors`).
private func isSafeSplit(_ ns: NSString, _ p: Int, interiors: Set<Int> = []) -> Bool {
    guard p > 0, p < ns.length else { return true }
    if interiors.contains(p) { return false }
    let prev = ns.character(at: p - 1), cur = ns.character(at: p)
    if prev == 10 { return true }
    if prev == 32 || prev == 9 { return cur != 39 }
    guard isWordUnit(prev), isWordUnit(cur) else { return false }
    var s = p - 1
    while s > 0, isWordUnit(ns.character(at: s - 1)) { s -= 1 }
    var e = p
    while e < ns.length, isWordUnit(ns.character(at: e)) { e += 1 }
    if s > 0, [UInt16(39), 34].contains(ns.character(at: s - 1)) { return false }
    if e < ns.length, [UInt16(34), 39, 35].contains(ns.character(at: e)) { return false }
    return true
}

/// Positions strictly inside a token a word-level split could still cut:
/// any occurrence of a multi-unit delimiter of `profile` (comment openers and
/// closers, fixed string delimiters, interpolation openers — `<![CDATA[` has
/// a word inside), and the atoms of the single pass `segments` (a JS regex
/// literal can contain words).
private func tokenInteriors(_ ns: NSString, _ profile: LexicalProfile,
                            segments: [(NSRange, LexicalSegment)]) -> Set<Int> {
    var delimiters = profile.lineComments
    for block in profile.blockComments { delimiters += [block.open, block.close] }
    for form in profile.strings {
        if case .fixed(let open, let close) = form.delimiter { delimiters += [open, close] }
        for interpolation in form.interpolations {
            delimiters.append(interpolation.open)
            if let escaped = interpolation.escapedOpen { delimiters.append(escaped) }
        }
    }
    var out = Set<Int>()
    for delimiter in Set(delimiters) where (delimiter as NSString).length > 1 {
        let length = (delimiter as NSString).length
        var from = 0
        while from < ns.length {
            let hit = ns.range(of: delimiter, options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard hit.location != NSNotFound else { break }
            for k in 1..<length { out.insert(hit.location + k) }
            from = hit.location + 1
        }
    }
    for (range, kind) in segments {
        guard case .atom = kind else { continue }
        for k in 1..<max(1, range.length) { out.insert(range.location + k) }
    }
    return out.union(lineBlockInteriors(ns, profile))
}

/// Positions strictly inside a line-block token (`LexicalScanner` "Split
/// guarantee"), over-approximated from the text alone: heredoc openers and
/// every line that could be a terminator (through its line break unit),
/// block-scalar indicators and every line's leading blanks through the first
/// other unit, fence openers' leading spaces and marker runs and every line
/// that could close a fence (through its line break unit).
private func lineBlockInteriors(_ ns: NSString, _ profile: LexicalProfile) -> Set<Int> {
    var out = Set<Int>()
    func insert(_ regex: String, options: NSRegularExpression.Options = [.anchorsMatchLines],
                through: Bool = false) {
        let re = try! NSRegularExpression(pattern: regex, options: options)
        for match in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            let last = through ? NSMaxRange(r) : NSMaxRange(r) - 1
            if last >= r.location + 1 { for k in (r.location + 1)...last { out.insert(k) } }
        }
    }
    for form in profile.lineBlocks {
        switch form {
        case .heredoc:
            insert(#"<<<|<<-?[ \t]*(?:'[A-Za-z_]\w*'|"[A-Za-z_]\w*"|\\?[A-Za-z_]\w*)"#)
            insert(#"^\t*[A-Za-z_]\w*$"#, through: true)
        case .indentedBlock:
            insert(#"[|>][-+1-9]{0,2}"#)
            insert(#"^[ \t]*"#, through: true)
        case .fence:
            insert(#"^ {0,3}(?:`{3,}|~{3,})"#)
            insert(#"^ {0,3}(?:`{3,}|~{3,})[ \t]*$"#, through: true)
        }
    }
    return out
}

/// Merges adjacent runs of the same kind (each call emits maximal runs of
/// its own range only).
private func merged(_ segments: [(NSRange, LexicalSegment)]) -> [(NSRange, LexicalSegment)] {
    var out: [(NSRange, LexicalSegment)] = []
    for (range, kind) in segments {
        if let last = out.last, last.1 == kind, NSMaxRange(last.0) == range.location {
            out[out.count - 1].0.length += range.length
        } else {
            out.append((range, kind))
        }
    }
    return out
}

/// Token kind per UTF-16 unit of `range` (nil where no token).
private func unitKinds(_ tokens: [(range: NSRange, kind: TokenKind)], in range: NSRange) -> [TokenKind?] {
    var out = [TokenKind?](repeating: nil, count: range.length)
    for token in tokens {
        let clipped = NSIntersectionRange(token.range, range)
        guard clipped.length > 0 else { continue }
        for i in clipped.location..<NSMaxRange(clipped) { out[i - range.location] = token.kind }
    }
    return out
}

private func lineStart(_ ns: NSString, near offset: Int) -> Int {
    ns.lineRange(for: NSRange(location: min(max(offset, 0), ns.length - 1), length: 0)).location
}

/// Whole lines from the line containing `start` through the line containing
/// `start + length`.
private func lineBand(_ ns: NSString, from start: Int, length: Int) -> NSRange {
    let s = lineStart(ns, near: start)
    let endLine = ns.lineRange(for: NSRange(location: min(s + length, ns.length - 1), length: 0))
    return NSRange(location: s, length: NSMaxRange(endLine) - s)
}

private func firstDifference(_ a: [TokenKind?], _ b: [TokenKind?]) -> Int? {
    if a.count != b.count { return min(a.count, b.count) }
    return zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset
}

/// A document longer than 4.5 × spacing made of fixture copies after a
/// whitespace-only padding line, the padding chosen so that a line
/// beginning with `anchor` lies at most `reach` units before the second
/// checkpoint a jump to 70 % records. An edit there then changes the
/// state *at* that checkpoint even in a language whose state resyncs
/// within about one fixture copy (JS), so resuming from un-invalidated
/// checkpoints would visibly go wrong. With `opener` (profiled languages),
/// the layout is only accepted when inserting it at the anchor really
/// changes the scanner state at that checkpoint — needed where the opened
/// construct ends within a few hundred units (a C block comment); `step` is
/// the padding increment.
private func editLayout(_ text: String, def: LanguageDefinition, anchor: String,
                        reach: Int = 2_500, opener: String? = nil,
                        step: Int = 500) throws -> (doc: String, checkpoint: Int, editAt: Int) {
    let spacing = CheckpointStore.spacing
    let body = repeated(text, longerThan: 4 * spacing + spacing / 2)
    for pad in stride(from: 0, to: 14_000, by: step) {
        let doc = String(repeating: " ", count: pad) + "\n" + body
        let ns = doc as NSString
        var store = CheckpointStore()
        let probe = lineBand(ns, from: Int(Double(ns.length) * 0.7), length: 1)
        _ = HighlightEngine.bandTokens(in: ns, range: probe, language: def, checkpoints: &store)
        guard store.entries.count >= 3 else { continue }
        let checkpoint = store.entries[1].offset
        let hit = ns.range(of: "\n" + anchor, options: [.literal, .backwards],
                           range: NSRange(location: 0, length: checkpoint - 64))
        guard hit.location != NSNotFound, checkpoint - (hit.location + 1) <= reach,
              hit.location + 1 > store.entries[0].offset else { continue }
        if let opener, let scanner = def.lexicalScanner {
            let edited = NSMutableString(string: doc)
            edited.insert(opener, at: hit.location + 1)
            var before = LexicalScanState(), after = LexicalScanState()
            scanner.advance(ns, from: 0, to: checkpoint, state: &before)
            scanner.advance(edited, from: 0, to: checkpoint + (opener as NSString).length, state: &after)
            guard before != after else { continue }
        }
        return (doc, checkpoint, hit.location + 1)
    }
    throw CocoaError(.featureUnsupported)
}

// MARK: - Split invariance

@Suite("LexicalConsistency")
struct LexicalConsistencyTests {
    /// Every profiled language's fixture (JSON / JSONL have no multi-line
    /// constructs and are covered by the long-line suite).
    static let pilots: [(file: String, language: String)] = [
        ("javascript.js", "javascript"), ("typescript.ts", "typescript"), ("rust.rs", "rust"),
        ("c.c", "c"), ("cpp.cpp", "cpp"), ("csharp.cs", "csharp"), ("java.java", "java"), ("go.go", "go"),
        ("css.css", "css"), ("sql.sql", "sql"), ("swift.swift", "swift"), ("toml.toml", "toml"),
        ("html.html", "html"), ("xml.xml", "xml"), ("bash.sh", "bash"), ("yaml.yaml", "yaml"),
        ("markdown.md", "markdown"), ("embedded/fences.md", "markdown"),
    ]

    @Test(arguments: pilots)
    func randomSplitsGiveTheSameStateAndSegments(_ pilot: (file: String, language: String)) throws {
        let def = try #require(LanguageRegistry.definition(forIdentifier: pilot.language))
        let scanner = try #require(def.lexicalScanner)
        // Two copies, so the second starts in whatever state the first left.
        let text = try fixture(pilot.file)
        let ns = (text + "\n" + text) as NSString

        var oneState = LexicalScanState()
        var one: [(NSRange, LexicalSegment)] = []
        scanner.segments(ns, from: 0, to: ns.length, state: &oneState) { one.append(($0, $1)) }
        #expect(one.contains { $0.1 == .comment } || pilot.file == "embedded/fences.md")
        #expect(scanner.profile.strings.isEmpty || one.contains { $0.1 == .string })
        #expect(scanner.profile.lineBlocks.isEmpty || one.contains { if case .block = $0.1 { true } else { false } })

        let interiors = tokenInteriors(ns, scanner.profile, segments: one)
        let safe = (1..<ns.length).filter { isSafeSplit(ns, $0, interiors: interiors) }
        #expect(safe.count > ns.length / 3, "too few safe split points: \(safe.count)")
        var rng = SplitMix(state: 0x17_2_0_5EED)
        for trial in 0..<150 {
            let k = Int.random(in: 1...6, using: &rng)
            let points = Set((0..<k).map { _ in safe.randomElement(using: &rng)! }).sorted()
            var state = LexicalScanState()
            var advanced = LexicalScanState()
            var pieces: [(NSRange, LexicalSegment)] = []
            var from = 0
            for to in points + [ns.length] {
                scanner.segments(ns, from: from, to: to, state: &state) { pieces.append(($0, $1)) }
                scanner.advance(ns, from: from, to: to, state: &advanced)
                from = to
            }
            #expect(state == oneState, "trial \(trial): end state differs for splits \(points)")
            #expect(advanced == oneState, "trial \(trial): advance end state differs for splits \(points)")
            let joined = merged(pieces)
            let same = joined.count == one.count && zip(joined, one).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            #expect(same, "trial \(trial): segments differ for splits \(points)")
            if !same { break }
        }

        // Every line start at once (what checkpoints and the highlighter use).
        var lineState = LexicalScanState()
        var lines: [(NSRange, LexicalSegment)] = []
        var loc = 0
        while loc < ns.length {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0)))
            scanner.segments(ns, from: loc, to: end, state: &lineState) { lines.append(($0, $1)) }
            loc = end
        }
        #expect(lineState == oneState)
        #expect(merged(lines).map(\.0) == one.map(\.0))
    }

    // MARK: - Four-way consistency (pure band path)

    /// Each edit inserts `opener` at the start of the line that begins with
    /// `anchor` (the first such line before a checkpoint, see `editLayout`):
    /// a template / comment opener on a blank line, an interpolation opener
    /// typed into a template / f-string body line, a nesting comment opener.
    ///
    /// T17.3 languages: a C block comment opened in `main` (closed by the next
    /// copy's first line), a C++ raw string that never closes, a C# raw
    /// string and a Java text block that re-pair the triple quotes below, a
    /// Go raw string re-pairing the backticks, a CSS comment, an SQL string
    /// re-pairing the quotes, a nesting Swift comment that never closes, a
    /// TOML literal block, an HTML comment and an XML CDATA section.
    ///
    /// T17.3b: a Bash heredoc whose terminator never comes, a YAML quoted
    /// scalar that re-pairs the quotes below, and Markdown fences longer
    /// than any closer in the document.
    static let fourWay: [(file: String, language: String, opener: String, anchor: String)] = [
        ("javascript.js", "javascript", "`", "\nfunction priceLabel"),
        ("typescript.ts", "typescript", "${", "User: ${user.name}"),
        ("rust.rs", "rust", "/*", "//! Config loader"),
        ("python.py", "python", "{", "    <h1>{title.upper()}"),
        ("c.c", "c", "/*", "int main(void)"),
        ("cpp.cpp", "cpp", "R\"zz(", "int main() {"),
        ("csharp.cs", "csharp", "\"\"\"", "    public string Summary()"),
        ("java.java", "java", "\"\"\"", "    public String render(String title) {"),
        ("go.go", "go", "`", "func main() {"),
        ("css.css", "css", "/*", "a[href^="),
        ("sql.sql", "sql", "'", "INSERT INTO"),
        ("swift.swift", "swift", "/*", "struct Greeter {"),
        ("toml.toml", "toml", "'''", "[server]"),
        ("html.html", "html", "<!--", "  <footer>"),
        ("xml.xml", "xml", "<![CDATA[", "  </item>"),
        ("bash.sh", "bash", "cat <<ZZZ ", "usage() {"),
        ("yaml.yaml", "yaml", "\"", "jobs:"),
        ("markdown.md", "markdown", "````", "### Code"),
        ("embedded/fences.md", "markdown", "`````", "Bash:"),
    ]

    /// Reference = one sequential pass from offset 0. (i) Head-to-tail (bands
    /// in order, shared checkpoints) and jumping into the middle with an empty
    /// store give the reference band; (ii) an upstream edit that changes the
    /// lexical state, with `CheckpointStore.invalidate`, gives a fresh pass
    /// over the edited text — both just after the next checkpoint (where the
    /// state changed) and far below — while resuming from the un-invalidated
    /// store would not; (iii) undoing it gives the reference again.
    @Test(arguments: fourWay)
    func headToTailJumpEditAndUndoAgree(_ sample: (file: String, language: String, opener: String, anchor: String)) throws {
        let def = try #require(LanguageRegistry.definition(forIdentifier: sample.language))
        let spacing = CheckpointStore.spacing
        // Pilots keep their T17.2 layout; T17.3 languages search finer and
        // require the opener to change the state at the checkpoint.
        let pilot = ["javascript", "typescript", "rust", "python"].contains(sample.language)
        let layout = try editLayout(try fixture(sample.file), def: def, anchor: sample.anchor,
                                    opener: pilot ? nil : sample.opener, step: pilot ? 500 : 100)
        let doc = layout.doc
        let ns = doc as NSString
        #expect(ns.length > 4 * spacing)

        func tokens(_ text: NSString, _ range: NSRange, _ store: inout CheckpointStore) -> [(range: NSRange, kind: TokenKind)] {
            HighlightEngine.bandTokens(in: text, range: range, language: def, checkpoints: &store)
        }
        func reference(_ text: NSString, _ band: NSRange) -> [TokenKind?] {
            var none = CheckpointStore()
            let all = tokens(text, NSRange(location: 0, length: NSMaxRange(band)), &none)
            #expect(none.entries.isEmpty)   // a pass from 0 never resumes
            return unitKinds(all, in: band)
        }
        func describe(_ a: [TokenKind?], _ b: [TokenKind?], _ band: NSRange) -> String {
            firstDifference(a, b).map { "first difference at \(band.location + $0)" } ?? "equal"
        }

        let band = lineBand(ns, from: Int(Double(ns.length) * 0.7), length: 12_000)
        let near = lineBand(ns, from: layout.checkpoint + 1, length: 6_000)
        let expected = reference(ns, band)
        let expectedNear = reference(ns, near)
        #expect(expected.contains(.string) || expected.contains(.comment))

        // (i a) Head to tail: consecutive bands, checkpoints shared.
        var scrolled = CheckpointStore()
        var top = 0
        while top < band.location {
            let step = lineBand(ns, from: top, length: 20_000)
            _ = tokens(ns, step, &scrolled)
            top = NSMaxRange(step)
        }
        let headToTail = unitKinds(tokens(ns, band, &scrolled), in: band)
        #expect(firstDifference(headToTail, expected) == nil, "head-to-tail: \(describe(headToTail, expected, band))")
        #expect(scrolled.entries.count >= 3)

        // (i b) Jump into the middle with an empty store.
        var store = CheckpointStore()
        let jumped = unitKinds(tokens(ns, band, &store), in: band)
        #expect(firstDifference(jumped, expected) == nil, "jump: \(describe(jumped, expected, band))")
        #expect(store.entries.count >= 3)

        // (ii) Upstream edit between the first two checkpoints: the first one
        // survives the invalidation, the rest are dropped.
        let edited = NSMutableString(string: doc)
        let inserted = (sample.opener as NSString).length
        edited.insert(sample.opener, at: layout.editAt)
        let stale = store
        store.invalidate(editedRange: NSRange(location: layout.editAt, length: inserted),
                         changeInLength: inserted, in: edited)
        #expect(store.entries.count == 1 && store.entries[0].offset < layout.editAt)
        func shifted(_ r: NSRange) -> NSRange { NSRange(location: r.location + inserted, length: r.length) }

        let freshNear = reference(edited, shifted(near))
        var nearStore = store
        let afterEditNear = unitKinds(tokens(edited, shifted(near), &nearStore), in: shifted(near))
        #expect(firstDifference(afterEditNear, freshNear) == nil, "after edit (near): \(describe(afterEditNear, freshNear, shifted(near)))")
        // The edit really changes this band, and stale checkpoints would miss it.
        #expect(freshNear != expectedNear, "the edit did not change the band after the checkpoint")
        var staleStore = stale
        let fromStale = unitKinds(tokens(edited, shifted(near), &staleStore), in: shifted(near))
        #expect(fromStale != freshNear, "stale checkpoints happen to give the right answer")

        let freshFar = reference(edited, shifted(band))
        let afterEditFar = unitKinds(tokens(edited, shifted(band), &store), in: shifted(band))
        #expect(firstDifference(afterEditFar, freshFar) == nil, "after edit (far): \(describe(afterEditFar, freshFar, shifted(band)))")

        // (iii) Undo.
        edited.deleteCharacters(in: NSRange(location: layout.editAt, length: inserted))
        #expect(edited as String == doc)
        store.invalidate(editedRange: NSRange(location: layout.editAt, length: 0),
                         changeInLength: -inserted, in: edited)
        let undoneNear = unitKinds(tokens(edited, near, &store), in: near)
        let undone = unitKinds(tokens(edited, band, &store), in: band)
        #expect(firstDifference(undoneNear, expectedNear) == nil, "after undo (near): \(describe(undoneNear, expectedNear, near))")
        #expect(firstDifference(undone, expected) == nil, "after undo: \(describe(undone, expected, band))")
    }

    // MARK: - Off-screen cleanup arithmetic

    @Test func rangeDifferenceAndHeldRangeMapping() {
        #expect(HighlightEngine.ranges(NSRange(location: 10, length: 90), minus: NSRange(location: 40, length: 20),
                                       clampedTo: 1_000) == [NSRange(location: 10, length: 30), NSRange(location: 60, length: 40)])
        #expect(HighlightEngine.ranges(NSRange(location: 10, length: 20), minus: NSRange(location: 500, length: 20),
                                       clampedTo: 1_000) == [NSRange(location: 10, length: 20)])
        #expect(HighlightEngine.ranges(NSRange(location: 10, length: 20), minus: NSRange(location: 0, length: 100),
                                       clampedTo: 1_000).isEmpty)
        #expect(HighlightEngine.ranges(NSRange(location: 10, length: 200), minus: NSRange(location: 0, length: 5),
                                       clampedTo: 50) == [NSRange(location: 10, length: 40)])

        let held = NSRange(location: 100, length: 50)
        // Insertion before: shifted.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 10, length: 5), delta: 5)
                == NSRange(location: 105, length: 50))
        // Deletion before: shifted back.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 10, length: 0), delta: -5)
                == NSRange(location: 95, length: 50))
        // Insertion inside: grows.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 120, length: 7), delta: 7)
                == NSRange(location: 100, length: 57))
        // Insertion touching the end: widened over the inserted text.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 150, length: 4), delta: 4)
                == NSRange(location: 100, length: 54))
        // Insertion after: unchanged.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 400, length: 4), delta: 4) == held)
        // Deletion across the start: clamps to the edit.
        #expect(HighlightEngine.heldRange(held, afterEditing: NSRange(location: 90, length: 0), delta: -20)
                == NSRange(location: 90, length: 40))
    }
}

// MARK: - Engine level (real text view)

@MainActor
private func pump(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// A standalone engine (private analysis) on a windowed text view with undo.
@MainActor
private final class Painter {
    let center = NotificationCenter()
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let engine: HighlightEngine

    init(text: String, language: String) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView = NSScrollView(frame: frame)
        textView = EditorTextView(frame: frame)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        let name = "LexicalConsistencyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        engine = HighlightEngine(textView: textView, scrollView: scrollView,
                                 moduleSettings: ModuleSettings(defaults: defaults, center: center),
                                 moduleCenter: center)
        hub.add(engine)
        textView.textStorage?.delegate = hub
        engine.setLanguage(identifier: language)
    }

    var length: Int { (textView.string as NSString).length }

    /// Scrolls `offset` into view and repaints synchronously.
    func paint(at offset: Int) {
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        engine.appearanceDidChange()
    }

    /// An undoable edit through the text view (as typing would register it).
    func replace(_ range: NSRange, with string: String) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }

    /// Foreground colour identity per UTF-16 unit of `range`.
    func colours(in range: NSRange) -> [ObjectIdentifier?] {
        let lm = textView.layoutManager!
        var out: [ObjectIdentifier?] = []
        out.reserveCapacity(range.length)
        var index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange(location: 0, length: 0)
            let colour = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                               longestEffectiveRange: &effective, in: range)
            let id = (colour as? NSColor).map { ObjectIdentifier($0) }
            let end = max(index + 1, NSMaxRange(effective))
            out += Array(repeating: id, count: end - index)
            index = end
        }
        return out
    }

    /// Number of foreground runs (and coloured units) inside `range`.
    func foregroundRuns(in range: NSRange) -> (runs: Int, units: Int) {
        guard range.length > 0 else { return (0, 0) }
        let lm = textView.layoutManager!
        var runs = 0, units = 0, index = range.location
        while index < NSMaxRange(range) {
            var effective = NSRange(location: 0, length: 0)
            let value = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                              longestEffectiveRange: &effective, in: range)
            let end = max(index + 1, NSMaxRange(effective))
            if value != nil { runs += 1; units += end - index }
            index = end
        }
        return (runs, units)
    }

    /// Foreground runs outside the painted band.
    func runsOutsideBand() -> Int {
        guard let band = engine.paintedRange else { return foregroundRuns(in: NSRange(location: 0, length: length)).runs }
        return foregroundRuns(in: NSRange(location: 0, length: band.location)).runs
            + foregroundRuns(in: NSRange(location: NSMaxRange(band), length: length - NSMaxRange(band))).runs
    }
}

@Suite("LexicalConsistencyEngine", .serialized)
@MainActor
struct LexicalConsistencyEngineTests {
    init() { _ = NSApplication.shared }

    /// Colours `painter` holds over the overlap of its band and a fresh
    /// engine's band painted at the same offset over the same text.
    private func expectMatchesFresh(_ painter: Painter, at offset: Int, _ label: String,
                                    language: String = "javascript",
                                    sourceLocation: SourceLocation = #_sourceLocation) -> [ObjectIdentifier?] {
        painter.paint(at: offset)
        let fresh = Painter(text: painter.textView.string, language: language)
        fresh.paint(at: offset)
        guard let a = painter.engine.paintedRange, let b = fresh.engine.paintedRange else {
            Issue.record("\(label): nothing painted", sourceLocation: sourceLocation)
            return []
        }
        let overlap = NSIntersectionRange(a, b)
        #expect(overlap.length > 1_000, "\(label): overlap \(overlap)", sourceLocation: sourceLocation)
        #expect(NSLocationInRange(offset, overlap), "\(label): target not in \(overlap)", sourceLocation: sourceLocation)
        let mine = painter.colours(in: overlap)
        let theirs = fresh.colours(in: overlap)
        let diff = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(diff == nil, "\(label): colours differ at \(overlap.location + (diff ?? 0))",
                sourceLocation: sourceLocation)
        let comment = HighlightTheme().color(for: .comment).map { ObjectIdentifier($0) }
        let string = HighlightTheme().color(for: .string).map { ObjectIdentifier($0) }
        #expect(mine.contains(comment) || mine.contains(string), "\(label): band lacks comment and string colour",
                sourceLocation: sourceLocation)
        return mine
    }

    @Test func javascriptBandColoursAgreeAcrossScrollJumpEditAndUndo() async throws {
        let layout = try editLayout(try fixture("javascript.js"), def: JavaScriptLanguage.make(),
                                    anchor: "\nfunction priceLabel")
        let text = layout.doc

        // Scrolled from the top in steps (checkpoints recorded on the way)…
        let scrolled = Painter(text: text, language: "javascript")
        let length = scrolled.length
        for tenth in 0...7 { scrolled.paint(at: length * tenth / 10) }
        #expect(scrolled.engine.analysis.checkpoints.entries.map(\.offset).contains(layout.checkpoint))
        // …equals a jump straight into the middle (fresh engine, no checkpoints),
        // both just after a checkpoint and far below.
        let target = layout.checkpoint + 2_500
        let probe = NSRange(location: layout.checkpoint + 1_000, length: 2_000)
        _ = expectMatchesFresh(scrolled, at: target, "scroll vs jump")
        let original = scrolled.colours(in: probe)
        _ = expectMatchesFresh(scrolled, at: Int(Double(length) * 0.8), "scroll vs jump (far)")

        // Upstream edit through the text view: a backtick on a blank line
        // opens a template that re-pairs the backticks below it.
        scrolled.replace(NSRange(location: layout.editAt, length: 0), with: "`")
        #expect(scrolled.engine.analysis.checkpoints.entries.allSatisfy { $0.offset < layout.editAt })
        await pump(0.3)   // the edit's declaration rescan lands
        _ = expectMatchesFresh(scrolled, at: target + 1, "after edit")
        let edited = scrolled.colours(in: NSRange(location: probe.location + 1, length: probe.length))
        #expect(edited != original, "the edit did not change the colours after the checkpoint")
        _ = expectMatchesFresh(scrolled, at: Int(Double(length) * 0.8) + 1, "after edit (far)")

        // Undo through the text view's undo manager.
        let undo = try #require(scrolled.textView.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(scrolled.textView.string == text)
        await pump(0.3)
        _ = expectMatchesFresh(scrolled, at: target, "after undo")
        #expect(scrolled.colours(in: probe) == original)
        _ = expectMatchesFresh(scrolled, at: Int(Double(length) * 0.8), "after undo (far)")
    }

    /// T17.3b line blocks: an edit inside a Bash heredoc terminator line
    /// (`EOF` → `EOFX`: the body runs on to the next terminator) and inside
    /// a YAML block scalar's dedent line (indented: the indented mapping below
    /// joins the block), then undo — each repaint equals a fresh engine's
    /// full scan, near the edit and far below, and the edit really changes
    /// the colours there. Both layouts put the edited line before a
    /// checkpoint whose state the edit changes (`editLayout`).
    nonisolated static let lineBlockEdits: [(language: String, anchor: String, opener: String, column: Int, insert: String)] = [
        ("bash", "EOF\n}\n\nwrite_config", "X", 3, "X"),
        ("yaml", "next:", "  ", 0, "  "),
    ]

    @Test(arguments: lineBlockEdits)
    func lineBlockEditsRepaintLikeAFreshScan(
        _ sample: (language: String, anchor: String, opener: String, column: Int, insert: String)
    ) async throws {
        let def = try #require(LanguageRegistry.definition(forIdentifier: sample.language))
        let source: String
        if sample.language == "yaml" {
            // A block scalar whose dedent line `next:` owns a long indented
            // mapping (the fixture, indented by two).
            let indented = try fixture("yaml.yaml").split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : "  " + $0 }.joined(separator: "\n")
            source = "top: |\n  text\nnext:\n" + indented
        } else {
            source = try fixture("bash.sh")
        }
        let layout = try editLayout(source, def: def, anchor: sample.anchor, opener: sample.opener, step: 100)
        let text = layout.doc
        let language = sample.language

        let painter = Painter(text: text, language: language)
        let length = painter.length
        for tenth in 0...7 { painter.paint(at: length * tenth / 10) }
        #expect(painter.engine.analysis.checkpoints.entries.map(\.offset).contains(layout.checkpoint))
        let target = layout.checkpoint + 64
        let probe = NSRange(location: layout.editAt + 40, length: layout.checkpoint + 200 - (layout.editAt + 40))
        _ = expectMatchesFresh(painter, at: target, "\(language): scroll vs jump", language: language)
        let original = painter.colours(in: probe)

        let editAt = layout.editAt + sample.column
        let inserted = (sample.insert as NSString).length
        painter.replace(NSRange(location: editAt, length: 0), with: sample.insert)
        #expect(painter.engine.analysis.checkpoints.entries.allSatisfy { $0.offset < layout.editAt })
        await pump(0.3)
        _ = expectMatchesFresh(painter, at: target + inserted, "\(language): after edit", language: language)
        let edited = painter.colours(in: NSRange(location: probe.location + inserted, length: probe.length))
        #expect(edited != original, "\(language): the edit did not change the colours")
        _ = expectMatchesFresh(painter, at: Int(Double(length) * 0.8), "\(language): after edit (far)",
                               language: language)

        let undo = try #require(painter.textView.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(painter.textView.string == text)
        await pump(0.3)
        _ = expectMatchesFresh(painter, at: target, "\(language): after undo", language: language)
        #expect(painter.colours(in: probe) == original)
        _ = expectMatchesFresh(painter, at: Int(Double(length) * 0.8), "\(language): after undo (far)",
                               language: language)
    }

    @Test func colourIsHeldOnlyInTheCurrentBand() async throws {
        let text = repeated(try fixture("javascript.js"), longerThan: 400_000)
        let painter = Painter(text: text, language: "javascript")
        let length = painter.length
        for fraction in [0.0, 0.5, 0.95, 0.25, 0.75] {
            painter.paint(at: Int(Double(length) * fraction))
            let band = try #require(painter.engine.paintedRange)
            #expect(painter.foregroundRuns(in: band).runs > 0, "nothing painted at \(fraction)")
            #expect(painter.runsOutsideBand() == 0, "colour left outside the band after painting at \(fraction)")
            #expect(painter.engine.colouredRange == band)
        }
        // After an edit (positions shift; the held span is mapped through it)
        // the next band still leaves nothing behind.
        painter.replace(NSRange(location: 10, length: 0), with: "/* x */\n")
        await pump(0.3)
        painter.paint(at: Int(Double(painter.length) * 0.4))
        #expect(painter.runsOutsideBand() == 0)
        painter.replace(NSRange(location: Int(Double(painter.length) * 0.41), length: 30), with: "")
        await pump(0.3)
        painter.paint(at: 0)
        #expect(painter.runsOutsideBand() == 0)
    }
}
