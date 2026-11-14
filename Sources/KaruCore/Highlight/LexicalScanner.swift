import Foundation

/// The generic lexical scanner (M17 T17.2, plan §4): executes a
/// `LexicalProfile` over an `NSString` range, carrying a `LexicalScanState`.
///
/// Two modes over the same core:
/// - `advance` only updates the state (checkpoints, jumping into a document).
///   Ordinary code, comment and string text is skipped with
///   `rangeOfCharacter(from:)` marker searches, so the per-unit work is
///   limited to the few characters that can start or end a construct.
/// - `segments` additionally reports maximal runs of `LexicalSegment`s with
///   absolute ranges.
///
/// **Ranges.** Both accept any `[from, to)`, not necessarily line-aligned. The
/// scanner never reads at or beyond `to`; it may read *before* `from`, but
/// only the single unit in front of a string / atom prefix (the word-boundary
/// guard), an atom's lookbehind context (16 units), an atom's `precededBy`
/// context (up to `LexicalProfile.AtomContext.reach` units of whitespace,
/// then the unit or word before it) or, when stopping at a safe point, the
/// unit in front of `from` itself. The atom reads depend on the text alone,
/// never on the state, so they cannot break the split guarantee below.
///
/// **Split guarantee.** For a split point `b` in `[a, c)`, scanning `a..<b`
/// then `b..<c` gives the same end state as scanning `a..<c`, and the
/// concatenated segments equal the single pass's after merging adjacent runs
/// of the same kind (each call emits maximal runs *within its own range*) —
/// provided `b` does not fall strictly inside a token: an opener (including a
/// string prefix, lead and hashes), a closer, an escape sequence, an
/// interpolation delimiter, an atom match or a surrogate pair. Line starts
/// are always safe (no token crosses a line break: escape + newline counts as
/// one escape).
///
/// **Safe points** (long-line slicing, plan §6 item 2) are what the
/// `stoppingAtSafePointFrom:` variants return: a token boundary that is also
/// not inside a surrogate pair, an identifier run or a CRLF, and — in code —
/// not right after a unit that a later token's backward lookback (string
/// prefix, hashed lead / hashes, C++ `R`, atom prefix) could include. Resuming
/// there floors those lookbacks at the safe point instead of at the single
/// pass's earlier code start, so this last condition keeps them identical.
/// Checkpoints and the highlighter split only at line starts and at returned
/// safe points.
///
/// **Lines.** CR, LF and CRLF terminate lines. A line comment, and a
/// single-line string not continued by escape + newline, end at the
/// terminator; when the terminator is reached inside an interpolation, the
/// innermost single-line string that has no multi-line construct above it is
/// closed together with everything above it.
///
/// **Depth.** At most `LexicalScanState.maximumDepth` frames. An opener met at
/// the cap is not opened (its characters stay code / content); a nesting
/// block comment counts depth inside one frame and is not limited by the cap.
public struct LexicalScanner: Sendable {
    public let profile: LexicalProfile

    // MARK: - Compiled profile

    private struct Block: Sendable {
        let open: [unichar]
        let close: [unichar]
        let closeString: String
        let nests: Bool
        let markers: CharacterSet
    }

    private enum Opening: Sendable {
        case fixed(open: [unichar], close: [unichar])
        case repeated(quote: unichar, minimum: Int)
        case hashed(lead: [unichar], hash: unichar, quote: [unichar], hashesApplyToEscapes: Bool)
        case cppRaw
    }

    private struct Interpolation: Sendable {
        let open: [unichar]
        let close: unichar
        let escapedOpen: [unichar]?
        /// The opener starts with the string's escape character (`\(`).
        let escapeLed: Bool
    }

    private struct StringSpec: Sendable {
        let prefixes: [[unichar]]          // longest first
        let prefixRequired: Bool
        let prefixCaseInsensitive: Bool
        let opening: Opening
        /// The code character that triggers an opening attempt.
        let anchor: unichar
        /// The content character that triggers a closing attempt.
        let closeAnchor: unichar
        let multiline: Bool
        let escape: unichar?
        let doubledCloseEscapes: Bool
        let interpolations: [Interpolation]
        let contentMarkers: CharacterSet
    }

    /// `NSRegularExpression` is immutable and documented thread-safe.
    private struct RegexBox: @unchecked Sendable {
        let regex: NSRegularExpression
    }

    /// Compiled `LexicalProfile.AtomContext`.
    private struct AtomContext: Sendable {
        let characters: Set<unichar>
        let words: Set<[unichar]>
        let longestWord: Int
    }

