import Foundation

// M17 T17.4a — the lightweight token stream the declaration walkers read
// (T17.4b: also the seven brace languages).
//
// Built from the generic lexical scanner's *code* segments only (strings,
// comments and regex literals become a single `literal` token, or nothing),
// so a `def` in a comment or a `function` in a string can never look like a
// declaration. Only what the walkers need is distinguished: identifiers (with
// a keyword id), the punctuation that shapes declarations, literals, template
// / f-string interpolation boundaries and — for Python — logical line ends.
//
// Pure value code (`Sendable`), no AppKit.

/// Token kinds the walkers distinguish. Everything else is `.op`.
enum DeclTokenKind: UInt8, Sendable {
    case ident, literal
    case lparen, rparen, lbracket, rbracket, lbrace, rbrace
    case comma, colon, semicolon
    /// `=` (assignment / default / initializer).
    case assign
    /// `+=`, `-=`, `??=`, `//=`, … (never a new binding).
    case augAssign
    /// `.` and JS `?.`.
    case dot
    /// `=>`.
    case arrow
    case star, doubleStar, ellipsis, question, less, greater, at
    /// Python `:=`.
    case walrus
    /// Python `->`.
    case thinArrow
    /// `!` (TS definite assignment / non-null).
    case bang
    case op
    /// Python logical line end (emitted by the tokenizer, never by text).
    case newline
    /// Template literal `${` / f-string `{`, and their closers.
    case interpOpen, interpClose
}

/// Keywords of both families. Which words are keywords depends on the
/// family's table (`DeclKeywords.python` / `.javascript`); contextual words
/// (`type`, `of`, `get`, `match`, …) are listed so walkers can recognise them,
/// and `isBindable` tells whether such a word may still be a binding name.
enum DeclKeyword: UInt8, Sendable {
    case none = 0
    // Shared / Python
    case def, `class`, lambda, `for`, `in`, `if`, elif, `else`, `while`, with, `as`, `try`, except
    case finally, `import`, from, global, nonlocal, `return`, yield, async, await, pass, `break`
    case `continue`, raise, del, assert, not, and, or, `is`, match, `case`
    // JavaScript / TypeScript
    case function, const, `let`, `var`, new, `typeof`, instanceof, of, extends, implements
    case interface, type, `enum`, namespace, module, declare, abstract, export, `default`
    case `static`, get, set, `public`, `private`, protected, readonly, override, accessor
    case this, `super`, `catch`, `switch`, `do`, `throw`, void, delete, `true`, `false`, null
    case undefined, satisfies, keyof, infer, debugger, using
    // Brace languages (T17.4b): Swift, Go, Rust, Java, C#, C, C++.
    case `func`, fn, `struct`, `protocol`, `extension`, actor, `guard`, `repeat`, `defer`, initializer
    case `deinit`, `subscript`, `typealias`, `operator`, `inout`, `where`, `throws`, `rethrows`, selfValue
    case `nil`, `fallthrough`, go, chan, map, range, select, package, goto, impl, trait, mod, use
    case mut, ref, pub, crate, unsafe, loop, move, union, extern, foreach, out, params, record, event
    case delegate, sealed, lock, fixed, checked, base, sizeof, typedef, template, typename, inline
    case virtual, noexcept, decltype, nullptr, when, nameof, dyn
    /// A primitive type word (`int`, `char`, `boolean`, `decimal`, `string` in C#, …).
    case primitiveType
    /// A declaration modifier with no other role (`final`, `mutating`, `volatile`, `transient`, …).
    case modifier
}

/// Per-family keyword lookup without allocating a `String` per identifier:
/// an identifier of 2…12 lowercase ASCII letters is packed into 5 bits per
/// letter and looked up in a small dictionary.
struct DeclKeywords: Sendable {
    private let table: [UInt64: DeclKeyword]

