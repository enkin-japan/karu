import Foundation

/// Python declaration walker (M17 T17.4a, plan §5.2 "完整").
///
/// Reads the token stream one **logical line** at a time (the tokenizer
/// emits `newline` tokens and marks each logical line's first token with its
/// indentation), so it needs no lookahead across lines and is trivially
/// resumable: tokens are buffered until their line ends.
///
/// - **Scopes**: `def` / `class` open a function / class scope (a function's
///   at its `(`, so parameters fall inside; a class's right after its name);
///   it ends at the physical start of the first later logical line indented
///   no deeper than the `def` / `class` line (trailing blank and comment lines
///   stay inside), or at the document end (so blank lines after the last
///   function stay inside it: the caret's column decides there — T17.5).
///   `lambda` scopes run from the keyword to the end of the body expression
///   (a `,`, a closing bracket, a comprehension `for`, or the end of the
///   statement plus trailing blanks); comprehension / generator scopes span
///   their brackets.
/// - **Bindings**: def / class names (`method` inside a class body),
///   parameters (annotations skipped, defaults scanned — brackets, strings
///   and lambdas inside them do not end a parameter), assignment targets
///   (tuple / list unpacking, starred, chained, annotated `x: T = v` and bare
///   `x: T`; attribute / subscript targets are not bindings), walrus `:=`,
///   `for` targets, `with … as`, `except … as`, `import a.b as c` (`a` without
///   alias), `from m import a as b, (c, d)`, comprehension targets, lambda
///   parameters, `global` / `nonlocal` names (kinds `.global` / `.nonlocal`;
///   later assignments to them in that function are not local bindings) and
///   `match` / `case` capture names. Class-body assignments are `.property`.
/// - **Augmented assignment** (`x += 1`) never creates a binding (Python
///   requires an earlier one; for a global it needs `global x`).
/// - Walrus targets bind by location (inside a comprehension: in the
///   comprehension scope, not the enclosing function as PEP 572 says).
/// - **Listed** (table / navigator): def / class names, parameters, a
///   single-name assignment target that is the first target of its statement,
///   the first name of a `for` target, `as` aliases — the legacy coverage.
/// - Robustness: a logical line longer than `maxLineTokens` is processed in
///   pieces; bracket nesting deeper than `maxNesting` is skipped; unbalanced
///   brackets are recovered by the tokenizer at a dedent.
struct PythonDeclarationWalker: Sendable {
    static let maxLineTokens = 100_000
    static let maxNesting = 128

    private struct Block: Sendable {
        var indent: Int
        var scope: Int32
        var isClass: Bool
        var globals: [String]
    }

    private var blocks: [Block] = []
    private var line: [DeclToken] = []
    /// Per line token: index of its matching closer / opener (-1 none).
    private var match: [Int32] = []
    /// Per line token: a binding mark, `kindCode + 1` (0 none).
    private var marks: [UInt8] = []
    private var lineIndent = 0
    private var nesting = 0

    // MARK: - Driver interface

    mutating func process(_ buffer: inout DeclTokenBuffer, _ text: NSString, final: Bool,
                          _ b: inout DeclarationBuilder) {
        while let token = buffer.peek() {
            buffer.consume()
            if token.kind == .newline {
                if !line.isEmpty { processLine(text, &b) }
                continue
            }
            line.append(token)
            if line.count >= Self.maxLineTokens { processLine(text, &b) }
        }
        if final, !line.isEmpty { processLine(text, &b) }
    }

    mutating func finish(at end: Int, _ b: inout DeclarationBuilder) {
        while let block = blocks.popLast() { b.closeScope(block.scope, at: end) }
    }

    // MARK: - Lines

    private mutating func processLine(_ text: NSString, _ b: inout DeclarationBuilder) {
        let count = line.count
        // Matching brackets.
        match = [Int32](repeating: -1, count: count)
        var stack: [Int] = []
        for i in 0..<count {
            switch line[i].kind {
            case .lparen, .lbracket, .lbrace:
                stack.append(i)
            case .rparen, .rbracket, .rbrace:
                if let open = stack.popLast() {
                    match[open] = Int32(i)
                    match[i] = Int32(open)
                }
            default:
                break
            }
        }
        marks = [UInt8](repeating: 0, count: count)
        let first = line[0]
        if first.isLogicalStart {
            lineIndent = first.indent
            while let block = blocks.last, block.indent >= first.indent {
                b.closeScope(block.scope, at: first.lineStart)
                blocks.removeLast()
            }
        }
        nesting = 0
        statements(0, count, text, &b)
        line.removeAll(keepingCapacity: line.count <= 4096)
    }

