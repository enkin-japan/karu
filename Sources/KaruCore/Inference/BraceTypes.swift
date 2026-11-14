import Foundation

// M17 T17.11d — types written in declarations of the statically typed brace
// languages, and what a declaration says about its name (written type or
// initializer, modifiers, signature). Pure token logic over `DeclToken`s
// read by `BraceTokenReader`; plan §8.1 「只用显式声明」: nothing is guessed —
// a type that is not written (or not a nominal type of this file) is
// unknown.

/// A type as written in a declaration.
struct BraceWrittenType: Hashable, Sendable {
    /// The nominal type's path (`Outer.Inner`, `ns::Foo`, `pkg.Name`);
    /// empty for anything else (arrays, tuples, functions, primitives).
    var path: [String] = []
    /// C / C++ elaborated type (`struct point`).
    var tag = false
    /// C / C++ pointer depth (references do not count).
    var pointer = 0
    /// Swift `T?`.
    var optional = false
    /// C++ `unique_ptr<T>` / `shared_ptr<T>`, Rust `Box<T>` / `Rc<T>` /
    /// `Arc<T>`: `path` is the pointee (reached with `->` / auto-deref).
    var smart = false
    /// C# `T?` (`Nullable<T>` for a struct, an annotation for a class).
    var nullable = false
    /// Display text (source, white space collapsed).
    var text = ""

    var isNominal: Bool { !path.isEmpty }
    var name: String { path.last ?? "" }
}

/// Member / declaration visibility as written.
enum BraceAccess: UInt8, Sendable {
    case unspecified, `public`, `private`, `protected`, `fileprivate`, `internal`
}

/// Parses written types for one language.
struct BraceTypeParser {
    let reader: BraceTokenReader
    let language: BraceLanguage

    enum Result {
        case type(BraceWrittenType, end: Int)
        /// `var` (Java, C#) / `auto` (C++): the type comes from the initializer.
        case infer(end: Int)
    }

    private func word(_ t: DeclToken, _ w: String) -> Bool { t.kind == .ident && reader.spells(t, w) }

    private func isWordIn(_ t: DeclToken, _ words: [String]) -> Bool {
        guard t.kind == .ident else { return false }
        for w in words where reader.spells(t, w) { return true }
        return false
    }

    /// `::` (a two-unit dot token).
    func isPathSeparator(_ t: DeclToken) -> Bool { t.kind == .dot && t.end - t.start == 2 && reader.spells(t, "::") }

    func isPlainDot(_ t: DeclToken) -> Bool { t.kind == .dot && t.end - t.start == 1 }

    private func finish(_ type: inout BraceWrittenType, _ tk: [DeclToken], _ i: Int, _ k: Int) {
        if k > i { type.text = reader.compact(from: tk[i].start, to: tk[k - 1].end) }
    }

    /// A type starting at `i` (before `end`); nil when there is none.
    func parse(_ tk: [DeclToken], _ i: Int, _ end: Int) -> Result? {
        guard i < end else { return nil }
        switch language {
        case .swift: return swift(tk, i, end).map { .type($0.0, end: $0.1) }
        case .go: return go(tk, i, end).map { .type($0.0, end: $0.1) }
        case .rust: return rust(tk, i, end).map { .type($0.0, end: $0.1) }
        case .java, .csharp: return javaLike(tk, i, end)
        case .c, .cpp: return cLike(tk, i, end)
        }
    }

    /// Generic arguments `<…>` at `k` (returns the index after `>`), or `k`.
    private func skipAngle(_ tk: [DeclToken], _ k: Int, _ end: Int) -> Int {
        guard k < end, tk[k].kind == .less, let close = BraceTokens.matchingAngle(tk, k, end: end) else { return k }
        return close + 1
    }

    // MARK: Swift

    private func swift(_ tk: [DeclToken], _ i: Int, _ end: Int) -> (BraceWrittenType, Int)? {
        var k = i
        while k < end {
            let t = tk[k]
            if t.kind == .at, k + 1 < end {
                k += 2
                if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
                continue
            }
            if t.keyword == .inout || isWordIn(t, ["some", "any", "borrowing", "consuming", "sending", "__owned",
                                                    "__shared", "isolated"]) {
                k += 1
                continue
            }
            break
        }
        let first = k
        guard k < end else { return nil }
        var type = BraceWrittenType()
        switch tk[k].kind {
        case .lbracket:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            k = m + 1
        case .lparen:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            k = m + 1
            while k < end, isWordIn(tk[k], ["async", "throws", "rethrows"]) || tk[k].keyword == .throws { k += 1 }
            if k < end, tk[k].kind == .thinArrow, let r = swift(tk, k + 1, end) { k = r.1 }
        case .ident:
            let t = tk[k]
            guard t.keyword == .none else { return nil }
            while k < end, tk[k].kind == .ident {
                type.path.append(reader.string(tk[k]))
                k = skipAngle(tk, k + 1, end)
                guard k + 1 < end, isPlainDot(tk[k]), tk[k + 1].kind == .ident else { break }
                if reader.spells(tk[k + 1], "Type") || reader.spells(tk[k + 1], "Protocol") {
                    type.path = []
                    k += 2
                    break
                }
                k += 1
            }
        default:
            return nil
        }
        while k < end {
            if tk[k].kind == .question { type.optional = true; k += 1; continue }
            if tk[k].kind == .bang { k += 1; continue }
            break
        }
        if k < end, tk[k].kind == .thinArrow {
            type.path = []
            if let r = swift(tk, k + 1, end) { k = r.1 }
        }
        finish(&type, tk, first, k)
        return (type, k)
    }

