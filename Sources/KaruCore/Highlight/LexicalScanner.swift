import Foundation
import os

/// The generic lexical scanner (M17 T17.2, plan §4): executes a
/// `LexicalProfile` over an `NSString` range, carrying a `LexicalScanState`.
///
/// Two modes over the same core:
/// - `advance` only updates the state (checkpoints, jumping into a document).
///   Ordinary code, comment and string text is skipped with
///   `rangeOfCharacter(from:)` marker searches, so the per-unit work is
///   limited to the few characters that can start or end a construct.
/// - `segments` additionally reports maximal runs of `LexicalSegment`s with
///   absolute ranges (with `languages:`, each run's language too).
///
/// **Embedded languages** (T17.8a, `LexicalProfile.embeds`): inside an HTML
/// raw-text body or a Markdown fence of a known language, the host runs the
/// child's scanner (compiled on first entry, `embeddedScanner`) over the
/// body through the same emitter, keeping the child's state in
/// `LexicalScanState.embedded`. The host alone finds the body's end: a
/// fence closer at each body line start, or the first `</name` end tag
/// (searched as text) — so the child's state never decides it, and a child
/// run never reads at or past it. A fence body is handed to the child in
/// chunks ending at the next line that may close the fence; a raw-text body
/// up to its end tag. When stopping, one step searches at most
/// `embedWindow` units past the target. One level only.
///
/// **JSX** (T17.8b, `LexicalProfile.jsx`): a `<` in code that opens an
/// element pushes a `jsxTag` frame; one tree's nested elements, closing tags
/// and children text then live in that one frame (its depth counter), so a
/// deep tree costs no frames; each `{…}` expression pushes a `jsxExpression`
/// frame of code whose `}` returns to the tag or text below. A tag is scanned
/// token by token: blanks, a tag or attribute name (read whole, up to `to`),
/// a string, `{`, a comment, `>` / `/>`, a stray unit.
///
/// **Ranges.** Both accept any `[from, to)`, not necessarily line-aligned. The
/// scanner never reads at or beyond `to`; it may read *before* `from`, but
/// only the single unit in front of a string / atom prefix (the word-boundary
/// guard), an atom's lookbehind context (16 units), an atom's or string's
/// `precededBy` context (up to `LexicalProfile.AtomContext.reach` units of
/// whitespace, then the unit or word before it), the unit in front of a line
/// comment opener (`lineCommentPrecededBy`), the unit in front of a position
/// tested for a line start (line blocks; `from` included), a block-scalar
/// indicator's line up to `blockScalarLineReach` units back, a fence opener
/// line up to `fenceInfoReach` units back when it ends (its info string), a
/// raw-text start tag from its `<` (at most `startTagReach` units) when its
/// `>` is reached (its `type`), a child's own reads of these kinds (into the
/// host text before its body too), a JSX opener's `context` (like an atom's
/// `precededBy`), the unit in front of a `<` inside a JSX tag (TSX type
/// arguments follow a name) or of a `>` in type arguments (`=>`), or, when
/// stopping at a safe point, the unit in front of `from` itself and — TSX —
/// up to `typeParameterReach` + 1 units back to a `<` whose type-parameter
/// check a stop must not cut. These reads depend on the text alone, never on
/// the state, so they cannot break the split guarantee below.
///
/// **Split guarantee.** For a split point `b` in `[a, c)`, scanning `a..<b`
/// then `b..<c` gives the same end state as scanning `a..<c`, and the
/// concatenated segments equal the single pass's after merging adjacent runs
/// of the same kind and language (each call emits maximal runs *within its
/// own range*) —
/// provided `b` does not fall strictly inside a token: an opener (including a
/// string prefix, lead and hashes), a closer, an escape sequence, an
/// interpolation delimiter, an atom match or a surrogate pair — or, for line
/// blocks, a heredoc opener (`<<-'EOF'`, a `<<<`), a block-scalar indicator
/// with its indicators, a fence opener's leading spaces and marker run, a
/// heredoc terminator or fence closer line through its first line-break unit,
/// and in a block-scalar body a line's leading blanks through the first other
/// unit (the indentation check) — or, for embedded languages (T17.8a), a
/// raw-text start tag opener (`<script` with its blank, `/` or `>`), an end
/// tag (`</script` with its delimiter), a CRLF ending a known-language fence's
/// opener line or inside its body, and inside a body any token of the child
/// language — or, for JSX (T17.8b), an opener in code (`<` with its next
/// unit; in TSX through the text its type-parameter check reads on the
/// line: the identifier, blanks and `,` / `=` / `extends` / `const` + blank +
/// identifier start), a `<` in children with its next unit (`</`, `<name`,
/// `<>`), a tag name or attribute name (read whole; cut, the rest reads as
/// an attribute name), a TSX type-argument identifier, `/>` and a `//` / `/*`
/// in a tag. Line starts are always safe (no token
/// crosses a line break: escape + newline counts as one escape; a line
/// block's line-start checks run at the line start, from the text after it).
///
/// **Safe points** (long-line slicing, plan §6 item 2) are what the
/// `stoppingAtSafePointFrom:` variants return: a token boundary that is also
/// not inside a surrogate pair, an identifier run or a CRLF, and — in code —
/// not right after a unit that a later token's backward lookback (string
/// prefix, hashed lead / hashes, C++ `R`, atom prefix) could include. Resuming
/// there floors those lookbacks at the safe point instead of at the single
/// pass's earlier code start, so this last condition keeps them identical.
/// A line-block body is treated like string content (no lookback); a line
/// start in a body or in code is always friendly, and stopping there leaves
/// its line-start checks to the resumed pass. Inside a start tag every unit
/// is a step of its own (any friendly point up to the next tag marker, but
/// not right after the opener's name); a plain raw-text body is like string
/// content. Inside a child's body a safe point is the child's own safe
/// point, which lies before the end tag or the next possible closer line,
/// never inside them. In a JSX tag every non-blank unit starts a token (a
/// safe point lies among the blanks before it), in a tag string or type
/// arguments any friendly point before the closer / next angle bracket, in
/// children text any friendly point before the next `<` or `{`, and a JSX
/// expression is code. Checkpoints and the highlighter split only at line
/// starts and at returned safe points.
///
/// **Lines.** CR, LF and CRLF terminate lines. A line comment, and a
/// single-line string not continued by escape + newline, end at the
/// terminator; when the terminator is reached inside an interpolation, the
/// innermost single-line string that has no multi-line construct above it is
/// closed together with everything above it.
///
/// **Depth.** At most `LexicalScanState.maximumDepth` frames. An opener met at
/// the cap is not opened (its characters stay code / content); a nesting
/// block comment counts depth inside one frame and is not limited by the cap,
/// and so do the nested elements of one JSX tree (a `{` at the cap stays
/// text or tag filler).
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
        let context: AtomContext?
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
        let doubledCloseIsEscape: Bool
        let escapeForms: LexicalProfile.EscapeForms
        let variablePrefix: unichar?
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
        let lineStart: Bool

        init(_ c: LexicalProfile.AtomContext) {
            characters = Set(c.characters.utf16)
            words = Set(c.words.filter { !$0.isEmpty }.map { Array($0.utf16) })
            longestWord = c.words.map(\.utf16.count).max() ?? 0
            lineStart = c.lineStart
        }
    }

    private struct Atom: Sendable {
        let regex: RegexBox
        let first: Set<unichar>
        let kind: TokenKind
        let prefixes: [[unichar]]          // longest first
        let context: AtomContext?
    }

    /// Compiled `LexicalProfile.RawTextElement` (T17.8a).
    private struct RawElement: Sendable {
        /// Lowercase ASCII name.
        let name: [unichar]
        let language: UInt8
        let typeLanguages: [String: UInt8]
        let otherTypesLanguage: UInt8
    }

    /// The child scanners, compiled on first entry (T17.8a). Shared by the
    /// copies of one scanner; the lock keeps the scanner `Sendable`.
    private final class EmbedCache: Sendable {
        let slots: OSAllocatedUnfairLock<[LexicalScanner?]>
        init(count: Int) { slots = OSAllocatedUnfairLock(initialState: Array(repeating: nil, count: count)) }
    }

    private let lineComments: [[unichar]]
    /// `lineCommentPrecededBy`, compiled.
    private let lineCommentContext: Set<unichar>?
    private let blocks: [Block]
    private let strings: [StringSpec]
    private let atoms: [Atom]
    private let codeMarkers: CharacterSet
    private let interpolationMarkers: CharacterSet
    /// Units a backward lookback in code may include (see "Safe points").
    private let lookbackUnits: CharacterSet
    /// Body kinds of the profile's line blocks (nil: no such form).
    private let heredocKind: TokenKind?
    private let indentedKind: TokenKind?
    private let fenceKind: TokenKind?
    /// T17.8a: raw-text elements, child profiles (without their own embeds)
    /// and their compiled scanners, fence info words → language index.
    private let rawElements: [RawElement]
    private let embedProfiles: [LexicalProfile]
    private let embedCache: EmbedCache?
    private let fenceAliases: [String: UInt8]
    private var hasEmbeds: Bool { embedCache != nil }
    /// T17.8b: JSX (`LexicalProfile.jsx`) — the expression-position context
    /// (nil: no JSX), TSX rules, and what ends a code run in a JSX expression.
    private let jsxContext: AtomContext?
    private let jsxTypeScript: Bool
    private let jsxExpressionMarkers: CharacterSet
    /// First units of every opener `scanCode` tries before brackets: line
    /// and block comments, string anchors, atoms, heredoc / raw-text `<`,
    /// block-scalar `|` `>` — as an ASCII bitmask (two words), and whether
    /// any lies beyond ASCII.
    private let openerMask: [UInt64]
    private let openersBeyondASCII: Bool
    /// JSX children text: a child element / closing tag, or an expression.
    private static let jsxTextMarkers = CharacterSet(charactersIn: "<{")
    private static let lineBreaks = CharacterSet(charactersIn: "\r\n")
    /// Start-tag scanning (T17.8a): `>` or `=` between attributes; anything
    /// but a blank after `=`; the closing quote; the end of an unquoted value.
    private static let tagSeparators = CharacterSet(charactersIn: ">=")
    private static let tagBlanks = CharacterSet(charactersIn: " \t\n\u{0C}\r")
    private static let tagNonBlank = tagBlanks.inverted
    private static let doubleQuote = CharacterSet(charactersIn: "\"")
    private static let angleBrackets = CharacterSet(charactersIn: "<>")
    private static let singleQuote = CharacterSet(charactersIn: "'")
    private static let unquotedValueEnd = tagBlanks.union(CharacterSet(charactersIn: ">"))

    /// What ends a start-tag phase (see `LexicalScanState.Frame.rawTextTag`).
    private static func tagMarkers(phase: UInt8) -> CharacterSet {
        switch phase {
        case 0: return tagSeparators
        case 1: return tagNonBlank
        case 2: return doubleQuote
        case 3: return singleQuote
        default: return unquotedValueEnd
        }
    }
    /// Anything but a space or tab (the rest of a block-scalar opener line).
    private static let nonBlank = CharacterSet(charactersIn: " \t").inverted
    /// A backtick fence's info string: a backtick drops the fence.
    private static let backtickInfoMarkers = CharacterSet(charactersIn: "`\r\n")

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
    /// How far back a block-scalar indicator looks for its line start (the
    /// parent indentation); beyond it, any non-blank body line ends the scalar.
    static let blockScalarLineReach = 4_096
    /// TSX (T17.8b): the longest identifier plus blanks a `<`'s
    /// type-parameter check reads; beyond it the `<` opens an element.
    static let typeParameterReach = 256
    /// How far a raw-text start tag is re-read from its `<` for its `type`
    /// (T17.8a); attributes beyond are ignored.
    public static let startTagReach = 4_096
    /// How far back a fence's info string is re-read when its line ends
    /// (T17.8a); a longer opener line has no language.
    public static let fenceInfoReach = 4_096
    /// How far past the target (or the position, past it) an embedded body's
    /// end is searched in one step when stopping at a safe point (T17.8a).
    /// Far beyond any child token's look-ahead (≤ `atomWindow` +
    /// `safePointWindow`), so the child never reads near a step end before
    /// it stops; without a target the search runs to the range end.
    static let embedWindow = 16_384

    public init(profile: LexicalProfile) {
        precondition(profile.embeds.count < 256, "LexicalProfile: at most 255 embedded languages")
        precondition(profile.rawTextElements.count < 256, "LexicalProfile: at most 255 raw-text elements")
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
        lineCommentContext = profile.lineCommentPrecededBy.map { Set($0.utf16) }
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
            let variablePrefix = form.variablePrefix.map(unit)
            if let variablePrefix { content.append(variablePrefix) }
            for i in interps where !i.escapeLed {
                content.append(i.open[0])
                if let e = i.escapedOpen { content.append(e[0]) }
            }
            if !form.multiline { content += [Self.cr, Self.lf] }
            specs.append(StringSpec(prefixes: longestFirst(form.prefixes),
                                    context: form.precededBy.map(AtomContext.init),
                                    prefixRequired: form.prefixRequired && !form.prefixes.isEmpty,
                                    prefixCaseInsensitive: form.prefixCaseInsensitive,
                                    opening: opening, anchor: anchor, closeAnchor: closeAnchor,
                                    multiline: form.multiline, escape: escape,
                                    doubledCloseEscapes: form.doubledCloseEscapes,
                                    doubledCloseIsEscape: form.doubledCloseEscapes && form.doubledCloseIsEscape,
                                    escapeForms: form.escapeForms,
                                    variablePrefix: variablePrefix,
                                    interpolations: interps, contentMarkers: set(content)))
        }
        strings = specs

        atoms = profile.atoms.map { form in
            // swiftlint:disable:next force_try
            let regex = try! NSRegularExpression(pattern: form.pattern)
            return Atom(regex: RegexBox(regex: regex), first: Set(form.firstCharacters.utf16),
                        kind: form.kind, prefixes: longestFirst(form.prefixes),
                        context: form.precededBy.map(AtomContext.init))
        }

        var heredoc: TokenKind?, indented: TokenKind?, fence: TokenKind?
        for form in profile.lineBlocks {
            switch form {
            case .heredoc(let kind):
                precondition(heredoc == nil, "LexicalProfile: at most one heredoc form")
                heredoc = kind
            case .indentedBlock(let kind):
                precondition(indented == nil, "LexicalProfile: at most one indented block form")
                indented = kind
            case .fence(let kind):
                precondition(fence == nil, "LexicalProfile: at most one fence form")
                fence = kind
            }
        }
        heredocKind = heredoc
        indentedKind = indented
        fenceKind = fence

        let embedCount = profile.embeds.count
        func embedIndex(_ index: Int) -> UInt8 {
            precondition(index >= 0 && index <= embedCount, "LexicalProfile: embed index \(index) out of range")
            return UInt8(index)
        }
        rawElements = profile.rawTextElements.map { element in
            let name = Array(element.name.lowercased().utf16)
            precondition(!name.isEmpty && name.allSatisfy { (97...122).contains($0) },
                         "LexicalProfile: raw-text element names are ASCII letters")
            return RawElement(name: name, language: embedIndex(element.language),
                              typeLanguages: element.typeLanguages.mapValues(embedIndex),
                              otherTypesLanguage: embedIndex(element.otherTypesLanguage))
        }
        embedProfiles = profile.embeds.map(\.profile.withoutEmbeds)
        embedCache = embedCount > 0 ? EmbedCache(count: embedCount) : nil
        var aliases: [String: UInt8] = [:]
        if fence != nil {
            for (index, embed) in profile.embeds.enumerated() {
                for alias in embed.aliases where aliases[alias.lowercased()] == nil {
                    aliases[alias.lowercased()] = UInt8(index + 1)
                }
            }
        }
        fenceAliases = aliases

        var code: [unichar] = lineComments.map { $0[0] } + blocks.map { $0.open[0] } + strings.map(\.anchor)
        for atom in atoms { code += atom.first }
        if heredoc != nil { code.append(60) }               // <
        if indented != nil { code += [124, 62] }            // | >
        // Line breaks end a heredoc opener line and lead to line starts.
        if !profile.lineBlocks.isEmpty { code += [Self.cr, Self.lf] }
        if !profile.rawTextElements.isEmpty || profile.jsx != nil { code.append(60) }   // <
        codeMarkers = set(code)
        jsxContext = profile.jsx.map { AtomContext($0.context) }
        jsxTypeScript = profile.jsx?.typeScript ?? false
        jsxExpressionMarkers = set(code + Array("{}".utf16))
        var openers: [unichar] = lineComments.map { $0[0] } + blocks.map { $0.open[0] } + strings.map(\.anchor)
        for atom in atoms { openers += atom.first }
        if heredoc != nil || !profile.rawTextElements.isEmpty { openers.append(60) }   // <
        if indented != nil { openers += [124, 62] }                                       // | >
        var mask: [UInt64] = [0, 0]
        for u in openers where u < 128 { mask[Int(u) >> 6] |= 1 << UInt64(u & 63) }
        openerMask = mask
        openersBeyondASCII = openers.contains { $0 >= 128 }
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
    /// covering exactly `[from, to)`. Runs of an embedded language are
    /// reported like the host's (adjacent runs of one kind merge across
    /// languages); see `segments(_:from:to:state:languages:)`.
    public func segments(_ text: NSString, from: Int, to: Int, state: inout LexicalScanState,
                         emit: (NSRange, LexicalSegment) -> Void) {
        withoutActuallyEscaping(emit) { escapable in
            var emitter = Emitter(emit: { range, kind, _ in escapable(range, kind) }, tracksLanguage: false)
            run(text, from: from, to: to, state: &state, emitter: &emitter)
        }
    }

    /// Like `segments(_:from:to:state:emit:)`, also reporting each run's
    /// language (T17.8a): 0 for the host, else the index into the profile's
    /// `embeds` plus one. A run is maximal for its kind *and* language.
    public func segments(_ text: NSString, from: Int, to: Int, state: inout LexicalScanState,
                         languages emit: (NSRange, LexicalSegment, Int) -> Void) {
        withoutActuallyEscaping(emit) { escapable in
            var emitter = Emitter(emit: { range, kind, language in escapable(range, kind, Int(language)) },
                                  tracksLanguage: true)
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
            var emitter = Emitter(emit: { range, kind, _ in escapable(range, kind) }, tracksLanguage: false)
            return run(text, from: from, to: to, stop: target, state: &state, emitter: &emitter)
        }
    }

    /// Same, with each run's language (see `segments(_:from:to:state:languages:)`).
    @discardableResult
    public func segments(_ text: NSString, from: Int, to: Int,
                         stoppingAtSafePointFrom target: Int, state: inout LexicalScanState,
                         languages emit: (NSRange, LexicalSegment, Int) -> Void) -> Int {
        withoutActuallyEscaping(emit) { escapable in
            var emitter = Emitter(emit: { range, kind, language in escapable(range, kind, Int(language)) },
                                  tracksLanguage: true)
            return run(text, from: from, to: to, stop: target, state: &state, emitter: &emitter)
        }
    }

    /// The scanner of embedded language `language` (index into the
    /// profile's `embeds` plus one), compiled on first use; nil for 0 or an
    /// index out of range.
    public func embeddedScanner(_ language: Int) -> LexicalScanner? {
        guard let embedCache, language >= 1, language <= embedProfiles.count else { return nil }
        if let cached = embedCache.slots.withLock({ $0[language - 1] }) { return cached }
        // Compiled outside the lock; a concurrent first use keeps the first one stored.
        let built = LexicalScanner(profile: embedProfiles[language - 1])
        return embedCache.slots.withLock { slots in
            if let stored = slots[language - 1] { return stored }
            slots[language - 1] = built
            return built
        }
    }

    // MARK: - Emission

    /// Coalesces marks into maximal runs. A no-op shell in `advance` mode.
    /// `language` is the language of the marks being made (T17.8a: the host
    /// sets it around a child's run, which marks through the same emitter);
    /// it splits runs only when `tracksLanguage`.
    private struct Emitter {
        let emit: ((NSRange, LexicalSegment, UInt8) -> Void)?
        let tracksLanguage: Bool
        var language: UInt8 = 0
        private var runStart = 0
        private var runKind: LexicalSegment?
        private var runLanguage: UInt8 = 0
        private var pending: (range: NSRange, kind: LexicalSegment, language: UInt8)?

        init(emit: ((NSRange, LexicalSegment, UInt8) -> Void)?, tracksLanguage: Bool = false) {
            self.emit = emit
            self.tracksLanguage = tracksLanguage
        }

        /// From `at` on, text is `kind` (until the next mark).
        @inline(__always)
        mutating func mark(_ at: Int, _ kind: LexicalSegment) {
            guard emit != nil else { return }
            let markLanguage = tracksLanguage ? language : 0
            guard runKind != kind || runLanguage != markLanguage else { return }
            if let current = runKind, at > runStart {
                push(NSRange(location: runStart, length: at - runStart), current, runLanguage)
            }
            runStart = at
            runKind = kind
            runLanguage = markLanguage
        }

        mutating func finish(at end: Int) {
            guard emit != nil else { return }
            if let current = runKind, end > runStart {
                push(NSRange(location: runStart, length: end - runStart), current, runLanguage)
            }
            if let pending { emit?(pending.range, pending.kind, pending.language) }
            pending = nil
        }

        private mutating func push(_ range: NSRange, _ kind: LexicalSegment, _ language: UInt8) {
            if let p = pending, p.kind == kind, p.language == language, NSMaxRange(p.range) == range.location {
                pending = (NSRange(location: p.range.location, length: p.range.length + range.length), kind, language)
                return
            }
            if let pending { emit?(pending.range, pending.kind, pending.language) }
            pending = (range, kind, language)
        }
    }

    // MARK: - Core

    private func contextKind(_ state: LexicalScanState) -> LexicalSegment {
        switch state.frames.last {
        case nil, .interpolation?: return .code
        case .lineComment?, .blockComment?: return .comment
        case .string?: return .string
        case .heredoc(_, _, let inBody)?: return inBody ? .block(heredocKind ?? .string) : .code
        case .indentedBlock(_, let inBody)?: return inBody ? .block(indentedKind ?? .string) : .code
        case .fence?: return .block(fenceKind ?? .plain)
        case .rawTextTag?: return .code
        // A child body is marked by the child's own run.
        case .rawText(_, let language)?: return language == 0 ? .block(.plain) : .code
        case .jsxTag(_, let phase, _, _)?: return phase == 2 || phase == 3 ? .string : .atom(.plain)
        case .jsxText?: return .atom(.plain)
        case .jsxExpression?: return .code
        }
    }

    @inline(__always)
    private static func isLineBreak(_ u: unichar) -> Bool { u == cr || u == lf }

    /// Length of a line-comment opener at `p` that counts there
    /// (`lineCommentPrecededBy`), or nil. Reads `p - 1` at most backward.
    private func lineCommentLength(_ text: NSString, at p: Int, to: Int,
                                   matches: ([unichar], Int, Int) -> Bool) -> Int? {
        let c = text.character(at: p)
        for opener in lineComments where opener[0] == c && matches(opener, p, to) {
            if let context = lineCommentContext, p > 0 {
                let previous = text.character(at: p - 1)
                if !Self.isLineBreak(previous) && !context.contains(previous) { continue }
            }
            return opener.count
        }
        return nil
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
                     state: inout LexicalScanState, emitter: inout Emitter, nested: Bool = false) -> Int {
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

        // Embedded language (T17.8a): the active child's state, unboxed for
        // the run and stored back on return (nil when empty).
        var child = LexicalScanState()
        if hasEmbeds, Self.childLanguage(state.frames.last) != 0, let saved = state.embedded {
            child = saved.state
        }
        var childScanner: (language: UInt8, scanner: LexicalScanner)?
        func storeChild() {
            guard hasEmbeds else { return }
            let language = Self.childLanguage(state.frames.last)
            if language != 0, !child.isEmpty {
                let embedded = LexicalScanState.EmbeddedState(language: Int(language), state: child)
                if state.embedded != embedded { state.embedded = embedded }
            } else if state.embedded != nil {
                state.embedded = nil
            }
        }
        /// Ends the run at `end`: flushes the segments (not in a child's run,
        /// whose host goes on emitting) and stores the child's state.
        func finish(at end: Int) -> Int {
            if !nested { emitter.finish(at: end) }
            storeChild()
            return end
        }
        // A child's own run marks a child body.
        if !(hasEmbeds && Self.childLanguage(state.frames.last) != 0) {
            emitter.mark(from, contextKind(state))
        }

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

        // MARK: Line blocks (all reads text-only and before `to`)

        /// `p` (< `to`) starts a line: the document start, or after LF, or
        /// after a CR not followed by LF (CRLF counts once).
        func startsLine(_ p: Int) -> Bool {
            guard p > 0 else { return true }
            let previous = at(p - 1)
            return previous == Self.lf || (previous == Self.cr && at(p) != Self.lf)
        }
        /// End of a closing line once `q` is past its significant text and
        /// blanks: after its first line-break unit, or the document end; nil
        /// when anything else follows or `to` cuts the line first.
        func closingLineEnd(_ q: Int) -> Int? {
            if q == to { return to == length ? q : nil }
            return Self.isLineBreak(at(q)) ? q + 1 : nil
        }
        /// The heredoc terminator line at line start `ls`, through its line
        /// break unit (or the document end), or nil.
        func heredocTerminatorEnd(_ ls: Int, _ terminator: String, stripTabs: Bool) -> Int? {
            var q = ls
            if stripTabs { while q < to, at(q) == 9 { q += 1 } }
            for u in terminator.utf16 {
                guard q < to, at(q) == u else { return nil }
                q += 1
            }
            return closingLineEnd(q)
        }
        /// After up to 3 spaces from line start `ls`: the position, or nil
        /// when a fourth space follows.
        func afterFenceIndent(_ ls: Int) -> Int? {
            var q = ls
            while q < to, at(q) == 32 {
                if q - ls == 3 { return nil }
                q += 1
            }
            return q
        }
        /// A fence opener at line start `ls`: marker, run length, run end.
        func fenceOpener(_ ls: Int) -> (marker: unichar, length: Int, end: Int)? {
            guard let q = afterFenceIndent(ls), q < to else { return nil }
            let marker = at(q)
            guard marker == 96 || marker == 126 else { return nil }
            var end = q
            while end < to, at(end) == marker { end += 1 }
            return end - q >= 3 ? (marker, end - q, end) : nil
        }
        /// The closing fence line at line start `ls`, through its line break
        /// unit (or the document end), or nil.
        func fenceCloserEnd(_ ls: Int, marker: unichar, length: Int) -> Int? {
            guard var q = afterFenceIndent(ls) else { return nil }
            let runStart = q
            while q < to, at(q) == marker { q += 1 }
            guard q - runStart >= length else { return nil }
            while q < to, at(q) == 32 || at(q) == 9 { q += 1 }
            return closingLineEnd(q)
        }
        /// A block-scalar body line at line start `ls` ends the scalar: it is
        /// indented ≤ `parentIndent` and not blank. When `to` cuts its
        /// leading blanks before that is known, it stays in the body.
        func dedents(_ ls: Int, parentIndent: Int) -> Bool {
            var q = ls
            while q < to, at(q) == 32 {
                if q - ls >= parentIndent { return false }   // deeper than the parent
                q += 1
            }
            while q < to, at(q) == 32 || at(q) == 9 { q += 1 }
            return q < to && !Self.isLineBreak(at(q))
        }
        /// Past the body text of the current line: after its next line break
        /// unit, or the plain-run end at `limit`.
        func skipBodyLine(_ limit: Int) -> Int {
            let hit = text.rangeOfCharacter(from: Self.lineBreaks, options: [],
                                            range: NSRange(location: pos, length: limit - pos))
            return hit.location == NSNotFound ? afterPlainRun(limit) : hit.location + 1
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
            if code, jsxTypeScript, insideTypeParameterCheck(q) { return false }
            return true
        }
        /// TSX (T17.8b): `q` lies in the text a `<`'s type-parameter check
        /// reads (`<T |,`): after `<`, an identifier and blanks.
        func insideTypeParameterCheck(_ q: Int) -> Bool {
            let floor = max(0, q - Self.typeParameterReach - 1)
            var k = q - 1
            while k >= floor, at(k) == 32 || at(k) == 9 { k -= 1 }
            let identifierEnd = k
            while k >= floor, Self.isJSXIdentifierPart(at(k)) { k -= 1 }
            guard k >= floor, k < identifierEnd, at(k) == 60 else { return false }   // <
            return Self.isJSXNameStart(at(k + 1))
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
            case .heredoc(_, _, false)?: markers = codeMarkers; code = true
            // A body is like string content: only line breaks matter.
            case .heredoc(_, _, true)?, .indentedBlock(_, true)?, .fence(_, _, true, _)?, .rawText?:
                markers = Self.lineBreaks; code = false
            case .indentedBlock(_, false)?: markers = Self.nonBlank; code = false
            // JSX (T17.8b): in a tag every non-blank unit starts a token
            // (names are read whole); strings and type arguments end at their
            // closer; text at a child tag or an expression.
            case .jsxTag(_, let phase, _, _)?:
                switch phase {
                case 2: markers = Self.doubleQuote
                case 3: markers = Self.singleQuote
                case 4: markers = Self.angleBrackets
                default: markers = Self.tagNonBlank
                }
                code = false
            case .jsxText?: markers = Self.jsxTextMarkers; code = false
            case .jsxExpression?: markers = jsxExpressionMarkers; code = true
            case .fence(let marker, _, false, _)?:
                markers = marker == 96 ? Self.backtickInfoMarkers : Self.lineBreaks; code = false
            // Each unit of a start tag is a step of its own; only the opener
            // (`<script` + its delimiter) is one token.
            case .rawTextTag(let element, let phase, let start)?:
                let afterName = start + 1 + rawElements[Int(element)].name.count
                let windowEnd = min(to, pos + Self.safePointWindow)
                let hit = text.rangeOfCharacter(from: Self.tagMarkers(phase: phase), options: [],
                                                range: NSRange(location: pos, length: windowEnd - pos))
                let bound = hit.location == NSNotFound ? windowEnd : hit.location
                var q = pos
                while q <= bound {
                    if q != afterName, friendly(q, code: false) { return q }
                    q += 1
                }
                return nil
            }
            let windowEnd = min(to, pos + Self.safePointWindow)
            // A forward search starting on a low surrogate skips the next
            // unit (Foundation); start on the pair's first unit instead.
            let searchStart = pos > from && isLowSurrogate(pos) ? pos - 1 : pos
            let hit = text.rangeOfCharacter(from: markers, options: [],
                                            range: NSRange(location: searchStart, length: windowEnd - searchStart))
            let bound = hit.location == NSNotFound ? windowEnd : hit.location
            // A JSX element's `<` and the unit after it are one token.
            var avoid = -1
            if case .jsxTag(_, 0, false, _)? = state.frames.last, pos > 0, at(pos - 1) == 60 { avoid = pos }
            var q = pos
            while q <= bound {
                if q != avoid, friendly(q, code: code) { return q }
                q += 1
            }
            return nil
        }

        // MARK: Embedded bodies (T17.8a)

        /// End of one step through an embedded body: the range end, or
        /// `embedWindow` past the target (past `pos` beyond it) when stopping;
        /// never inside a surrogate pair.
        func embedStepEnd() -> Int {
            let base = target.map { max(pos, $0) } ?? to
            var end = min(to, base + Self.embedWindow)
            if end < to, isLowSurrogate(end) { end += 1 }
            return end
        }
        /// Start of the first end tag of `raw` (`</name` + blank, `/` or `>`)
        /// starting in `[pos, before)`, read up to `to`.
        func rawTextEnd(_ raw: RawElement, before: Int) -> Int? {
            var s = pos > from && isLowSurrogate(pos) ? pos - 1 : pos
            let length = raw.name.count
            while s < before {
                let hit = text.range(of: "</", options: .literal,
                                     range: NSRange(location: s, length: min(to, before + 1) - s))
                guard hit.location != NSNotFound, hit.location < before else { return nil }
                let p = hit.location
                if p + 2 + length < to, Self.matchesName(raw.name, in: text, at: p + 2),
                   Self.isTagDelimiter(at(p + 2 + length)) {
                    return p
                }
                s = p + 1
            }
            return nil
        }
        /// The first line start in `(pos, before)` followed by up to 3 spaces
        /// and `marker` — where a fence closer may stand.
        func nextFenceCandidate(_ marker: unichar, before: Int) -> Int? {
            let markers = marker == 96 ? Self.backtick : Self.tilde
            var s = pos
            while s < before {
                let hit = text.rangeOfCharacter(from: markers, options: [],
                                                range: NSRange(location: s, length: before - s))
                guard hit.location != NSNotFound else { return nil }
                let m = hit.location
                var ls = m
                while ls > pos, m - ls < 3, at(ls - 1) == 32 { ls -= 1 }
                if ls > pos, startsLine(ls) { return ls }
                var e = m + 1
                while e < before, at(e) == marker { e += 1 }
                s = e
            }
            return nil
        }
        /// Runs the child `language` from `pos` to `end` (stopping like this
        /// run) through the same emitter; its position.
        func runChild(_ language: UInt8, to end: Int) -> Int {
            if childScanner?.language != language, let scanner = embeddedScanner(Int(language)) {
                childScanner = (language, scanner)
            }
            guard let scanner = childScanner?.scanner else { return end }
            emitter.language = language
            let q = scanner.run(text, from: pos, to: end, stop: target, state: &child, emitter: &emitter, nested: true)
            emitter.language = 0
            return q
        }

        // MARK: JSX (T17.8b)

        /// One token inside a JSX tag (see `LexicalProfile.JSXForm` and
        /// `LexicalScanState.Frame.jsxTag`); the new position.
        // swiftlint:disable:next cyclomatic_complexity function_body_length
        func jsxTagStep(depth: UInt32, phase: UInt8, closing: Bool, angles: UInt8, limit: Int) -> Int {
            func setPhase(_ next: UInt8, angles: UInt8 = 0) {
                state.frames[state.frames.count - 1] = .jsxTag(depth: depth, phase: next, closing: closing,
                                                               angles: angles)
            }
            switch phase {
            case 2, 3:
                // A string: no escapes, may span lines.
                let hit = text.rangeOfCharacter(from: phase == 2 ? Self.doubleQuote : Self.singleQuote, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { return afterPlainRun(limit) }
                setPhase(1)
                emitter.mark(hit.location + 1, .atom(.plain))
                return hit.location + 1
            case 4:
                // TSX type arguments: identifiers are types; `=>` is no closer.
                var q = pos
                while q < limit {
                    let u = at(q)
                    if u == 60 || u == 62 || Self.isJSXNameStart(u) { break }
                    q += 1
                }
                guard q < limit else { return afterPlainRun(limit) }
                let u = at(q)
                if u == 60 {
                    setPhase(4, angles: angles == UInt8.max ? angles : angles + 1)
                    return q + 1
                }
                if u == 62 {
                    if q > 0, at(q - 1) == 61 { return q + 1 }             // =>
                    if angles <= 1 { setPhase(1) } else { setPhase(4, angles: angles - 1) }
                    return q + 1
                }
                var e = q + 1
                while e < to, Self.isJSXIdentifierPart(at(e)) { e += 1 }
                emitter.mark(q, .atom(.type))
                emitter.mark(e, .atom(.plain))
                return e
            default:
                break
            }
            // Phases 0 and 1: the next token after blanks (usually at `pos`).
            var p = pos
            var c = at(p)
            if c == 32 || c == 9 || c == 10 || c == 12 || c == 13 {
                let hit = text.rangeOfCharacter(from: Self.tagNonBlank, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { return afterPlainRun(limit) }
                p = hit.location
                c = at(p)
            }
            switch c {
            case 62:                                                        // >
                return endJSXTag(at: p, end: p + 1, depth: depth, closing: closing, selfClosing: false)
            case 47:                                                        // /
                if p + 1 < to, at(p + 1) == 62 {
                    return endJSXTag(at: p, end: p + 2, depth: depth, closing: closing, selfClosing: true)
                }
                if let count = lineCommentLength(text, at: p, to: to, matches: matches),
                   Self.push(.lineComment, &state) {
                    emitter.mark(p, .comment)
                    return p + count
                }
                for (index, block) in blocks.enumerated() where block.open[0] == c && matches(block.open, p, to) {
                    guard Self.push(.blockComment(form: UInt8(index), depth: 1), &state) else { break }
                    emitter.mark(p, .comment)
                    return p + block.open.count
                }
                return p + 1
            case 123:                                                       // {
                if Self.push(.jsxExpression(braces: 0), &state) {
                    emitter.mark(p, .interpolationDelimiter)
                    emitter.mark(p + 1, .code)
                    codeStart = p + 1
                }
                return p + 1
            case 34, 39:                                                    // " '
                setPhase(c == 34 ? 2 : 3)
                emitter.mark(p, .string)
                return p + 1
            case 60:                                                        // <
                // TSX type arguments right after the tag name.
                if jsxTypeScript, !closing, phase == 1, p > 0, Self.isJSXNamePart(at(p - 1)) {
                    setPhase(4, angles: 1)
                }
                return p + 1
            default:
                guard Self.isJSXNameStart(c) else {
                    if phase == 0 { setPhase(1) }
                    return p + 1
                }
                var e = p + 1
                while e < to, Self.isJSXNamePart(at(e)) { e += 1 }
                if phase == 0 {
                    markJSXTagName(from: p, to: e)
                    setPhase(1)
                } else {
                    emitter.mark(p, .atom(.attributeName))
                }
                emitter.mark(e, .atom(.plain))
                return e
            }
        }
        /// Colours a tag name: a lowercase intrinsic tag or a component
        /// (each part of `ns:name` on its own, the `:` plain).
        func markJSXTagName(from start: Int, to end: Int) {
            var local = start
            var q = start
            while q < end, at(q) != 58 { q += 1 }                           // :
            if q < end {
                emitter.mark(start, .atom(.tagName))
                emitter.mark(q, .atom(.plain))
                local = q + 1
            }
            guard local < end else { return }
            var intrinsic = (97...122).contains(at(local))
            var k = local + 1
            while intrinsic, k < end {
                let u = at(k)
                intrinsic = (97...122).contains(u) || (48...57).contains(u)
                k += 1
            }
            emitter.mark(local, .atom(intrinsic ? .tagName : .type))
        }
        /// The tag's `>` (or `/>`) at `p`: the children of the element it
        /// opens, the parent's children after a self-closing or closing tag,
        /// or — when the tree's outermost element ends — the context below.
        func endJSXTag(at p: Int, end: Int, depth: UInt32, closing: Bool, selfClosing: Bool) -> Int {
            emitter.mark(p, .atom(.tagPunctuation))
            let remaining: UInt32
            if closing {
                remaining = depth > 0 ? depth - 1 : 0
            } else if selfClosing {
                remaining = depth
            } else {
                remaining = depth == UInt32.max ? depth : depth + 1
            }
            if remaining == 0 {
                state.frames.removeLast()
                emitter.mark(end, contextKind(state))
                codeStart = end
            } else {
                state.frames[state.frames.count - 1] = .jsxText(depth: remaining)
                emitter.mark(end, .atom(.plain))
            }
            return end
        }

        while pos < to {
            if hasEmbeds, let top = state.frames.last {
                if case .rawText(let element, let language) = top {
                    let raw = rawElements[Int(element)]
                    let stepEnd = embedStepEnd()
                    let end = rawTextEnd(raw, before: stepEnd)
                    let bodyEnd = end ?? stepEnd
                    if bodyEnd > pos {
                        if language == 0 {
                            // Plain text: like string content.
                            if let target {
                                var q = max(pos, target)
                                while q < bodyEnd, !friendly(q, code: false) { q += 1 }
                                if q < bodyEnd { return finish(at: q) }
                            }
                        } else {
                            let q = runChild(language, to: bodyEnd)
                            if target != nil, q < bodyEnd { return finish(at: q) }
                        }
                        pos = bodyEnd
                    }
                    if let end, pos == end {
                        // The end tag is host code, its delimiter included.
                        state.frames.removeLast()
                        child = LexicalScanState()
                        emitter.mark(end, .code)
                        pos = end + raw.name.count + 3
                        codeStart = pos
                    }
                    continue
                }
                if case .fence(let marker, let length, true, let language) = top, language != 0 {
                    if startsLine(pos), let end = fenceCloserEnd(pos, marker: unichar(marker), length: Int(length)) {
                        state.frames.removeLast()
                        child = LexicalScanState()
                        emitter.mark(pos, .block(fenceKind ?? .plain))
                        pos = end
                        codeStart = end
                        emitter.mark(end, contextKind(state))
                        continue
                    }
                    let stepEnd = embedStepEnd()
                    let chunkEnd = nextFenceCandidate(unichar(marker), before: stepEnd) ?? stepEnd
                    let q = runChild(language, to: chunkEnd)
                    if target != nil, q < chunkEnd { return finish(at: q) }
                    pos = chunkEnd
                    continue
                }
            }
            // Phase B: past the target, stop at the first safe point.
            if let target, pos >= target, let q = safePoint() {
                return finish(at: q)
            }
            // Phase A: before the target, marker searches end there.
            let limit = target.map { pos < $0 ? $0 : to } ?? to
            guard let top = state.frames.last else {
                // A fence opens only at a line start, before anything else.
                if fenceKind != nil, startsLine(pos), let fence = fenceOpener(pos),
                   Self.push(.fence(marker: fence.marker, length: UInt16(min(fence.length, Int(UInt16.max))),
                                    inBody: false), &state) {
                    emitter.mark(pos, contextKind(state))
                    pos = fence.end
                    continue
                }
                pos = scanCode(text, pos, to, limit, &state, &emitter, &codeStart, inInterpolation: false,
                               matches: matches, prefixStart: prefixStart, boundary: boundary)
                if pos == limit, limit < to { pos = afterPlainRun(limit) }
                continue
            }
            switch top {
            case .rawTextTag(let element, let phase, let start):
                let hit = text.rangeOfCharacter(from: Self.tagMarkers(phase: phase), options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                let c = at(p)
                var next: UInt8 = 0
                switch phase {
                case 0: next = c == 61 ? 1 : 0                              // =
                case 1: next = c == 34 ? 2 : c == 39 ? 3 : c == 62 ? 0 : 4  // " ' >
                case 2, 3: next = 0
                default: next = 0
                }
                if c == 62, phase != 2, phase != 3 {                        // > ends the tag
                    pos = enterRawTextBody(text, element: element, start: start, gt: p,
                                           state: &state, emitter: &emitter)
                    child = LexicalScanState()
                    codeStart = pos
                    break
                }
                state.frames[state.frames.count - 1] = .rawTextTag(element: element, phase: next, start: start)
                pos = p + 1

            case .rawText:
                // Handled above (embedded bodies).
                pos = to

            case .jsxTag(let depth, let phase, let closing, let angles):
                pos = jsxTagStep(depth: depth, phase: phase, closing: closing, angles: angles, limit: limit)

            case .jsxText(let depth):
                let hit = text.rangeOfCharacter(from: Self.jsxTextMarkers, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                if at(p) == 123 {                                           // {
                    pos = p + 1
                    if Self.push(.jsxExpression(braces: 0), &state) {
                        emitter.mark(p, .interpolationDelimiter)
                        emitter.mark(p + 1, .code)
                        codeStart = p + 1
                    }
                    break
                }
                // `<` + its next unit is one token: `</`, `<name`, `<>`.
                guard p + 1 < to else { pos = p + 1; break }
                let next = at(p + 1)
                let closingTag = next == 47                                 // /
                guard closingTag || next == 62 || Self.isJSXNameStart(next) else { pos = p + 1; break }
                state.frames[state.frames.count - 1] = .jsxTag(depth: depth, phase: 0, closing: closingTag, angles: 0)
                emitter.mark(p, .atom(.tagPunctuation))
                pos = closingTag ? p + 2 : p + 1
                emitter.mark(pos, .atom(.plain))

            case .jsxExpression:
                pos = scanCode(text, pos, to, limit, &state, &emitter, &codeStart, inInterpolation: false,
                               inJSXExpression: true, matches: matches, prefixStart: prefixStart, boundary: boundary)
                if pos == limit, limit < to { pos = afterPlainRun(limit) }

            case .heredoc(_, _, false):
                // The rest of the opener line: code; its line break starts the body.
                pos = scanCode(text, pos, to, limit, &state, &emitter, &codeStart, inInterpolation: false,
                               matches: matches, prefixStart: prefixStart, boundary: boundary)
                if pos == limit, limit < to { pos = afterPlainRun(limit) }

            case .heredoc(let terminator, let stripTabs, true):
                if startsLine(pos), let end = heredocTerminatorEnd(pos, terminator, stripTabs: stripTabs) {
                    // The terminator line is code, like the opener's delimiter.
                    state.frames.removeLast()
                    emitter.mark(pos, contextKind(state))
                    pos = end
                    codeStart = end
                    break
                }
                pos = skipBodyLine(limit)

            case .fence(let marker, let length, false, _):
                let markers = marker == 96 ? Self.backtickInfoMarkers : Self.lineBreaks
                let hit = text.rangeOfCharacter(from: markers, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                if Self.isLineBreak(at(p)) {
                    let language = fenceLanguage(text, lineBreak: p)
                    state.frames[state.frames.count - 1] = .fence(marker: marker, length: length, inBody: true,
                                                                  language: language)
                    pos = p + 1
                    if language != 0 {
                        // The opener line's CRLF stays the host's.
                        child = LexicalScanState()
                        if at(p) == Self.cr, p + 1 < to, at(p + 1) == Self.lf { pos = p + 2 }
                    }
                } else {
                    // A backtick in a backtick fence's info string: no fence.
                    state.frames.removeLast()
                    emitter.mark(p, contextKind(state))
                    pos = p
                    codeStart = p
                }

            case .fence(let marker, let length, true, _):
                if startsLine(pos), let end = fenceCloserEnd(pos, marker: unichar(marker), length: Int(length)) {
                    state.frames.removeLast()
                    pos = end
                    codeStart = end
                    emitter.mark(end, contextKind(state))
                    break
                }
                pos = skipBodyLine(limit)

            case .indentedBlock(let parentIndent, false):
                // The rest of the indicator line: blanks and a comment only.
                let hit = text.rangeOfCharacter(from: Self.nonBlank, options: [],
                                                range: NSRange(location: pos, length: limit - pos))
                guard hit.location != NSNotFound else { pos = afterPlainRun(limit); break }
                let p = hit.location
                if Self.isLineBreak(at(p)) {
                    state.frames[state.frames.count - 1] = .indentedBlock(parentIndent: parentIndent, inBody: true)
                    pos = p + 1
                    emitter.mark(pos, contextKind(state))
                } else if let count = lineCommentLength(text, at: p, to: to, matches: matches),
                          Self.push(.lineComment, &state) {
                    emitter.mark(p, .comment)
                    pos = p + count
                } else {
                    // Anything else: no block scalar; the line goes on as code.
                    state.frames.removeLast()
                    emitter.mark(p, contextKind(state))
                    pos = p
                }

            case .indentedBlock(let parentIndent, true):
                if startsLine(pos), dedents(pos, parentIndent: Int(parentIndent)) {
                    state.frames.removeLast()
                    emitter.mark(pos, contextKind(state))
                    codeStart = pos
                    break
                }
                pos = skipBodyLine(limit)

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
                    // character — or a longer form (`escapeForms`); CRLF
                    // after it counts as one line continuation, a surrogate
                    // pair as one character (a search must never start on a
                    // low surrogate: Foundation then skips a unit).
                    var q = afterEscape
                    if q < to {
                        let escaped = at(q)
                        let pair = q + 1 < to
                            && ((escaped == Self.cr && at(q + 1) == Self.lf)
                                || ((0xD800...0xDBFF).contains(escaped) && (0xDC00...0xDFFF).contains(at(q + 1))))
                        if pair {
                            q += 2
                        } else if !spec.escapeForms.isEmpty,
                                  let end = Self.longEscapeEnd(text, escaped: q, to: to, forms: spec.escapeForms) {
                            q = end
                        } else {
                            q += 1
                        }
                    }
                    q = min(q, to)
                    emitter.mark(p, .escape)
                    emitter.mark(q, contextKind(state))
                    pos = q
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
                            // Escaped closer: content, or an escape segment.
                            if spec.doubledCloseIsEscape {
                                emitter.mark(p, .escape)
                                emitter.mark(again, contextKind(state))
                            }
                            pos = again
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
                if !handled, let prefix = spec.variablePrefix, c == prefix, p + 1 < to {
                    // A variable reference (`$name`, `$1`, `$@`).
                    let next = at(p + 1)
                    var end = p
                    if next == 95 || (65...90).contains(next) || (97...122).contains(next) {
                        end = p + 2
                        while end < to, Self.isIdentifier(at(end)), at(end) < 128 { end += 1 }
                    } else if (48...57).contains(next) || [UInt16(64), 35, 63, 42, 36, 33, 45].contains(next) {
                        end = p + 2                                     // 0-9 @ # ? * $ ! -
                    }
                    if end > p {
                        emitter.mark(p, .atom(.symbolVariable))
                        emitter.mark(end, contextKind(state))
                        pos = end
                        handled = true
                    }
                }
                if !handled { pos = p + 1 }
            }
        }
        return finish(at: to)
    }

    @inline(__always)
    private static func childLanguage(_ frame: LexicalScanState.Frame?) -> UInt8 {
        switch frame {
        case .rawText(_, let language)?: return language
        case .fence(_, _, true, let language)?: return language
        default: return 0
        }
    }

    /// A unit that may follow a raw-text element's name in its start or end
    /// tag: a blank, `/` or `>`.
    @inline(__always)
    private static func isTagDelimiter(_ u: unichar) -> Bool {
        u == 32 || u == 9 || u == 10 || u == 12 || u == 13 || u == 47 || u == 62
    }

    private static let backtick = CharacterSet(charactersIn: "`")
    private static let tilde = CharacterSet(charactersIn: "~")

    /// A raw-text start tag opener at `p` (a `<`): the element and the
    /// position after the name and its delimiter — or, when the delimiter
    /// is `>`, at the `>` (the tag machine ends the tag there). Reads
    /// forward only, before `to`.
    private func rawTextOpener(_ text: NSString, at p: Int, to: Int) -> (element: Int, end: Int)? {
        guard p + 1 < to else { return nil }
        let first = text.character(at: p + 1) | 0x20   // ASCII lowercase
        for index in 0..<rawElements.count where rawElements[index].name[0] == first {
            let name = rawElements[index].name
            let n = name.count
            guard p + 1 + n < to, Self.matchesName(name, in: text, at: p + 1) else { continue }
            let delimiter = text.character(at: p + 1 + n)
            guard Self.isTagDelimiter(delimiter) else { continue }
            return (index, delimiter == 62 ? p + 1 + n : p + 2 + n)
        }
        return nil
    }

    /// `name` (lowercase ASCII letters) at `at`, in any case; the caller
    /// checks that it fits before the range end.
    @inline(__always)
    private static func matchesName(_ name: [unichar], in text: NSString, at: Int) -> Bool {
        var k = 0
        while k < name.count {
            if text.character(at: at + k) | 0x20 != name[k] { return false }
            k += 1
        }
        return true
    }

    /// The start tag of raw-text element `element` from the `<` at `start`
    /// ends with the `>` at `gt`: replaces its frame (or pushes) the body's,
    /// marks a plain body, and returns the body start.
    // swiftlint:disable:next function_parameter_count
    private func enterRawTextBody(_ text: NSString, element: UInt8, start: Int, gt: Int,
                                  state: inout LexicalScanState, emitter: inout Emitter) -> Int {
        let language = rawTextLanguage(text, element: Int(element), start: start, gt: gt)
        let frame = LexicalScanState.Frame.rawText(element: element, language: language)
        if case .rawTextTag? = state.frames.last {
            state.frames[state.frames.count - 1] = frame
        } else {
            _ = Self.push(frame, &state)
        }
        if language == 0 { emitter.mark(gt + 1, .block(.plain)) }
        return gt + 1
    }

    /// The body language of a raw-text start tag from `start` (its `<`) to
    /// `gt` (its `>`): the first `type` attribute's value, trimmed and
    /// lowercased, through the element's table. Reads `text[start, gt)`, at
    /// most `startTagReach` units (text only).
    private func rawTextLanguage(_ text: NSString, element: Int, start: Int, gt: Int) -> UInt8 {
        let raw = rawElements[element]
        let end = min(gt, start + Self.startTagReach)
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        func blank(_ u: unichar) -> Bool { u == 32 || u == 9 || u == 10 || u == 12 || u == 13 }
        func lowered(_ from: Int, _ to: Int) -> String {
            text.substring(with: NSRange(location: from, length: to - from)).lowercased()
        }
        var q = start + 1 + raw.name.count
        while q < end {
            while q < end, blank(at(q)) || at(q) == 47 { q += 1 }    // /
            guard q < end else { break }
            let nameStart = q
            while q < end, !blank(at(q)), at(q) != 47, at(q) != 61, at(q) != 62 { q += 1 }
            if q == nameStart { q += 1; continue }                   // a stray `=`
            let name = lowered(nameStart, q)
            var r = q
            while r < end, blank(at(r)) { r += 1 }
            var value: String?
            if r < end, at(r) == 61 {                                 // =
                r += 1
                while r < end, blank(at(r)) { r += 1 }
                if r < end, at(r) == 34 || at(r) == 39 {
                    let quote = at(r)
                    let valueStart = r + 1
                    r = valueStart
                    while r < end, at(r) != quote { r += 1 }
                    value = lowered(valueStart, r)
                    if r < end { r += 1 }
                } else {
                    let valueStart = r
                    while r < end, !blank(at(r)), at(r) != 62 { r += 1 }
                    value = lowered(valueStart, r)
                }
                q = r
            }
            if name == "type" {
                let key = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.typeLanguages[key] ?? raw.otherTypesLanguage
            }
        }
        return raw.language
    }

    /// The embedded language of a fence whose opener line ends with the line
    /// break at `lineBreak`: the info string's first word through
    /// `fenceAliases`, or 0. Reads the opener line back from `lineBreak`, at
    /// most `fenceInfoReach` units (text only).
    private func fenceLanguage(_ text: NSString, lineBreak p: Int) -> UInt8 {
        guard !fenceAliases.isEmpty else { return 0 }
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        let floor = max(0, p - Self.fenceInfoReach)
        var ls = p
        while ls > floor, !Self.isLineBreak(at(ls - 1)) { ls -= 1 }
        if ls == floor, floor > 0, !Self.isLineBreak(at(floor - 1)) { return 0 }
        var q = ls
        while q < p, at(q) == 32 { q += 1 }
        let marker = at(q)
        while q < p, at(q) == marker { q += 1 }
        while q < p, at(q) == 32 || at(q) == 9 { q += 1 }
        let wordStart = q
        while q < p {
            let u = at(q)
            // blank { , : ? `
            if u == 32 || u == 9 || u == 123 || u == 44 || u == 58 || u == 63 || u == 96 { break }
            q += 1
        }
        guard q > wordStart, q - wordStart <= 32 else { return 0 }
        let word = text.substring(with: NSRange(location: wordStart, length: q - wordStart)).lowercased()
        return fenceAliases[word] ?? 0
    }

    // MARK: - JSX (T17.8b)

    private static let constWord = Array("const".utf16)
    private static let extendsWord = Array("extends".utf16)

    /// A unit that may start a JSX tag or attribute name, or a TSX type
    /// argument identifier: an ASCII letter, `_`, `$`, or ≥ U+0080 except a
    /// low surrogate and the blanks `DeclTokenizer` treats as spaces.
    @inline(__always)
    static func isJSXNameStart(_ u: unichar) -> Bool {
        if u < 128 { return (97...122).contains(u) || (65...90).contains(u) || u == 95 || u == 36 }
        return !(0xDC00...0xDFFF).contains(u) && u != 0xA0 && u != 0xFEFF && u != 0x2028 && u != 0x2029
            && u != 0x3000
    }

    /// An identifier unit after the first (`isJSXNameStart`, digits, low surrogates).
    @inline(__always)
    static func isJSXIdentifierPart(_ u: unichar) -> Bool {
        isJSXNameStart(u) || (48...57).contains(u) || (0xDC00...0xDFFF).contains(u)
    }

    /// A unit of a JSX tag or attribute name after the first: identifier
    /// units, `-`, `.`, `:`.
    @inline(__always)
    static func isJSXNamePart(_ u: unichar) -> Bool {
        isJSXIdentifierPart(u) || u == 45 || u == 46 || u == 58
    }

    /// The `<` at `p` (in code) opens a JSX element: an identifier start or
    /// `>` follows, the context before it allows an expression, and — TSX —
    /// it is no type parameter list (`<T,`, `<T =`, `<T extends`, `<const T`,
    /// read forward on the line, before `to`; an identifier and blanks
    /// longer than `typeParameterReach` make an element). A cut before the
    /// check is decided also makes an element, so safe points avoid that
    /// text (`insideTypeParameterCheck`).
    private func opensJSX(_ text: NSString, at p: Int, to: Int) -> Bool {
        guard let context = jsxContext, p + 1 < to else { return false }
        let next = text.character(at: p + 1)
        guard next == 62 || Self.isJSXNameStart(next) else { return false }
        guard Self.allows(context, before: p, in: text) else { return false }
        guard jsxTypeScript, next != 62 else { return true }
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        let reach = min(to, p + 1 + Self.typeParameterReach)
        var e = p + 2
        while e < reach, Self.isJSXIdentifierPart(at(e)) { e += 1 }
        var f = e
        while f < reach, at(f) == 32 || at(f) == 9 { f += 1 }
        guard f < reach else { return true }
        let u = at(f)
        if u == 44 || u == 61 { return false }                               // , =
        guard f > e else { return true }
        // `<const T`: the identifier is `const`, a name follows the blanks.
        if e - (p + 1) == 5, at(p + 1) == 99, Self.isJSXNameStart(u) {     // c
            var k = 1
            while k < 5, at(p + 1 + k) == Self.constWord[k] { k += 1 }
            if k == 5 { return false }
        }
        // `<T extends`: the word `extends`, then no identifier unit.
        if u == 101, f + 7 <= to {                                           // e
            var k = 1
            while k < 7, at(f + k) == Self.extendsWord[k] { k += 1 }
            if k == 7, f + 7 == to || !Self.isJSXIdentifierPart(at(f + 7)) { return false }
        }
        return true
    }

    /// End of a long escape whose escaped character is at `q` (`escapeForms`),
    /// or nil when none applies there (the escape is then one character).
    /// Reads forward from `q`, never at or past `to`, never past a line break.
    private static func longEscapeEnd(_ text: NSString, escaped q: Int, to: Int,
                                      forms: LexicalProfile.EscapeForms) -> Int? {
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        func isHex(_ u: unichar) -> Bool {
            (48...57).contains(u) || (65...70).contains(u) || (97...102).contains(u)
        }
        /// Hex digits from `start`, at most `limit`; the end position.
        func hexRun(from start: Int, limit: Int) -> Int {
            var e = start
            while e < to, e - start < limit, isHex(at(e)) { e += 1 }
            return e
        }
        let c = at(q)
        switch c {
        case 120:   // x
            if forms.contains(.hexRun) {
                let e = hexRun(from: q + 1, limit: 8)
                return e > q + 1 ? e : nil
            }
            if forms.contains(.hex2) {
                let e = hexRun(from: q + 1, limit: 2)
                return e == q + 3 ? e : nil
            }
        case 117:   // u
            if forms.contains(.unicodeBraced), q + 1 < to, at(q + 1) == 123 {
                var e = q + 2
                while e < to, e - (q + 2) < 8, isHex(at(e)) || at(e) == 95 { e += 1 }
                if e > q + 2, e < to, at(e) == 125 { return e + 1 }
            }
            if forms.contains(.unicode4) {
                let e = hexRun(from: q + 1, limit: 4)
                if e == q + 5 { return e }
            }
        case 85:    // U
            if forms.contains(.unicode8) {
                let e = hexRun(from: q + 1, limit: 8)
                if e == q + 9 { return e }
            }
        default:
            break
        }
        if forms.contains(.octal), (48...55).contains(c) {
            var e = q + 1
            while e < to, e - q < 3, (48...55).contains(at(e)) { e += 1 }
            return e
        }
        if forms.contains(.cssHex), isHex(c) {
            return hexRun(from: q, limit: 6)
        }
        return nil
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
                          inInterpolation: Bool, inJSXExpression: Bool = false,
                          matches: ([unichar], Int, Int) -> Bool,
                          prefixStart: ([[unichar]], Int, Int, Bool) -> Int?,
                          boundary: (Int) -> Bool) -> Int {
        let markers = inInterpolation ? interpolationMarkers : inJSXExpression ? jsxExpressionMarkers : codeMarkers
        let hit = text.rangeOfCharacter(from: markers, options: [],
                                        range: NSRange(location: pos, length: limit - pos))
        guard hit.location != NSNotFound else { return limit }
        let p = hit.location
        let c = text.character(at: p)

        if c == Self.cr || c == Self.lf {
            if case .heredoc(let terminator, let stripTabs, false)? = state.frames.last {
                // The heredoc opener line ends: the body starts.
                state.frames[state.frames.count - 1] = .heredoc(terminator: terminator, stripTabs: stripTabs,
                                                                inBody: true)
                emitter.mark(p + 1, contextKind(state))
                return p + 1
            }
            if inInterpolation, let cut = lineEndCut(state) {
                state.frames.removeSubrange(cut...)
                codeStart = p + 1
            }
            return p + 1
        }

        // Units that start no comment, string, atom, raw-text tag or line
        // block (brackets, closers, a JSX `<`) skip those checks (T17.8b).
        let mayOpen = c < 128 ? openerMask[Int(c) >> 6] & (1 << UInt64(c & 63)) != 0 : openersBeyondASCII
        if mayOpen {
            if let count = lineCommentLength(text, at: p, to: to, matches: matches), Self.push(.lineComment, &state) {
                emitter.mark(p, .comment)
                return p + count
            }

            for (index, block) in blocks.enumerated() where block.open[0] == c && matches(block.open, p, to) {
                guard Self.push(.blockComment(form: UInt8(index), depth: 1), &state) else { break }
                emitter.mark(p, .comment)
                return p + block.open.count
            }

            // A raw-text element's start tag (T17.8a), only outside every construct.
            if c == 60, !rawElements.isEmpty, !inInterpolation, state.frames.isEmpty,
               let opener = rawTextOpener(text, at: p, to: to),
               Self.push(.rawTextTag(element: UInt8(opener.element), phase: 0, start: p), &state) {
                return opener.end
            }
        }

        // A JSX element (T17.8b) in an expression position.
        if c == 60, jsxContext != nil, opensJSX(text, at: p, to: to),
           Self.push(.jsxTag(depth: 0, phase: 0, closing: false, angles: 0), &state) {
            emitter.mark(p, .atom(.tagPunctuation))
            emitter.mark(p + 1, contextKind(state))
            return p + 1
        }

        if mayOpen {
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

            if heredocKind != nil, c == 60, let opener = heredocOpener(text, at: p, to: to, state: state) {
                if let terminator = opener.terminator {
                    // At the depth cap the opener stays code.
                    _ = Self.push(.heredoc(terminator: terminator, stripTabs: opener.stripTabs, inBody: false), &state)
                }
                return opener.end
            }

            if indentedKind != nil, c == 124 || c == 62, let header = blockScalarHeader(text, at: p, to: to) {
                _ = Self.push(.indentedBlock(parentIndent: header.parentIndent, inBody: false), &state)
                return header.end
            }
        }

        if inJSXExpression, c == 123 || c == 125, case .jsxExpression(let braces)? = state.frames.last {
            if c == 125 {                                                   // }
                if braces == 0 {
                    state.frames.removeLast()
                    emitter.mark(p, .interpolationDelimiter)
                    emitter.mark(p + 1, contextKind(state))
                    codeStart = p + 1
                    return p + 1
                }
                state.frames[state.frames.count - 1] = .jsxExpression(braces: braces - 1)
            } else if c == 123, braces < UInt32.max {                       // {
                state.frames[state.frames.count - 1] = .jsxExpression(braces: braces + 1)
            }
            return p + 1
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
            case .blockComment, .heredoc, .indentedBlock, .fence, .rawTextTag, .rawText, .jsxTag, .jsxText,
                 .jsxExpression:
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
        if let context = spec.context, !Self.allows(context, before: tokenStart, in: text) { return nil }
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

    // MARK: - Line-block openers

    /// A heredoc opener at `p` (a `<`): `end` past the delimiter and
    /// `terminator` = the delimiter word; a here-string `<<<` gives `end`
    /// past it and no terminator. Nil when `p` opens neither, or while the
    /// stack already holds a heredoc whose body has not started (only the
    /// first heredoc of a line is tracked). Reads forward only, before `to`.
    private func heredocOpener(_ text: NSString, at p: Int, to: Int,
                               state: LexicalScanState) -> (end: Int, terminator: String?, stripTabs: Bool)? {
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        guard p + 1 < to, at(p + 1) == 60 else { return nil }
        for frame in state.frames {
            if case .heredoc(_, _, false) = frame { return nil }
        }
        if p + 2 < to, at(p + 2) == 60 { return (p + 3, nil, false) }   // <<< here-string
        var q = p + 2
        var stripTabs = false
        if q < to, at(q) == 45 { stripTabs = true; q += 1 }               // <<-
        while q < to, at(q) == 32 || at(q) == 9 { q += 1 }
        guard q < to else { return nil }
        var quote: unichar?
        switch at(q) {
        case 39, 34: quote = at(q); q += 1                                 // ' "
        case 92: q += 1                                                     // backslash
        default: break
        }
        let wordStart = q
        func isWordHead(_ u: unichar) -> Bool { u == 95 || (65...90).contains(u) || (97...122).contains(u) }
        guard q < to, isWordHead(at(q)) else { return nil }
        q += 1
        while q < to, isWordHead(at(q)) || (48...57).contains(at(q)) { q += 1 }
        let word = text.substring(with: NSRange(location: wordStart, length: q - wordStart))
        if let quote {
            guard q < to, at(q) == quote else { return nil }
            q += 1
        }
        return (q, word, stripTabs)
    }

    /// A block-scalar header at `p` (a `|` or `>`): `end` past its
    /// indicators and the parent indentation (see
    /// `LexicalScanState.Frame.indentedBlock`), or nil when the unit before
    /// it (after blanks) is not `:`, `-`, `?`, a line break or the document
    /// start. Reads back over the opener line (≤ `blockScalarLineReach`)
    /// and forward over at most two indicators, before `to`.
    private func blockScalarHeader(_ text: NSString, at p: Int, to: Int) -> (end: Int, parentIndent: UInt16)? {
        @inline(__always) func at(_ i: Int) -> unichar { text.character(at: i) }
        let floor = max(0, p - LexicalProfile.AtomContext.reach)
        var q = p - 1
        while q >= floor, at(q) == 32 || at(q) == 9 { q -= 1 }
        if q >= 0 {
            guard q >= floor else { return nil }
            let u = at(q)
            guard Self.isLineBreak(u) || u == 58 || u == 45 || u == 63 else { return nil }   // : - ?
        }
        var end = p + 1
        var sign = false, digit = false
        while end < to {
            let u = at(end)
            if !sign, u == 45 || u == 43 { sign = true } else if !digit, (49...57).contains(u) { digit = true } else { break }
            end += 1
        }

        // Parent indentation from the opener line's start.
        let reachStart = max(0, p - Self.blockScalarLineReach)
        let hit = text.rangeOfCharacter(from: Self.lineBreaks, options: .backwards,
                                        range: NSRange(location: reachStart, length: p - reachStart))
        let lineStart: Int
        if hit.location != NSNotFound {
            lineStart = hit.location + 1
        } else if reachStart == 0 {
            lineStart = 0
        } else {
            return (end, UInt16.max)
        }
        var c = lineStart
        while c < p, at(c) == 32 { c += 1 }
        var lastMarker: Int?
        while c + 1 < p, at(c) == 45, at(c + 1) == 32 || at(c + 1) == 9 {   // "- "
            lastMarker = c
            c += 1
            while c < p, at(c) == 32 || at(c) == 9 { c += 1 }
        }
        let column = (c == p ? lastMarker ?? c : c) - lineStart
        return (end, UInt16(min(column, Int(UInt16.max))))
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
            if u == cr || u == lf {
                if context.lineStart { return true }   // first on its line
            } else if u != 32 && u != 9 {
                break
            }
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