    // MARK: - Token helpers

    @inline(__always) private func keyword(_ i: Int) -> DeclKeyword {
        line[i].kind == .ident ? line[i].keyword : .none
    }

    /// An identifier usable as a name (soft keywords included).
    @inline(__always) private func isName(_ i: Int) -> Bool {
        let t = line[i]
        guard t.kind == .ident else { return false }
        switch t.keyword {
        case .none, .match, .case, .type: return true
        default: return false
        }
    }

    @inline(__always) private func isOpener(_ i: Int) -> Bool {
        let k = line[i].kind
        return k == .lparen || k == .lbracket || k == .lbrace
    }

    /// Index of the closer matching the opener at `i`, or `hi` when it is
    /// unmatched or beyond `hi`.
    @inline(__always) private func closer(_ i: Int, _ hi: Int) -> Int {
        let m = Int(match[i])
        return m > i && m < hi ? m : hi
    }

    /// The first depth-0 token in `lo..<hi` satisfying `test`, or `hi`.
    private func find(_ lo: Int, _ hi: Int, _ test: (DeclToken) -> Bool) -> Int {
        var j = lo
        while j < hi {
            if test(line[j]) { return j }
            j = isOpener(j) ? closer(j, hi) + 1 : j + 1
        }
        return hi
    }

    /// Depth-0 comma-separated items of `lo..<hi`.
    private func items(_ lo: Int, _ hi: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = lo
        var j = lo
        while j < hi {
            if line[j].kind == .comma {
                out.append((start, j))
                start = j + 1
            }
            j = isOpener(j) ? closer(j, hi) + 1 : j + 1
        }
        if start < hi { out.append((start, hi)) }
        return out
    }

    /// The header colon of a compound statement: the first depth-0 `:` not
    /// consumed by a depth-0 `lambda`, or `hi`.
    private func headerColon(_ lo: Int, _ hi: Int) -> Int {
        var lambdas = 0
        var j = lo
        while j < hi {
            if isOpener(j) { j = closer(j, hi) + 1; continue }
            if keyword(j) == .lambda { lambdas += 1 }
            if line[j].kind == .colon {
                if lambdas > 0 { lambdas -= 1 } else { return j }
            }
            j += 1
        }
        return hi
    }

    private var inClass: Bool { blocks.last?.isClass ?? false }
    private var localKind: DeclarationScan.DeclarationKind { inClass ? .property : .variable }

    private mutating func mark(_ i: Int, _ kind: DeclarationScan.DeclarationKind, listed: Bool) {
        marks[i] = UInt8(DeclarationScan.code(kind, listed: listed) + 1)
    }

    private static let markKinds: [(DeclarationScan.DeclarationKind, Bool)] = (0..<16).map { code in
        let all = DeclarationScan.DeclarationKind.allCases
        for kind in all {
            for listed in [true, false] where DeclarationScan.code(kind, listed: listed) == code {
                return (kind, listed)
            }
        }
        return (.variable, false)
    }

    /// Emits a binding, unless it names a `global` / `nonlocal` of the
    /// current function.
    private mutating func bind(_ i: Int, _ kind: DeclarationScan.DeclarationKind, listed: Bool,
                               _ text: NSString, _ b: inout DeclarationBuilder) {
        if kind == .variable, let block = blocks.last, !block.isClass, !block.globals.isEmpty {
            let t = line[i]
            let name = text.substring(with: NSRange(location: t.start, length: t.length))
            if block.globals.contains(name) { return }
        }
        b.declare(text, line[i], kind: kind, listed: listed)
    }

    // MARK: - Statements

    private mutating func statements(_ lo: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        var s = lo
        while s < hi {
            let e = find(s, hi) { $0.kind == .semicolon }
            statement(s, e, text, &b)
            s = e + 1
        }
    }