    // MARK: Go

    private func go(_ tk: [DeclToken], _ i: Int, _ end: Int) -> (BraceWrittenType, Int)? {
        var k = i
        var type = BraceWrittenType()
        while k < end, tk[k].kind == .star { type.pointer += 1; k += 1 }
        guard k < end else { return nil }
        let t = tk[k]
        switch t.kind {
        case .lbracket:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            k = m + 1
            if let inner = go(tk, k, end) { k = inner.1 }
            type.path = []
        case .ident where t.keyword == .map:
            k += 1
            if k < end, tk[k].kind == .lbracket, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
            if let inner = go(tk, k, end) { k = inner.1 }
        case .ident where t.keyword == .chan:
            k += 1
            if let inner = go(tk, k, end) { k = inner.1 }
        case .ident where t.keyword == .func:
            k += 1
            if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
            if k < end, !tk[k].isLineStart, tk[k].kind == .lparen || tk[k].kind == .ident || tk[k].kind == .star,
               tk[k].keyword == .none || tk[k].keyword == .map || tk[k].keyword == .func {
                if tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
                else if let inner = go(tk, k, end) { k = inner.1 }
            }
        case .ident where t.keyword == .struct || t.keyword == .interface:
            k += 1
            if k < end, tk[k].kind == .lbrace, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
        case .ident where t.keyword == .none:
            type.path.append(reader.string(t))
            k += 1
            if k + 1 < end, isPlainDot(tk[k]), tk[k + 1].kind == .ident, !tk[k].isLineStart {
                type.path.append(reader.string(tk[k + 1]))
                k += 2
            }
            if k < end, tk[k].kind == .lbracket, !tk[k].isLineStart, let m = BraceTokens.matching(tk, k, limit: end) {
                k = m + 1
            }
        case .lparen:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            if let inner = go(tk, k + 1, m), inner.1 == m { type = inner.0 }
            k = m + 1
        default:
            return nil
        }
        finish(&type, tk, i, k)
        return (type, k)
    }

    // MARK: Rust

    private func rust(_ tk: [DeclToken], _ i: Int, _ end: Int) -> (BraceWrittenType, Int)? {
        var k = i
        while k < end {
            let t = tk[k]
            if t.kind == .op, reader.spells(t, "&") || reader.spells(t, "&&") { k += 1; continue }
            if t.kind == .literal, reader.text.character(at: t.start) == 39 { k += 1; continue }   // 'a
            if t.keyword == .mut || t.keyword == .dyn || t.keyword == .impl { k += 1; continue }
            break
        }
        guard k < end else { return nil }
        var type = BraceWrittenType()
        let first = k
        let t = tk[k]
        switch t.kind {
        case .star:
            k += 1
            if k < end, tk[k].keyword == .const || tk[k].keyword == .mut { k += 1 }
            if let inner = rust(tk, k, end) { k = inner.1 }
        case .lbracket, .lparen:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            k = m + 1
        case .bang:
            k += 1
        case .ident where t.keyword == .fn || t.keyword == .unsafe || t.keyword == .extern:
            while k < end, tk[k].kind == .ident || tk[k].kind == .literal { k += 1 }
            if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
            if k < end, tk[k].kind == .thinArrow, let inner = rust(tk, k + 1, end) { k = inner.1 }
        case .ident, .dot:
            if t.kind == .dot {
                guard isPathSeparator(t) else { return nil }
                k += 1
            }
            var generics: [(Int, Int)] = []
            while k < end, tk[k].kind == .ident {
                let w = tk[k]
                guard w.keyword == .none || w.keyword == .selfValue || w.keyword == .crate || w.keyword == .super
                else { return nil }
                type.path.append(reader.string(w))
                k += 1
                if k + 1 < end, isPathSeparator(tk[k]), tk[k + 1].kind == .less { k += 1 }
                if k < end, tk[k].kind == .less, let close = BraceTokens.matchingAngle(tk, k, end: end) {
                    generics.append((k + 1, close))
                    k = close + 1
                } else {
                    generics.append((-1, -1))
                }
                guard k + 1 < end, isPathSeparator(tk[k]), tk[k + 1].kind == .ident else { break }
                k += 1
            }
            if let last = type.path.last, ["Box", "Rc", "Arc"].contains(last), let g = generics.last, g.0 >= 0,
               let inner = rust(tk, g.0, g.1), inner.1 == g.1, inner.0.isNominal {
                let text = type.text
                type = inner.0
                type.smart = true
                type.text = text
            }
            if !type.path.isEmpty, type.path[0] == "crate" || type.path[0] == "self" { type.path.removeFirst() }
            // `dyn A + Send`
            while k + 1 < end, tk[k].kind == .op, reader.spells(tk[k], "+"), tk[k + 1].kind == .ident {
                k += 2
                k = skipAngle(tk, k, end)
            }
        default:
            return nil
        }
        finish(&type, tk, first == i ? i : i, k)
        return (type, k)
    }

