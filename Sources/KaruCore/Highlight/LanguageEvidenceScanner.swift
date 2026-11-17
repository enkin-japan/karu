import Foundation

// One pass over the lines of a sample, reporting SniffFeature occurrences.
//
// The scanner works on UTF-8 bytes. Each line is tokenised once: identifiers
// are looked up in a small keyword table and punctuation pairs (`=>`, `:=`,
// `::`, …) are recorded as flags, both only outside string literals. Feature
// rules then dispatch on the first word and these facts; the few shapes that
// need a regular expression run on the single line, and only after a cheap
// precheck passes.
//
// Multi-line regions whose content is not code of the host language are
// skipped: C-style block comments, Python/Swift/Java/C# triple-quoted strings,
// backtick strings that span lines (JS templates, Go raw strings), Markdown
// fences and markup comments.

/// Keywords and well-known names the rules look at.
enum SniffToken: Int {
    // Python
    case none_, true_, false_, elif, lambda, pass, raise, except, nonlocal, global, self_, in_, not_, def
    case async_, yield
    // JavaScript / TypeScript
    case undefined, console, document, window, require, typeof, module, exports, constructor
    case const_, let_, var_, function, this_, export, of, await_, new_
    case string_, number, boolean, any, unknown, never, void_, readonly, interface, type, declare, as_
    case implements, extends, enum_, namespace
    // Java
    case String_, System_, final, throws_, instanceof, public_, private_, protected_, static_, abstract
    case synchronized, package, import_, class_, Override
    // C#
    case Console_, foreach, bool_, Task_, using, decimal, override, sealed, internal_, virtual, record
    case partial, get, set, init_, out, ref
    // C / C++
    case printf, scanf, malloc, calloc, realloc, free, sizeof, NULL_, struct_, typedef, unsigned, signed
    case size_t, char_, int_, long_, double_, float_, short_, fprintf, fopen, fclose, strlen, strcmp
    case memcpy, memset, puts, main, std, nullptr, cout, cin, cerr, endl, auto, template, typename
    case constexpr, noexcept, explicit, vector, inline, extern
    // Go
    case fmt, nil_, func_, defer_, range, chan, make, go, err
    // Rust
    case fn, mut, impl, pub, use, mod, crate, Some, Ok, Err, match, loop, i8, i16, i32, i64, i128
    case u8, u16, u32, u64, u128, usize, isize, f32, f64, Self_, trait, dyn, unwrap, where_
    // Swift
    case guard_, Int_, Double_, Bool_, Character, extension_, protocol_, inout_, fileprivate_, some, weak
    case print, if_, for_, while_, return_, else_, switch_, case_, do_, then, fi, done, esac, local
    case echo, source, exit, try_, finally, with, from

    static let table: [String: SniffToken] = [
        "None": .none_, "True": .true_, "False": .false_, "elif": .elif, "lambda": .lambda, "pass": .pass,
        "raise": .raise, "except": .except, "nonlocal": .nonlocal, "global": .global, "self": .self_,
        "in": .in_, "not": .not_, "def": .def, "async": .async_, "yield": .yield,
        "undefined": .undefined, "console": .console, "document": .document, "window": .window,
        "require": .require, "typeof": .typeof, "module": .module, "exports": .exports,
        "constructor": .constructor, "const": .const_, "let": .let_, "var": .var_, "function": .function,
        "this": .this_, "export": .export, "of": .of, "await": .await_, "new": .new_,
        "string": .string_, "number": .number, "boolean": .boolean, "any": .any, "unknown": .unknown,
        "never": .never, "void": .void_, "readonly": .readonly, "interface": .interface, "type": .type,
        "declare": .declare, "as": .as_, "implements": .implements, "extends": .extends, "enum": .enum_,
        "namespace": .namespace,
        "String": .String_, "System": .System_, "final": .final, "throws": .throws_,
        "instanceof": .instanceof, "public": .public_, "private": .private_, "protected": .protected_,
        "static": .static_, "abstract": .abstract, "synchronized": .synchronized, "package": .package,
        "import": .import_, "class": .class_, "Override": .Override,
        "Console": .Console_, "foreach": .foreach, "bool": .bool_, "Task": .Task_, "using": .using,
        "decimal": .decimal, "override": .override, "sealed": .sealed, "internal": .internal_,
        "virtual": .virtual, "record": .record, "partial": .partial, "get": .get, "set": .set,
        "init": .init_, "out": .out, "ref": .ref,
        "printf": .printf, "scanf": .scanf, "malloc": .malloc, "calloc": .calloc, "realloc": .realloc,
        "free": .free, "sizeof": .sizeof, "NULL": .NULL_, "struct": .struct_, "typedef": .typedef,
        "unsigned": .unsigned, "signed": .signed, "size_t": .size_t, "char": .char_, "int": .int_,
        "long": .long_, "double": .double_, "float": .float_, "short": .short_, "fprintf": .fprintf,
        "fopen": .fopen, "fclose": .fclose, "strlen": .strlen, "strcmp": .strcmp, "memcpy": .memcpy,
        "memset": .memset, "puts": .puts, "main": .main, "std": .std, "nullptr": .nullptr, "cout": .cout,
        "cin": .cin, "cerr": .cerr, "endl": .endl, "auto": .auto, "template": .template,
        "typename": .typename, "constexpr": .constexpr, "noexcept": .noexcept, "explicit": .explicit,
        "vector": .vector, "inline": .inline, "extern": .extern,
        "fmt": .fmt, "nil": .nil_, "func": .func_, "defer": .defer_, "range": .range, "chan": .chan,
        "make": .make, "go": .go, "err": .err,
        "fn": .fn, "mut": .mut, "impl": .impl, "pub": .pub, "use": .use, "mod": .mod, "crate": .crate,
        "Some": .Some, "Ok": .Ok, "Err": .Err, "match": .match, "loop": .loop, "i8": .i8, "i16": .i16,
        "i32": .i32, "i64": .i64, "i128": .i128, "u8": .u8, "u16": .u16, "u32": .u32, "u64": .u64,
        "u128": .u128, "usize": .usize, "isize": .isize, "f32": .f32, "f64": .f64, "Self": .Self_,
        "trait": .trait, "dyn": .dyn, "unwrap": .unwrap, "where": .where_,
        "guard": .guard_, "Int": .Int_, "Double": .Double_, "Bool": .Bool_, "Character": .Character,
        "extension": .extension_, "protocol": .protocol_, "inout": .inout_, "fileprivate": .fileprivate_,
        "some": .some, "weak": .weak, "print": .print, "if": .if_, "for": .for_, "while": .while_,
        "return": .return_, "else": .else_, "switch": .switch_, "case": .case_, "do": .do_, "then": .then,
        "fi": .fi, "done": .done, "esac": .esac, "local": .local, "echo": .echo, "source": .source,
        "exit": .exit, "try": .try_, "finally": .finally, "with": .with, "from": .from,
    ]

    static let cTypes: Set<SniffToken> = [
        .int_, .char_, .long_, .double_, .float_, .short_, .unsigned, .signed, .size_t, .void_, .bool_,
        .struct_, .static_, .const_, .inline, .extern, .auto,
    ]
    static let modifiers: Set<SniffToken> = [
        .public_, .private_, .protected_, .internal_, .static_, .final, .abstract, .synchronized, .override,
        .virtual, .sealed, .async_, .readonly, .partial, .extern,
    ]
}

/// A 256-bit set of SniffToken values.
struct SniffTokenSet {
    private var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)

    mutating func insert(_ token: SniffToken) {
        let bit = UInt64(1) << UInt64(token.rawValue & 63)
        switch token.rawValue >> 6 {
        case 0: words.0 |= bit
        case 1: words.1 |= bit
        case 2: words.2 |= bit
        default: words.3 |= bit
        }
    }

    func contains(_ token: SniffToken) -> Bool {
        let bit = UInt64(1) << UInt64(token.rawValue & 63)
        switch token.rawValue >> 6 {
        case 0: return words.0 & bit != 0
        case 1: return words.1 & bit != 0
        case 2: return words.2 & bit != 0
        default: return words.3 & bit != 0
        }
    }
}

/// Punctuation facts of one line, outside string literals. `has` / `set`
/// test bits directly: the generic `OptionSet` paths are slow in debug builds.
struct SniffFlags: OptionSet {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }
    func has(_ flag: SniffFlags) -> Bool { rawValue & flag.rawValue != 0 }
    mutating func set(_ flag: SniffFlags) { self = SniffFlags(rawValue: rawValue | flag.rawValue) }
    static let fatArrow = SniffFlags(rawValue: 1 << 0)        // =>
    static let spacedArrow = SniffFlags(rawValue: 1 << 1)     // ` -> `
    static let ptrArrow = SniffFlags(rawValue: 1 << 2)        // a->b
    static let colonEq = SniffFlags(rawValue: 1 << 3)         // :=
    static let doubleColon = SniffFlags(rawValue: 1 << 4)     // ::
    static let strictEq = SniffFlags(rawValue: 1 << 5)        // === / !==
    static let dollarVar = SniffFlags(rawValue: 1 << 6)       // $name ${ $1 $@
    static let dollarParen = SniffFlags(rawValue: 1 << 7)     // $(cmd
    static let templateInterp = SniffFlags(rawValue: 1 << 8)  // `…${…}`
    static let swiftInterp = SniffFlags(rawValue: 1 << 9)     // "…\(…)"
    static let csInterp = SniffFlags(rawValue: 1 << 10)       // $"
    static let csVerbatim = SniffFlags(rawValue: 1 << 11)     // @"
    static let fString = SniffFlags(rawValue: 1 << 12)        // f"
    static let macroBang = SniffFlags(rawValue: 1 << 13)      // name!( name![
    static let rustRef = SniffFlags(rawValue: 1 << 14)        // &str &mut &self &'a
    static let pipeClosure = SniffFlags(rawValue: 1 << 15)    // |x|
    static let tagOpen = SniffFlags(rawValue: 1 << 16)        // <tag
    static let tagClose = SniffFlags(rawValue: 1 << 17)       // </
    static let selfClose = SniffFlags(rawValue: 1 << 18)      // />
    static let braceAttr = SniffFlags(rawValue: 1 << 19)      // name={
    static let andAnd = SniffFlags(rawValue: 1 << 20)         // &&
    static let orOr = SniffFlags(rawValue: 1 << 21)           // ||
    static let redirect = SniffFlags(rawValue: 1 << 22)       // 2> >& >/dev
    static let parenColon = SniffFlags(rawValue: 1 << 23)     // ): T
    static let questionTry = SniffFlags(rawValue: 1 << 24)    // ?; ?) ?.
    static let diamond = SniffFlags(rawValue: 1 << 25)        // <>(
    static let chanArrow = SniffFlags(rawValue: 1 << 26)      // <-
    static let sliceType = SniffFlags(rawValue: 1 << 27)      // []T / map[
    static let closureArg = SniffFlags(rawValue: 1 << 28)     // $0
    static let optionalCast = SniffFlags(rawValue: 1 << 29)   // as? as! try? try!
    static let entity = SniffFlags(rawValue: 1 << 30)         // &amp;
    static let doubleSemi = SniffFlags(rawValue: 1 << 31)     // ;;
    static let mdLink = SniffFlags(rawValue: 1 << 32)         // ](
    static let mdEmphasis = SniffFlags(rawValue: 1 << 33)     // **x
    static let pascalCall = SniffFlags(rawValue: 1 << 34)     // .Name(
    static let pathCall = SniffFlags(rawValue: 1 << 35)       // Type::name(
    static let important = SniffFlags(rawValue: 1 << 37)      // !important
    static let dunder = SniffFlags(rawValue: 1 << 38)         // __name__
    static let backtickPair = SniffFlags(rawValue: 1 << 39)   // `code` closed on the line
    static let genericAfterColon = SniffFlags(rawValue: 1 << 40) // : Name<
    static let questionColon = SniffFlags(rawValue: 1 << 41)  // name?:
    static let atAttribute = SniffFlags(rawValue: 1 << 42)    // @Name
    static let closureIn = SniffFlags(rawValue: 1 << 43)      // `{ x in`
    static let objectLiteral = SniffFlags(rawValue: 1 << 44)  // = { key: value
    static let stringPrefix = SniffFlags(rawValue: 1 << 45)   // r"…" b"…" r'''…
}

/// Facts about one line, gathered in a single byte pass.
struct SniffLineFacts {
    var tokens = SniffTokenSet()
    var flags: SniffFlags = []
    var words = 0
    var punctuation = 0
    var nonASCII = 0
    var firstWord: SniffToken?
    var secondWord: SniffToken?
    var firstWordRange = 0..<0
    var secondWordRange = 0..<0
    var thirdWordRange = 0..<0
    /// One past the last byte before a trailing `//` comment.
    var codeEnd = 0
    /// Last non-blank code byte (0 when none).
    var last: UInt8 = 0
    var backticks = 0
    var tripleQuotes = 0
    var tripleQuoteByte: UInt8 = 0
    /// The line ends inside an unterminated `/*` comment.
    var opensBlockComment = false
    var equalsAssign = false
}

struct LanguageEvidenceScanner {
    private let b: [UInt8]
    private var lineEnds: [Int] = []
    private var lineLo: [Int] = []
    private var lineIndent: [Int] = []
    private var lineTab: [Bool] = []
    private(set) var counts = [Int](repeating: 0, count: SniffFeature.allCases.count)
    private(set) var jsxSeen = false
    /// The current line is `key = literal` (config, not code).
    private var tomlLiteralAssignment = false
    /// Lines deeper than this indentation are YAML block-scalar content.
    private var skipDeeperThan: Int? = nil

    init(_ sample: String) {
        b = Array(sample.utf8)
        splitLines()
    }

    private mutating func hit(_ feature: SniffFeature) {
        counts[feature.rawValue] += 1
    }

    func count(_ feature: SniffFeature) -> Int { counts[feature.rawValue] }

    // MARK: Lines

    private mutating func splitLines() {
        var start = 0
        let n = b.count
        var i = 0
        while i <= n {
            if i == n || b[i] == 10 {
                var end = i
                if end > start && b[end - 1] == 13 { end -= 1 }
                while end > start && (b[end - 1] == 32 || b[end - 1] == 9) { end -= 1 }
                var lo = start
                var indent = 0
                var tab = false
                while lo < end && (b[lo] == 32 || b[lo] == 9) {
                    if b[lo] == 9 { tab = true; indent += 4 } else { indent += 1 }
                    lo += 1
                }
                lineLo.append(lo)
                lineEnds.append(end)
                lineIndent.append(indent)
                lineTab.append(tab)
                start = i + 1
            }
            i += 1
        }
    }