    private struct Atom: Sendable {
        let regex: RegexBox
        let first: Set<unichar>
        let kind: TokenKind
        let prefixes: [[unichar]]          // longest first
        let context: AtomContext?
    }

    private let lineComments: [[unichar]]
    private let blocks: [Block]
    private let strings: [StringSpec]
    private let atoms: [Atom]
    private let codeMarkers: CharacterSet
    private let interpolationMarkers: CharacterSet
    /// Units a backward lookback in code may include (see "Safe points").
    private let lookbackUnits: CharacterSet
    private static let lineBreaks = CharacterSet(charactersIn: "\r\n")

    private static let cr: unichar = 13
    private static let lf: unichar = 10

    /// Longest lookahead an atom match may use (atoms are short tokens on
    /// one line).
    private static let atomWindow = 512
    /// Context kept before an atom so `\b` and short lookbehinds work.
    private static let atomLookbehind = 16
    /// How far ahead of a token boundary a safe-point search looks for the
    /// next marker before falling back to scanning one more token.
    private static let safePointWindow = 256

    public init(profile: LexicalProfile) {
        precondition(profile.blockComments.count < 256 && profile.strings.count < 256
                         && profile.strings.allSatisfy { $0.interpolations.count < 256 },
                     "LexicalProfile: at most 255 block comment / string / interpolation forms")
        self.profile = profile

        func units(_ s: String) -> [unichar] { Array(s.utf16) }
        func unit(_ c: Character) -> unichar {
            let u = Array(String(c).utf16)
            precondition(u.count == 1, "LexicalProfile: single UTF-16 unit expected, got \(c)")
            return u[0]
        }
        func set(_ us: [unichar]) -> CharacterSet {
            var cs = CharacterSet()
            for u in us { if let s = Unicode.Scalar(u) { cs.insert(s) } }
            return cs
        }
        func longestFirst(_ ps: [String]) -> [[unichar]] {
            ps.filter { !$0.isEmpty }.map(units).sorted { $0.count > $1.count }
        }

        lineComments = profile.lineComments.filter { !$0.isEmpty }.map(units)
        blocks = profile.blockComments.map { form in
            let open = units(form.open), close = units(form.close)
            precondition(!open.isEmpty && !close.isEmpty, "LexicalProfile: empty block comment delimiter")
            return Block(open: open, close: close, closeString: form.close, nests: form.nests,
                         markers: set([open[0], close[0]]))
        }

        var specs: [StringSpec] = []
        for form in profile.strings {
            let escape = form.escape.map(unit)
            let opening: Opening
            let anchor: unichar
            let closeAnchor: unichar
            switch form.delimiter {
            case .fixed(let open, let close):
                let o = units(open), c = units(close)
                precondition(!o.isEmpty && !c.isEmpty, "LexicalProfile: empty string delimiter")
                opening = .fixed(open: o, close: c)
                anchor = o[0]
                closeAnchor = c[0]
            case .repeatedQuote(let quote, let minimum):
                let q = unit(quote)
                opening = .repeated(quote: q, minimum: max(1, minimum))
                anchor = q
                closeAnchor = q
            case .hashed(let lead, let hash, let quote, let applies):
                let q = units(quote)
                precondition(!q.isEmpty, "LexicalProfile: empty hashed quote")
                opening = .hashed(lead: units(lead), hash: unit(hash), quote: q, hashesApplyToEscapes: applies)
                anchor = q[0]
                closeAnchor = q[0]
            case .cppRaw:
                opening = .cppRaw
                anchor = 34      // "
                closeAnchor = 41 // )
            }
            let interps = form.interpolations.map { i -> Interpolation in
                let o = units(i.open)
                precondition(!o.isEmpty, "LexicalProfile: empty interpolation opener")
                return Interpolation(open: o, close: unit(i.close),
                                     escapedOpen: i.escapedOpen.map(units).flatMap { $0.isEmpty ? nil : $0 },
                                     escapeLed: escape != nil && o[0] == escape!)
            }
            var content: [unichar] = [closeAnchor]
            if let escape { content.append(escape) }
            for i in interps where !i.escapeLed {
                content.append(i.open[0])
                if let e = i.escapedOpen { content.append(e[0]) }
            }
            if !form.multiline { content += [Self.cr, Self.lf] }
            specs.append(StringSpec(prefixes: longestFirst(form.prefixes),
                                    prefixRequired: form.prefixRequired && !form.prefixes.isEmpty,
                                    prefixCaseInsensitive: form.prefixCaseInsensitive,
                                    opening: opening, anchor: anchor, closeAnchor: closeAnchor,
                                    multiline: form.multiline, escape: escape,
                                    doubledCloseEscapes: form.doubledCloseEscapes,
                                    interpolations: interps, contentMarkers: set(content)))
        }
        strings = specs

        atoms = profile.atoms.map { form in
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(pattern: form.pattern)
            let context = form.precededBy.map { c in
                AtomContext(characters: Set(c.characters.utf16),
                            words: Set(c.words.filter { !$0.isEmpty }.map(units)),
                            longestWord: c.words.map(\.utf16.count).max() ?? 0)
            }
            return Atom(regex: RegexBox(regex: regex), first: Set(form.firstCharacters.utf16),
                        kind: form.kind, prefixes: longestFirst(form.prefixes), context: context)
        }

        var code: [unichar] = lineComments.map { $0[0] } + blocks.map { $0.open[0] } + strings.map(\.anchor)
        for atom in atoms { code += atom.first }
        codeMarkers = set(code)
        var interp = code + [Self.cr, Self.lf] + Array("()[]{}".utf16)
        for spec in strings { interp += spec.interpolations.map(\.close) }
        interpolationMarkers = set(interp)

        var lookback = CharacterSet()
        func insertUnits(_ text: String, bothCases: Bool) {
            for u in text.utf16 {
                if let scalar = Unicode.Scalar(u) { lookback.insert(scalar) }
                if bothCases, (65...90).contains(u) || (97...122).contains(u),
                   let flipped = Unicode.Scalar(u ^ 0x20) {
                    lookback.insert(flipped)
                }
            }
        }
        for form in profile.strings {
            for prefix in form.prefixes { insertUnits(prefix, bothCases: form.prefixCaseInsensitive) }
            switch form.delimiter {
            case .hashed(let lead, let hash, _, _):
                insertUnits(lead, bothCases: false)
                insertUnits(String(hash), bothCases: false)
            case .cppRaw:
                insertUnits("R", bothCases: false)
            case .fixed, .repeatedQuote:
                break
            }
        }
        for atom in profile.atoms {
            for prefix in atom.prefixes { insertUnits(prefix, bothCases: false) }
        }
        lookbackUnits = lookback
    }