    // MARK: Java / C#

    private func javaLike(_ tk: [DeclToken], _ i: Int, _ end: Int) -> Result? {
        var k = i
        let cs = language == .csharp
        while k < end {
            let t = tk[k]
            if t.kind == .at, k + 1 < end {   // Java annotation
                k += 2
                while k + 1 < end, isPlainDot(tk[k]), tk[k + 1].kind == .ident { k += 2 }
                if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
                continue
            }
            if t.keyword == .modifier || t.keyword == .readonly || t.keyword == .ref || t.keyword == .out
                || t.keyword == .params || (cs && t.keyword == .in) || (cs && t.keyword == .this) {
                k += 1
                continue
            }
            break
        }
        guard k < end else { return nil }
        let first = k
        var type = BraceWrittenType()
        let t = tk[k]
        if t.keyword == .var { return .infer(end: k + 1) }
        switch t.kind {
        case .lparen where cs:
            guard let m = BraceTokens.matching(tk, k, limit: end) else { return nil }
            k = m + 1
        case .ident where t.keyword == .primitiveType || t.keyword == .void:
            k += 1
        case .ident where t.keyword == .none:
            while k < end, tk[k].kind == .ident, tk[k].keyword == .none {
                type.path.append(reader.string(tk[k]))
                k = skipAngle(tk, k + 1, end)
                guard k + 1 < end, tk[k].kind == .dot, tk[k + 1].kind == .ident, tk[k + 1].keyword == .none else { break }
                if isPathSeparator(tk[k]), type.path == ["global"] { type.path = [] }
                k += 1
            }
        default:
            return nil
        }
        while k < end {
            if cs, tk[k].kind == .question { type.nullable = true; k += 1; continue }
            if tk[k].kind == .lbracket, let m = BraceTokens.matching(tk, k, limit: end) {
                type.path = []
                k = m + 1
                continue
            }
            if tk[k].kind == .ellipsis || tk[k].kind == .star { type.path = []; k += 1; continue }
            break
        }
        finish(&type, tk, first, k)
        return .type(type, end: k)
    }

    // MARK: C / C++

    private func isCQualifier(_ t: DeclToken) -> Bool {
        guard t.kind == .ident else { return false }
        switch t.keyword {
        case .const, .static, .extern, .inline, .modifier, .virtual, .typename: return true
        default: return isWordIn(t, ["_Atomic", "thread_local", "__restrict", "__inline"])
        }
    }