    init(_ words: [(String, DeclKeyword)]) {
        var table: [UInt64: DeclKeyword] = [:]
        for (word, keyword) in words {
            var pack: UInt64 = 0
            for unit in word.utf16 { pack = pack << 5 | UInt64(unit - 96) }
            table[pack << 4 | UInt64(word.utf16.count)] = keyword
        }
        self.table = table
    }

    /// `pack` as built by the tokenizer (5 bits per letter `a`…`z`), `length` ≤ 12.
    @inline(__always)
    func lookup(pack: UInt64, length: Int) -> DeclKeyword {
        table[pack << 4 | UInt64(length)] ?? .none
    }

    /// The keyword `word` is in this table (`.none` otherwise); for tests.
    func lookup(_ word: String) -> DeclKeyword {
        let units = Array(word.utf16)
        guard (2...12).contains(units.count), units.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return .none }
        return lookup(pack: units.reduce(0) { $0 << 5 | UInt64($1 - 96) }, length: units.count)
    }

    static let python = DeclKeywords([
        ("def", .def), ("class", .class), ("lambda", .lambda), ("for", .for), ("in", .in), ("if", .if),
        ("elif", .elif), ("else", .else), ("while", .while), ("with", .with), ("as", .as), ("try", .try),
        ("except", .except), ("finally", .finally), ("import", .import), ("from", .from),
        ("global", .global), ("nonlocal", .nonlocal), ("return", .return), ("yield", .yield),
        ("async", .async), ("await", .await), ("pass", .pass), ("break", .break),
        ("continue", .continue), ("raise", .raise), ("del", .del), ("assert", .assert), ("not", .not),
        ("and", .and), ("or", .or), ("is", .is), ("match", .match), ("case", .case), ("type", .type),
    ])

    static let javascript = DeclKeywords([
        ("function", .function), ("class", .class), ("const", .const), ("let", .let), ("var", .var),
        ("if", .if), ("else", .else), ("for", .for), ("while", .while), ("do", .do), ("switch", .switch),
        ("case", .case), ("default", .default), ("break", .break), ("continue", .continue),
        ("return", .return), ("throw", .throw), ("try", .try), ("catch", .catch), ("finally", .finally),
        ("new", .new), ("delete", .delete), ("typeof", .typeof), ("instanceof", .instanceof),
        ("in", .in), ("of", .of), ("void", .void), ("this", .this), ("super", .super),
        ("true", .true), ("false", .false), ("null", .null), ("undefined", .undefined),
        ("import", .import), ("export", .export), ("from", .from), ("as", .as), ("async", .async),
        ("await", .await), ("yield", .yield), ("extends", .extends), ("implements", .implements),
        ("static", .static), ("get", .get), ("set", .set), ("with", .with), ("debugger", .debugger),
        ("interface", .interface), ("type", .type), ("enum", .enum), ("namespace", .namespace),
        ("module", .module), ("declare", .declare), ("abstract", .abstract), ("public", .public),
        ("private", .private), ("protected", .protected), ("readonly", .readonly),
        ("override", .override), ("accessor", .accessor), ("satisfies", .satisfies),
        ("keyof", .keyof), ("infer", .infer), ("is", .is), ("using", .using),
    ])

    // MARK: Brace languages (T17.4b)

    /// Words every brace language shares the meaning of.
    private static let braceCommon: [(String, DeclKeyword)] = [
        ("if", .if), ("else", .else), ("for", .for), ("while", .while), ("switch", .switch), ("case", .case),
        ("default", .default), ("break", .break), ("continue", .continue), ("return", .return),
    ]

    private static func words(_ list: String, _ keyword: DeclKeyword) -> [(String, DeclKeyword)] {
        list.split(separator: " ").map { (String($0), keyword) }
    }

    static let swift = DeclKeywords(braceCommon + [
        ("func", .func), ("class", .class), ("struct", .struct), ("enum", .enum), ("protocol", .protocol),
        ("extension", .extension), ("actor", .actor), ("var", .var), ("let", .let), ("guard", .guard),
        ("in", .in), ("repeat", .repeat), ("do", .do), ("fallthrough", .fallthrough), ("throw", .throw),
        ("throws", .throws), ("rethrows", .rethrows), ("try", .try), ("catch", .catch), ("defer", .defer),
        ("import", .import), ("init", .initializer), ("deinit", .deinit), ("subscript", .subscript),
        ("typealias", .typealias), ("operator", .operator), ("inout", .inout), ("static", .static),
        ("public", .public), ("private", .private), ("override", .override), ("where", .where), ("is", .is),
        ("as", .as), ("self", .selfValue), ("super", .super), ("nil", .nil), ("true", .true), ("false", .false),
        ("get", .get), ("set", .set), ("async", .async), ("await", .await),
    ] + words("fileprivate internal open final lazy weak unowned mutating nonmutating required convenience "
              + "dynamic indirect optional nonisolated prefix postfix infix", .modifier))

    static let go = DeclKeywords(braceCommon + [
        ("func", .func), ("var", .var), ("const", .const), ("type", .type), ("struct", .struct),
        ("interface", .interface), ("map", .map), ("chan", .chan), ("package", .package), ("import", .import),
        ("range", .range), ("select", .select), ("go", .go), ("defer", .defer), ("goto", .goto),
        ("fallthrough", .fallthrough),
    ])

    static let rust = DeclKeywords(braceCommon + [
        ("fn", .fn), ("let", .let), ("mut", .mut), ("ref", .ref), ("pub", .pub), ("crate", .crate),
        ("impl", .impl), ("trait", .trait), ("struct", .struct), ("enum", .enum), ("union", .union),
        ("mod", .mod), ("use", .use), ("const", .const), ("static", .static), ("type", .type),
        ("where", .where), ("as", .as), ("match", .match), ("loop", .loop), ("in", .in), ("move", .move),
        ("unsafe", .unsafe), ("extern", .extern), ("async", .async), ("await", .await), ("dyn", .dyn),
        ("self", .selfValue), ("super", .super), ("true", .true), ("false", .false), ("box", .modifier),
    ])

    static let java = DeclKeywords(braceCommon + [
        ("class", .class), ("interface", .interface), ("enum", .enum), ("record", .record),
        ("extends", .extends), ("implements", .implements), ("package", .package), ("import", .import),
        ("public", .public), ("private", .private), ("protected", .protected), ("static", .static),
        ("abstract", .abstract), ("const", .const), ("new", .new), ("this", .this), ("super", .super),
        ("do", .do), ("try", .try), ("catch", .catch), ("finally", .finally), ("throw", .throw),
        ("throws", .throws), ("goto", .goto), ("instanceof", .instanceof), ("assert", .assert),
        ("void", .void), ("var", .var), ("yield", .yield), ("true", .true), ("false", .false), ("null", .null),
    ] + words("boolean byte char short int long float double", .primitiveType)
      + words("final native synchronized transient volatile strictfp sealed permits", .modifier))

    static let csharp = DeclKeywords(braceCommon + [
        ("class", .class), ("struct", .struct), ("interface", .interface), ("enum", .enum),
        ("record", .record), ("namespace", .namespace), ("using", .using), ("public", .public),
        ("private", .private), ("protected", .protected), ("static", .static), ("abstract", .abstract),
        ("override", .override), ("readonly", .readonly), ("const", .const), ("new", .new), ("this", .this),
        ("base", .base), ("do", .do), ("try", .try), ("catch", .catch), ("finally", .finally),
        ("throw", .throw), ("goto", .goto), ("foreach", .foreach), ("in", .in), ("out", .out), ("ref", .ref),
        ("params", .params), ("is", .is), ("as", .as), ("typeof", .typeof), ("sizeof", .sizeof),
        ("nameof", .nameof), ("operator", .operator), ("delegate", .delegate), ("event", .event),
        ("lock", .lock), ("fixed", .fixed), ("checked", .checked), ("unchecked", .checked),
        ("unsafe", .unsafe), ("extern", .extern), ("sealed", .sealed), ("void", .void), ("var", .var),
        ("async", .async), ("await", .await), ("yield", .yield), ("get", .get), ("set", .set),
        ("init", .initializer), ("when", .when), ("where", .where), ("true", .true), ("false", .false),
        ("null", .null),
    ] + words("bool byte sbyte char short ushort int uint long ulong float double decimal string object "
              + "dynamic nint nuint", .primitiveType)
      + words("internal virtual volatile partial implicit explicit stackalloc required file scoped", .modifier))

    private static let cWords: [(String, DeclKeyword)] = braceCommon + [
        ("struct", .struct), ("union", .union), ("enum", .enum), ("typedef", .typedef), ("const", .const),
        ("static", .static), ("extern", .extern), ("inline", .inline), ("sizeof", .sizeof), ("do", .do),
        ("goto", .goto), ("void", .void),
    ] + words("char short int long float double signed unsigned bool auto", .primitiveType)
      + words("volatile register restrict", .modifier)

    static let c = DeclKeywords(cWords)

    static let cpp = DeclKeywords(cWords + [
        ("class", .class), ("namespace", .namespace), ("using", .using), ("template", .template),
        ("typename", .typename), ("public", .public), ("private", .private), ("protected", .protected),
        ("virtual", .virtual), ("operator", .operator), ("new", .new), ("delete", .delete), ("this", .this),
        ("try", .try), ("catch", .catch), ("throw", .throw), ("noexcept", .noexcept), ("decltype", .decltype),
        ("nullptr", .nullptr), ("true", .true), ("false", .false),
    ] + words("explicit friend mutable constexpr consteval constinit", .modifier))
}