    // MARK: - Public API

    /// Advances `state` over `text[from..<to]` without reporting anything.
    public func advance(_ text: NSString, from: Int, to: Int, state: inout LexicalScanState) {
        var emitter = Emitter(emit: nil)
        run(text, from: from, to: to, state: &state, emitter: &emitter)
    }

    /// Advances `state` over `text[from..<to]` and reports the maximal
    /// segment runs in ascending, non-overlapping, gap-free absolute ranges
    /// covering exactly `[from, to)`.
    public func segments(_ text: NSString, from: Int, to: Int, state: inout LexicalScanState,
                         emit: (NSRange, LexicalSegment) -> Void) {
        withoutActuallyEscaping(emit) { escapable in
            var emitter = Emitter(emit: escapable)
            run(text, from: from, to: to, state: &state, emitter: &emitter)
        }
    }

    /// Advances from `from` and stops at the first *split-safe* position p with
    /// target <= p <= to (p == to when none). Returns p; `state` is the state at p.
    ///
    /// `target` is clamped to `[from, to]`. Up to `target` this does the same
    /// work as `advance` (marker searches are only cut at `target`); past it,
    /// at most a few tokens are scanned before a safe point is found.
    @discardableResult
    public func advance(_ text: NSString, from: Int, to: Int,
                        stoppingAtSafePointFrom target: Int, state: inout LexicalScanState) -> Int {
        var emitter = Emitter(emit: nil)
        return run(text, from: from, to: to, stop: target, state: &state, emitter: &emitter)
    }

    /// Same, also emitting segments covering exactly [from, p).
    @discardableResult
    public func segments(_ text: NSString, from: Int, to: Int,
                         stoppingAtSafePointFrom target: Int, state: inout LexicalScanState,
                         emit: (NSRange, LexicalSegment) -> Void) -> Int {
        withoutActuallyEscaping(emit) { escapable in
            var emitter = Emitter(emit: escapable)
            return run(text, from: from, to: to, stop: target, state: &state, emitter: &emitter)
        }
    }

    // MARK: - Emission

    /// Coalesces marks into maximal runs. A no-op shell in `advance` mode.
    private struct Emitter {
        let emit: ((NSRange, LexicalSegment) -> Void)?
        private var runStart = 0
        private var runKind: LexicalSegment?
        private var pending: (range: NSRange, kind: LexicalSegment)?

        init(emit: ((NSRange, LexicalSegment) -> Void)?) { self.emit = emit }