    private func cLike(_ tk: [DeclToken], _ i: Int, _ end: Int) -> Result? {
        var k = i
        let cpp = language == .cpp
        while k < end, isCQualifier(tk[k]) { k += 1 }
        guard k < end else { return nil }
        let first = k
        var type = BraceWrittenType()
        let t = tk[k]
        if cpp, word(t, "auto") {
            k += 1
            while k < end, tk[k].kind == .star || tk[k].kind == .op && reader.spells(tk[k], "&")
                || tk[k].kind == .op && reader.spells(tk[k], "&&") || isCQualifier(tk[k]) { k += 1 }
            return .infer(end: k)
        }
        if t.keyword == .struct || t.keyword == .union || t.keyword == .enum || t.keyword == .class {
            k += 1
            if k < end, tk[k].keyword == .class || tk[k].keyword == .struct { k += 1 }   // enum class
            guard k < end, tk[k].kind == .ident, tk[k].keyword == .none else { return nil }
            type.tag = true
            type.path = [reader.string(tk[k])]
            k += 1
            while cpp, k + 1 < end, isPathSeparator(tk[k]), tk[k + 1].kind == .ident {
                type.path.append(reader.string(tk[k + 1]))
                k += 2
            }
        } else if t.keyword == .primitiveType || t.keyword == .void {
            while k < end, tk[k].keyword == .primitiveType || tk[k].keyword == .void || isCQualifier(tk[k]) { k += 1 }
        } else if cpp, word(t, "decltype") {
            k += 1
            if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
        } else if t.kind == .ident && t.keyword == .none || cpp && isPathSeparator(t) {
            if isPathSeparator(t) { k += 1 }
            var generics: [(Int, Int)] = []
            while k < end, tk[k].kind == .ident, tk[k].keyword == .none {
                type.path.append(reader.string(tk[k]))
                k += 1
                if cpp, k < end, tk[k].kind == .less, let close = BraceTokens.matchingAngle(tk, k, end: end) {
                    generics.append((k + 1, close))
                    k = close + 1
                } else {
                    generics.append((-1, -1))
                }
                guard cpp, k + 1 < end, isPathSeparator(tk[k]), tk[k + 1].kind == .ident else { break }
                k += 1
            }
            if cpp, let last = type.path.last, last == "unique_ptr" || last == "shared_ptr",
               type.path.count == 1 || type.path.count == 2 && type.path[0] == "std",
               let g = generics.last, g.0 >= 0, case .type(let inner, let innerEnd)? = cLike(tk, g.0, g.1),
               innerEnd == g.1, inner.isNominal, inner.pointer == 0 {
                type.path = inner.path
                type.tag = inner.tag
                type.smart = true
            }
        } else {
            return nil
        }
        while k < end {
            let u = tk[k]
            if u.kind == .star { type.pointer += 1; k += 1; continue }
            if u.kind == .op, reader.spells(u, "&") || reader.spells(u, "&&") { k += 1; continue }
            if isCQualifier(u) { k += 1; continue }
            break
        }
        finish(&type, tk, first, k)
        return .type(type, end: k)
    }
}

// MARK: - Declarations

/// What one declaration says about its name (T17.11d).
struct BraceDeclInfo {
    /// The written type: a variable's / field's / parameter's, or a
    /// function's (first) result.
    var type: BraceWrittenType?
    /// Go: every written result (`(T, error)`).
    var results: [BraceWrittenType?] = []
    /// The initializer's token range when no type is written.
    var initializer: Range<Int>?
    /// Go `a, b := f()`: the name's position in the left-hand list (with a
    /// single call on the right); nil for a single value.
    var resultIndex: Int?
    /// Swift `if let` / `guard let` / `while let`: the initializer is unwrapped.
    var unwrap = false
    var isStatic = false
    var access = BraceAccess.unspecified
    var isPartial = false
    var isFriend = false
    var isFunction = false
    /// The parameter list's tokens (inside the parentheses), split at
    /// top-level commas.
    var parameters: [Range<Int>] = []
    /// Rust: the first parameter is `self` / `&self` / `&mut self` / `mut self`.
    var hasSelfParameter = false
    /// C++ `Foo::method`: the qualifying path.
    var owner: [String] = []
    /// Text after the parameters that belongs to the signature (C++ ` const`).
    var suffix = ""
}

/// Reads declarations at a name token (T17.11d).
struct BraceDeclReader {
    let reader: BraceTokenReader
    let language: BraceLanguage
    let types: BraceTypeParser

    init(reader: BraceTokenReader) {
        self.reader = reader
        language = reader.language
        types = BraceTypeParser(reader: reader, language: reader.language)
    }

    private func word(_ t: DeclToken, _ w: String) -> Bool { t.kind == .ident && reader.spells(t, w) }

    /// Start of the item declaring the name at `n` (type-led languages):
    /// after the nearest `;` / `{` / `}` / access label, a `(` that opens
    /// the parameter list or header holding it (then after the nearest
    /// top-level `,`), or the window start. Also: the first declarator's
    /// `,` (`Foo a, b`), when the name is a later declarator.
    func itemStart(_ tk: [DeclToken], _ n: Int, floor: Int = 0) -> (start: Int, declaratorComma: Int?) {
        var depth = 0
        var comma: Int?
        var k = n - 1
        while k >= floor {
            let t = tk[k]
            switch t.kind {
            case .rparen, .rbracket: depth += 1
            case .lparen, .lbracket:
                if depth == 0 {
                    // A parameter list / header: the item is after the nearest comma.
                    return (comma.map { $0 + 1 } ?? k + 1, nil)
                }
                depth -= 1
            case .semicolon where depth == 0, .lbrace where depth == 0, .rbrace where depth == 0:
                return (k + 1, comma)
            case .colon where depth == 0:
                // C++ access label `public:`, a `case X:` label.
                return (k + 1, comma)
            case .comma where depth == 0:
                if comma == nil { comma = k }
            case .assign where depth == 0, .arrow where depth == 0:
                // Inside an initializer of an earlier declarator: keep going.
                break
            default: break
            }
            k -= 1
        }
        return (floor, comma)
    }