/// One token. Positions are absolute UTF-16 offsets.
struct DeclToken: Sendable {
    static let lineStartFlag: UInt8 = 1      // first token on its physical line
    static let logicalStartFlag: UInt8 = 2   // Python: first token of a logical line
    static let privateNameFlag: UInt8 = 4    // JS `#name`

    var kind: DeclTokenKind
    var keyword: DeclKeyword = .none
    var flags: UInt8 = 0
    var start: Int
    var end: Int
    /// Python, on a logical line start: the column (tabs to multiples of 8).
    var indent: Int = 0
    /// Python, on a logical line start: offset of its physical line start.
    var lineStart: Int = 0

    var isLineStart: Bool { flags & Self.lineStartFlag != 0 }
    var isLogicalStart: Bool { flags & Self.logicalStartFlag != 0 }
    var isPrivateName: Bool { flags & Self.privateNameFlag != 0 }
    var length: Int { end - start }
}

/// FIFO of tokens between the tokenizer and a walker; consumed from `head`.
struct DeclTokenBuffer: Sendable {
    private(set) var tokens: [DeclToken] = []
    private(set) var head = 0

    var count: Int { tokens.count - head }
    var isEmpty: Bool { head >= tokens.count }

    mutating func append(_ token: DeclToken) { tokens.append(token) }