    private func isBlank(_ i: Int) -> Bool { i >= lineLo.count || lineLo[i] >= lineEnds[i] }

    private func nextNonBlank(after i: Int) -> Int? {
        var j = i + 1
        while j < lineLo.count {
            if !isBlank(j) { return j }
            j += 1
        }
        return nil
    }

    private func string(_ lo: Int, _ hi: Int) -> String {
        String(decoding: b[lo..<hi], as: UTF8.self)
    }

    private func startsWith(_ lo: Int, _ hi: Int, _ prefix: [UInt8]) -> Bool {
        guard hi - lo >= prefix.count else { return false }
        for k in 0..<prefix.count where b[lo + k] != prefix[k] { return false }
        return true
    }

    private func contains(_ lo: Int, _ hi: Int, _ needle: [UInt8]) -> Bool {
        find(lo, hi, needle) != nil
    }

    private func find(_ lo: Int, _ hi: Int, _ needle: [UInt8]) -> Int? {
        let m = needle.count
        guard m > 0, hi - lo >= m else { return nil }
        let first = needle[0]
        var i = lo
        while i <= hi - m {
            if b[i] == first {
                var k = 1
                while k < m && b[i + k] == needle[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Scan

    mutating func scan() {
        var inBlockComment = false
        var inTriple: UInt8 = 0
        var inBacktick = false
        var inFence = false
        var inMarkupComment = false
        var pendingPythonColon: Int? = nil
        var previousWasHeading = false
        var previousHashLevel = 0
        var sawBlockOpen = false
        var sawTriple = false
        var sawBacktick = false

        for i in 0..<lineLo.count {
            let lo = lineLo[i]
            let hi = lineEnds[i]
            if lo >= hi { previousWasHeading = false; previousHashLevel = 0; continue }
            let first = b[lo]

            if inFence {
                if startsWith(lo, hi, SniffBytes.fence) || startsWith(lo, hi, SniffBytes.tildeFence) {
                    inFence = false
                    hit(.mdFence)
                }
                continue
            }
            if inBlockComment {
                if occurrences(lo, hi, SniffBytes.blockEnd) > occurrences(lo, hi, SniffBytes.blockStart) {
                    inBlockComment = false
                }
                continue
            }
            if let depth = skipDeeperThan {
                if lineIndent[i] > depth { continue }
                skipDeeperThan = nil
            }
            // A closing delimiter with no opener in the sample proves that
            // everything before it was comment or string content.
            if !sawBlockOpen && first == 42 && contains(lo, hi, SniffBytes.blockEnd)
                && !contains(lo, hi, SniffBytes.blockStart) {
                resetCounts()
                hit(.cBlockComment)
                continue
            }
            if !sawTriple && (closesTripleQuote(lo, hi) || loneTripleIsCloser(i, lo, hi)) {
                resetCounts()
                sawTriple = true
                continue
            }
            if inMarkupComment {
                if contains(lo, hi, SniffBytes.markupCommentEnd) { inMarkupComment = false }
                continue
            }
            if inTriple != 0 {
                if countTriples(lo, hi, inTriple) % 2 == 1 { inTriple = 0 }
                continue
            }
            if inBacktick {
                if countByte(lo, hi, 96) % 2 == 1 { inBacktick = false }
                continue
            }

            // Comment and region openers.
            if startsWith(lo, hi, SniffBytes.fence) || startsWith(lo, hi, SniffBytes.tildeFence) {
                hit(.mdFence)
                inFence = true
                continue
            }
            if first == 47 && hi - lo >= 2 {   // /
                if b[lo + 1] == 47 { hit(.slashComment); continue }
                if b[lo + 1] == 42 {
                    hit(.cBlockComment)
                    sawBlockOpen = true
                    if find(lo + 2, hi, SniffBytes.blockEnd) == nil { inBlockComment = true }
                    continue
                }
            }
            if first == 42 {   // *
                let next: UInt8 = hi - lo > 1 ? b[lo + 1] : 32
                if next == 47 { hit(.cBlockComment); continue }   // */
                if lineIndent[i] >= 1 && (next == 32 || hi - lo == 1) && !looksLikeListContext(i) {
                    hit(.cBlockComment)
                    continue
                }
            }
            if first == 45 && hi - lo >= 3 && b[lo + 1] == 45 && b[lo + 2] == 32 {   // -- comment
                hit(.sqlComment)
                continue
            }
            if startsWith(lo, hi, SniffBytes.markupCommentStart) {
                hit(.markupComment)
                if find(lo + 4, hi, SniffBytes.markupCommentEnd) == nil { inMarkupComment = true }
                continue
            }
            if first == 35 {   // #
                let level = hashLevel(lo, hi)
                if hashLine(i, lo, hi, previousWasHeading: previousWasHeading, previousLevel: previousHashLevel) {
                    previousWasHeading = true
                    previousHashLevel = level
                    continue
                }
                previousWasHeading = false
                previousHashLevel = level
                continue
            } else {
                previousWasHeading = false
                previousHashLevel = 0
            }

            var facts = analyze(lo, hi)
            if facts.opensBlockComment { inBlockComment = true; sawBlockOpen = true }
            if facts.tripleQuotes > 0 { sawTriple = true }
            if facts.tripleQuotes % 2 == 1 { inTriple = facts.tripleQuoteByte }
            if facts.backticks % 2 == 1 && facts.tripleQuotes == 0 {
                if !sawBacktick && closesBacktick(lo, hi) {
                    // A template / raw string closing with no opener in the sample.
                    resetCounts()
                    sawBacktick = true
                    continue
                }
                inBacktick = true
            }
            if facts.backticks > 0 { sawBacktick = true }

            if lineTab[i] { hit(.tabIndent) }

            // Python bodies: a `:` opener followed by a deeper line.
            if let opener = pendingPythonColon {
                if lineIndent[i] > opener { hit(.pyIndentedBody) }
                pendingPythonColon = nil
            }
            if classify(i, lo, hi, &facts) { pendingPythonColon = lineIndent[i] }
        }
    }

    /// The line's last backtick is followed only by `;`, `)`, `,` or `}`.
    private func closesBacktick(_ lo: Int, _ hi: Int) -> Bool {
        var k = hi - 1
        while k >= lo && b[k] != 96 {
            let c = b[k]
            if !(c == 59 || c == 41 || c == 44 || c == 125 || c == 32) { return false }
            k -= 1
        }
        return k >= lo
    }

    private mutating func resetCounts() {
        for k in counts.indices { counts[k] = 0 }
        jsxSeen = false
    }

    private func startsWithTriple(_ lo: Int, _ hi: Int) -> Bool {
        startsWith(lo, hi, SniffBytes.tripleDouble) || startsWith(lo, hi, SniffBytes.tripleSingle)
    }

    /// `""";`, `""")`, `""",` or `"""#` at the start of a line closes a multi-line string.
    private func closesTripleQuote(_ lo: Int, _ hi: Int) -> Bool {
        guard hi - lo >= 4, startsWithTriple(lo, hi) else { return false }
        let c = b[lo + 3]
        return c == 59 || c == 41 || c == 44 || c == 35
    }

    /// A lone `"""` line that cannot be an opener: openers follow a `:`
    /// line (a docstring) or start the sample.
    private func loneTripleIsCloser(_ i: Int, _ lo: Int, _ hi: Int) -> Bool {
        guard hi - lo == 3, startsWithTriple(lo, hi) else { return false }
        var j = i - 1
        while j >= 0 && isBlank(j) { j -= 1 }
        guard j >= 0 else { return false }
        let last = b[lineEnds[j] - 1]
        return last != 58 && last != 61 && last != 40 && last != 123 && last != 44 && last != 91
            && !(last >= 97 && last <= 122 && endsWithWord(j, SniffBytes.returnWord))
    }

    private func endsWithWord(_ j: Int, _ word: [UInt8]) -> Bool {
        let hi = lineEnds[j]
        guard hi - lineLo[j] >= word.count else { return false }
        return startsWith(hi - word.count, hi, word)
    }

    private func countTriples(_ lo: Int, _ hi: Int, _ quote: UInt8) -> Int {
        var n = 0
        var i = lo
        while i + 2 < hi {
            if b[i] == quote && b[i + 1] == quote && b[i + 2] == quote { n += 1; i += 3 } else { i += 1 }
        }
        return n
    }

    private func occurrences(_ lo: Int, _ hi: Int, _ needle: [UInt8]) -> Int {
        var n = 0
        var from = lo
        while let at = find(from, hi, needle) { n += 1; from = at + needle.count }
        return n
    }

    private func countByte(_ lo: Int, _ hi: Int, _ byte: UInt8) -> Int {
        var n = 0
        for k in lo..<hi where b[k] == byte { n += 1 }
        return n
    }

    /// A `* item` line belongs to a list when the previous content line is a list item too.
    private func looksLikeListContext(_ i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && isBlank(j) { j -= 1 }
        guard j >= 0 else { return false }
        let lo = lineLo[j]
        let c = b[lo]
        if c == 45 || c == 43 { return lineEnds[j] - lo > 1 && b[lo + 1] == 32 }   // - item, + item
        if c == 42 { return lineIndent[j] == 0 }
        return false
    }

    private func hashLevel(_ lo: Int, _ hi: Int) -> Int {
        var k = lo
        while k < hi && b[k] == 35 { k += 1 }
        let level = k - lo
        guard level <= 6, k < hi, b[k] == 32, k + 1 < hi else { return 0 }
        return level
    }

    /// Classifies a line starting with `#` (a preprocessor directive, a Rust
    /// attribute, a CSS id selector, a comment or a Markdown heading). Returns
    /// true when it counted as a heading.
    private mutating func hashLine(_ i: Int, _ lo: Int, _ hi: Int, previousWasHeading: Bool,
                                   previousLevel: Int) -> Bool {
        if i == 0 && hi - lo > 1 && b[lo + 1] == 33 { return false }   // shebang, decided earlier
        if hi - lo > 1 && b[lo + 1] == 34 { return false }   // Swift raw string #"…"#
        if startsWith(lo, hi, SniffBytes.include) {
            hit(.cInclude)
            if let open = find(lo, hi, [60]), let close = find(open, hi, [62]) {
                let header = b[(open + 1)..<close]
                if !header.contains(46) || contains(open, close, SniffBytes.stdcpp) { hit(.cppHeader) }
            }
            return false
        }
        for directive in SniffBytes.preprocessor where startsWith(lo, hi, directive) {
            let end = lo + directive.count
            if end == hi || b[end] == 32 || b[end] == 9 || b[end] == 40 {
                hit(.cPreproc)
                return false
            }
        }
        for directive in SniffBytes.csDirectives where startsWith(lo, hi, directive) {
            hit(.csDirective)
            return false
        }
        if startsWith(lo, hi, SniffBytes.rustAttr) || startsWith(lo, hi, SniffBytes.rustInnerAttr) {
            hit(.rustAttr)
            return false
        }
        let level = hashLevel(lo, hi)
        if level == 0 {
            // `#id {` is a CSS selector; anything else is a hash comment.
            if b[hi - 1] == 123 && hi - lo > 2 && isIdentStart(b[lo + 1]) {
                hit(.cssSelector)
            } else {
                hit(.hashComment)
            }
            return false
        }
        // A heading stands apart: the next line is blank, the end, or a
        // heading of another level. Runs of `#` lines are comments.
        let next = i + 1 < lineLo.count ? i + 1 : nil
        var standsApart = next == nil || isBlank(next!)
        if let n = next, !isBlank(n), b[lineLo[n]] == 35 {
            let nextLevel = hashLevel(lineLo[n], lineEnds[n])
            standsApart = nextLevel > 0 && nextLevel != level
        }
        if previousWasHeading == false && previousLevel == level { standsApart = false }
        if standsApart || (level >= 2 && !(previousLevel == level)) {
            hit(level >= 2 ? .mdHeadingDeep : .mdHeading)
            return true
        }
        hit(.hashComment)
        return false
    }

    // MARK: Line facts

    private func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95
    }

    private func isIdent(_ c: UInt8) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    private func analyze(_ lo: Int, _ hi: Int) -> SniffLineFacts {
        var f = SniffLineFacts()
        f.codeEnd = hi
        var i = lo
        var quote: UInt8 = 0
        var wordIndex = 0
        while i < hi {
            let c = b[i]
            if quote != 0 {
                if c == 92 {   // backslash
                    if quote == 34 && i + 1 < hi && b[i + 1] == 40 { f.flags.set(.swiftInterp) }
                    i += 2
                    continue
                }
                if quote == 96 && c == 36 && i + 1 < hi && b[i + 1] == 123 { f.flags.set(.templateInterp) }
                if quote == 34 && c == 36 && i + 1 < hi && (isIdentStart(b[i + 1]) || b[i + 1] == 123 || b[i + 1] == 40
                    || (b[i + 1] >= 48 && b[i + 1] <= 57) || b[i + 1] == 64) && !f.flags.has(.csInterp) {
                    f.flags.set(.dollarVar)
                    if b[i + 1] == 40 { f.flags.set(.dollarParen) }
                }
                if c == quote {
                    quote = 0
                    if c == 96 { f.flags.set(.backtickPair) }
                }
                if c == 96 { f.backticks += 1 }
                i += 1
                continue
            }
            switch c {
            case 34:   // "
                if i + 2 < hi && b[i + 1] == 34 && b[i + 2] == 34 {
                    f.tripleQuotes += 1
                    f.tripleQuoteByte = 34
                    if i > lo && b[i - 1] == 102 && (i - 1 == lo || !isIdent(b[i - 2])) { f.flags.set(.fString) }
                    if i > lo && (b[i - 1] == 114 || b[i - 1] == 98) && (i - 1 == lo || !isIdent(b[i - 2])) {
                        f.flags.set(.stringPrefix)
                    }
                    // Skip to a closing triple on the same line, else stop.
                    if let close = find(i + 3, hi, SniffBytes.tripleDouble) {
                        f.tripleQuotes += 1
                        i = close + 3
                        continue
                    }
                    f.codeEnd = i + 3
                    i = hi
                    continue
                }
                if i > lo {
                    let p = b[i - 1]
                    if p == 102 && (i - 1 == lo || !isIdent(b[i - 2])) { f.flags.set(.fString) }
                    if (p == 114 || p == 98) && i - 1 > lo && (b[i - 2] == 32 || b[i - 2] == 40 || b[i - 2] == 61) {
                        f.flags.set(.stringPrefix)
                    }
                    if p == 36 { f.flags.set(.csInterp) }
                    if p == 64 { f.flags.set(.csVerbatim) }
                }
                quote = 34
            case 39:   // '
                if i + 2 < hi && b[i + 1] == 39 && b[i + 2] == 39 {
                    f.tripleQuotes += 1
                    f.tripleQuoteByte = 39
                    let prefix: UInt8 = i > lo ? b[i - 1] : 0
                    if (prefix == 114 || prefix == 98 || prefix == 102) && (i - 1 == lo || !isIdent(b[i - 2])) {
                        f.flags.set(.stringPrefix)
                    }
                    if let close = find(i + 3, hi, SniffBytes.tripleSingle) {
                        f.tripleQuotes += 1
                        i = close + 3
                        continue
                    }
                    f.codeEnd = i + 3
                    i = hi
                    continue
                }
                let p: UInt8 = i > lo ? b[i - 1] : 32
                if isIdent(p) || p == 38 || p == 60 {
                    // Apostrophe, Rust lifetime (&'a, <'a), or a prefix.
                    if p == 102 && (i - 1 == lo || !isIdent(b[i - 2])) {
                        f.flags.set(.fString)
                        quote = 39
                    } else if p == 38 {
                        f.flags.set(.rustRef)
                    }
                } else if find(i + 1, hi, [39]) != nil {
                    quote = 39
                }
            case 96:   // `
                f.backticks += 1
                quote = 96
            case 47:   // /
                if i + 1 < hi && b[i + 1] == 47 && (i == lo || b[i - 1] == 32 || b[i - 1] == 9 || b[i - 1] == 59) {
                    f.codeEnd = i
                    i = hi
                    continue
                }
                if i + 1 < hi && b[i + 1] == 42 {
                    if let close = find(i + 2, hi, SniffBytes.blockEnd) {
                        i = close + 2
                        continue
                    }
                    f.opensBlockComment = true
                    f.codeEnd = i
                    i = hi
                    continue
                }
                if i + 1 < hi && b[i + 1] == 62 { f.flags.set(.selfClose) }
                f.punctuation += 1
            case 61:   // =
                f.punctuation += 1
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                let p: UInt8 = i > lo ? b[i - 1] : 0
                if n == 62 { f.flags.set(.fatArrow); i += 2; continue }
                if n == 61 {
                    if i + 2 < hi && b[i + 2] == 61 { f.flags.set(.strictEq); i += 3; continue }
                    i += 2
                    continue
                }
                if n == 123 && isIdent(p) { f.flags.set(.braceAttr) }
                if p != 33 && p != 60 && p != 62 && p != 58 && p != 43 && p != 45 && p != 42 && p != 47
                    && p != 61 && p != 124 && p != 38 && p != 37 {
                    f.equalsAssign = true
                }
            case 33:   // !
                if i + 2 < hi && b[i + 1] == 61 && b[i + 2] == 61 { f.flags.set(.strictEq) }
                if i > lo && isIdent(b[i - 1]) && i + 1 < hi && (b[i + 1] == 40 || b[i + 1] == 91 || b[i + 1] == 123) {
                    f.flags.set(.macroBang)
                }
                if startsWith(i, hi, SniffBytes.important) { f.flags.set(.important) }
            case 58:   // :
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if n == 61 { f.flags.set(.colonEq) }
                if n == 58 {
                    f.flags.set(.doubleColon)
                    // Type::name(
                    var k = i + 2
                    while k < hi && isIdent(b[k]) { k += 1 }
                    if k > i + 2 && k < hi && b[k] == 40 && i > lo && isIdent(b[i - 1]) { f.flags.set(.pathCall) }
                    i += 2
                    continue
                }
                if i > lo && b[i - 1] == 63 { f.flags.set(.questionColon) }
                // `): Type` and `: Name<`
                var p = i - 1
                while p > lo && b[p] == 32 { p -= 1 }
                if p >= lo && b[p] == 41 { f.flags.set(.parenColon) }
                var k = i + 1
                while k < hi && b[k] == 32 { k += 1 }
                if k < hi && b[k] >= 65 && b[k] <= 90 {
                    var e = k
                    while e < hi && isIdent(b[e]) { e += 1 }
                    if e < hi && b[e] == 60 { f.flags.set(.genericAfterColon) }
                }
            case 45:   // -
                if i + 1 < hi && b[i + 1] == 62 {
                    let spaced = i > lo && b[i - 1] == 32 && i + 2 < hi && b[i + 2] == 32
                    if spaced { f.flags.set(.spacedArrow) } else if i > lo && isIdent(b[i - 1]) {
                        f.flags.set(.ptrArrow)
                    }
                    i += 2
                    continue
                }
            case 60:   // <
                f.punctuation += 1
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if n == 45 { f.flags.set(.chanArrow) }
                if n == 47 { f.flags.set(.tagClose) }
                if n == 62 && i + 2 < hi && b[i + 2] == 40 { f.flags.set(.diamond) }
                if isIdentStart(n) && (i == lo || b[i - 1] == 32 || b[i - 1] == 40 || b[i - 1] == 62) {
                    f.flags.set(.tagOpen)
                }
            case 38:   // &
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if n == 38 { f.flags.set(.andAnd); i += 2; continue }
                if startsWith(i, hi, SniffBytes.refStr) || startsWith(i, hi, SniffBytes.refMut)
                    || startsWith(i, hi, SniffBytes.refSelf) {
                    f.flags.set(.rustRef)
                }
                if isIdentStart(n) {
                    var k = i + 1
                    while k < hi && isIdent(b[k]) { k += 1 }
                    if k < hi && b[k] == 59 && k - i <= 8 { f.flags.set(.entity) }
                }
                if i > lo && b[i - 1] == 62 { f.flags.set(.redirect) }
            case 124:  // |
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if n == 124 { f.flags.set(.orOr); i += 2; continue }
                if isIdentStart(n) || n == 95 {
                    var k = i + 1
                    while k < hi && (isIdent(b[k]) || b[k] == 44 || b[k] == 32 || b[k] == 38) { k += 1 }
                    if k < hi && b[k] == 124 && k > i + 1 && (i == lo || b[i - 1] == 40 || b[i - 1] == 32) {
                        f.flags.set(.pipeClosure)
                    }
                }
            case 62:   // >
                if i > lo && (b[i - 1] == 50 || b[i - 1] == 49) && (i - 1 == lo || b[i - 2] == 32) {
                    f.flags.set(.redirect)
                }
                if i + 1 < hi && b[i + 1] == 38 { f.flags.set(.redirect) }
                if startsWith(i, hi, SniffBytes.devNull) || startsWith(i, hi, SniffBytes.devNullSpaced) {
                    f.flags.set(.redirect)
                }
                f.punctuation += 1
            case 36:   // $
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if n == 40 && i + 2 < hi && isIdentStart(b[i + 2]) { f.flags.set(.dollarParen) }
                if n == 40 && i + 2 < hi && b[i + 2] == 40 { f.flags.set(.dollarParen) }
                if isIdentStart(n) || n == 123 || (n >= 49 && n <= 57) || n == 64 || n == 35 || n == 63 {
                    f.flags.set(.dollarVar)
                }
                if n == 48 { f.flags.set(.closureArg) }
            case 63:   // ?
                let n: UInt8 = i + 1 < hi ? b[i + 1] : 0
                if (n == 59 || n == 41 || n == 46) && i > lo && (isIdent(b[i - 1]) || b[i - 1] == 41) {
                    f.flags.set(.questionTry)
                }
            case 59:   // ;
                f.punctuation += 1
                if i + 1 < hi && b[i + 1] == 59 { f.flags.set(.doubleSemi) }
            case 93:   // ]
                f.punctuation += 1
                if i + 1 < hi && b[i + 1] == 40 { f.flags.set(.mdLink) }
                if i > lo && b[i - 1] == 91 && i + 1 < hi && isIdentStart(b[i + 1]) { f.flags.set(.sliceType) }
            case 42:   // *
                if i + 2 < hi && b[i + 1] == 42 && isIdentStart(b[i + 2]) && (i == lo || b[i - 1] == 32) {
                    f.flags.set(.mdEmphasis)
                }
            case 46:   // .
                if i + 1 < hi && b[i + 1] >= 65 && b[i + 1] <= 90 && i > lo && isIdent(b[i - 1]) {
                    var k = i + 1
                    while k < hi && isIdent(b[k]) { k += 1 }
                    if k < hi && b[k] == 40 { f.flags.set(.pascalCall) }
                }
            case 64:   // @
                if i + 1 < hi && isIdentStart(b[i + 1]) { f.flags.set(.atAttribute) }
            case 123:  // {
                f.punctuation += 1
                // `= { key: v` / `({ key: v` / `return { key: v` — an object literal.
                var p = i - 1
                while p >= lo && b[p] == 32 { p -= 1 }
                let afterReturn = p - 5 >= lo && b[p] == 110 && startsWith(p - 5, p + 1, SniffBytes.returnWord)
                if p >= lo && (b[p] == 61 || b[p] == 40 || afterReturn) {
                    var k = i + 1
                    while k < hi && b[k] == 32 { k += 1 }
                    let keyStart = k
                    while k < hi && isIdent(b[k]) { k += 1 }
                    if k > keyStart && k + 1 < hi && b[k] == 58 && b[k + 1] == 32 { f.flags.set(.objectLiteral) }
                }
            case 40, 41, 125, 91:
                f.punctuation += 1
            default:
                if c >= 0x80 {
                    f.nonASCII += 1
                } else if isIdentStart(c) {
                    var k = i + 1
                    while k < hi && isIdent(b[k]) { k += 1 }
                    f.words += 1
                    var token: SniffToken? = nil
                    if k - i <= 12 { token = SniffToken.table[string(i, k)] }
                    if let token { f.tokens.insert(token) }
                    if wordIndex == 0 && i == lo {
                        f.firstWord = token
                        f.firstWordRange = i..<k
                    } else if wordIndex == 1 {
                        f.secondWord = token
                        f.secondWordRange = i..<k
                    } else if wordIndex == 2 {
                        f.thirdWordRange = i..<k
                    }
                    if c == 95 && k - i > 4 && b[i + 1] == 95 && b[k - 1] == 95 && b[k - 2] == 95 {
                        f.flags.set(.dunder)
                    }
                    if token == .as_ || token == .try_, k < hi, b[k] == 63 || b[k] == 33 {
                        f.flags.set(.optionalCast)
                    }
                    if token == .in_, i > lo + 1, b[i - 1] == 32 {
                        // `{ x in` / `{ (a, b) in` closure heads
                        var p = i - 2
                        while p > lo && (isIdent(b[p]) || b[p] == 44 || b[p] == 32 || b[p] == 41 || b[p] == 40) {
                            p -= 1
                        }
                        if b[p] == 123 && k == hi { f.flags.set(.closureIn) }
                    }
                    wordIndex += 1
                    i = k
                    continue
                } else if c >= 48 && c <= 57 {
                    var k = i + 1
                    while k < hi && (isIdent(b[k]) || b[k] == 46) { k += 1 }
                    i = k
                    continue
                }
            }
            i += 1
        }
        var e = f.codeEnd
        while e > lo && (b[e - 1] == 32 || b[e - 1] == 9) { e -= 1 }
        f.last = e > lo ? b[e - 1] : 0
        f.codeEnd = e
        return f
    }

    // MARK: Rules

    /// Classifies one content line. Returns true when the line opens a Python
    /// block (a keyword line ending in `:`).
    private mutating func classify(_ i: Int, _ lo: Int, _ hi: Int, _ f: inout SniffLineFacts) -> Bool {
        let end = f.codeEnd
        let last = f.last
        let fw = f.firstWord
        let sw = f.secondWord
        let t = f.tokens
        let first = b[lo]
        var opensPythonBlock = false
        var isCode = false

        // Generic statement shape.
        if last == 59 {
            if end - lo >= 2 && b[end - 2] == 125 { hit(.braceSemicolon) } else { hit(.semicolonEnd) }
            isCode = true
        }
        if last == 123 {
            hit(.braceOpenEnd)
            isCode = true
            if end - lo == 1 { hit(.allmanBrace) }
        }
        if first == 125 { hit(.closeBraceLine); isCode = true }
        if f.flags.has(.fatArrow) { hit(.fatArrow) }
        if t.contains(.nil_) { hit(.nilToken) }
        if f.flags.has(.dunder) { hit(.pyDunder) }

        // ---- Python
        switch fw {
        case .def:
            if last == 58 && contains(lo, end, [40]) { hit(.pyDef); opensPythonBlock = true; isCode = true }
        case .async_ where sw == .def:
            if last == 58 { hit(.pyDef); opensPythonBlock = true; isCode = true }
        case .class_:
            if last == 58 { hit(.pyClass); opensPythonBlock = true; isCode = true } else if last == 123 {
                classLine(lo, end, &f)
            }
        case .elif:
            if last == 58 { hit(.pyElif); hit(.pyBlock); opensPythonBlock = true; isCode = true }
        case .if_, .while_, .with, .try_, .except, .finally, .else_:
            if last == 58 {
                hit(.pyBlock); opensPythonBlock = true; isCode = true
            }
        case .for_:
            if last == 58 && t.contains(.in_) { hit(.pyBlock); opensPythonBlock = true; isCode = true }
        case .from:
            if t.contains(.import_) && !contains(lo, end, [39]) && !contains(lo, end, [34]) && last != 59 {
                hit(.pyFromImport); isCode = true
            }
        case .pass:
            if end - lo == 4 { hit(.pyKeywordLine) }   // `pass` alone
        case .raise:
            if last != 59 && last != 46 && (contains(lo, end, [40]) || f.words <= 3) { hit(.pyKeywordLine) }
        case .nonlocal, .global, .lambda:
            if last != 59 && last != 46 && f.punctuation <= 6 { hit(.pyKeywordLine) }
        default:
            break
        }
        if t.contains(.none_) || t.contains(.true_) || t.contains(.false_) {
            if last != 59 && !t.contains(.Some) { hit(.pyConstant) }
        }
        if f.flags.has(.fString) { hit(.pyFString) }
        if t.contains(.for_) && t.contains(.in_) && contains(lo, end, [91]) && fw != .for_ {
            if SniffPattern.comprehension.firstMatch(in: string(lo, end)) { hit(.pyComprehension) }
        }
        if t.contains(.self_) && contains(lo, end, SniffBytes.selfDot) { hit(.selfDot) }

        // ---- imports
        if fw == .import_ { importLine(lo, end, &f); isCode = true }

        // ---- JavaScript family
        switch fw {
        case .const_:
            constLine(lo, end, &f)
        case .let_:
            letLine(lo, end, &f)
        case .var_:
            varLine(lo, end, &f)
        case .function:
            functionLine(lo, end, &f)
        case .async_ where sw == .function:
            hit(.jsFunction)
        case .export:
            if sw == .function || sw == .const_ || sw == .class_ || sw == .let_
                || sw == .interface || sw == .type || sw == .enum_ || contains(lo, end, SniffBytes.exportDefault)
                || contains(lo, end, SniffBytes.exportBrace) {
                hit(.jsExport)
                if sw == .function { hit(.jsFunction) }
                if sw == .interface { hit(.tsInterface) }
                if sw == .type {
                    if contains(lo, end, [61]) {
                        hit(.tsTypeAlias)
                    } else if contains(lo, end, [123]) {
                        hit(.tsImportType)
                    }
                }
                if sw == .const_ { hit(.jsConst) }
            } else if f.words >= 2 && contains(lo, end, [61]) && !contains(lo, end, SniffBytes.spaceEq) {
                hit(.bashCommand)   // export NAME=value
            }
        case .interface:
            if last == 123 {
                if contains(lo, end, SniffBytes.extendsWord) || f.words <= 3 { hit(.tsInterface) }
            }
        case .type:
            if f.equalsAssign {
                hit(.tsTypeAlias)
            } else if contains(lo, end, SniffBytes.structWord) || contains(lo, end, SniffBytes.interfaceWord) {
                if last == 123 { hit(.goTypeDecl) }
            } else if f.words == 3 && last != 59 && last != 58 {
                hit(.goTypeDecl)   // type Celsius float64
            }
        case .readonly:
            if contains(lo, end, [58]) { hit(.tsMember) }
        case .declare:
            if f.words >= 3 { hit(.tsMember) }
        case .constructor:
            if contains(lo, end, [40]) && (last == 123 || last == 125) { hit(.jsConstructor) }
        default:
            break
        }
        if f.flags.has(.strictEq) { hit(.jsStrictEq) }
        if f.flags.has(.objectLiteral) { hit(.jsObjectLiteral) }
        if startsWith(lo, end, SniffBytes.useStrictSingle) || startsWith(lo, end, SniffBytes.useStrictDouble) {
            hit(.jsUseStrict)
        }
        if (t.contains(.console) || t.contains(.document) || t.contains(.window)) && contains(lo, end, [46]) {
            if containsWordDot(lo, end, SniffBytes.console) || containsWordDot(lo, end, SniffBytes.document)
                || containsWordDot(lo, end, SniffBytes.window) {
                hit(.jsGlobals)
            }
        }
        if t.contains(.require) && contains(lo, end, SniffBytes.requireCall) { hit(.jsRequire) }
        if t.contains(.module) && contains(lo, end, SniffBytes.moduleExports) { hit(.jsRequire) }
        if f.flags.has(.templateInterp) { hit(.jsTemplate) }
        if t.contains(.undefined) { hit(.jsUndefined) }
        if t.contains(.typeof) && fw != .type { hit(.jsUndefined) }
        if fw == .for_ && t.contains(.of) && contains(lo, end, SniffBytes.forParen)
            && (t.contains(.const_) || t.contains(.let_)) {
            hit(.jsForOf)
        }
        if t.contains(.as_) && contains(lo, end, SniffBytes.asConst) { hit(.tsAsConst) }
        typeScriptAnnotations(lo, end, &f)
        jsxShapes(lo, end, &f)
        if fw == nil || (fw != .if_ && fw != .for_ && fw != .while_ && fw != .switch_ && fw != .function
                         && fw != .return_) {
            if last == 123 && first != 46 && first != 35 && isIdentStart(first) { methodShorthand(lo, end, &f) }
        }

        // ---- Java / C#
        if let fw, SniffToken.modifiers.contains(fw) {
            modifierLine(lo, end, &f)
        }
        if fw == .package {
            if last == 59 { hit(.javaPackage) } else if f.words == 2 && end == f.secondWordRange.upperBound {
                hit(.goPackage)
            }
        }
        if t.contains(.System_) && contains(lo, end, SniffBytes.systemOut) { hit(.javaPrint) }
        if f.flags.has(.atAttribute) && first == 64 { atLine(lo, end, &f) }
        if f.flags.has(.diamond) { hit(.javaDiamond) }
        if t.contains(.static_) && t.contains(.final) { hit(.javaStaticFinal) }
        if fw == nil && f.last == 59 && (f.flags.has(.questionColon) || f.firstWordRange.upperBound < end
            && b[f.firstWordRange.upperBound] == 58) {
            // `name?: Type;` / `name: Type;` — an interface or class member.
            var k = f.firstWordRange.upperBound
            if k < end && b[k] == 63 { k += 1 }
            if k + 2 < end && b[k] == 58 && b[k + 1] == 32 && b[k + 2] >= 65 && b[k + 2] <= 90 {
                hit(.tsMember)
            } else if f.flags.has(.questionColon) && k + 1 < end && b[k] == 58 {
                hit(.tsMember)
            }
        }
        if t.contains(.throws_) && contains(lo, end, [41]) { hit(.javaThrows) }
        if (t.contains(.extends) || t.contains(.implements)) && last == 123 { hit(.extendsImplements) }
        if f.flags.has(.spacedArrow) && fw != .def && fw != .func_ && fw != .fn && fw != .pub
            && !t.contains(.func_) && !t.contains(.fn) && !t.contains(.def) && !f.flags.has(.closureIn) {
            if SniffPattern.javaLambda.firstMatch(in: string(lo, end)) { hit(.javaLambda) }
        }
        typeFirstDeclaration(lo, end, &f)
        if fw == .for_ && contains(lo, end, SniffBytes.forParen) { forParenLine(lo, end, &f) }
        if fw == .using { usingLine(lo, end, &f) }
        if fw == .namespace { namespaceLine(lo, end, &f) }
        if t.contains(.get) && contains(lo, end, SniffBytes.getSemicolon) { hit(.csProperty) }
        if t.contains(.Console_) && contains(lo, end, SniffBytes.consoleDot) { hit(.csConsole) }
        if f.flags.has(.csInterp) { hit(.csInterp) }
        if f.flags.has(.csVerbatim) { hit(.csVerbatim) }
        if fw == .foreach && contains(lo, end, [40]) { hit(.csForeach) }
        if t.contains(.Task_)
            && (contains(lo, end, SniffBytes.asyncTask) || contains(lo, end, SniffBytes.taskGeneric)) {
            hit(.csTask)
        }
        if f.flags.has(.pascalCall) { hit(.pascalCall) }
        if fw == .enum_ && last == 123 { hit(.enumDecl) }

        // ---- C / C++
        if f.flags.has(.ptrArrow) { hit(.cPtrArrow) }
        if t.contains(.printf) || t.contains(.scanf) || t.contains(.malloc) || t.contains(.free)
            || t.contains(.sizeof) || t.contains(.fprintf) || t.contains(.fopen) || t.contains(.fclose)
            || t.contains(.strlen)
            || t.contains(.strcmp) || t.contains(.memcpy) || t.contains(.memset) || t.contains(.calloc)
            || t.contains(.realloc) || t.contains(.puts) {
            if SniffPattern.cCall.firstMatch(in: string(lo, end)) && !f.flags.has(.dollarVar) { hit(.cStdCall) }
        }
        if t.contains(.NULL_) { hit(.cNull) }
        if fw == .typedef { hit(.cTypedef) }
        if fw == .struct_ || (fw == .static_ && sw == .struct_) {
            let nameRange = fw == .struct_ ? f.secondWordRange : f.thirdWordRange
            if !nameRange.isEmpty, b[nameRange.lowerBound] >= 97, b[nameRange.lowerBound] <= 122 {
                hit(.cStruct)
            } else if last == 123 && f.words == 2 {
                hit(.braceClass)   // struct Name { — C, C++, C#, Swift, Rust
            }
        }
        if t.contains(.std) && f.flags.has(.doubleColon) && contains(lo, end, SniffBytes.stdColons) {
            hit(.cppStd)
        }
        if t.contains(.cout) || t.contains(.cin) || t.contains(.cerr) {
            if contains(lo, end, SniffBytes.shiftLeft) || contains(lo, end, SniffBytes.shiftRight) { hit(.cppStream) }
        }
        if t.contains(.nullptr) { hit(.cppNullptr) }
        if fw == .template && contains(lo, end, [60]) { hit(.cppTemplate) }
        if (fw == .public_ || fw == .private_ || fw == .protected_) && last == 58 && f.words == 1 { hit(.cppAccess) }
        if t.contains(.constexpr) || t.contains(.noexcept) || fw == .explicit
            || (fw == .virtual && !contains(lo, end, [123]) && last == 59)
            || (t.contains(.typename) && fw != .template) {
            hit(.cppKeyword)
        }
        if fw == .auto && (contains(lo, end, [61]) || contains(lo, end, [38])) { hit(.cppAuto) }

        // ---- Go
        if fw == .func_ { funcLine(lo, end, &f) }
        if f.flags.has(.colonEq) { hit(.goColonEq) }
        if t.contains(.err) && contains(lo, end, SniffBytes.errNil) { hit(.goErrNil) }
        if t.contains(.fmt) && contains(lo, end, SniffBytes.fmtDot) { hit(.goFmt) }
        if f.flags.has(.chanArrow) || t.contains(.chan)
            || (t.contains(.make) && contains(lo, end, SniffBytes.makeCall))
            || (f.flags.has(.sliceType) && !contains(lo, end, SniffBytes.mdTaskOpen)) {
            hit(.goTypes)
        }
        if fw == .defer_ { hit(.deferStmt) }
        if t.contains(.range) && f.flags.has(.colonEq) { hit(.goRange) }
        if fw == .go && (sw == .func_ || contains(lo, end, [40])) && last != 46 { hit(.goTypes) }

        // ---- Rust
        rustLine(lo, end, &f)

        // ---- Swift
        swiftLine(lo, end, &f)

        // ---- Shared control flow
        if fw == .if_ || fw == .while_ || fw == .switch_ {
            let open = f.firstWordRange.upperBound
            var k = open
            while k < end && b[k] == 32 { k += 1 }
            if k < end && b[k] == 40 && (last == 123 || last == 41 || last == 59) {
                hit(.ifParen)
            } else if last == 123 && k < end && b[k] != 91 {
                if fw == .while_ { hit(.whileBare) } else { hit(.ifBare) }
            }
        }
        if fw == .for_ && last == 123 && t.contains(.in_) && !contains(lo, end, SniffBytes.forParen) {
            hit(.forInBrace)
        }
        if fw == .return_ {
            if last == 59 { hit(.returnSemi) } else if last != 46 && last != 44 && f.words <= 8 { hit(.returnBare) }
        }
        if fw == .print && contains(lo, end, SniffBytes.printCall) && last == 41 { hit(.printCall) }

        // ---- Bash
        bashLine(i, lo, end, &f)

        // ---- SQL
        sqlLine(lo, end, &f)

        // ---- CSS
        cssLine(lo, end, &f)

        // ---- Markup
        if first == 60 { markupLine(lo, end, &f) }
        if f.flags.has(.entity) { hit(.entity) }

        // ---- Data formats and prose
        tomlLiteralAssignment = false
        dataLine(i, lo, end, &f, isCode: isCode)

        // Python-ish bare assignments (no declaration keyword, no `;`).
        if fw == nil, f.equalsAssign, last != 59, last != 123, last != 44, isIdentStart(first),
           f.firstWordRange.upperBound > lo, !f.flags.has(.colonEq) {
            let after = f.firstWordRange.upperBound
            var k = after
            while k < end && b[k] == 32 { k += 1 }
            let spacedEquals = contains(lo, end, SniffBytes.spaceEq)
            if k < end && b[k] == 44 && spacedEquals {
                hit(.pyTupleAssign)   // a, b = …
            } else if k < end && ((b[k] == 61 && k > after) || b[k] == 46 || b[k] == 91) && spacedEquals {
                if !f.flags.has(.dollarVar) && f.nonASCII == 0 && !tomlLiteralAssignment {
                    hit(.bareAssign)
                    if f.tripleQuotes > 0 || f.flags.has(.stringPrefix) { hit(.pyDocstring) }
                }
            }
        }
        return opensPythonBlock
    }

    private func containsWordDot(_ lo: Int, _ hi: Int, _ word: [UInt8]) -> Bool {
        var from = lo
        while let at = find(from, hi, word) {
            if at == lo || !isIdent(b[at - 1]) { return true }
            from = at + 1
        }
        return false
    }

    // MARK: Language rules

    private mutating func importLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let sw = f.secondWord
        if contains(lo, end, SniffBytes.fromQuote) || contains(lo, end, SniffBytes.fromDoubleQuote)
            || (f.words <= 2 && (contains(lo, end, [39]) || contains(lo, end, [34])) && f.last == 59)
            || contains(lo, end, SniffBytes.importBrace) || contains(lo, end, SniffBytes.importStar) {
            hit(.jsImport)
            if sw == .type { hit(.tsImportType) }
            return
        }
        if f.last == 59 {
            if sw == .static_ { hit(.javaImport) }
            let s = f.secondWordRange
            if !s.isEmpty && (startsWith(s.lowerBound, end, SniffBytes.javaPrefix)
                              || startsWith(s.lowerBound, end, SniffBytes.javaxPrefix)) {
                hit(.javaImportJava)
            } else if contains(lo, end, [46]) {
                hit(.javaImport)
            }
            return
        }
        // Go: `import (` or `import "fmt"` or `import alias "path"`.
        if end - lo >= 8 && (b[end - 1] == 40 || b[end - 1] == 34) && !contains(lo, end, SniffBytes.fromWord) {
            hit(.goImport)
            return
        }
        let s = f.secondWordRange
        guard !s.isEmpty else { return }
        let c = b[s.lowerBound]
        if c >= 65 && c <= 90 && f.words == 2 {
            let name = string(s.lowerBound, s.upperBound)
            if Self.swiftFrameworks.contains(name) { hit(.swiftFrameworkImport) } else { hit(.swiftImport) }
        } else if c >= 97 && c <= 122 {
            // `import numpy as np` — aliasing without `from` is Python-only.
            if f.tokens.contains(.as_) && !contains(lo, end, [123]) && !contains(lo, end, [42]) {
                hit(.pyFromImport)
            } else {
                hit(.pyImport)
            }
        }
    }

    static let swiftFrameworks: Set<String> = [
        "Foundation", "SwiftUI", "UIKit", "AppKit", "Cocoa", "Combine", "Dispatch", "Darwin", "XCTest",
        "Testing", "Observation", "CoreData", "CoreGraphics", "PackageDescription", "SwiftData", "MapKit",
    ]

    private mutating func constLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let s = f.secondWordRange
        var k = s.isEmpty ? f.firstWordRange.upperBound : s.upperBound
        while k < end && b[k] == 32 { k += 1 }
        if s.isEmpty || s.lowerBound > k {
            // `const [a, b] =` / `const { a } =`
            if k < end && (b[k] == 91 || b[k] == 123) { hit(.jsConst) }
            return
        }
        if let sw = f.secondWord, SniffToken.cTypes.contains(sw) || sw == .std || sw == .auto { return }
        guard k < end else { return }
        if b[k] == 61 && (k + 1 >= end || b[k + 1] != 61) {
            hit(.jsConst)
            if contains(k, end, SniffBytes.fatArrowBytes) { hit(.jsArrowDecl) }
        } else if b[k] == 58 {
            // const NAME: Type = — TypeScript or Rust
            var v = k + 1
            while v < end && b[v] == 32 { v += 1 }
            if v < end && b[v] >= 65 && b[v] <= 90 && f.last != 59 { hit(.jsConst); return }
            typedBinding(k, end, &f, semicolon: f.last == 59)
        }
    }

    private mutating func letLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        if f.secondWord == .mut { hit(.rustLetMut); return }
        var k = f.secondWordRange.isEmpty ? f.firstWordRange.upperBound : f.secondWordRange.upperBound
        while k < end && b[k] == 32 { k += 1 }
        let semicolon = f.last == 59
        if k < end && b[k] == 58 {
            typedBinding(k, end, &f, semicolon: semicolon)
            return
        }
        if semicolon { hit(.letSemi) } else { hit(.letBare) }
    }