    /// Modifiers in `[from, to)`.
    func modifiers(_ tk: [DeclToken], from: Int, to: Int, into info: inout BraceDeclInfo) {
        var k = from
        while k < to {
            let t = tk[k]
            if t.kind == .ident {
                switch t.keyword {
                case .public: info.access = .public
                case .private: info.access = .private
                case .protected: info.access = .protected
                case .pub: info.access = .public
                case .static: info.isStatic = true
                case .const where language == .csharp: info.isStatic = true
                case .class where language == .swift:
                    if k + 1 < to, [.func, .var, .let, .subscript, .override].contains(tk[k + 1].keyword)
                        || tk[k + 1].keyword == .modifier {
                        info.isStatic = true
                    }
                case .modifier:
                    if reader.spells(t, "fileprivate") { info.access = .fileprivate }
                    else if reader.spells(t, "internal") { info.access = .internal }
                    else if reader.spells(t, "open") { info.access = .public }
                    else if reader.spells(t, "partial") { info.isPartial = true }
                    else if reader.spells(t, "friend") { info.isFriend = true }
                default: break
                }
            }
            k += 1
        }
    }

    /// Parameters `( … )` at `open`: the ranges of its top-level items and
    /// the index after `)`.
    func parameters(_ tk: [DeclToken], open: Int, end: Int) -> ([Range<Int>], Int)? {
        guard open < end, tk[open].kind == .lparen, let close = BraceTokens.matching(tk, open, limit: end) else {
            return nil
        }
        var items: [Range<Int>] = []
        var depth = 0
        var angle = 0
        var start = open + 1
        var k = open + 1
        while k < close {
            let kind = tk[k].kind
            if BraceTokens.isOpener(kind) { depth += 1 } else if BraceTokens.isCloser(kind) { depth -= 1 }
            if kind == .less { angle += 1 } else if kind == .greater, angle > 0 { angle -= 1 }
            if kind == .comma, depth == 0, angle == 0 {
                items.append(start..<k)
                start = k + 1
            }
            k += 1
        }
        if close > start { items.append(start..<close) }
        return (items, close + 1)
    }

    /// The end of an expression starting at `from`: before a top-level `;`,
    /// `,`, an unbalanced closer or `end`; Swift / Go also before a line
    /// break at depth 0 that does not continue with `.`; Swift conditions
    /// before `{`; Rust before `else`.
    func expressionEnd(_ tk: [DeclToken], from: Int, end: Int, condition: Bool = false) -> Int {
        var depth = 0
        var k = from
        while k < end {
            let t = tk[k]
            if depth == 0 {
                if t.kind == .semicolon || t.kind == .comma { return k }
                if k > from, t.isLineStart, language.newlineTerminated, t.kind != .dot { return k }
                if condition, t.kind == .lbrace { return k }
                if language == .rust || language == .swift && condition, t.keyword == .else { return k }
                if t.kind == .colon, language == .cpp || language == .java { return k }   // for (T x : xs)
            }
            if BraceTokens.isOpener(t.kind) { depth += 1 } else if BraceTokens.isCloser(t.kind) {
                depth -= 1
                if depth < 0 { return k }
            }
            k += 1
        }
        return end
    }

    /// Reads the declaration whose name token is `tk[n]`; `statementStart`
    /// when known (a type body walk), else found within the window.
    func read(_ tk: [DeclToken], name n: Int, kind: DeclarationScan.DeclarationKind,
              statementStart: Int? = nil) -> BraceDeclInfo {
        var info = BraceDeclInfo()
        let end = tk.count
        let isFunction = kind == .function || kind == .method
        info.isFunction = isFunction
        switch language {
        case .java, .csharp, .c, .cpp:
            typeLed(tk, n, kind: kind, statementStart: statementStart, end: end, into: &info)
        case .swift:
            nameLedSwift(tk, n, function: isFunction, statementStart: statementStart, end: end, into: &info)
        case .go:
            nameLedGo(tk, n, function: isFunction, end: end, into: &info)
        case .rust:
            nameLedRust(tk, n, function: isFunction, statementStart: statementStart, end: end, into: &info)
        }
        return info
    }

    // MARK: Type-led (Java, C#, C, C++)