        /// From `at` on, text is `kind` (until the next mark).
        @inline(__always)
        mutating func mark(_ at: Int, _ kind: LexicalSegment) {
            guard emit != nil, runKind != kind else { return }
            if let current = runKind, at > runStart {
                push(NSRange(location: runStart, length: at - runStart), current)
            }
            runStart = at
            runKind = kind
        }

        mutating func finish(at end: Int) {
            guard emit != nil else { return }
            if let current = runKind, end > runStart {
                push(NSRange(location: runStart, length: end - runStart), current)
            }
            if let pending { emit?(pending.range, pending.kind) }
            pending = nil
        }

        private mutating func push(_ range: NSRange, _ kind: LexicalSegment) {
            if let p = pending, p.kind == kind, NSMaxRange(p.range) == range.location {
                pending = (NSRange(location: p.range.location, length: p.range.length + range.length), kind)
                return
            }
            if let pending { emit?(pending.range, pending.kind) }
            pending = (range, kind)
        }
    }

    // MARK: - Core

    private func contextKind(_ state: LexicalScanState) -> LexicalSegment {
        switch state.frames.last {
        case nil, .interpolation?: return .code
        case .lineComment?, .blockComment?: return .comment
        case .string?: return .string
        }
    }

    @inline(__always)
    private static func isIdentifier(_ u: unichar) -> Bool {
        u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) || u >= 128
    }

    @inline(__always)
    private static func push(_ frame: LexicalScanState.Frame, _ state: inout LexicalScanState) -> Bool {
        guard state.frames.count < LexicalScanState.maximumDepth else { return false }
        state.frames.append(frame)
        return true
    }

    /// The scan loop. With `stop` (a target), it returns at the first safe
    /// point at or after the target (see "Safe points"); without, at `to`.
    ///
    /// Stopping is layered on the plain loop without a second search per
    /// token: while `pos < target`, every marker search ends at `target` (the
    /// non-nesting block-comment closer search a closer's length beyond, so a
    /// closer straddling `target` is still found) while matching still uses
    /// the real `to`; a search that finds nothing moves `pos` to `target`,
    /// which is what the single pass would do to the state. From `target` on,
    /// each loop top (a token boundary) first looks for a safe point before
    /// the next possible token start.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    @discardableResult
    private func run(_ text: NSString, from rawFrom: Int, to rawTo: Int, stop: Int? = nil,
                     state: inout LexicalScanState, emitter: inout Emitter) -> Int {
        let length = text.length
        let to = min(max(rawTo, 0), length)
        var pos = min(max(rawFrom, 0), to)
        let from = pos
        let target = stop.map { min(max($0, from), to) }

        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        /// `units` occur at `p`, entirely before `limit`.
        func matches(_ units: [unichar], _ p: Int, _ limit: Int) -> Bool {
            guard p >= 0, p + units.count <= limit else { return false }
            for (k, u) in units.enumerated() where at(p + k) != u { return false }
            return true
        }
        func boundary(_ s: Int) -> Bool { s == 0 || !Self.isIdentifier(at(s - 1)) }
        /// Start of the longest of `prefixes` ending at `end`, word-boundary
        /// guarded and not before `floor`.
        func prefixStart(_ prefixes: [[unichar]], before end: Int, floor: Int, caseInsensitive: Bool) -> Int? {
            for prefix in prefixes {
                let s = end - prefix.count
                guard s >= floor else { continue }
                var equal = true
                for (k, u) in prefix.enumerated() {
                    var c = at(s + k)
                    var e = u
                    if caseInsensitive {
                        if (65...90).contains(c) { c += 32 }
                        if (65...90).contains(e) { e += 32 }
                    }
                    if c != e { equal = false; break }
                }
                if equal, boundary(s) { return s }
            }
            return nil
        }

        /// Start of the current code context: prefix lookback never crosses it.
        var codeStart = from
        emitter.mark(from, contextKind(state))

        /// `i` is the second unit of a surrogate pair.
        func isLowSurrogate(_ i: Int) -> Bool {
            i > 0 && i < to && (0xDC00...0xDFFF).contains(at(i)) && (0xD800...0xDBFF).contains(at(i - 1))
        }
        /// Where a marker search that found nothing before `limit` leaves the
        /// plain run: `limit`, or past it when it splits a surrogate pair (a
        /// low surrogate is never a marker, and a search must not start on it).
        func afterPlainRun(_ limit: Int) -> Int {
            limit < to && isLowSurrogate(limit) ? limit + 1 : limit
        }

        /// `q` is split-safe in a context of this kind (`q` at a token
        /// boundary). Reads at most `q - 1` and `q`, never at `to`.
        func friendly(_ q: Int, code: Bool) -> Bool {
            guard q > 0, q < to else { return true }
            let previous = at(q - 1)
            if (0xD800...0xDBFF).contains(previous) { return false }
            let current = at(q)
            if Self.isIdentifier(previous) && Self.isIdentifier(current) { return false }
            if previous == Self.cr && current == Self.lf { return false }
            if code, let scalar = Unicode.Scalar(previous), lookbackUnits.contains(scalar) { return false }
            return true
        }
        /// At a loop top past the target: the first safe point between `pos`
        /// and a lower bound of the next token start, or nil.
        func safePoint() -> Int? {
            let markers: CharacterSet
            let code: Bool
            switch state.frames.last {
            case nil: markers = codeMarkers; code = true
            case .interpolation?: markers = interpolationMarkers; code = true
            case .lineComment?: markers = Self.lineBreaks; code = false
            // Both delimiters' first units, also for a non-nesting comment: a
            // closer straddling the window end must not yield a stop inside it.
            case .blockComment(let form, _)?: markers = blocks[Int(form)].markers; code = false
            case .string(let form, _, _)?: markers = strings[Int(form)].contentMarkers; code = false
            }
            let windowEnd = min(to, pos + Self.safePointWindow)
            // A forward search starting on a low surrogate skips the next
            // unit (Foundation); start on the pair's first unit instead.
            let searchStart = pos > from && isLowSurrogate(pos) ? pos - 1 : pos
            let hit = text.rangeOfCharacter(from: markers, options: [],
                                            range: NSRange(location: searchStart, length: windowEnd - searchStart))
            let bound = hit.location == NSNotFound ? windowEnd : hit.location
            var q = pos
            while q <= bound {
                if friendly(q, code: code) { return q }
                q += 1
            }
            return nil
        }

        while pos < to {
            // Phase B: past the target, stop at the first safe point.
            if let target, pos >= target, let q = safePoint() {
                emitter.finish(at: q)
                return q
            }
            // Phase A: before the target, marker searches end there.
            let limit = target.map { pos < $0 ? $0 : to } ?? to
            guard let top = state.frames.last else {
                pos = scanCode(text, pos, to, limit, &state, &emitter, &codeStart, inInterpolation: false,
                               matches: matches, prefixStart: prefixStart, boundary: boundary)
                if pos == limit, limit < to { pos = afterPlainRun(limit) }
                continue
            }
            switch top {
            case .interpolation:
                pos = scanCode(text, pos, to, limit, &state, &emitter, &codeStart, inInterpolation: true,
                               matches: matches, prefixStart: prefixStart, boundary: boundary)
                if pos == limit, limit < to { pos = afterPlainRun(limit) }

            case .lineComment:
                let hit = text.rangeOfCharacter(from: Self.lineBreaks, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                state.frames.removeLast()
                pos = hit.location
                codeStart = pos
                emitter.mark(pos, contextKind(state))

            case .blockComment(let formIndex, let depth):
                let block = blocks[Int(formIndex)]
                if !block.nests {
                    // A closer starting before `limit` may end after it.
                    let searchEnd = limit < to ? min(to, limit + block.close.count - 1) : to
                    let hit = text.range(of: block.closeString, options: .literal,
                                         range: NSRange(location: pos, length: searchEnd - pos))
                    guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                    state.frames.removeLast()
                    pos = NSMaxRange(hit)
                    codeStart = pos
                    emitter.mark(pos, contextKind(state))
                    break
                }
                let hit = text.rangeOfCharacter(from: block.markers, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                if matches(block.close, p, to) {
                    pos = p + block.close.count
                    if depth <= 1 {
                        state.frames.removeLast()
                        codeStart = pos
                        emitter.mark(pos, contextKind(state))
                    } else {
                        state.frames[state.frames.count - 1] = .blockComment(form: formIndex, depth: depth - 1)
                    }
                } else if matches(block.open, p, to) {
                    pos = p + block.open.count
                    if depth < UInt32.max {
                        state.frames[state.frames.count - 1] = .blockComment(form: formIndex, depth: depth + 1)
                    }
                } else {
                    pos = p + 1
                }

            case .string(let formIndex, let count, let delimiter):
                let spec = strings[Int(formIndex)]
                let hit = text.rangeOfCharacter(from: spec.contentMarkers, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                let c = at(p)

                // End of line in a single-line string: it ends here; the code
                // context below handles the terminator.
                if !spec.multiline, c == Self.cr || c == Self.lf {
                    state.frames.removeLast()
                    pos = p
                    codeStart = p
                    emitter.mark(p, contextKind(state))
                    break
                }

                if let escape = spec.escape, c == escape {
                    var hashes = 0
                    if case .hashed(_, let hash, _, true) = spec.opening, count > 0 {
                        hashes = Int(count)
                        var ok = p + 1 + hashes <= to
                        if ok { for k in 0..<hashes where at(p + 1 + k) != hash { ok = false; break } }
                        // `\` without its hashes is literal content.
                        if !ok { pos = p + 1; break }
                    }
                    let afterEscape = p + 1 + hashes
                    // Escape-led interpolation (`\(`, `\#(`).
                    var opened = false
                    for (k, interp) in spec.interpolations.enumerated() where interp.escapeLed {
                        let rest = Array(interp.open.dropFirst())
                        guard matches(rest, afterEscape, to) else { continue }
                        guard Self.push(.interpolation(form: formIndex, interpolation: UInt8(k), depth: 0),
                                        &state) else { break }
                        emitter.mark(p, .interpolationDelimiter)
                        pos = afterEscape + rest.count
                        codeStart = pos
                        emitter.mark(pos, .code)
                        opened = true
                        break
                    }
                    if opened { break }
                    // Plain escape: the escape (+ hashes) and one escaped
                    // character; CRLF after it counts as one line continuation,
                    // a surrogate pair as one character (a search must never
                    // start on a low surrogate: Foundation then skips a unit).
                    var q = afterEscape
                    if q < to {
                        let escaped = at(q)
                        let pair = q + 1 < to
                            && ((escaped == Self.cr && at(q + 1) == Self.lf)
                                || ((0xD800...0xDBFF).contains(escaped) && (0xDC00...0xDFFF).contains(at(q + 1))))
                        q += pair ? 2 : 1
                    }
                    pos = min(q, to)
                    break
                }

                if c == spec.closeAnchor {
                    if case .repeated(let quote, _) = spec.opening {
                        var run = 0
                        while p + run < to, at(p + run) == quote { run += 1 }
                        pos = p + run
                        if run == Int(count) {
                            state.frames.removeLast()
                            codeStart = pos
                            emitter.mark(pos, contextKind(state))
                        }
                        break
                    }
                    if let end = closeEnd(spec, count: Int(count), delimiter: delimiter, at: p, to: to,
                                          matches: matches) {
                        if spec.doubledCloseEscapes, let again = closeEnd(spec, count: Int(count),
                                                                          delimiter: delimiter, at: end, to: to,
                                                                          matches: matches) {
                            pos = again          // escaped closer: content
                            break
                        }
                        state.frames.removeLast()
                        pos = end
                        codeStart = end
                        emitter.mark(end, contextKind(state))
                        break
                    }
                }

                var handled = false
                for (k, interp) in spec.interpolations.enumerated() where !interp.escapeLed {
                    if let escaped = interp.escapedOpen, escaped[0] == c, matches(escaped, p, to) {
                        pos = p + escaped.count
                        handled = true
                        break
                    }
                    guard interp.open[0] == c, matches(interp.open, p, to) else { continue }
                    guard Self.push(.interpolation(form: formIndex, interpolation: UInt8(k), depth: 0),
                                    &state) else { break }
                    emitter.mark(p, .interpolationDelimiter)
                    pos = p + interp.open.count
                    codeStart = pos
                    emitter.mark(pos, .code)
                    handled = true
                    break
                }
                if !handled { pos = p + 1 }
            }
        }
        emitter.finish(at: to)
        return to
    }

    /// End of the string's closer at `p`, or nil when `p` does not close it.
    private func closeEnd(_ spec: StringSpec, count: Int, delimiter: String?, at p: Int, to: Int,
                          matches: ([unichar], Int, Int) -> Bool) -> Int? {
        switch spec.opening {
        case .fixed(_, let close):
            return matches(close, p, to) ? p + close.count : nil
        case .repeated:
            return nil   // handled by run length in `run`
        case .hashed(_, let hash, let quote, _):
            let closer = quote + Array(repeating: hash, count: count)
            return matches(closer, p, to) ? p + closer.count : nil
        case .cppRaw:
            let closer: [unichar] = [41] + Array((delimiter ?? "").utf16) + [34]
            return matches(closer, p, to) ? p + closer.count : nil
        }
    }

    /// Scans code from `pos` up to the next construct boundary and returns the
    /// new position. In an interpolation it also tracks brackets, the closer
    /// and line ends. The marker search ends at `limit` (≤ `to`; returned when
    /// nothing is found); matching uses `to`.
    // swiftlint:disable:next function_parameter_count function_body_length cyclomatic_complexity
    private func scanCode(_ text: NSString, _ pos: Int, _ to: Int, _ limit: Int,
                          _ state: inout LexicalScanState, _ emitter: inout Emitter, _ codeStart: inout Int,
                          inInterpolation: Bool,
                          matches: ([unichar], Int, Int) -> Bool,
                          prefixStart: ([[unichar]], Int, Int, Bool) -> Int?,
                          boundary: (Int) -> Bool) -> Int {
        let markers = inInterpolation ? interpolationMarkers : codeMarkers
        let hit = text.rangeOfCharacter(from: markers, options: [],
                                        range: NSRange(location: pos, length: limit - pos))
        guard hit.location != NSNotFound else { return limit }
        let p = hit.location
        let c = text.character(at: p)

        if c == Self.cr || c == Self.lf {
            if inInterpolation, let cut = lineEndCut(state) {
                state.frames.removeSubrange(cut...)
                codeStart = p + 1
            }
            return p + 1
        }

        for opener in lineComments where opener[0] == c && matches(opener, p, to) {
            guard Self.push(.lineComment, &state) else { break }
            emitter.mark(p, .comment)
            return p + opener.count
        }

        for (index, block) in blocks.enumerated() where block.open[0] == c && matches(block.open, p, to) {
            guard Self.push(.blockComment(form: UInt8(index), depth: 1), &state) else { break }
            emitter.mark(p, .comment)
            return p + block.open.count
        }

        for (index, spec) in strings.enumerated() where spec.anchor == c {
            guard let open = openString(spec, at: p, to: to, codeStart: codeStart, text: text,
                                        matches: matches, prefixStart: prefixStart, boundary: boundary)
            else { continue }
            guard Self.push(.string(form: UInt8(index), count: open.count, delimiter: open.delimiter),
                            &state) else { break }
            emitter.mark(open.tokenStart, .string)
            return open.contentStart
        }

        var window: (start: Int, end: Int, text: String)?
        for atom in atoms where atom.first.contains(c) {
            if window == nil { window = atomWindow(text, at: p, to: to) }
            guard let match = matchAtom(atom, at: p, window: window!, codeStart: codeStart, text: text,
                                        prefixStart: prefixStart) else { continue }
            emitter.mark(match.start, .atom(atom.kind))
            emitter.mark(match.end, .code)
            codeStart = match.end
            return match.end
        }

        if inInterpolation, case .interpolation(let form, let k, let depth)? = state.frames.last {
            let close = strings[Int(form)].interpolations[Int(k)].close
            if depth == 0, c == close {
                state.frames.removeLast()
                emitter.mark(p, .interpolationDelimiter)
                emitter.mark(p + 1, contextKind(state))
                codeStart = p + 1
                return p + 1
            }
            switch c {
            case 40, 91, 123:   // ( [ {
                if depth < UInt32.max {
                    state.frames[state.frames.count - 1] = .interpolation(form: form, interpolation: k, depth: depth + 1)
                }
            case 41, 93, 125:   // ) ] }
                if depth > 0 {
                    state.frames[state.frames.count - 1] = .interpolation(form: form, interpolation: k, depth: depth - 1)
                }
            default:
                break
            }
        }
        return p + 1
    }

    /// Index from which a line end inside an interpolation truncates the
    /// stack: the lowest single-line string above the topmost multi-line
    /// construct, or nil.
    private func lineEndCut(_ state: LexicalScanState) -> Int? {
        var cut: Int?
        for index in stride(from: state.frames.count - 1, through: 0, by: -1) {
            switch state.frames[index] {
            case .string(let form, _, _):
                if strings[Int(form)].multiline { return cut }
                cut = index
            case .blockComment:
                return cut
            case .interpolation, .lineComment:
                continue
            }
        }
        return cut
    }

    private struct Opened {
        let tokenStart: Int
        let contentStart: Int
        let count: UInt16
        let delimiter: String?
    }

    // swiftlint:disable:next function_parameter_count
    private func openString(_ spec: StringSpec, at p: Int, to: Int, codeStart: Int, text: NSString,
                            matches: ([unichar], Int, Int) -> Bool,
                            prefixStart: ([[unichar]], Int, Int, Bool) -> Int?,
                            boundary: (Int) -> Bool) -> Opened? {
        var leadStart = p          // start of lead + hashes (before the anchor)
        var contentStart: Int
        var count: UInt16 = 0
        var delimiter: String?
        switch spec.opening {
        case .fixed(let open, _):
            guard matches(open, p, to) else { return nil }
            contentStart = p + open.count
        case .repeated(let quote, let minimum):
            var run = 0
            while p + run < to, text.character(at: p + run) == quote { run += 1 }
            guard run >= minimum else { return nil }
            contentStart = p + run
            count = UInt16(min(run, Int(UInt16.max)))
        case .hashed(let lead, let hash, let quote, _):
            guard matches(quote, p, to) else { return nil }
            var hashes = 0
            while p - hashes - 1 >= codeStart, text.character(at: p - hashes - 1) == hash { hashes += 1 }
            let start = p - hashes - lead.count
            guard start >= codeStart, matches(lead, start, p - hashes) else { return nil }
            leadStart = start
            contentStart = p + quote.count
            count = UInt16(min(hashes, Int(UInt16.max)))
        case .cppRaw:
            guard p - 1 >= codeStart, text.character(at: p - 1) == 82 else { return nil }   // R
            var q = p + 1
            var delim: [unichar] = []
            while q < to, delim.count <= 16 {
                let u = text.character(at: q)
                if u == 40 { break }   // (
                if u == 32 || u == 41 || u == 92 || u == 9 || u == Self.cr || u == Self.lf { return nil }
                delim.append(u)
                q += 1
            }
            guard q < to, text.character(at: q) == 40, delim.count <= 16 else { return nil }
            leadStart = p - 1
            contentStart = q + 1
            delimiter = String(utf16CodeUnits: delim, count: delim.count)
        }
        var tokenStart = leadStart
        if let s = prefixStart(spec.prefixes, leadStart, codeStart, spec.prefixCaseInsensitive) {
            tokenStart = s
        } else if spec.prefixRequired {
            return nil
        } else if leadStart < p, !boundary(leadStart) {
            // A lead (`r`, `R`) is itself word-boundary guarded like a prefix;
            // bare hashes (Swift `#"`) are not.
            var hashesOnly = false
            if case .hashed(let lead, _, _, _) = spec.opening, lead.isEmpty { hashesOnly = true }
            if !hashesOnly { return nil }
        }
        return Opened(tokenStart: tokenStart, contentStart: contentStart, count: count, delimiter: delimiter)
    }

    /// The text an atom at `p` may match: from a short lookbehind to the end
    /// of `p`'s line (atoms never cross a line break), at most `atomWindow`
    /// units and never past `to`. Built once per candidate position.
    private func atomWindow(_ text: NSString, at p: Int, to: Int) -> (start: Int, end: Int, text: String) {
        let start = max(0, p - Self.atomLookbehind)
        let limit = min(to, p + Self.atomWindow)
        let lineBreak = text.rangeOfCharacter(from: Self.lineBreaks, options: [],
                                              range: NSRange(location: p, length: limit - p))
        let end = lineBreak.location == NSNotFound ? limit : lineBreak.location
        return (start, end, text.substring(with: NSRange(location: start, length: end - start)))
    }

    // swiftlint:disable:next function_parameter_count
    private func matchAtom(_ atom: Atom, at p: Int, window: (start: Int, end: Int, text: String),
                           codeStart: Int, text: NSString,
                           prefixStart: ([[unichar]], Int, Int, Bool) -> Int?) -> (start: Int, end: Int)? {
        guard window.end > p else { return nil }
        let start = prefixStart(atom.prefixes, p, codeStart, false) ?? p
        // The context check is cheap; run it before the regex.
        if let context = atom.context, !Self.allows(context, before: start, in: text) { return nil }
        guard let match = atom.regex.regex.firstMatch(
                  in: window.text,
                  options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                  range: NSRange(location: p - window.start, length: window.end - p)),
              match.range.length > 0 else { return nil }
        return (start, p + match.range.length)
    }

    /// `AtomContext` check: reads only text before `start` — at most
    /// `LexicalProfile.AtomContext.reach` units of whitespace, then the unit
    /// or word ending there (≤ the longest word + 1 units) — independent of
    /// the scanner state, so it gives the same answer for any split.
    private static func allows(_ context: AtomContext, before start: Int, in text: NSString) -> Bool {
        let floor = max(0, start - LexicalProfile.AtomContext.reach)
        var q = start - 1
        while q >= floor {
            let u = text.character(at: q)
            guard u == 32 || u == 9 || u == cr || u == lf else { break }
            q -= 1
        }
        if q < 0 { return true }              // document start
        if q < floor { return false }         // only whitespace within reach
        let last = text.character(at: q)
        if context.characters.contains(last) { return true }
        guard context.longestWord > 0, isIdentifier(last) || last == 36 else { return false }
        // The identifier run ending at `q` (`$` included, as in JS), read up
        // to one unit past the longest word: a longer run is no word.
        var s = q
        while s > 0, q - s + 1 <= context.longestWord {
            let u = text.character(at: s - 1)
            guard isIdentifier(u) || u == 36 else { break }
            s -= 1
        }
        guard q - s + 1 <= context.longestWord else { return false }
        return context.words.contains((s...q).map { text.character(at: $0) })
    }
}