    private mutating func varLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        var k = f.secondWordRange.isEmpty ? f.firstWordRange.upperBound : f.secondWordRange.upperBound
        while k < end && b[k] == 32 { k += 1 }
        let semicolon = f.last == 59
        if k < end && b[k] == 58 {
            typedBinding(k, end, &f, semicolon: semicolon)
            return
        }
        if k < end && isIdentStart(b[k]) && !semicolon {
            hit(.goVarTyped)   // var cfg Config
            return
        }
        if k < end && isIdentStart(b[k]) && semicolon {
            hit(.cTypedDecl)
            return
        }
        if semicolon { hit(.varSemi) } else { hit(.varBare) }
    }

    /// `let/var/const name: Type` — the type spelling tells the language.
    private mutating func typedBinding(_ colon: Int, _ end: Int, _ f: inout SniffLineFacts, semicolon: Bool) {
        var k = colon + 1
        while k < end && b[k] == 32 { k += 1 }
        guard k < end else { return }
        let t = f.tokens
        if t.contains(.i32) || t.contains(.i64) || t.contains(.u32) || t.contains(.u64) || t.contains(.usize)
            || t.contains(.f64) || t.contains(.u8) || t.contains(.f32) || b[k] == 38 {
            hit(.rustTypes)
        } else if b[k] >= 97 && b[k] <= 122 {
            if t.contains(.string_) || t.contains(.number) || t.contains(.boolean) || t.contains(.any) {
                hit(.tsPrimAnnotation)
            }
        } else if b[k] >= 65 && b[k] <= 90 || b[k] == 91 {
            if semicolon { hit(.letSemi) } else { hit(.swiftTypedBinding) }
        }
    }

    private mutating func functionLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // Bash: `function name {` / `function name() {` with no parameters.
        let hasParen = contains(lo, end, [40])
        if !hasParen && f.last == 123 { hit(.bashFunctionKeyword); return }
        if hasParen {
            hit(.jsFunction)
            if SniffPattern.tsGenericFunction.firstMatch(in: string(lo, end)) { hit(.tsGenericFunction) }
        }
    }

    private mutating func classLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // class Name {  /  class Name: Base {  /  class Name extends Base {
        let s = f.secondWordRange
        guard !s.isEmpty else { return }
        var k = s.upperBound
        if k < end && b[k] == 58 && k + 1 < end && b[k + 1] == 32 {
            hit(.swiftConformance)
            return
        }
        while k < end && b[k] == 32 { k += 1 }
        if k < end && b[k] == 58 { hit(.csClassDecl); return }   // class Name : Base
        hit(.braceClass)
    }

    private mutating func methodShorthand(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // name(a, b) {  — a JS class method or object method with bare parameters.
        let w = f.firstWordRange
        guard !w.isEmpty, w.lowerBound == lo else { return }
        var k = w.upperBound
        guard k < end, b[k] == 40 else { return }
        k += 1
        var depth = 1
        var bare = true
        var paramWords = 0
        var inWord = false
        while k < end && depth > 0 {
            let c = b[k]
            if c == 40 { depth += 1 } else if c == 41 { depth -= 1 } else if c == 58 || c == 34 || c == 39 {
                bare = false
            }
            if isIdent(c) {
                if !inWord { paramWords += 1; inWord = true }
            } else {
                inWord = false
                if c == 32 && k + 1 < end && isIdentStart(b[k + 1]) && k > 0 && isIdent(b[k - 1]) { bare = false }
            }
            k += 1
        }
        guard depth == 0 else { return }
        while k < end && b[k] == 32 { k += 1 }
        guard k == end - 1 else { return }
        if bare {
            let name = string(w.lowerBound, w.upperBound)
            if f.firstWord == nil || name == "get" || name == "set" {
                if lineIndentOf(lo) > 0 || paramWords > 0 { hit(.jsMethod) } else { hit(.bashFuncDef) }
            }
        }
    }

    private func lineIndentOf(_ lo: Int) -> Int {
        var k = lo
        var n = 0
        while k > 0 && (b[k - 1] == 32 || b[k - 1] == 9) { k -= 1; n += 1 }
        return n
    }

    private mutating func typeScriptAnnotations(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let t = f.tokens
        let fw = f.firstWord
        // Python, Rust and Swift annotate with `:` too; their keywords rule them out.
        if fw == .pub || t.contains(.def) || t.contains(.fn) || t.contains(.func_) { return }
        if t.contains(.string_) || t.contains(.number) || t.contains(.boolean) || t.contains(.any)
            || t.contains(.unknown) || t.contains(.void_) || t.contains(.never) {
            let binding = fw == .let_ || fw == .const_ || fw == .var_
            if !binding && SniffPattern.tsPrimitive.firstMatch(in: string(lo, end)) {
                hit(.tsPrimAnnotation)
            }
        }
        if f.flags.has(.parenColon) && SniffPattern.tsReturn.firstMatch(in: string(lo, end)) {
            hit(.tsReturnType)
        }
        if f.flags.has(.questionColon) && contains(lo, end, [40]) { hit(.tsOptionalParam) }
        if f.flags.has(.genericAfterColon) && fw != .let_ && fw != .var_ { hit(.tsGenericAnnotation) }
    }

    private mutating func jsxShapes(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        guard f.flags.has(.tagOpen) || f.flags.has(.tagClose) || f.flags.has(.selfClose) else { return }
        if f.flags.has(.braceAttr) && f.flags.has(.tagOpen) { hit(.jsxAttr); jsxSeen = true }
        if contains(lo, end, SniffBytes.className) { hit(.jsxAttr); jsxSeen = true }
        if SniffPattern.jsxComponent.firstMatch(in: string(lo, end)) { hit(.jsxComponent); jsxSeen = true }
        if (f.firstWord == .return_ || contains(lo, end, SniffBytes.fatArrowTag)) && f.flags.has(.tagOpen) {
            hit(.jsxComponent); jsxSeen = true
        }
    }

    private mutating func modifierLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let s = string(lo, end)
        let t = f.tokens
        // Class-like declarations.
        if t.contains(.class_) || t.contains(.interface) || t.contains(.enum_) || t.contains(.record)
            || t.contains(.struct_) {
            if let mods = SniffPattern.typeDecl.match(in: s) {
                if mods.contains("sealed") || mods.contains("internal") || mods.contains("partial")
                    || (t.contains(.record) && t.contains(.struct_)) || (t.contains(.static_) && t.contains(.class_)) {
                    hit(.csClassDecl)
                } else if mods.contains("final") || (mods.contains("abstract") && t.contains(.extends)) {
                    hit(.javaClassDecl)
                } else if t.contains(.extends) || t.contains(.implements) {
                    hit(.accessClassDecl)
                    hit(.extendsImplements)
                } else if contains(lo, end, SniffBytes.spacedColon) {
                    hit(.csClassDecl)
                } else {
                    hit(.accessClassDecl)
                }
                if t.contains(.interface) { hit(.interfaceDecl) }
                return
            }
        }
        if t.contains(.static_) && t.contains(.void_) && contains(lo, end, SniffBytes.mainStringArgs) {
            hit(.javaMain)
            return
        }
        if contains(lo, end, SniffBytes.csMain) { hit(.csMain); return }
        if let method = SniffPattern.method.groups(in: s) {
            let (type, name, params) = method
            let paramsHaveColon = params.contains(":")
            if paramsHaveColon || type.isEmpty {
                // TypeScript: `public get(id: string): Promise<User> {` / `private x = 1`
                if paramsHaveColon || f.flags.has(.parenColon) { hit(.tsMember) }
                return
            }
            let pascal = name.first.map { $0.isUppercase } ?? false
            if t.contains(.override) || t.contains(.virtual) || t.contains(.async_) || t.contains(.sealed)
                || t.contains(.internal_) || contains(lo, end, SniffBytes.arrowSpace) {
                hit(.csMethod)
            } else if t.contains(.synchronized) || t.contains(.final) || t.contains(.throws_) {
                hit(.javaMethod)
            } else if pascal {
                hit(.csMethod)
            } else {
                hit(.javaMethod)
            }
            if type == "String" || type.hasPrefix("String[") || type == "boolean" { hit(.javaStringType) }
            if type == "string" || type == "bool" || type.hasPrefix("Task") { hit(.csTypeFirst) }
            return
        }
        // Fields: modifiers + Type name [= …];  vs  modifiers + name [: T] [= …]
        if let field = SniffPattern.field.groups(in: s) {
            let (type, _, _) = field
            if type.isEmpty {
                hit(.tsMember)
            } else if t.contains(.final) {
                hit(.javaField)
            } else if t.contains(.readonly) || type == "string" || type == "bool" || type == "decimal" {
                hit(.csField)
            } else if type == "String" || type == "boolean" {
                hit(.javaField)
            } else if contains(lo, end, SniffBytes.getSemicolon) {
                hit(.csField)
            }
            return
        }
        if f.flags.has(.parenColon) || (contains(lo, end, SniffBytes.colonSpace) && !contains(lo, end, [40])) {
            if !t.contains(.var_) && !t.contains(.let_) && !t.contains(.func_) { hit(.tsMember) }
        }
    }

    private mutating func atLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let w1 = lo + 1
        var k = w1
        while k < end && isIdent(b[k]) { k += 1 }
        let name = string(w1, k)
        if name == "Override" { hit(.javaOverride); return }
        if Self.swiftAttributes.contains(name) { hit(.swiftAttribute); return }
        if k == end || (b[k] == 40 && b[end - 1] == 41) || b[k] == 46 {
            hit(.annotationLine)
        }
    }

    static let swiftAttributes: Set<String> = [
        "main", "MainActor", "State", "Binding", "Published", "ObservedObject", "StateObject", "Environment",
        "EnvironmentObject", "objc", "discardableResult", "escaping", "Observable", "available", "propertyWrapper",
        "IBOutlet", "IBAction", "frozen", "inlinable", "Sendable", "unknown", "AppStorage", "Query", "Model",
    ]

    /// `int x = 0;` / `String s = …;` / `bool ok;` — a type before the name.
    private mutating func typeFirstDeclaration(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        guard let fw = f.firstWord else {
            // `String name = …;` / `List<String> xs = …;`
            let w = f.firstWordRange
            if !w.isEmpty && f.last == 59 && b[w.lowerBound] >= 65 && b[w.lowerBound] <= 90 {
                if contains(lo, end, SniffBytes.genericString) { hit(.javaStringType) }
            }
            return
        }
        switch fw {
        case .String_:
            let declares = !f.secondWordRange.isEmpty || contains(lo, end, SniffBytes.brackets)
            if (f.last == 59 || f.last == 41 || f.last == 123) && declares {
                if !contains(lo, end, [58]) { hit(.javaStringType) }
            }
        case .boolean:
            if !f.secondWordRange.isEmpty && !contains(lo, end, [58]) { hit(.javaStringType) }
        case .string_, .bool_, .decimal:
            if !f.secondWordRange.isEmpty && f.secondWordRange.lowerBound > f.firstWordRange.upperBound
                && !contains(lo, end, [58]) && (f.last == 59 || f.last == 41 || f.last == 123) {
                hit(.csTypeFirst)
            }
        case .int_, .char_, .long_, .double_, .float_, .short_, .unsigned, .signed, .size_t, .void_, .static_,
             .const_, .inline, .extern:
            let s = string(lo, end)
            if SniffPattern.cFunction.firstMatch(in: s) {
                hit(.cFuncDef)
                if f.tokens.contains(.main) && fw == .int_ { hit(.cMain) }
                if contains(lo, end, SniffBytes.starSpace) || SniffPattern.cPointerParam.firstMatch(in: s) {
                    hit(.cPointerDecl)
                }
            } else if f.last == 59 {
                if SniffPattern.cDeclaration.firstMatch(in: s) {
                    hit(.cTypedDecl)
                    if SniffPattern.cPointerDecl.firstMatch(in: s) { hit(.cPointerDecl) }
                }
            }
        default:
            break
        }
    }

    private mutating func forParenLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // for (Type x : xs)  /  for (auto& x : v)
        guard let open = find(lo, end, [40]) else { return }
        guard let colon = find(open, end, SniffBytes.spacedColon) else { return }
        if f.tokens.contains(.auto) || contains(open, colon, [38]) { hit(.cppRangeFor); return }
        if !contains(open, colon, [59]) { hit(.enhancedFor) }
    }

    private mutating func usingLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        if f.secondWord == .namespace { hit(.cppUsingNamespace); return }
        if f.flags.has(.doubleColon) { hit(.cppStd); return }
        if f.secondWord == .var_ || contains(lo, end, SniffBytes.usingParen) { hit(.csUsing); return }
        guard f.last == 59, !f.equalsAssign else { return }
        hit(.csUsing)
        if contains(lo, end, SniffBytes.usingSystem) { hit(.csUsingSystem) }
    }

    private mutating func namespaceLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let s = f.secondWordRange
        guard !s.isEmpty else { return }
        if f.last == 59 { hit(.csFileNamespace); return }
        let c = b[s.lowerBound]
        // `namespace gfx {` (C++ style) vs `namespace Billing.Core` (C# style)
        if c >= 97 && c <= 122 && !contains(s.lowerBound, end, [46]) { hit(.cppNamespace) } else { hit(.csNamespace) }
    }

    private mutating func funcLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // Go: func (r *T) Name(…) / func name(a, b int) T {   Swift: func name(_ x: Int) -> Int {
        var k = f.firstWordRange.upperBound
        while k < end && b[k] == 32 { k += 1 }
        guard k < end else { return }
        if b[k] == 40 { hit(.goMethod); return }
        guard let open = find(k, end, [40]) else { return }
        var depth = 0
        var close = open
        while close < end {
            if b[close] == 40 {
                depth += 1
            } else if b[close] == 41 {
                depth -= 1
                if depth == 0 { break }
            }
            close += 1
        }
        let paramsHaveColon = contains(open, min(close, end), [58])
        let arrow = contains(close, end, SniffBytes.arrow)
        let swiftEffects = f.tokens.contains(.throws_) || contains(close, end, SniffBytes.asyncWord)
        if paramsHaveColon || arrow || swiftEffects || contains(open, close, SniffBytes.underscoreSpace) {
            hit(.swiftFunc)
            return
        }
        if find(k, open, [60]) != nil { hit(.swiftFunc); return }   // func name<T>(
        if close - open > 1 {
            hit(.goFunc)   // parameters without colons: `a, b int`
            return
        }
        // No parameters: a result type before `{` is Go.
        var r = close + 1
        while r < end && b[r] == 32 { r += 1 }
        if r < end && b[r] != 123 { hit(.goFunc) } else { hit(.funcEmpty) }
    }

    private mutating func rustLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let fw = f.firstWord
        let t = f.tokens
        var fnLine = fw == .fn
        if !fnLine && (fw == .pub || fw == .async_ || fw == .const_ || fw == .extern) && t.contains(.fn) {
            fnLine = true
        }
        if fnLine && contains(lo, end, [40]) { hit(.rustFn) }
        if fw == .pub && !fnLine { hit(.rustPub) }
        if fw == .impl { hit(.rustImpl) }
        if fw == .trait && f.last == 123 { hit(.rustImpl) }
        if (fw == .use || (fw == .pub && f.secondWord == .use)) && f.flags.has(.doubleColon) { hit(.rustUse) }
        if fw == .mod && f.last == 59 && f.words == 2 { hit(.rustUse) }
        if f.flags.has(.macroBang) && SniffPattern.rustMacro.firstMatch(in: string(lo, end)) { hit(.rustMacro) }
        if f.flags.has(.rustRef) { hit(.rustRef) }
        if t.contains(.i32) || t.contains(.i64) || t.contains(.u32) || t.contains(.u64) || t.contains(.usize)
            || t.contains(.f64) || t.contains(.u8) || t.contains(.isize) || t.contains(.f32) || t.contains(.i8)
            || t.contains(.u16) || t.contains(.i16) {
            let typePosition = contains(lo, end, [58]) || contains(lo, end, SniffBytes.arrow) || t.contains(.as_)
            if fw != .let_ && fw != .const_ && typePosition {
                hit(.rustTypes)
            }
        }
        if fw == .match && f.last == 123 { hit(.rustMatch) }
        let constructsOption = (t.contains(.Some) || t.contains(.Ok) || t.contains(.Err))
            && (contains(lo, end, SniffBytes.someParen) || contains(lo, end, SniffBytes.okParen)
                || contains(lo, end, SniffBytes.errParen))
        if constructsOption { hit(.rustEnumCtor) }
        if f.flags.has(.questionTry) && (f.last == 59 || f.last == 41)
            && !contains(lo, end, SniffBytes.questionDot) {
            hit(.rustTry)
        }
        if t.contains(.unwrap) && contains(lo, end, SniffBytes.unwrapCall) { hit(.rustTry) }
        if f.flags.has(.pipeClosure) { hit(.rustClosure) }
        if fw == .loop && f.last == 123 { hit(.rustLoop) }
        if f.flags.has(.pathCall) && !t.contains(.std) { hit(.rustPathCall) }
        if (fw == .if_ || fw == .while_) && f.secondWord == .let_ {
            // `if let Some(x) = …` (Rust pattern) vs `if let x = …` (Swift binding)
            if constructsOption { hit(.rustIfLet) } else { hit(.swiftIfLet) }
        }
        if f.flags.has(.fatArrow) {
            // Match arms: `Pattern => value,` / `Enum::Variant => …`
            if (f.last == 44 && fw != .return_ && !contains(lo, end, [40])) || f.flags.has(.doubleColon) {
                hit(.matchArm)
            }
        }
        if t.contains(.Self_) && (t.contains(.fn) || contains(lo, end, SniffBytes.selfColons)) { hit(.rustPub) }
    }

    private mutating func swiftLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let fw = f.firstWord
        let t = f.tokens
        if fw == .guard_ && (f.secondWord == .let_ || f.secondWord == .var_ || contains(lo, end, SniffBytes.elseWord)) {
            hit(.swiftGuard)
        }
        if f.flags.has(.swiftInterp) { hit(.swiftInterp) }
        if fw == .extension_ || fw == .protocol_ { if f.last == 123 { hit(.swiftExtProto) } }
        if (fw == .struct_ || fw == .enum_) && f.last == 123 {
            let s = f.secondWordRange
            if !s.isEmpty && s.upperBound < end && b[s.upperBound] == 58 { hit(.swiftConformance) }
        }
        let swiftModifier = fw == .private_ || fw == .fileprivate_ || fw == .public_ || fw == .override
            || fw == .static_ || fw == .weak
        if swiftModifier && (t.contains(.func_) || t.contains(.var_) || t.contains(.let_)) {
            if !contains(lo, end, [59]) { hit(.swiftDecl) }
        }
        if fw == .init_ && contains(lo, end, [40]) && (f.last == 123 || contains(lo, end, [58])) { hit(.swiftDecl) }
        if fw == .var_ && f.last == 123 && contains(lo, end, [58]) { hit(.swiftDecl) }   // computed property
        if f.flags.has(.closureArg) && contains(lo, end, [123]) { hit(.swiftClosureArg) }
        if f.flags.has(.closureIn) { hit(.swiftClosureArg) }
        if f.flags.has(.optionalCast) { hit(.swiftOptionalCast) }
        if fw == .case_ && f.secondWordRange.lowerBound - 1 >= lo && b[f.secondWordRange.lowerBound - 1] == 46 {
            hit(.swiftDecl)   // case .member
        }
        if t.contains(.some) && contains(lo, end, SniffBytes.someView) { hit(.swiftDecl) }
    }

    private mutating func bashLine(_ i: Int, _ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let fw = f.firstWord
        let t = f.tokens
        switch fw {
        case .if_, .elif:
            if contains(lo, end, SniffBytes.semicolonThen)
                || (contains(lo, end, SniffBytes.bracketSpace) && f.last == 93) {
                hit(.bashIf)
            }
        case .then, .fi, .done, .esac:
            if f.words <= 2 && f.punctuation == 0 { hit(.bashKeyword) }
        case .do_:
            if f.words == 1 && f.punctuation == 0 && f.last != 123 { hit(.bashKeyword) }
        case .for_, .while_:
            if contains(lo, end, SniffBytes.semicolonDo)
                || (f.words >= 2 && end - lo > 3 && startsWith(end - 3, end, SniffBytes.spaceDo)) {
                hit(.bashFor)
            }
        case .case_:
            if t.contains(.in_) && f.last == 110 { hit(.bashCase) }
        case .echo, .local, .source, .exit:
            let sentence = f.last == 58 || f.last == 46 || (fw == .exit && f.words > 2)
                || (fw == .local && !f.equalsAssign && f.words > 3)
            if (f.last != 59 || fw == .echo || f.flags.has(.dollarVar)) && !sentence {
                hit(.bashCommand)
            }
        default:
            let commandWord = fw == nil || fw == .printf || fw == .set || fw == .make
            if commandWord && f.firstWordRange.lowerBound == lo && !f.firstWordRange.isEmpty {
                let w = f.firstWordRange
                let k = w.upperBound
                // NAME=value with no spaces
                if k < end && b[k] == 61 && k + 1 < end && b[k + 1] != 61 && b[k + 1] != 32 {
                    hit(.bashAssign)
                } else if k == end || b[k] == 32 {
                    let word = string(w.lowerBound, w.upperBound)
                    if Self.shellCommands.contains(word) && f.last != 59 && f.last != 46 && f.last != 58
                        && !f.flags.has(.parenColon) && !contains(lo, end, SniffBytes.spaceEq) {
                        if word != "set" || contains(lo, end, SniffBytes.spaceDash) { hit(.bashCommand) }
                    }
                }
            }
        }
        if f.flags.has(.dollarVar) && !f.flags.has(.templateInterp) && !f.flags.has(.csInterp) {
            hit(.bashVar)
        }
        if f.flags.has(.dollarParen) { hit(.bashSubst) }
        if f.flags.has(.redirect) { hit(.bashRedirect) }
        if f.flags.has(.doubleSemi) { hit(.bashCase) }
        if contains(lo, end, SniffBytes.doubleBracket)
            || (contains(lo, end, SniffBytes.spaceDash) && SniffPattern.bashTest.firstMatch(in: string(lo, end))) {
            hit(.bashTest)
        }
        if (f.flags.has(.andAnd) || f.flags.has(.orOr)) && !contains(lo, end, [40]) && f.last != 59
            && f.last != 123 {
            hit(.bashChain)
        }
        if startsWith(lo, end, SniffBytes.dotSlash) { hit(.bashCommand) }
        // name() {  at column 0
        if f.last == 123 && fw == nil && f.words == 1 && lineIndent[i] == 0 && end - lo >= 5
            && startsWith(end - 4, end, SniffBytes.emptyParensBrace) {
            hit(.bashFuncDef)
        }
    }

    static let shellCommands: Set<String> = [
        "cd", "mkdir", "sudo", "rm", "cp", "mv", "chmod", "chown", "curl", "wget", "grep", "sed", "awk", "cat",
        "ls", "tar", "apt", "brew", "npm", "yarn", "pip", "pip3", "git", "docker", "make", "ln", "touch", "unset",
        "alias", "set", "shift", "read", "trap", "pushd", "popd", "xargs", "find", "kill", "ssh", "scp", "rsync",
        "tee", "sort", "uniq", "wc", "head", "tail", "printf", "eval", "exec", "test", "pnpm", "npx", "kubectl",
    ]

    private mutating func sqlLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        // A VALUES row: `(1, 'Ada', 9.5),`
        if b[lo] == 40 && end - lo > 4 && (f.last == 44 || f.last == 59) && b[end - 2] == 41
            && contains(lo, end, [39]) {
            hit(.sqlColumn)
        }
        let w = f.firstWordRange
        guard !w.isEmpty, w.lowerBound == lo, w.count <= 10 else { return }
        // A select-list item with an alias: `SUM(total) AS revenue,`
        if (f.last == 44 || isIdent(f.last)) && contains(lo, end, SniffBytes.upperAs) && f.firstWord == nil {
            hit(.sqlColumn)
        }
        // Column definitions: `name TYPE …,`
        let s2 = f.secondWordRange
        if !s2.isEmpty, f.last == 44 || f.last == 41 || f.last == 40, s2.count >= 3,
           b[s2.lowerBound] >= 65, b[s2.lowerBound] <= 90,
           Self.sqlTypes.contains(string(s2.lowerBound, s2.upperBound)) {
            hit(.sqlColumn)
        }
        let word = string(w.lowerBound, w.upperBound)
        let upper = word.uppercased()
        guard Self.sqlKeywords.contains(upper) else { return }
        // Keywords count in upper or lower case; `Select an option` is prose.
        if word == upper {
            hit(.sqlKeywordUpper)
        } else if word == word.lowercased() && Self.sqlLowerKeywords.contains(word)
                    && (word != "from" || !f.tokens.contains(.import_)) {
            hit(.sqlKeywordLower)
        } else {
            return
        }
        let s = string(lo, end)
        let structure = word == upper ? SniffPattern.sqlStructureUpper : SniffPattern.sqlStructureLower
        if structure.firstMatch(in: s) { hit(.sqlStructure) }
    }

    static let sqlKeywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "JOIN", "LEFT", "RIGHT",
        "INNER", "OUTER", "GROUP", "ORDER", "HAVING", "LIMIT", "VALUES", "SET", "WITH", "UNION", "AND", "OR", "BEGIN",
        "END", "RETURNS", "PRIMARY", "FOREIGN", "REFERENCES", "ON", "CASE", "WHEN", "DECLARE", "GRANT", "TRUNCATE",
        "RETURN", "LANGUAGE", "OFFSET", "INTO", "COMMIT", "ROLLBACK", "INDEX", "TABLE", "USE",
    ]
    static let sqlTypes: Set<String> = [
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "SERIAL", "BIGSERIAL", "VARCHAR", "NVARCHAR", "CHAR", "TEXT",
        "BOOLEAN", "BOOL", "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "DECIMAL", "NUMERIC", "REAL",
        "FLOAT", "DOUBLE", "BLOB", "UUID", "JSON", "JSONB", "BYTEA", "MONEY",
    ]
    static let sqlLowerKeywords: Set<String> = [
        "select", "from", "where", "insert", "update", "delete", "create", "alter", "drop", "join", "left", "inner",
        "group", "order", "having", "limit", "values", "union", "truncate",
    ]

    private mutating func cssLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        let first = b[lo]
        if first == 64 {   // @
            for rule in SniffBytes.cssAtRules where startsWith(lo, end, rule) { hit(.cssAtRule); return }
        }
        if f.last == 123 || (f.last == 44 && f.punctuation == 0) {
            if cssSelectorShape(lo, end, f) { hit(.cssSelector) }
            return
        }
        if f.last == 59 && (first == 45 || (first >= 97 && first <= 122)) {
            if first == 45 && end - lo > 3 && b[lo + 1] == 45 && contains(lo, end, [58]) {
                hit(.cssCustomProp)
                return
            }
            if cssDeclaration(lo, end) {
                hit(.cssProperty)
                if SniffPattern.cssValue.firstMatch(in: string(lo, end)) { hit(.cssValue) }
            }
        }
        if f.flags.has(.important) { hit(.cssImportant) }
    }

    /// `property-name: value;` with no braces or further `;` in the value.
    private func cssDeclaration(_ lo: Int, _ end: Int) -> Bool {
        var k = lo
        while k < end && b[k] == 45 { k += 1 }
        guard k < end, b[k] >= 97 && b[k] <= 122 else { return false }
        while k < end && ((b[k] >= 97 && b[k] <= 122) || (b[k] >= 48 && b[k] <= 57) || b[k] == 45) { k += 1 }
        while k < end && b[k] == 32 { k += 1 }
        guard k < end, b[k] == 58 else { return false }
        k += 1
        while k < end && b[k] == 32 { k += 1 }
        guard k < end - 1 else { return false }
        for q in k..<(end - 1) where b[q] == 59 || b[q] == 123 || b[q] == 125 { return false }
        return true
    }

    private func cssSelectorShape(_ lo: Int, _ end: Int, _ f: SniffLineFacts) -> Bool {
        let first = b[lo]
        // No statement keywords, assignments or arrows.
        if let fw = f.firstWord, Self.selectorBlocking(fw) { return false }
        if contains(lo, end, SniffBytes.spaceEq) || contains(lo, end, [59]) || f.flags.has(.fatArrow) {
            return false
        }
        if first == 46 || first == 35 || first == 58 || first == 91 || first == 42 {
            return first != 46 || (end - lo > 1 && isIdentStart(b[lo + 1]))
        }
        guard isIdentStart(first) else { return false }
        let w = f.firstWordRange
        guard !w.isEmpty else { return false }
        let tag = string(w.lowerBound, w.upperBound)
        guard Self.htmlTags.contains(tag) else { return false }
        let k = w.upperBound
        guard k < end else { return false }
        let c = b[k]
        return c == 32 || c == 46 || c == 58 || c == 35 || c == 44 || c == 91 || c == 62 || c == 123
    }

    static func selectorBlocking(_ token: SniffToken) -> Bool {
        switch token {
        case .if_, .for_, .while_, .switch_, .function, .class_, .struct_, .enum_, .interface, .impl, .fn, .func_,
             .namespace, .else_, .do_, .try_, .public_, .private_, .protected_, .static_, .export, .const_, .let_,
             .var_, .type, .match, .loop, .extension_, .protocol_, .case_, .return_, .package, .trait,
             .guard_, .with, .def, .async_, .template, .typedef:
            return true
        default:
            return false
        }
    }

    static let htmlTags: Set<String> = [
        "html", "head", "body", "div", "span", "p", "a", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6",
        "table", "thead", "tbody", "tr", "td", "th", "img", "form", "input", "button", "label", "select",
        "option", "textarea", "header", "footer", "main", "nav", "section", "article", "aside", "meta", "link",
        "script", "style", "title", "br", "hr", "pre", "code", "em", "strong", "b", "i", "small", "iframe",
        "canvas", "svg", "video", "audio", "source", "figure", "figcaption", "blockquote", "dl", "dt", "dd",
        "noscript", "template", "details", "summary", "dialog", "picture", "caption", "col", "colgroup",
        "fieldset", "legend", "sup", "sub", "abbr", "time", "mark", "u", "s", "q", "cite", "kbd", "var", "wbr",
    ]

    private mutating func markupLine(_ lo: Int, _ end: Int, _ f: inout SniffLineFacts) {
        guard end - lo >= 2 else { return }
        var k = lo + 1
        if b[k] == 63 {   // <?
            if startsWith(lo, end, SniffBytes.xmlDeclaration) { hit(.xmlDecl) } else { hit(.xmlTag) }
            return
        }
        if b[k] == 33 {   // <!
            if startsWith(lo, end, SniffBytes.cdata) { hit(.xmlCData) }
            return
        }
        if b[k] == 47 { k += 1 }
        let nameStart = k
        while k < end && (isIdent(b[k]) || b[k] == 45 || b[k] == 58 || b[k] == 46) { k += 1 }
        guard k > nameStart else { return }
        if k < end && !(b[k] == 32 || b[k] == 62 || b[k] == 47) { return }
        let name = string(nameStart, k)
        if contains(lo, end, SniffBytes.xmlns) { hit(.xmlNamespace) }
        if Self.htmlTags.contains(name) {
            hit(.htmlTag)
        } else if name.contains(":") {
            hit(.xmlNamespace)
            hit(.xmlTag)
        } else {
            hit(.xmlTag)
        }
        if SniffPattern.markupAttribute.firstMatch(in: string(lo, end)) { hit(.markupAttr) }
    }

    /// JSON, YAML, TOML, Markdown and prose shapes.
    private mutating func dataLine(_ i: Int, _ lo: Int, _ end: Int, _ f: inout SniffLineFacts, isCode: Bool) {
        let first = b[lo]
        let last = f.last
        let hiRaw = lineEnds[i]

        // JSON
        var jsonLike = false
        if first == 34 {
            // "key": value
            var k = lo + 1
            while k < hiRaw && b[k] != 34 { if b[k] == 92 { k += 1 }; k += 1 }
            var c = k + 1
            while c < hiRaw && b[c] == 32 { c += 1 }
            if c < hiRaw && b[c] == 58 {
                hit(.jsonKeyLine)
                jsonLike = true
            } else if b[hiRaw - 1] == 44 || k + 1 >= hiRaw {
                jsonLike = true   // "value",
            }
        } else if (first == 123 || first == 125 || first == 91 || first == 93) && hiRaw - lo <= 2 {
            hit(.jsonBraceLine)
            jsonLike = true
        } else if first == 123 && (b[hiRaw - 1] == 125 || b[hiRaw - 1] == 44) {
            // { "id": 1, … },
            jsonLike = contains(lo, hiRaw, SniffBytes.quoteColon)
            if jsonLike { hit(.jsonKeyLine) }
        } else if (first >= 48 && first <= 57)
                    || (first == 45 && hiRaw - lo > 1 && b[lo + 1] >= 48 && b[lo + 1] <= 57) {
            jsonLike = !contains(lo, hiRaw, [32])
        } else if startsWith(lo, hiRaw, SniffBytes.trueWord) || startsWith(lo, hiRaw, SniffBytes.falseWord)
                    || startsWith(lo, hiRaw, SniffBytes.nullWord) {
            jsonLike = hiRaw - lo <= 6
        }
        if !jsonLike { hit(.nonJSONLine) }

        // TOML headers: [section] / [[array]] / [a.b]
        if first == 91 && b[hiRaw - 1] == 93 && hiRaw - lo >= 3 {
            var k = lo + 1
            if b[k] == 91 { k += 1 }
            var ok = k < hiRaw - 1
            var inQuote = false
            while k < hiRaw - 1 {
                let c = b[k]
                if c == 34 { inQuote.toggle() } else if c == 93 && b[k + 1] == 93 && k + 2 == hiRaw {
                    break
                } else if !inQuote && !(isIdent(c) || c == 46 || c == 45) {
                    ok = false
                    break
                }
                k += 1
            }
            if ok && !(b[lo + 1] == 32) { hit(.tomlHeader); return }
        }

        // TOML key = value
        if f.equalsAssign && last != 59 && last != 123 && (isIdentStart(first) || first == 34) && f.firstWord == nil {
            if let eq = find(lo, end, SniffBytes.spaceEq) {
                var keyOK = true
                var k = lo
                while k < eq {
                    let c = b[k]
                    if !(isIdent(c) || c == 46 || c == 45 || c == 34) { keyOK = false; break }
                    k += 1
                }
                if keyOK {
                    var v = eq + 3
                    while v < end && b[v] == 32 { v += 1 }
                    if v < end {
                        if tomlValue(v, end) {
                            hit(.tomlKV)
                            tomlLiteralAssignment = true
                        } else {
                            hit(.tomlBadValue)
                        }
                    }
                }
            }
        }

        // YAML
        yamlLine(i, lo, end, &f, isCode: isCode)

        // Markdown
        if f.flags.has(.mdLink) && SniffPattern.markdownLink.firstMatch(in: string(lo, hiRaw)) { hit(.mdLink) }
        if f.flags.has(.mdEmphasis) && contains(lo, hiRaw, SniffBytes.doubleStarEnd) { hit(.mdEmphasis) }
        if f.flags.has(.backtickPair) && !f.flags.has(.templateInterp) && f.punctuation <= 2
            && f.words >= 3 {
            hit(.mdInlineCode)
        }
        if first == 124 && b[hiRaw - 1] == 124 {
            if SniffPattern.markdownTableRule.firstMatch(in: string(lo, hiRaw)) {
                hit(.mdTable)
            } else {
                hit(.mdTableRow)
            }
        }
        if first == 62 && hiRaw - lo > 2 && b[lo + 1] == 32 { hit(.mdQuote) }
        if (first == 45 || first == 42 || first == 43) && hiRaw - lo > 2 && b[lo + 1] == 32 {
            if startsWith(lo, hiRaw, SniffBytes.taskOpen) || startsWith(lo, hiRaw, SniffBytes.taskDone)
                || startsWith(lo, hiRaw, SniffBytes.taskDoneUpper) {
                hit(.mdTask)
            } else {
                hit(.dashItem)
            }
        }
        if first >= 48 && first <= 57 && SniffPattern.numberedItem.firstMatch(in: string(lo, hiRaw)) {
            hit(.numberedItem)
        }
        if (first == 61 || first == 45) && hiRaw - lo >= 3 {
            var k = lo
            while k < hiRaw && b[k] == first { k += 1 }
            if k == hiRaw {
                if first == 45 && i == 0 {
                    hit(.yamlDocStart)
                } else if i > 0 && !isBlank(i - 1) {
                    hit(.mdSetext)
                }
            }
        }

        // Prose: several words, little code punctuation, no assignment.
        if !isCode && f.words + (f.nonASCII / 6) >= 4 && f.punctuation <= 1 && !f.flags.has(.dollarVar)
            && !f.equalsAssign && last != 58 && last != 123 && last != 59 {
            hit(.proseLine)
        } else if !isCode && f.nonASCII >= 9 && f.punctuation <= 2 {
            hit(.proseLine)
        }
    }

    private func tomlValue(_ v: Int, _ end: Int) -> Bool {
        let c = b[v]
        if startsWith(v, end, SniffBytes.tripleDouble) || startsWith(v, end, SniffBytes.tripleSingle) { return true }
        if c == 34 || c == 39 {
            // A single string literal and nothing after it.
            var k = v + 1
            while k < end && b[k] != c { if b[k] == 92 { k += 1 }; k += 1 }
            return k >= end - 1
        }
        if c == 91 || c == 123 { return true }
        if (c >= 48 && c <= 57) || c == 45 || c == 43 {
            for k in v..<end where b[k] == 32 || b[k] == 40 || b[k] == 42 || b[k] == 47 { return false }
            return true
        }
        let rest = string(v, end)
        return rest == "true" || rest == "false" || rest == "inf" || rest == "nan"
    }

    private mutating func yamlLine(_ i: Int, _ lo: Int, _ end: Int, _ f: inout SniffLineFacts, isCode: Bool) {
        if startsWith(lo, end, SniffBytes.mergeKey) { hit(.yamlAnchor); return }   // <<: *defaults
        var k = lo
        var listItem = false
        if b[k] == 45 && k + 1 < end && b[k + 1] == 32 {
            listItem = true
            k += 2
            while k < end && b[k] == 32 { k += 1 }
        }
        guard k < end, isIdentStart(b[k]) || b[k] == 34 else { return }
        let keyStart = k
        if b[k] == 34 {
            k += 1
            while k < end && b[k] != 34 { k += 1 }
            k += 1
        } else {
            while k < end && (isIdent(b[k]) || b[k] == 45 || b[k] == 46) { k += 1 }
        }
        guard k < end, b[k] == 58 else { return }
        let afterColon = k + 1
        guard afterColon == end || b[afterColon] == 32 else { return }
        if f.last == 59 || f.last == 123 || f.last == 44 || f.last == 40 { return }
        if let fw = f.firstWord, !listItem, Self.yamlBlockingKeyword(fw) { return }
        if isCode && !listItem { return }
        var lowerKey = (b[keyStart] >= 97 && b[keyStart] <= 122) || b[keyStart] == 34 || b[keyStart] == 95
        if !lowerKey && k - keyStart >= 2 {
            // ENV_STYLE keys are identifiers too; `Content-Type` and `Name` read as prose.
            var allCaps = true
            for q in keyStart..<k where !((b[q] >= 65 && b[q] <= 90) || b[q] == 95 || (b[q] >= 48 && b[q] <= 57)) {
                allCaps = false
                break
            }
            lowerKey = allCaps
        }
        if listItem { hit(.yamlListMap) }
        let blockIndicator = end - afterColon <= 3
            && (b[end - 1] == 124 || b[end - 1] == 62 || b[end - 1] == 45 || b[end - 1] == 43)   // | > |- >+
        if afterColon >= end || blockIndicator {
            if afterColon < end {
                hit(.yamlBlockScalar)
                skipDeeperThan = lineIndent[i]
            }
            // key: with a deeper next line
            if let n = nextNonBlank(after: i), lineIndent[n] > lineIndent[i] {
                hit(.yamlParent)
            } else if let n = nextNonBlank(after: i), b[lineLo[n]] == 45, lineIndent[n] == lineIndent[i],
                      lowerKey {
                hit(.yamlParent)
            }
            return
        }
        var v = afterColon
        while v < end && b[v] == 32 { v += 1 }
        if v < end && (b[v] == 38 || b[v] == 42) && v + 1 < end && isIdentStart(b[v + 1]) { hit(.yamlAnchor) }
        if lowerKey && f.nonASCII == 0 {
            hit(.yamlKV)
            if b[v] == 91 && b[end - 1] == 93 && !contains(v, end, [34]) { hit(.yamlFlowValue) }
            if lineIndent[i] > 0 && !listItem { hit(.yamlNested) }
        } else {
            hit(.yamlKVWeak)
        }
    }

    static func yamlBlockingKeyword(_ token: SniffToken) -> Bool {
        switch token {
        case .else_, .try_, .finally, .except, .case_, .public_, .private_, .protected_, .return_,
             .if_, .for_, .while_, .def, .class_, .let_, .var_, .const_:
            return true
        default:
            return false
        }
    }
}