    private func typeLed(_ tk: [DeclToken], _ n: Int, kind: DeclarationScan.DeclarationKind, statementStart: Int?,
                         end: Int, into info: inout BraceDeclInfo) {
        let item = itemStart(tk, n, floor: statementStart ?? 0)
        let start = max(statementStart ?? 0, item.start)
        // Owner path `A::B::name` (C++ out-of-class definitions).
        var ownerStart = n
        if language == .cpp {
            var k = n
            while k >= start + 2, types.isPathSeparator(tk[k - 1]) {
                var q = k - 2
                if tk[q].kind == .greater {
                    // `Foo<T>::m`
                    var angle = 0
                    var j = q
                    while j >= start {
                        if tk[j].kind == .greater { angle += 1 } else if tk[j].kind == .less {
                            angle -= 1
                            if angle == 0 { break }
                        }
                        j -= 1
                    }
                    guard j > start else { break }
                    q = j - 1
                }
                guard tk[q].kind == .ident, tk[q].keyword == .none else { break }
                info.owner.insert(reader.string(tk[q]), at: 0)
                k = q
            }
            ownerStart = k
            if ownerStart < n, ownerStart > start, tk[ownerStart - 1].kind == .op,
               reader.spells(tk[ownerStart - 1], "~") { ownerStart -= 1 }
        }
        // Skip modifiers, annotations / attributes, `template<…>`, Java `<T>`.
        var k = start
        while k < ownerStart {
            let t = tk[k]
            if t.kind == .lbracket, language == .csharp || language == .cpp,
               let m = BraceTokens.matching(tk, k, limit: ownerStart) {
                k = m + 1          // [Attr] / [[attr]]
                continue
            }
            if t.kind == .at, language == .java, k + 1 < ownerStart {
                k += 2
                while k + 1 < ownerStart, types.isPlainDot(tk[k]), tk[k + 1].kind == .ident { k += 2 }
                if k < ownerStart, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: ownerStart) {
                    k = m + 1
                }
                continue
            }
            if t.keyword == .template {
                k += 1
                if k < ownerStart, tk[k].kind == .less, let m = BraceTokens.matchingAngle(tk, k, end: ownerStart) {
                    k = m + 1
                }
                continue
            }
            if t.kind == .less, language == .java, let m = BraceTokens.matchingAngle(tk, k, end: ownerStart) {
                k = m + 1
                continue
            }
            if isModifier(t) {
                k += 1
                continue
            }
            break
        }
        modifiers(tk, from: start, to: ownerStart, into: &info)
        if language == .cpp, k < ownerStart, word(tk[k], "friend") { info.isFriend = true }
        var declaredType: BraceWrittenType?
        var infer = false
        if item.declaratorComma == nil || info.isFunction {
            if k < ownerStart, let parsed = types.parse(tk, k, ownerStart) {
                switch parsed {
                case .type(var type, let typeEnd):
                    // Declarator prefix between the type and the name.
                    var j = typeEnd
                    while j < ownerStart {
                        if tk[j].kind == .star { type.pointer += 1 }
                        j += 1
                    }
                    if typeEnd <= ownerStart { declaredType = type }
                case .infer:
                    infer = true
                }
            }
        } else if let comma = item.declaratorComma {
            // A later declarator `Foo a, *b`: the base type, own pointers.
            if k < end, let parsed = types.parse(tk, k, comma) {
                switch parsed {
                case .type(var type, _):
                    type.pointer = 0
                    var j = comma + 1
                    while j < n {
                        if tk[j].kind == .star { type.pointer += 1 }
                        j += 1
                    }
                    declaredType = type
                case .infer: infer = true
                }
            }
        }
        if info.isFunction {
            info.type = declaredType
            var open = n + 1
            if open < end, tk[open].kind == .less, let m = BraceTokens.matchingAngle(tk, open, end: end) { open = m + 1 }
            if let (items, after) = parameters(tk, open: open, end: end) {
                info.parameters = items
                // Trailing `const` / `-> T` (C++).
                var j = after
                var suffix: [String] = []
                while j < end, tk[j].kind == .ident, tk[j].keyword == .const || tk[j].keyword == .noexcept
                    || word(tk[j], "override") || word(tk[j], "final") {
                    if tk[j].keyword == .const { suffix.append("const") }
                    j += 1
                }
                if language == .cpp, j < end, tk[j].kind == .thinArrow,
                   case .type(let trailing, _)? = types.parse(tk, j + 1, end) {
                    info.type = trailing
                }
                info.suffix = suffix.joined(separator: " ")
            }
            return
        }
        info.type = declaredType
        if infer || declaredType == nil {
            // `var x = …` / `auto x = …`.
            if infer, n + 1 < end, tk[n + 1].kind == .assign {
                let e = expressionEnd(tk, from: n + 2, end: end)
                if e > n + 2 { info.initializer = (n + 2)..<e }
            } else if infer, language == .cpp, n + 1 < end, tk[n + 1].kind == .lbrace || tk[n + 1].kind == .lparen {
                info.initializer = nil
            }
        }
    }

    private func isModifier(_ t: DeclToken) -> Bool {
        guard t.kind == .ident else { return false }
        switch t.keyword {
        case .public, .private, .protected, .static, .abstract, .override, .readonly, .modifier, .virtual,
             .inline, .extern, .async, .sealed, .unsafe, .event, .default:
            return true
        case .const:
            return language != .c && language != .cpp   // C / C++ `const` is part of the type
        case .new:
            return language == .csharp
        default:
            return word(t, "constexpr") || word(t, "thread_local")
        }
    }

    // MARK: Swift

    private func nameLedSwift(_ tk: [DeclToken], _ n: Int, function: Bool, statementStart: Int?, end: Int,
                              into info: inout BraceDeclInfo) {
        let start = statementStart ?? headStart(tk, n)
        modifiers(tk, from: start, to: n, into: &info)
        if function {
            var open = n + 1
            if open < end, tk[open].kind == .less, let m = BraceTokens.matchingAngle(tk, open, end: end) { open = m + 1 }
            guard let (items, after) = parameters(tk, open: open, end: end) else { return }
            info.parameters = items
            var j = after
            while j < end, tk[j].keyword == .async || tk[j].keyword == .throws || tk[j].keyword == .rethrows
                || word(tk[j], "reasync") {
                j += 1
                if j < end, tk[j].kind == .lparen, let m = BraceTokens.matching(tk, j, limit: end) { j = m + 1 }
            }
            if j < end, tk[j].kind == .thinArrow, case .type(let type, _)? = types.parse(tk, j + 1, end) {
                info.type = type
            }
            return
        }
        guard n + 1 < end else { return }
        if tk[n + 1].kind == .colon {
            if case .type(let type, _)? = types.parse(tk, n + 2, end) { info.type = type }
            return
        }
        // `let x = …` (a plain binding: the token before is `let` / `var`).
        guard n > 0, tk[n - 1].keyword == .let || tk[n - 1].keyword == .var else { return }
        let introducer = n - 1
        var condition = false
        if introducer > 0 {
            let before = tk[introducer - 1]
            if before.keyword == .case { return }   // pattern
            condition = before.keyword == .if || before.keyword == .guard || before.keyword == .while
                || before.kind == .comma && isConditionList(tk, introducer - 1)
        }
        info.unwrap = condition
        if tk[n + 1].kind == .assign {
            let e = expressionEnd(tk, from: n + 2, end: end, condition: condition)
            if e > n + 2 { info.initializer = (n + 2)..<e }
        } else if condition, tk[n + 1].kind == .lbrace || tk[n + 1].kind == .comma {
            // `if let x {` (Swift 5.7 shorthand): the outer `x`, unwrapped.
            info.initializer = n..<(n + 1)
        }
    }

    /// A `,` that continues an `if` / `guard` / `while` condition list.
    private func isConditionList(_ tk: [DeclToken], _ comma: Int) -> Bool {
        var depth = 0
        var k = comma - 1
        while k >= 0 {
            let t = tk[k]
            if BraceTokens.isCloser(t.kind) { depth += 1 } else if BraceTokens.isOpener(t.kind) {
                if depth == 0 { return false }
                depth -= 1
            } else if depth == 0 {
                if t.keyword == .if || t.keyword == .guard || t.keyword == .while { return true }
                if t.kind == .semicolon { return false }
            }
            k -= 1
        }
        return false
    }

    /// Back from `n` to the statement start within the window (name-led).
    private func headStart(_ tk: [DeclToken], _ n: Int) -> Int {
        var k = n
        while k > 0 {
            let t = tk[k - 1]
            if t.kind == .semicolon || t.kind == .lbrace || t.kind == .rbrace || t.kind == .lparen
                || t.kind == .comma { return k }
            if tk[k].isLineStart, k < n, language.newlineTerminated { return k }
            k -= 1
        }
        return 0
    }

    // MARK: Go

    private func nameLedGo(_ tk: [DeclToken], _ n: Int, function: Bool, end: Int, into info: inout BraceDeclInfo) {
        if function {
            var open = n + 1
            if open < end, tk[open].kind == .lbracket, let m = BraceTokens.matching(tk, open, limit: end) { open = m + 1 }
            guard let (items, after) = parameters(tk, open: open, end: end) else { return }
            info.parameters = items
            guard after < end, !tk[after].isLineStart else { return }
            if tk[after].kind == .lparen, let (results, _) = parameters(tk, open: after, end: end) {
                for r in results {
                    // `(n int, err error)` or `(int, error)`.
                    var s = r.lowerBound
                    if r.count >= 2, tk[s].kind == .ident, tk[s].keyword == .none,
                       tk[s + 1].kind != .dot, tk[s + 1].kind != .lbracket { s += 1 }
                    if case .type(let type, let e)? = types.parse(tk, s, r.upperBound), e == r.upperBound {
                        info.results.append(type)
                    } else {
                        info.results.append(nil)
                    }
                }
            } else if tk[after].kind != .lbrace, case .type(let type, _)? = types.parse(tk, after, end) {
                info.results = [type]
            }
            info.type = info.results.count == 1 ? info.results[0] : info.results.first ?? nil
            return
        }
        // The identifier list around `n` (`a, b T`, `a, b := …`).
        var listStart = n
        while listStart >= 2, tk[listStart - 1].kind == .comma, tk[listStart - 2].kind == .ident,
              tk[listStart - 2].keyword == .none { listStart -= 2 }
        var names: [Int] = [listStart]
        var j = listStart + 1
        while j + 1 < end, tk[j].kind == .comma, tk[j + 1].kind == .ident, tk[j + 1].keyword == .none {
            names.append(j + 1)
            j += 2
        }
        let listEnd = j
        guard let position = names.firstIndex(of: n), listEnd < end else { return }
        let next = tk[listEnd]
        if next.kind == .walrus || next.kind == .assign {
            let e = expressionEnd(tk, from: listEnd + 1, end: end)
            guard e > listEnd + 1 else { return }
            if tk[listEnd + 1].keyword == .range { return }
            if names.count == 1 {
                info.initializer = (listEnd + 1)..<e
            } else {
                // `a, b := f()` (one call) or `a, b := x, y`.
                let rhs = splitTopLevel(tk, from: listEnd + 1, to: e)
                if rhs.count == names.count {
                    info.initializer = rhs[position]
                } else if rhs.count == 1 {
                    info.initializer = rhs[0]
                    info.resultIndex = position
                }
            }
            return
        }
        if next.isLineStart || next.kind == .rparen || next.kind == .semicolon { return }
        if case .type(let type, _)? = types.parse(tk, listEnd, end) { info.type = type }
    }

    func splitTopLevel(_ tk: [DeclToken], from: Int, to: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var depth = 0
        var start = from
        var k = from
        while k < to {
            let kind = tk[k].kind
            if BraceTokens.isOpener(kind) { depth += 1 } else if BraceTokens.isCloser(kind) { depth -= 1 }
            if kind == .comma, depth == 0 {
                out.append(start..<k)
                start = k + 1
            }
            k += 1
        }
        if to > start { out.append(start..<to) }
        return out
    }

    // MARK: Rust

    private func nameLedRust(_ tk: [DeclToken], _ n: Int, function: Bool, statementStart: Int?, end: Int,
                             into info: inout BraceDeclInfo) {
        let start = statementStart ?? headStart(tk, n)
        modifiers(tk, from: start, to: n, into: &info)
        if function {
            var open = n + 1
            if open < end, tk[open].kind == .less, let m = BraceTokens.matchingAngle(tk, open, end: end) { open = m + 1 }
            guard let (items, after) = parameters(tk, open: open, end: end) else { return }
            info.parameters = items
            if let first = items.first {
                var s = first.lowerBound
                while s < first.upperBound, tk[s].kind == .op && reader.spells(tk[s], "&")
                    || tk[s].kind == .literal || tk[s].keyword == .mut { s += 1 }
                info.hasSelfParameter = s < first.upperBound && tk[s].keyword == .selfValue
            }
            if after < end, tk[after].kind == .thinArrow, case .type(let type, _)? = types.parse(tk, after + 1, end) {
                info.type = type
            }
            return
        }
        guard n + 1 < end else { return }
        if tk[n + 1].kind == .colon {
            // A field, a parameter, or `let x: T` (plain bindings only).
            if n > 0, start < n {
                let before = tk[n - 1]
                let plain = before.keyword == .let || before.keyword == .mut || before.keyword == .pub
                    || before.kind == .lparen || before.kind == .comma || before.kind == .lbrace
                    || before.kind == .op && reader.spells(before, "|") || before.kind == .rparen
                    || before.keyword == .ref
                guard plain else { return }
            }
            if case .type(let type, _)? = types.parse(tk, n + 2, end) { info.type = type }
            return
        }
        // `let [mut] x = …`
        var k = n - 1
        if k >= 0, tk[k].keyword == .mut { k -= 1 }
        guard k >= 0, tk[k].keyword == .let else { return }
        if k > 0, tk[k - 1].keyword == .if || tk[k - 1].keyword == .while { return }
        if tk[n + 1].kind == .assign {
            let e = expressionEnd(tk, from: n + 2, end: end)
            if e > n + 2 { info.initializer = (n + 2)..<e }
        }
    }
}