    /// The token `offset` places after the head, or nil when not yet available.
    @inline(__always)
    func peek(_ offset: Int = 0) -> DeclToken? {
        let i = head + offset
        return i < tokens.count ? tokens[i] : nil
    }

    mutating func consume(_ n: Int = 1) {
        head = min(tokens.count, head + n)
        // Compact once the consumed prefix dominates, keeping appends O(1) amortised.
        if head > 4096, head * 2 > tokens.count {
            tokens.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        tokens.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Turns lexer segments into `DeclToken`s, one chunk at a time.
///
/// **Chunk independence.** Chunks end at lexer safe points, which never split
/// an identifier. A multi-unit operator (`=>`, `**`, `...`, `:=`, `>=`) or a
/// number may still straddle a chunk end; the tokenizer then reads the rest
/// directly from the text (those continuation units — `= > * . digits
/// letters` — can never open a string or comment in Python or JS, so they are
/// code) and skips them when the next chunk starts. The token sequence is
/// therefore the same however the text is chunked.
///
/// **Python logical lines.** A line break in code outside brackets and
/// interpolations, not escaped with `\`, ends a logical line (`newline`
/// token, only when the line had tokens). Brackets left open are recovered at
/// a physical line whose first token is not a closer and is indented less
/// than the logical line's start, or is a statement-only keyword (`def`,
/// `class`, `return`, `import`, …) indented no deeper: the bracket depth is
/// reset there and a `newline` is emitted first. Comment-only and blank lines
/// produce nothing.
///
/// **Brace languages** (T17.4b, `brace` set): `->` is `thinArrow`, `::` is
/// one `dot` (paths read like member access), `:=` is `walrus` (Go), and an
/// interpolation delimiter (`\(` / `)` in Swift, `{` / `{{` / `}` in C#) is
/// one `interpOpen` / `interpClose`. Every continuation unit read past a chunk
/// end (`>`, `:`, `=`, digits, letters) is code in these languages too.
struct DeclTokenizer: Sendable {
    let python: Bool
    /// One of the seven brace languages (T17.4b).
    let brace: Bool
    /// `$` may start / continue an identifier (JS, Swift `$0`, Java).
    let dollar: Bool
    let keywords: DeclKeywords

    /// Units before this offset were consumed by a token of the previous chunk.
    private var consumedUpTo = 0
    /// Previous segment kind was a string / atom (a run continuing across
    /// chunks or interpolations yields one literal token per string start).
    private var previousWasLiteral = false
    private var sawLineBreak = true
    private var hasTokens = false
    // Python logical line state.
    private var depth = 0
    private var interpolationDepth = 0
    private var atLogicalStart = true
    private var logicalIndent = 0

    init(python: Bool) {
        self.python = python
        self.brace = false
        self.dollar = !python
        self.keywords = python ? .python : .javascript
    }

    /// A tokenizer for one of the seven brace languages.
    init(brace language: BraceLanguage) {
        python = false
        brace = true
        dollar = language == .swift || language == .java
        keywords = language.keywords
    }

    // MARK: - Text access

    /// UTF-16 units of the current chunk, read once with `getCharacters`.
    private struct Units {
        var buffer: [unichar] = []
        var start = 0
        var end = 0
        let text: NSString

        @inline(__always)
        func at(_ i: Int) -> unichar {
            i >= start && i < end ? buffer[i - start] : text.character(at: i)
        }
    }

    // MARK: - Segments

    /// Tokenizes the segments of one chunk `[from, to)` (ascending, gap-free).
    mutating func tokenize(_ text: NSString, from: Int, to: Int,
                           segments: [(NSRange, LexicalSegment)], into out: inout DeclTokenBuffer) {
        let length = text.length
        var units = Units(text: text)
        let readEnd = min(length, to + 8)
        if readEnd > from {
            units.buffer = [unichar](repeating: 0, count: readEnd - from)
            units.buffer.withUnsafeMutableBufferPointer { ptr in
                text.getCharacters(ptr.baseAddress!, range: NSRange(location: from, length: readEnd - from))
            }
            units.start = from
            units.end = readEnd
        }
        for (range, segment) in segments {
            switch segment {
            case .code:
                previousWasLiteral = false
                tokenizeCode(&units, from: range.location, to: NSMaxRange(range), length: length, into: &out)
            case .string, .atom, .block:
                if !previousWasLiteral {
                    push(DeclToken(kind: .literal, start: range.location, end: NSMaxRange(range)), &units, &out)
                }
                previousWasLiteral = true
            case .comment:
                previousWasLiteral = false
                if !python {
                    // A line break inside a block comment separates lines (ASI).
                    var i = range.location
                    while i < NSMaxRange(range) {
                        let u = units.at(i)
                        if u == 10 || u == 13 || u == 0x2028 || u == 0x2029 { sawLineBreak = true; break }
                        i += 1
                    }
                }
            case .interpolationDelimiter where brace:
                // One opener / closer per delimiter (`\(`, `)`, `{{`, `}`).
                previousWasLiteral = false
                var i = range.location
                while i < NSMaxRange(range) {
                    let u = units.at(i)
                    if u == 123 || u == 40 {
                        push(DeclToken(kind: .interpOpen, start: i, end: i + 1), &units, &out)
                        break
                    } else if u == 125 || u == 41 {
                        push(DeclToken(kind: .interpClose, start: i, end: i + 1), &units, &out)
                        break
                    }
                    i += 1
                }
            case .interpolationDelimiter:
                previousWasLiteral = false
                var i = range.location
                while i < NSMaxRange(range) {
                    let u = units.at(i)
                    if u == 123 {          // {
                        push(DeclToken(kind: .interpOpen, start: i, end: i + 1), &units, &out)
                        interpolationDepth += 1
                    } else if u == 125 {   // }
                        push(DeclToken(kind: .interpClose, start: i, end: i + 1), &units, &out)
                        interpolationDepth = max(0, interpolationDepth - 1)
                    }
                    i += 1
                }
            }
        }
    }

    /// Called once after the last chunk: ends the last Python logical line.
    mutating func finish(at end: Int, into out: inout DeclTokenBuffer) {
        if python, pendingNewline || !atLogicalStart {
            out.append(DeclToken(kind: .newline, start: end, end: end))
            pendingNewline = false
            atLogicalStart = true
        }
    }

    // MARK: - Code

    @inline(__always)
    private static func isIdentifierStart(_ u: unichar, dollar: Bool) -> Bool {
        (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || u == 95 || (dollar && u == 36)
            || (u >= 0x80 && !isExtraSpace(u))
    }

    @inline(__always)
    private static func isIdentifierPart(_ u: unichar, dollar: Bool) -> Bool {
        isIdentifierStart(u, dollar: dollar) || (u >= 48 && u <= 57)
    }

    /// Non-ASCII units treated as blanks rather than identifier characters.
    @inline(__always)
    private static func isExtraSpace(_ u: unichar) -> Bool {
        u == 0xA0 || u == 0xFEFF || u == 0x2028 || u == 0x2029 || u == 0x3000
    }

    private mutating func tokenizeCode(_ units: inout Units, from: Int, to: Int, length: Int,
                                       into out: inout DeclTokenBuffer) {
        var i = max(from, consumedUpTo)
        let dollar = self.dollar
        while i < to {
            let c = units.at(i)
            // Blanks.
            if c == 32 || c == 9 || c == 12 || c == 11 || (c >= 0x80 && Self.isExtraSpace(c)) {
                if !python, c == 0x2028 || c == 0x2029 { lineBreak() }
                i += 1
                continue
            }
            if c == 10 || c == 13 {
                lineBreak()
                i += (c == 13 && i + 1 < length && units.at(i + 1) == 10) ? 2 : 1
                continue
            }
            // Python explicit line joining: `\` + line break.
            if python, c == 92, i + 1 < length {
                let n = units.at(i + 1)
                if n == 10 || n == 13 {
                    i += (n == 13 && i + 2 < length && units.at(i + 2) == 10) ? 3 : 2
                    continue
                }
            }
            let start = i
            // Identifiers (JS `#private` too).
            var isPrivate = false
            if !python, !brace, c == 35, i + 1 < length, Self.isIdentifierStart(units.at(i + 1), dollar: true) {
                isPrivate = true
                i += 1
            }
            if isPrivate || Self.isIdentifierStart(c, dollar: dollar) {
                var pack: UInt64 = 0
                var lower = !isPrivate
                var j = i
                while j < length {
                    let u = units.at(j)
                    guard Self.isIdentifierPart(u, dollar: dollar) else { break }
                    if lower {
                        if u >= 97 && u <= 122, j - start < 12 { pack = pack << 5 | UInt64(u - 96) } else { lower = false }
                    }
                    j += 1
                }
                var token = DeclToken(kind: .ident, start: start, end: j)
                if isPrivate { token.flags |= DeclToken.privateNameFlag }
                if lower, j - start >= 2 { token.keyword = keywords.lookup(pack: pack, length: j - start) }
                push(token, &units, &out)
                i = j
                if j > to { consumedUpTo = j }
                continue
            }
            // Numbers (`.5` too).
            if (c >= 48 && c <= 57) || (c == 46 && i + 1 < length && (48...57).contains(units.at(i + 1))) {
                var j = i + 1
                while j < length {
                    let u = units.at(j)
                    if Self.isIdentifierPart(u, dollar: false) || u == 46 { j += 1 } else { break }
                }
                push(DeclToken(kind: .literal, start: start, end: j), &units, &out)
                i = j
                if j > to { consumedUpTo = j }
                continue
            }
            // Punctuation.
            @inline(__always) func next(_ k: Int) -> unichar { i + k < length ? units.at(i + k) : 0 }
            var kind: DeclTokenKind = .op
            var width = 1
            switch c {
            case 40: kind = .lparen
            case 41: kind = .rparen
            case 91: kind = .lbracket
            case 93: kind = .rbracket
            case 123: kind = .lbrace
            case 125: kind = .rbrace
            case 44: kind = .comma
            case 59: kind = .semicolon
            case 64:                                   // @  @=
                if python, next(1) == 61 { kind = .augAssign; width = 2 } else { kind = .at }
            case 58:                                   // :  :=  (brace: ::)
                if python || brace, next(1) == 61 { kind = .walrus; width = 2 }
                else if brace, next(1) == 58 { kind = .dot; width = 2 }
                else { kind = .colon }
            case 61:                                   // =  ==  ===  =>
                if next(1) == 61 { kind = .op; width = next(2) == 61 ? 3 : 2 }
                else if next(1) == 62 { kind = .arrow; width = 2 }
                else { kind = .assign }
            case 46:                                   // .  ...
                if next(1) == 46, next(2) == 46 { kind = .ellipsis; width = 3 } else { kind = .dot }
            case 42:                                   // *  **  *=  **=
                if next(1) == 42 {
                    if next(2) == 61 { kind = .augAssign; width = 3 } else { kind = .doubleStar; width = 2 }
                } else if next(1) == 61 { kind = .augAssign; width = 2 } else { kind = .star }
            case 63:                                   // ?  ?.  ??  ??=
                if next(1) == 46, !(48...57).contains(next(2)) { kind = .dot; width = 2 }
                else if next(1) == 63 { if next(2) == 61 { kind = .augAssign; width = 3 } else { width = 2 } }
                else { kind = .question }
            case 60:                                   // <  <=  <<  <<=
                if next(1) == 61 { width = 2 }
                else if next(1) == 60 { if next(2) == 61 { kind = .augAssign; width = 3 } else { width = 2 } }
                else { kind = .less }
            case 62:                                   // >  >=  (>> stays two `>` for generics)
                if next(1) == 61 { width = 2 } else { kind = .greater }
            case 33:                                   // !  !=  !==
                if next(1) == 61 { width = next(2) == 61 ? 3 : 2 } else { kind = .bang }
            case 45:                                   // -  ->  -=  --
                if next(1) == 62, python || brace { kind = .thinArrow; width = 2 }
                else if next(1) == 61 { kind = .augAssign; width = 2 }
                else if next(1) == 45 { width = 2 }
            case 43:                                   // +  +=  ++
                if next(1) == 61 { kind = .augAssign; width = 2 } else if next(1) == 43 { width = 2 }
            case 47:                                   // /  /=  //  //=
                if next(1) == 61 { kind = .augAssign; width = 2 }
                else if python, next(1) == 47 { if next(2) == 61 { kind = .augAssign; width = 3 } else { width = 2 } }
            case 37, 94:                               // %  ^  (+ =)
                if next(1) == 61 { kind = .augAssign; width = 2 }
            case 38, 124:                              // &  |  &&  ||  &=  |=  &&=  ||=
                if next(1) == c { if next(2) == 61 { kind = .augAssign; width = 3 } else { width = 2 } }
                else if next(1) == 61 { kind = .augAssign; width = 2 }
            default:
                kind = .op
            }
            push(DeclToken(kind: kind, start: start, end: start + width), &units, &out)
            i = start + width
            if i > to { consumedUpTo = i }
        }
    }

    private mutating func lineBreak() {
        sawLineBreak = true
        guard python else { return }
        if depth == 0, interpolationDepth == 0, !atLogicalStart {
            pendingNewline = true
        }
    }

    /// A Python logical line end seen but not yet emitted: emitted before the
    /// next token (so a token of the next chunk sees it in order) or at finish.
    private var pendingNewline = false

    /// Column of the token at `start` and its physical line start, reading
    /// back over blanks (bounded).
    private func indentation(of start: Int, _ units: inout Units) -> (column: Int, lineStart: Int) {
        var p = start
        let floor = max(0, start - 4096)
        while p > floor {
            let u = units.at(p - 1)
            if u == 10 || u == 13 { break }
            p -= 1
        }
        var column = 0
        var q = p
        while q < start {
            let u = units.at(q)
            if u == 9 { column = (column / 8 + 1) * 8 } else if u == 12 { column = 0 } else { column += 1 }
            q += 1
        }
        return (column, p)
    }

    /// Statement-only Python keywords that end an unbalanced bracket run.
    private static func isStatementKeyword(_ k: DeclKeyword) -> Bool {
        switch k {
        case .def, .class, .return, .import, .with, .try, .while, .elif, .except, .finally, .raise,
             .pass, .break, .continue, .global, .nonlocal, .del, .assert:
            return true
        default:
            return false
        }
    }

    private mutating func push(_ token: DeclToken, _ units: inout Units, _ out: inout DeclTokenBuffer) {
        var token = token
        let firstOnLine = sawLineBreak || !hasTokens
        if python {
            if pendingNewline {
                out.append(DeclToken(kind: .newline, start: token.start, end: token.start))
                pendingNewline = false
                atLogicalStart = true
            }
            if firstOnLine {
                let (column, lineStart) = indentation(of: token.start, &units)
                token.indent = column
                token.lineStart = lineStart
                // Bounded recovery of unbalanced brackets.
                if depth > 0, interpolationDepth == 0, !atLogicalStart {
                    let closer = token.kind == .rparen || token.kind == .rbracket || token.kind == .rbrace
                    if !closer, column < logicalIndent
                        || (column <= logicalIndent && Self.isStatementKeyword(token.keyword)) {
                        depth = 0
                        out.append(DeclToken(kind: .newline, start: token.start, end: token.start))
                        atLogicalStart = true
                    }
                }
            }
            if atLogicalStart {
                if !firstOnLine {
                    // After `;`-less continuation oddities: measure anyway.
                    let (column, lineStart) = indentation(of: token.start, &units)
                    token.indent = column
                    token.lineStart = lineStart
                }
                token.flags |= DeclToken.logicalStartFlag
                logicalIndent = token.indent
                atLogicalStart = false
            }
            switch token.kind {
            case .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket, .rbrace: depth = max(0, depth - 1)
            default: break
            }
        }
        if firstOnLine { token.flags |= DeclToken.lineStartFlag }
        sawLineBreak = false
        hasTokens = true
        out.append(token)
    }

}