    private mutating func statement(_ lo: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        guard lo < hi else { return }
        var i = lo
        if keyword(i) == .async, i + 1 < hi { i += 1 }
        switch keyword(i) {
        case .def:
            defStatement(i, hi, text, &b)
        case .class:
            classStatement(i, hi, text, &b)
        case .for:
            forStatement(i, hi, text, &b)
        case .while, .if, .elif:
            let colon = headerColon(i + 1, hi)
            scan(i + 1, colon, text, &b)
            statements(colon + 1, hi, text, &b)
        case .else, .try, .finally:
            let colon = headerColon(i + 1, hi)
            statements(colon + 1, hi, text, &b)
        case .with:
            withStatement(i, hi, text, &b)
        case .except:
            let colon = headerColon(i + 1, hi)
            let asIndex = find(i + 1, colon) { $0.kind == .ident && $0.keyword == .as }
            if asIndex + 1 < colon, isName(asIndex + 1) { mark(asIndex + 1, localKind, listed: true) }
            scan(i + 1, colon, text, &b)
            statements(colon + 1, hi, text, &b)
        case .import:
            importStatement(i, hi, text, &b)
        case .from:
            fromStatement(i, hi, text, &b)
        case .global, .nonlocal:
            globalStatement(i, hi, text, &b)
        case .match where isSoftHeader(i, hi), .case where isSoftHeader(i, hi):
            softHeader(i, hi, text, &b)
        case .return, .yield, .raise, .assert, .del, .pass, .break, .continue, .await:
            scan(i + 1, hi, text, &b)
        default:
            if line[i].kind == .at {
                scan(i + 1, hi, text, &b)
            } else {
                assignmentOrExpression(i, hi, text, &b)
            }
        }
    }