/// Byte strings the rules match.
enum SniffBytes {
    static let fence = Array("```".utf8)
    static let tildeFence = Array("~~~".utf8)
    static let blockEnd = Array("*/".utf8)
    static let blockStart = Array("/*".utf8)
    static let markupCommentStart = Array("<!--".utf8)
    static let markupCommentEnd = Array("-->".utf8)
    static let include = Array("#include".utf8)
    static let stdcpp = Array("stdc++".utf8)
    static let preprocessor: [[UInt8]] = ["#define", "#ifdef", "#ifndef", "#endif", "#pragma", "#undef", "#elif",
                                          "#if", "#else", "#error"].map { Array($0.utf8) }
    static let csDirectives: [[UInt8]] = ["#region", "#endregion", "#nullable", "#:"].map { Array($0.utf8) }
    static let rustAttr = Array("#[".utf8)
    static let rustInnerAttr = Array("#![".utf8)
    static let tripleDouble = Array("\"\"\"".utf8)
    static let tripleSingle = Array("'''".utf8)
    static let important = Array("!important".utf8)
    static let refStr = Array("&str".utf8)
    static let refMut = Array("&mut ".utf8)
    static let refSelf = Array("&self".utf8)
    static let devNull = Array(">/dev/".utf8)
    static let devNullSpaced = Array("> /dev/".utf8)
    static let selfDot = Array("self.".utf8)
    static let returnWord = Array("return".utf8)
    static let upperAs = Array(" AS ".utf8)
    static let useStrictSingle = Array("'use strict'".utf8)
    static let useStrictDouble = Array("\"use strict\"".utf8)
    static let exportDefault = Array("export default".utf8)
    static let exportBrace = Array("export {".utf8)
    static let spaceEq = Array(" = ".utf8)
    static let extendsWord = Array(" extends ".utf8)
    static let structWord = Array(" struct".utf8)
    static let interfaceWord = Array(" interface".utf8)
    static let console = Array("console.".utf8)
    static let document = Array("document.".utf8)
    static let window = Array("window.".utf8)
    static let requireCall = Array("require(".utf8)
    static let moduleExports = Array("module.exports".utf8)
    static let forParen = Array("(".utf8)
    static let asConst = Array("as const".utf8)
    static let systemOut = Array("System.".utf8)
    static let getSemicolon = Array("get;".utf8)
    static let consoleDot = Array("Console.".utf8)
    static let asyncTask = Array("async Task".utf8)
    static let taskGeneric = Array("Task<".utf8)
    static let stdColons = Array("std::".utf8)
    static let shiftLeft = Array("<<".utf8)
    static let shiftRight = Array(">>".utf8)
    static let errNil = Array("err != nil".utf8)
    static let fmtDot = Array("fmt.".utf8)
    static let makeCall = Array("make(".utf8)
    static let mdTaskOpen = Array("[ ]".utf8)
    static let printCall = Array("print(".utf8)
    static let fromQuote = Array(" from '".utf8)
    static let fromDoubleQuote = Array(" from \"".utf8)
    static let importBrace = Array("import {".utf8)
    static let importStar = Array("import * as".utf8)
    static let javaPrefix = Array("java.".utf8)
    static let javaxPrefix = Array("javax.".utf8)
    static let fromWord = Array(" from ".utf8)
    static let fatArrowBytes = Array("=>".utf8)
    static let className = Array("className=".utf8)
    static let fatArrowTag = Array("=> <".utf8)
    static let spacedColon = Array(" : ".utf8)
    static let mainStringArgs = Array("main(String".utf8)
    static let csMain = Array("static void Main(".utf8)
    static let arrowSpace = Array(") => ".utf8)
    static let colonSpace = Array(": ".utf8)
    static let genericString = Array("<String".utf8)
    static let brackets = Array("[]".utf8)
    static let starSpace = Array(" *".utf8)
    static let usingParen = Array("using (".utf8)
    static let usingSystem = Array("using System".utf8)
    static let arrow = Array("->".utf8)
    static let underscoreSpace = Array("(_ ".utf8)
    static let asyncWord = Array("async".utf8)
    static let someParen = Array("Some(".utf8)
    static let okParen = Array("Ok(".utf8)
    static let errParen = Array("Err(".utf8)
    static let questionDot = Array("?.".utf8)
    static let unwrapCall = Array(".unwrap()".utf8)
    static let selfColons = Array("Self::".utf8)
    static let elseWord = Array(" else ".utf8)
    static let someView = Array("some View".utf8)
    static let semicolonThen = Array("; then".utf8)
    static let bracketSpace = Array("[ ".utf8)
    static let semicolonDo = Array("; do".utf8)
    static let spaceDo = Array(" do".utf8)
    static let spaceDash = Array(" -".utf8)
    static let doubleBracket = Array("[[ ".utf8)
    static let dotSlash = Array("./".utf8)
    static let emptyParensBrace = Array("() {".utf8)
    static let cssAtRules: [[UInt8]] = ["@media", "@import", "@keyframes", "@font-face", "@charset", "@supports",
                                        "@layer", "@tailwind", "@page", "@namespace"].map { Array($0.utf8) }
    static let xmlDeclaration = Array("<?xml".utf8)
    static let cdata = Array("<![CDATA[".utf8)
    static let xmlns = Array("xmlns".utf8)
    static let quoteColon = Array("\":".utf8)
    static let trueWord = Array("true".utf8)
    static let falseWord = Array("false".utf8)
    static let nullWord = Array("null".utf8)
    static let doubleStarEnd = Array("**".utf8)
    static let taskOpen = Array("- [ ]".utf8)
    static let taskDone = Array("- [x]".utf8)
    static let taskDoneUpper = Array("- [X]".utf8)
    static let mergeKey = Array("<<:".utf8)
}

/// Line-level patterns, compiled once.
enum SniffPattern {
    struct Pattern {
        let regex: NSRegularExpression
        init(_ pattern: String) {
            regex = try! NSRegularExpression(pattern: pattern)
        }
        func firstMatch(in s: String) -> Bool {
            regex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
        }
        /// The first capture group of the first match.
        func match(in s: String) -> String? {
            guard let m = regex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r])
        }
        /// Three capture groups (missing groups are empty).
        func groups(in s: String) -> (String, String, String)? {
            guard let m = regex.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) else {
                return nil
            }
            func g(_ i: Int) -> String {
                guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            return (g(1), g(2), g(3))
        }
    }

    /// `a|b|c` for a word list.
    private static func words(_ list: [String]) -> String { list.joined(separator: "|") }

    private static let javaModifiers = words(["public", "private", "protected", "internal", "static", "final",
                                              "abstract", "synchronized", "override", "virtual", "sealed", "async",
                                              "native", "new", "partial", "extern", "unsafe", "readonly"])
    private static let fieldModifiers = words(["public", "private", "protected", "internal", "static", "final",
                                               "readonly", "const", "volatile", "transient"])
    /// A type such as `List<String>`, `int[]` or `string?`.
    private static let typeName = #"[\w.]+(?:<[^()]*>)?(?:\[\])*\??"#

    static let comprehension = Pattern(#"[\[{(][^\]\n]*\bfor\s+[\w, ()]+\s+in\s+[^\]]+[\]})]"#)
    static let javaLambda = Pattern(#"(\(\s*[\w, ]*\)|\b[a-z]\w*)\s+->\s+[\w({!"]"#)
    static let cCall = Pattern(#"\b("# + words(["printf", "scanf", "malloc", "calloc", "realloc", "free", "sizeof",
                                                 "fprintf", "fopen", "fclose", "strlen", "strcmp", "memcpy",
                                                 "memset", "puts"]) + #")\s*\("#)
    static let tsGenericFunction = Pattern(#"\bfunction\s*\*?\s*\w+\s*<\s*\w+"#)
    static let tsPrimitive = Pattern(#"[\w)\]]\s*\??:\s*("#
                                     + words(["string", "number", "boolean", "any", "unknown", "never", "void",
                                              "bigint", "symbol", "object"])
                                     + #")\b(\s*[\[\]|,;)=]|\s*$)"#)
    static let tsReturn = Pattern(#"\)\s*:\s*[\w<>\[\]|.,' ]+\s*(\{|=>)\s*$|\)\s*:\s*[\w<>\[\]|.]+\s*;\s*$"#)
    /// A component tag or fragment in expression position (not a generic `Name<T>`).
    static let jsxComponent = Pattern(#"(^|[(\s>?:{]|=>\s*|return\s+)<[A-Z][\w.]*(\s+\w+=|\s*/?>)"#
                                      + #"|(^|[(\s]|return\s+)<>|</>"#)
    /// Modifiers before `class` / `interface` / …; group 1 is the modifier list.
    static let typeDecl = Pattern(#"^((?:(?:"#
                                  + words(["public", "private", "protected", "internal", "static", "final",
                                           "abstract", "sealed", "partial", "readonly", "unsafe"])
                                  + #")\s+)+)(?:class|interface|enum|record|struct)\b"#)
    /// Modifiers, optional return type (group 1), name (group 2), parameters (group 3).
    static let method = Pattern(#"^(?:(?:"# + javaModifiers + #")\s+)+(?:("# + typeName + #")\s+)?"#
                                + #"([A-Za-z_]\w*)\s*(?:<[^()]*>)?\s*\((.*)\)\s*(?:throws\s+[\w.,\s]+)?\s*"#
                                + #"(?:\{|=>.*|;|:.*)?$"#)
    /// Modifiers, optional type (group 1), name (group 2), initialiser (group 3).
    static let field = Pattern(#"^(?:(?:"# + fieldModifiers + #")\s+)+(?:("# + typeName + #")\s+)?"#
                               + #"([A-Za-z_]\w*)\s*(=.*|;|\{.*|:.*)$"#)
    static let cFunction = Pattern(#"^(?:(?:static|inline|extern|const|unsigned|signed|struct|enum|long|short)\s+)*"#
                                   + #"[A-Za-z_]\w*(?:\s*\*+\s*|\s+)\**[A-Za-z_]\w*\s*\([^;]*\)\s*(?:const\s*)?\{?$"#)
    static let cPointerParam = Pattern(#"\(\s*(?:const\s+)?(?:struct\s+)?\w+\s*\*"#)
    static let cDeclaration = Pattern(#"^(?:(?:const|static|unsigned|signed|long|short|volatile|register)\s+)*"#
                                      + #"(?:int|char|float|double|long|short|size_t|bool|unsigned|void|u?int\d+_t)"#
                                      + #"\s*\**\s*[A-Za-z_]\w*(?:\s*\[[^\]]*\])*\s*(?:=[^;]*)?"#
                                      + #"(?:,\s*\**\w+(?:\s*\[[^\]]*\])*(?:\s*=[^,;]*)?)*;$"#)
    static let cPointerDecl = Pattern(#"^(?:const\s+)?\w+\s+\*\s*\w+|^(?:const\s+)?\w+\s*\*\s+\w+"#)
    static let rustMacro = Pattern(#"\b[a-z_][a-z0-9_]*!\s*[(\[{]"#)
    static let bashTest = Pattern(#"\[\s+-[a-zA-Z]\s|\s-(eq|ne|lt|le|gt|ge|nt|ot)\s"#)
    /// Statement shapes of upper-case SQL, matched from the line start.
    static let sqlStructureUpper = Pattern("^(" + [
        #"SELECT\b.*\bFROM\s+[\w."]+"#,
        #"SELECT\s+([\w.*]+(\s+AS\s+\w+)?\s*,?\s*)+$"#,
        #"INSERT\s+INTO\s+[\w."]+"#,
        #"CREATE\s+(OR\s+REPLACE\s+)?(TEMP\w*\s+)?(UNIQUE\s+)?"#
            + #"(TABLE|INDEX|VIEW|DATABASE|SCHEMA|FUNCTION|PROCEDURE|TRIGGER|TYPE|EXTENSION)\b"#,
        #"UPDATE\s+[\w."]+\s+SET\b"#,
        #"DELETE\s+FROM\s+[\w."]+"#,
        #"(GROUP|ORDER)\s+BY\s+\w"#,
        #"(LEFT|RIGHT|INNER|OUTER|FULL|CROSS)?\s*JOIN\s+[\w."]+(\s+\w+)?\s+ON\b"#,
        #"ALTER\s+TABLE\s+\w"#,
        #"DROP\s+(TABLE|INDEX|VIEW)\b"#,
        #"WITH\s+\w+\s+AS\s*\("#,
        #"WHERE\s+[\w."]+\s*(=|<|>|!=|<>|LIKE|IN|IS|BETWEEN)"#,
        #"VALUES\s*\("#,
    ].joined(separator: "|") + ")")
    /// The same for lower-case SQL, stricter because lower-case words occur in prose.
    static let sqlStructureLower = Pattern("^(" + [
        #"select\b.*\bfrom\s+[\w."]+(\s+\w+)?\s*(;|$|where|join|left|inner|group|order)"#,
        #"select\s+([\w.*()]+(\s+as\s+\w+)?\s*,\s*)+[\w.*()]+(\s+as\s+\w+)?$"#,
        #"insert\s+into\s+[\w."]+\s*[(v]"#,
        #"create\s+(table|index|view|database|schema|function|procedure|trigger)\s+(if\s+not\s+exists\s+)?"#
            + #"[\w."]+\s*(\(|$|as)"#,
        #"update\s+[\w."]+\s+set\s+\w+\s*="#,
        #"delete\s+from\s+[\w."]+"#,
        #"(group|order)\s+by\s+[\w.]+"#,
        #"(left|right|inner|outer|full|cross)?\s*join\s+[\w."]+(\s+\w+)?\s+on\s+[\w.]+\s*="#,
        #"alter\s+table\s+\w"#,
        #"drop\s+(table|index|view)\s+\w"#,
        #"where\s+[\w.]+\s*(=|<|>|!=|<>|like|in|is)\s"#,
        #"from\s+[\w.]+(\s+\w+)?\s*;?$"#,
    ].joined(separator: "|") + ")")
    /// Units, colours, CSS functions or common keyword values.
    static let cssValue = Pattern([
        #"\d(px|em|rem|vh|vw|%|s|ms|deg|fr|pt)\b"#,
        #"#[0-9a-fA-F]{3,8}\b"#,
        #"\b(rgba?|hsla?|var|calc|url|repeat|minmax|linear-gradient)\("#,
        #":\s*("# + words(["none", "auto", "flex", "grid", "block", "inline", "inline-block", "absolute",
                            "relative", "fixed", "sticky", "bold", "normal", "center", "hidden", "solid", "pointer",
                            "inherit", "transparent", "underline", "uppercase", "space-between", "nowrap", "wrap"])
            + #")\s*;"#,
        #":\s*\d+\s*;"#,
    ].joined(separator: "|"))
    static let markupAttribute = Pattern(#"\s("# + words(["class", "id", "href", "src", "type", "name", "style",
                                                            "rel", "alt", "for", "value", "lang", "charset",
                                                            "content", "action", "method"]) + #")="#)
    static let markdownLink = Pattern(#"!?\[[^\]]+\]\((https?://|/|\.|#|mailto:)[^)\s]*\)"#)
    static let markdownTableRule = Pattern(#"^\|(\s*:?-{3,}:?\s*\|)+$"#)
    static let numberedItem = Pattern(#"^\d+\.\s+\S"#)
}