    private mutating func defStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let nameIndex = i + 1
        guard nameIndex < hi, isName(nameIndex) else {
            scan(i + 1, hi, text, &b)
            return
        }
        let name = b.declare(text, line[nameIndex], kind: inClass ? .method : .function, listed: true)
        var j = nameIndex + 1
        let scopeStart = j < hi ? line[j].start : line[nameIndex].end
        let scope = b.openScope(.function, at: scopeStart, name: name)
        if j < hi, line[j].kind == .lbracket { j = closer(j, hi) + 1 }       // PEP 695 type parameters
        if j < hi, line[j].kind == .lparen {
            let close = closer(j, hi)
            parameters(j + 1, close, annotations: true, listed: true, text, &b)
            j = close + 1
        }
        let colon = headerColon(j, hi)
        blocks.append(Block(indent: lineIndent, scope: scope, isClass: false, globals: []))
        if colon < hi { statements(colon + 1, hi, text, &b) }
    }

    private mutating func classStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let nameIndex = i + 1
        guard nameIndex < hi, isName(nameIndex) else {
            scan(i + 1, hi, text, &b)
            return
        }
        let name = b.declare(text, line[nameIndex], kind: .class, listed: true)
        var j = nameIndex + 1
        let scopeStart = j < hi ? line[j].start : line[nameIndex].end
        let scope = b.openScope(.class, at: scopeStart, name: name)
        if j < hi, line[j].kind == .lbracket { j = closer(j, hi) + 1 }
        if j < hi, line[j].kind == .lparen {
            let close = closer(j, hi)
            scan(j + 1, close, text, &b)
            j = close + 1
        }
        let colon = headerColon(j, hi)
        blocks.append(Block(indent: lineIndent, scope: scope, isClass: true, globals: []))
        if colon < hi { statements(colon + 1, hi, text, &b) }
    }

    private mutating func forStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let inIndex = find(i + 1, hi) { $0.kind == .ident && $0.keyword == .in }
        markTargets(i + 1, inIndex, localKind, listedIndex: i + 1)
        let colon = headerColon(inIndex, hi)
        scan(i + 1, colon, text, &b)
        statements(colon + 1, hi, text, &b)
    }

    private mutating func withStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let colon = headerColon(i + 1, hi)
        var lo = i + 1
        var end = colon
        // `with (a as x, b as y):`
        if lo < end, line[lo].kind == .lparen, closer(lo, hi) == colon - 1 {
            lo += 1
            end = colon - 1
        }
        for (a, z) in items(lo, end) {
            let asIndex = find(a, z) { $0.kind == .ident && $0.keyword == .as }
            if asIndex + 1 < z { markTargets(asIndex + 1, z, localKind, listedIndex: asIndex + 1) }
        }
        scan(i + 1, colon, text, &b)
        statements(colon + 1, hi, text, &b)
    }

    private mutating func importStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        for (a, z) in items(i + 1, hi) {
            let asIndex = find(a, z) { $0.kind == .ident && $0.keyword == .as }
            if asIndex + 1 < z, isName(asIndex + 1) {
                b.declare(text, line[asIndex + 1], kind: .import, listed: true)
            } else if isName(a) {
                b.declare(text, line[a], kind: .import, listed: false)
            }
        }
    }

    private mutating func fromStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let importIndex = find(i + 1, hi) { $0.kind == .ident && $0.keyword == .import }
        guard importIndex < hi else {
            scan(i + 1, hi, text, &b)
            return
        }
        var lo = importIndex + 1
        var end = hi
        if lo < hi, line[lo].kind == .lparen {
            end = closer(lo, hi)
            lo += 1
        }
        for (a, z) in items(lo, end) {
            let asIndex = find(a, z) { $0.kind == .ident && $0.keyword == .as }
            if asIndex + 1 < z, isName(asIndex + 1) {
                b.declare(text, line[asIndex + 1], kind: .import, listed: true)
            } else if isName(a) {
                b.declare(text, line[a], kind: .import, listed: false)
            }
        }
    }

    private mutating func globalStatement(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let kind: DeclarationScan.DeclarationKind = keyword(i) == .global ? .global : .nonlocal
        for (a, _) in items(i + 1, hi) where isName(a) {
            b.declare(text, line[a], kind: kind, listed: false)
            if var block = blocks.last, !block.isClass {
                let t = line[a]
                block.globals.append(text.substring(with: NSRange(location: t.start, length: t.length)))
                blocks[blocks.count - 1] = block
            }
        }
    }

    /// `match subject:` / `case pattern [if guard]:` (soft keywords).
    private func isSoftHeader(_ i: Int, _ hi: Int) -> Bool {
        guard i + 1 < hi else { return false }
        switch line[i + 1].kind {
        case .assign, .augAssign, .dot, .colon, .walrus, .comma, .rparen, .rbracket, .rbrace, .op:
            return false
        default:
            return headerColon(i + 1, hi) < hi
        }
    }

    private mutating func softHeader(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) {
        let colon = headerColon(i + 1, hi)
        if keyword(i) == .case {
            let guardIndex = find(i + 1, colon) { $0.kind == .ident && $0.keyword == .if }
            var j = i + 1
            while j < guardIndex {
                if isName(j) {
                    let t = line[j]
                    let next = j + 1 < guardIndex ? line[j + 1].kind : .comma
                    let previous = j > i + 1 ? line[j - 1].kind : .comma
                    if next != .lparen, next != .dot, next != .assign, previous != .dot,
                       !Self.isPatternLiteralName(t, text) {
                        mark(j, .variable, listed: false)
                    }
                }
                j += 1
            }
        }
        scan(i + 1, colon, text, &b)
        statements(colon + 1, hi, text, &b)
    }

    /// `_`, `None`, `True`, `False` are not capture patterns.
    private static func isPatternLiteralName(_ t: DeclToken, _ text: NSString) -> Bool {
        guard t.length <= 5 else { return false }
        let name = text.substring(with: NSRange(location: t.start, length: t.length))
        return name == "_" || name == "None" || name == "True" || name == "False"
    }

    private mutating func assignmentOrExpression(_ lo: Int, _ hi: Int, _ text: NSString,
                                                 _ b: inout DeclarationBuilder) {
        var assigns: [Int] = []
        var annotation = -1
        var augmented = false
        var j = lo
        scanning: while j < hi {
            if isOpener(j) { j = closer(j, hi) + 1; continue }
            let t = line[j]
            switch t.kind {
            case .ident where t.keyword == .lambda:
                break scanning
            case .assign:
                assigns.append(j)
            case .colon where assigns.isEmpty && annotation < 0:
                annotation = j
            case .augAssign:
                augmented = true
                break scanning
            default:
                break
            }
            j += 1
        }
        if augmented {
            scan(lo, hi, text, &b)
            return
        }
        if annotation >= 0 {
            // `x: T` / `x: T = value` (an attribute / subscript target binds nothing).
            if annotation - lo == 1, isName(lo) { mark(lo, localKind, listed: false) }
            scan(lo, annotation, text, &b)
            if let eq = assigns.first(where: { $0 > annotation }) { scan(eq + 1, hi, text, &b) }
            return
        }
        if !assigns.isEmpty {
            var segment = lo
            for (n, eq) in assigns.enumerated() {
                markTargets(segment, eq, localKind, listedIndex: n == 0 && eq - segment == 1 ? segment : -1)
                segment = eq + 1
            }
        }
        scan(lo, hi, text, &b)
    }

    /// Marks the names bound by a target list `lo..<hi` (tuple / list
    /// unpacking, starred). `listedIndex`: the one token index that is listed.
    private mutating func markTargets(_ lo: Int, _ hi: Int, _ kind: DeclarationScan.DeclarationKind,
                                      listedIndex: Int, depth: Int = 0) {
        guard depth < 32 else { return }
        for (a, z) in items(lo, hi) {
            var s = a
            while s < z, line[s].kind == .star || line[s].kind == .doubleStar { s += 1 }
            guard s < z else { continue }
            if z - s == 1, isName(s) {
                mark(s, kind, listed: s == listedIndex)
            } else if line[s].kind == .lparen || line[s].kind == .lbracket, closer(s, z) == z - 1 {
                markTargets(s + 1, z - 1, kind, listedIndex: listedIndex, depth: depth + 1)
            }
        }
    }

    /// Parameters of a `def` (annotations) or a `lambda`.
    private mutating func parameters(_ lo: Int, _ hi: Int, annotations: Bool, listed: Bool,
                                     _ text: NSString, _ b: inout DeclarationBuilder) {
        for (a, z) in items(lo, hi) {
            var s = a
            while s < z, line[s].kind == .star || line[s].kind == .doubleStar { s += 1 }
            guard s < z else { continue }
            if isName(s) {
                b.declare(text, line[s], kind: .parameter, listed: listed)
                let eq = find(s + 1, z) { $0.kind == .assign }
                if eq < z { scan(eq + 1, z, text, &b) }
            } else if line[s].kind != .op {
                scan(s, z, text, &b)
            }
        }
    }

    // MARK: - Expressions

    /// Walks `lo..<hi` in order: emits marked bindings and walrus targets,
    /// opens lambda and comprehension scopes.
    private mutating func scan(_ lo: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder,
                               inComprehension: Bool = false) {
        var j = lo
        while j < hi {
            if marks[j] != 0 {
                let (kind, listed) = Self.markKinds[Int(marks[j] - 1)]
                bind(j, kind, listed: listed, text, &b)
                j += 1
                continue
            }
            let t = line[j]
            switch t.kind {
            case .ident:
                if t.keyword == .lambda {
                    j = lambda(j, hi, text, &b)
                    continue
                }
                if j + 1 < hi, line[j + 1].kind == .walrus, isName(j) {
                    bind(j, .variable, listed: false, text, &b)
                    j += 2
                    continue
                }
            case .lparen, .lbracket, .lbrace:
                let close = closer(j, hi)
                if nesting < Self.maxNesting {
                    nesting += 1
                    if isComprehension(j + 1, close) {
                        comprehension(j, close, hi, text, &b)
                    } else {
                        scan(j + 1, close, text, &b)
                    }
                    nesting -= 1
                }
                j = close + 1
                continue
            default:
                break
            }
            j += 1
        }
    }

    private func isComprehension(_ lo: Int, _ hi: Int) -> Bool {
        find(lo, hi) { $0.kind == .ident && $0.keyword == .for } < hi
    }

    private mutating func comprehension(_ open: Int, _ close: Int, _ hi: Int, _ text: NSString,
                                        _ b: inout DeclarationBuilder) {
        let scope = b.openScope(.comprehension, at: line[open].start)
        var j = open + 1
        while j < close {
            if isOpener(j) { j = closer(j, close) + 1; continue }
            if keyword(j) == .for {
                let inIndex = find(j + 1, close) { $0.kind == .ident && $0.keyword == .in }
                markTargets(j + 1, inIndex, .variable, listedIndex: j + 1)
                j = inIndex
                continue
            }
            j += 1
        }
        scan(open + 1, close, text, &b, inComprehension: true)
        let end = close < hi ? line[close].end : line[max(open, min(hi, line.count) - 1)].end
        b.closeScope(scope, at: end)
    }

    /// A `lambda` at `i`; returns the index after its body.
    private mutating func lambda(_ i: Int, _ hi: Int, _ text: NSString, _ b: inout DeclarationBuilder) -> Int {
        let scope = b.openScope(.lambda, at: line[i].start)
        // The parameter colon (nested lambdas in defaults consume their own).
        let colon = headerColon(i + 1, hi)
        parameters(i + 1, colon, annotations: false, listed: false, text, &b)
        var e = colon + 1
        while e < hi {
            if isOpener(e) { e = closer(e, hi) + 1; continue }
            let t = line[e]
            if t.kind == .comma { break }
            if t.kind == .ident, t.keyword == .for || (t.keyword == .async && e + 1 < hi && keyword(e + 1) == .for) {
                break
            }
            e += 1
        }
        e = min(e, hi)
        if colon + 1 < e { scan(colon + 1, e, text, &b) }
        var end = e > colon + 1 ? line[e - 1].end : (colon < hi ? line[colon].end : line[min(i, hi - 1)].end)
        if e >= hi {
            // The body ran to the end of the statement: blanks after it (where
            // the caret sits while typing the body) stay inside.
            let length = text.length
            while end < length, text.character(at: end) == 32 || text.character(at: end) == 9 { end += 1 }
            // …and so does the end of that line (the line break itself).
            if end < length, text.character(at: end) == 13 || text.character(at: end) == 10 {
                end += text.character(at: end) == 13 && end + 1 < length && text.character(at: end + 1) == 10 ? 2 : 1
            }
        }
        b.closeScope(scope, at: end)
        return max(e, i + 1)
    }
}
