import Foundation

/// Which surface syntax a type text uses.
public enum TypeSyntax: Sendable {
    /// Python annotations as printed by `ast.unparse` (typeshed tables,
    /// source annotations): `list[str]`, `int | None`, `Callable[[int], str]`.
    case python
    /// TypeScript type syntax: `Array<T>`, `T[]`, `(x: T) => U`, `{ a: T }`.
    case typescript
}

/// A small type-expression AST shared by Python and TypeScript (M17 T17.10;
/// reused by inference in T17.11). It keeps what inference needs — names,
/// generic arguments, unions, callables, arrays / tuples, object members — and
/// keeps the rest opaque with its source text (`keyof`, `typeof`, conditional
/// and mapped types, `infer`, type predicates, `unique symbol`).
///
/// Normalisations: Python `Union[...]` / `Optional[T]` become `.union`,
/// `Callable[...]` becomes `.function`; TypeScript `readonly T[]` drops the
/// `readonly` operator; `X | Y | Z` and nested unions are flattened.
public indirect enum TypeExpr: Hashable, Sendable {
    /// `int`, `os.PathLike`, `Intl.DateTimeFormat`, `None`, `null`, `this`.
    case name(String)
    /// `list[str]`, `Array<T>`, `Literal['a']`.
    case generic(TypeExpr, [TypeExpr])
    case union([TypeExpr])
    case intersection([TypeExpr])
    case function(FunctionType)
    /// TypeScript `T[]`.
    case array(TypeExpr)
    /// TypeScript `[A, B?, ...C]` (Python tuples stay `.generic(.name("tuple"), …)`).
    case tuple([TupleElement])
    /// Python bare list, e.g. a `Callable` parameter list or a ParamSpec value.
    case list([TypeExpr])
    /// String, number, template or boolean literal, as written (`'a'`, `-1`).
    case literal(String)
    /// TypeScript object type literal.
    case object([ObjectMember])
    /// TypeScript indexed access `T[K]`.
    case indexed(TypeExpr, TypeExpr)
    /// Python `...` (in `tuple[int, ...]`, `Callable[..., R]`).
    case ellipsis
    /// Python `*Ts` / `*tuple[int, ...]`.
    case unpacked(TypeExpr)
    /// Kept as source text.
    case opaque(OpaqueKind, String)

    public enum OpaqueKind: Hashable, Sendable {
        case keyof, typeQuery, conditional, mapped, infer, predicate, uniqueSymbol, importType
    }

    public struct FunctionType: Hashable, Sendable {
        public var typeParameters: [String] = []
        public var parameters: [Parameter] = []
        public var returnType: TypeExpr
        /// TypeScript `new (...) => T`.
        public var isConstructor = false
        /// Python `Callable[..., R]`.
        public var acceptsAnyArguments = false
        /// Python `Callable[P, R]` / `Callable[Concatenate[...], R]`.
        public var parameterSpec: TypeExpr?
    }

    public struct Parameter: Hashable, Sendable {
        /// nil for Python `Callable` parameters.
        public var name: String?
        public var type: TypeExpr?
        public var isOptional = false
        public var isRest = false
    }

    public struct TupleElement: Hashable, Sendable {
        public var name: String?
        public var type: TypeExpr
        public var isOptional = false
        public var isRest = false
    }

    public struct ObjectMember: Hashable, Sendable {
        public enum Kind: Hashable, Sendable { case property, method, call, construct, index, getter, setter }
        public var kind: Kind
        /// Property / method name; the key parameter for index signatures;
        /// empty for call and construct signatures.
        public var name: String
        /// Property type, `.function` for methods / call / construct
        /// signatures, value type for index signatures.
        public var type: TypeExpr
        public var isOptional = false
        public var isReadonly = false
    }

    /// Parses `text`; nil when it is empty or not a complete type expression.
    public static func parse(_ text: String, syntax: TypeSyntax) -> TypeExpr? {
        guard var parser = TypeExprParser(text, syntax: syntax) else { return nil }
        return parser.parseAll()
    }
}

// MARK: - Parser

private struct TypeExprParser {
    struct Failure: Error {}

    enum Kind: Equatable {
        case ident, number, string, template, ellipsis, arrow, end
        case punct(UInt8)
    }

    struct Token {
        var kind: Kind
        var start: Int
        var end: Int
    }

    let bytes: [UInt8]
    let syntax: TypeSyntax
    var tokens: [Token] = []
    /// For each bracket token, the index of its partner (else -1).
    var partner: [Int] = []
    var pos = 0

    init?(_ text: String, syntax: TypeSyntax) {
        self.bytes = Array(text.utf8)
        self.syntax = syntax
        guard lex() else { return nil }
    }

    // MARK: Lexer

    private static func isIdentStart(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || b == 0x5F || b == 0x24 || b >= 0x80
    }
    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    private mutating func lex() -> Bool {
        var i = 0
        let n = bytes.count
        var stack: [Int] = []
        while i < n {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1; continue }
            let start = i
            var kind: Kind
            if Self.isIdentStart(b) {
                while i < n, Self.isIdentStart(bytes[i]) || Self.isDigit(bytes[i]) { i += 1 }
                // Python string prefixes: b'..', r"..", rb'..'
                if syntax == .python, i < n, bytes[i] == 0x27 || bytes[i] == 0x22, i - start <= 2,
                   bytes[start..<i].allSatisfy({ "bBrRuU".utf8.contains($0) }) {
                    guard let e = scanQuoted(from: i) else { return false }
                    i = e
                    kind = .string
                } else {
                    kind = .ident
                }
            } else if Self.isDigit(b) || (b == 0x2E && i + 1 < n && Self.isDigit(bytes[i + 1])) {
                while i < n {
                    let c = bytes[i]
                    if Self.isDigit(c) || Self.isIdentStart(c) || c == 0x2E { i += 1; continue }
                    if (c == 0x2B || c == 0x2D), bytes[i - 1] == 0x65 || bytes[i - 1] == 0x45,
                       !(bytes[start] == 0x30 && start + 1 < n && (bytes[start + 1] | 0x20) == 0x78) {
                        i += 1; continue   // exponent sign, not in hex
                    }
                    break
                }
                kind = .number
            } else if b == 0x27 || b == 0x22 {
                guard let e = scanQuoted(from: i) else { return false }
                i = e
                kind = .string
            } else if b == 0x60 {
                guard syntax == .typescript, let e = scanTemplate(from: i) else { return false }
                i = e
                kind = .template
            } else if b == 0x2E, i + 2 < n, bytes[i + 1] == 0x2E, bytes[i + 2] == 0x2E {
                i += 3
                kind = .ellipsis
            } else if b == 0x3D, i + 1 < n, bytes[i + 1] == 0x3E {
                i += 2
                kind = .arrow
            } else if "[](){}<>,|&?:;.*=+-!@".utf8.contains(b) {
                i += 1
                kind = .punct(b)
            } else {
                return false
            }
            let index = tokens.count
            tokens.append(Token(kind: kind, start: start, end: i))
            partner.append(-1)
            if case .punct(let p) = kind {
                if p == 0x28 || p == 0x5B || p == 0x7B { stack.append(index) }
                if p == 0x29 || p == 0x5D || p == 0x7D {
                    guard let open = stack.popLast() else { return false }
                    let o = bytes[tokens[open].start]
                    guard (o == 0x28 && p == 0x29) || (o == 0x5B && p == 0x5D) || (o == 0x7B && p == 0x7D) else { return false }
                    partner[open] = index
                    partner[index] = open
                }
            }
        }
        guard stack.isEmpty else { return false }
        tokens.append(Token(kind: .end, start: n, end: n))
        partner.append(-1)
        return true
    }

    private func scanQuoted(from i: Int) -> Int? {
        let quote = bytes[i]
        var j = i + 1
        while j < bytes.count {
            if bytes[j] == 0x5C { j += 2; continue }
            if bytes[j] == quote { return j + 1 }
            j += 1
        }
        return nil
    }

    private func scanTemplate(from i: Int) -> Int? {
        var j = i + 1
        while j < bytes.count {
            let c = bytes[j]
            if c == 0x5C { j += 2; continue }
            if c == 0x60 { return j + 1 }
            if c == 0x24, j + 1 < bytes.count, bytes[j + 1] == 0x7B {
                var depth = 1
                j += 2
                while j < bytes.count, depth > 0 {
                    switch bytes[j] {
                    case 0x7B: depth += 1
                    case 0x7D: depth -= 1
                    case 0x27, 0x22: guard let e = scanQuoted(from: j) else { return nil }; j = e - 1
                    case 0x60: guard let e = scanTemplate(from: j) else { return nil }; j = e - 1
                    default: break
                    }
                    j += 1
                }
                continue
            }
            j += 1
        }
        return nil
    }

    // MARK: Token helpers

    var current: Token { tokens[pos] }

    func text(_ t: Token) -> String { String(decoding: bytes[t.start..<t.end], as: UTF8.self) }

    func isPunct(_ c: Character, at offset: Int = 0) -> Bool {
        let i = pos + offset
        guard i < tokens.count, case .punct(let p) = tokens[i].kind else { return false }
        return p == c.asciiValue!
    }

    func isIdent(_ word: String? = nil, at offset: Int = 0) -> Bool {
        let i = pos + offset
        guard i < tokens.count, tokens[i].kind == .ident else { return false }
        guard let word else { return true }
        let t = tokens[i]
        return t.end - t.start == word.utf8.count && bytes[t.start..<t.end].elementsEqual(word.utf8)
    }

    func kind(at offset: Int) -> Kind {
        let i = pos + offset
        return i < tokens.count ? tokens[i].kind : .end
    }

    mutating func eat(_ c: Character) -> Bool {
        if isPunct(c) { pos += 1; return true }
        return false
    }

    mutating func expect(_ c: Character) throws {
        guard eat(c) else { throw Failure() }
    }

    mutating func identifier() throws -> String {
        guard current.kind == .ident else { throw Failure() }
        defer { pos += 1 }
        return text(current)
    }

    func raw(from startToken: Int) -> String {
        let start = tokens[startToken].start
        let end = pos > startToken ? tokens[pos - 1].end : start
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    mutating func parseAll() -> TypeExpr? {
        guard tokens.count > 1 else { return nil }
        do {
            let expr = syntax == .python ? try pyExpr() : try tsReturnType()
            return current.kind == .end ? expr : nil
        } catch {
            return nil
        }
    }

    static func union(_ parts: [TypeExpr]) -> TypeExpr {
        var flat: [TypeExpr] = []
        for p in parts {
            if case .union(let inner) = p { flat.append(contentsOf: inner) } else { flat.append(p) }
        }
        return flat.count == 1 ? flat[0] : .union(flat)
    }

    // MARK: Python

    mutating func pyExpr() throws -> TypeExpr {
        var parts = [try pyPostfix()]
        while eat("|") { parts.append(try pyPostfix()) }
        return parts.count == 1 ? parts[0] : Self.union(parts)
    }

    mutating func pyPostfix() throws -> TypeExpr {
        var base = try pyPrimary()
        while isPunct("[") {
            pos += 1
            var args: [TypeExpr] = []
            while !isPunct("]") {
                args.append(try pyExpr())
                if !eat(",") { break }
            }
            try expect("]")
            base = Self.pySpecial(base, args)
        }
        return base
    }

    mutating func pyPrimary() throws -> TypeExpr {
        let t = current
        switch t.kind {
        case .ident:
            var name = text(t)
            pos += 1
            while isPunct("."), kind(at: 1) == .ident {
                pos += 1
                name += "." + text(current)
                pos += 1
            }
            return .name(name)
        case .string, .number:
            pos += 1
            return .literal(text(t))
        case .ellipsis:
            pos += 1
            return .ellipsis
        case .punct(let p):
            switch p {
            case UInt8(ascii: "-"):
                pos += 1
                guard current.kind == .number else { throw Failure() }
                defer { pos += 1 }
                return .literal("-" + text(current))
            case UInt8(ascii: "["):
                pos += 1
                var items: [TypeExpr] = []
                while !isPunct("]") {
                    items.append(try pyExpr())
                    if !eat(",") { break }
                }
                try expect("]")
                return .list(items)
            case UInt8(ascii: "("):
                pos += 1
                if eat(")") { return .generic(.name("tuple"), []) }   // `tuple[()]`
                var items = [try pyExpr()]
                var isTuple = false
                while eat(",") {
                    isTuple = true
                    if isPunct(")") { break }
                    items.append(try pyExpr())
                }
                try expect(")")
                return isTuple ? .generic(.name("tuple"), items) : items[0]
            case UInt8(ascii: "*"):
                pos += 1
                return .unpacked(try pyPostfix())
            default:
                throw Failure()
            }
        default:
            throw Failure()
        }
    }

    static func pySpecial(_ base: TypeExpr, _ args: [TypeExpr]) -> TypeExpr {
        guard case .name(let full) = base else { return .generic(base, args) }
        let last = full.split(separator: ".").last.map(String.init) ?? full
        switch last {
        case "Union" where !args.isEmpty:
            return union(args)
        case "Optional" where args.count == 1:
            return union([args[0], .name("None")])
        case "Callable" where args.count == 2:
            var fn = TypeExpr.FunctionType(returnType: args[1])
            switch args[0] {
            case .list(let params): fn.parameters = params.map { TypeExpr.Parameter(name: nil, type: $0) }
            case .ellipsis: fn.acceptsAnyArguments = true
            default: fn.parameterSpec = args[0]
            }
            return .function(fn)
        default:
            return .generic(base, args)
        }
    }

    // MARK: TypeScript

    /// A type that may be a type predicate (`x is T`, `asserts x`, `asserts x is T`).
    mutating func tsReturnType() throws -> TypeExpr {
        let start = pos
        if isIdent("asserts"), kind(at: 1) == .ident {
            pos += 2
            if isIdent("is") { pos += 1; _ = try tsType() }
            return .opaque(.predicate, raw(from: start))
        }
        if current.kind == .ident, isIdent("is", at: 1) {
            pos += 2
            _ = try tsType()
            return .opaque(.predicate, raw(from: start))
        }
        return try tsType()
    }

    mutating func tsType(noConditional: Bool = false) throws -> TypeExpr {
        let start = pos
        if isFunctionTypeStart() { return try tsFunctionType() }
        let check = try tsUnion(noConditional: noConditional)
        if !noConditional, isIdent("extends") {
            pos += 1
            if isFunctionTypeStart() {
                _ = try tsFunctionType()
            } else {
                _ = try tsUnion(noConditional: true, inExtends: true)
            }
            try expect("?")
            _ = try tsType()
            try expect(":")
            _ = try tsType()
            return .opaque(.conditional, raw(from: start))
        }
        return check
    }

    func isFunctionTypeStart() -> Bool {
        if isPunct("<") { return true }
        if isIdent("new") && (isPunct("(", at: 1) || isPunct("<", at: 1)) { return true }
        if isIdent("abstract") && isIdent("new", at: 1) { return true }
        if isPunct("("), partner[pos] > 0, partner[pos] + 1 < tokens.count,
           tokens[partner[pos] + 1].kind == .arrow { return true }
        return false
    }

    mutating func tsFunctionType() throws -> TypeExpr {
        var fn = TypeExpr.FunctionType(returnType: .name("any"))
        if isIdent("abstract") { pos += 1 }
        if isIdent("new") { pos += 1; fn.isConstructor = true }
        fn.typeParameters = try tsTypeParametersIfAny()
        fn.parameters = try tsParameters()
        guard current.kind == .arrow else { throw Failure() }
        pos += 1
        fn.returnType = try tsReturnType()
        return .function(fn)
    }

    mutating func tsTypeParametersIfAny() throws -> [String] {
        guard eat("<") else { return [] }
        var names: [String] = []
        while !isPunct(">") {
            // modifiers: const, in, out
            while (isIdent("const") || isIdent("in") || isIdent("out")), kind(at: 1) == .ident { pos += 1 }
            names.append(try identifier())
            if isIdent("extends") { pos += 1; _ = try tsType() }
            if eat("=") { _ = try tsType() }
            if !eat(",") { break }
        }
        try expect(">")
        return names
    }

    mutating func tsParameters() throws -> [TypeExpr.Parameter] {
        try expect("(")
        var params: [TypeExpr.Parameter] = []
        while !isPunct(")") {
            var p = TypeExpr.Parameter()
            while (isIdent("readonly") || isIdent("public") || isIdent("private") || isIdent("protected")),
                  kind(at: 1) == .ident { pos += 1 }
            if current.kind == .ellipsis { pos += 1; p.isRest = true }
            if current.kind == .ident {
                p.name = try identifier()
            } else if isPunct("{") || isPunct("[") {
                let start = pos
                pos = partner[pos] + 1          // destructuring pattern
                p.name = raw(from: start)
            } else {
                throw Failure()
            }
            if eat("?") { p.isOptional = true }
            if eat(":") { p.type = try tsReturnType() }
            if eat("=") { throw Failure() }      // initializers never appear in type texts
            params.append(p)
            if !eat(",") { break }
        }
        try expect(")")
        return params
    }

    mutating func tsUnion(noConditional: Bool, inExtends: Bool = false) throws -> TypeExpr {
        _ = eat("|")
        var parts = [try tsIntersection(noConditional: noConditional, inExtends: inExtends)]
        while eat("|") { parts.append(try tsIntersection(noConditional: noConditional, inExtends: inExtends)) }
        return parts.count == 1 ? parts[0] : Self.union(parts)
    }

    mutating func tsIntersection(noConditional: Bool, inExtends: Bool) throws -> TypeExpr {
        _ = eat("&")
        var parts = [try tsOperator(noConditional: noConditional, inExtends: inExtends)]
        while eat("&") { parts.append(try tsOperator(noConditional: noConditional, inExtends: inExtends)) }
        return parts.count == 1 ? parts[0] : .intersection(parts)
    }

    mutating func tsOperator(noConditional: Bool, inExtends: Bool) throws -> TypeExpr {
        let start = pos
        if isIdent("keyof"), startsType(at: 1) {
            pos += 1
            _ = try tsOperator(noConditional: noConditional, inExtends: inExtends)
            return .opaque(.keyof, raw(from: start))
        }
        if isIdent("unique"), isIdent("symbol", at: 1) {
            pos += 2
            return .opaque(.uniqueSymbol, "unique symbol")
        }
        if isIdent("readonly"), startsType(at: 1) {
            pos += 1
            return try tsOperator(noConditional: noConditional, inExtends: inExtends)
        }
        if isIdent("infer"), kind(at: 1) == .ident {
            pos += 2
            if isIdent("extends") {
                let save = pos
                pos += 1
                _ = try tsType(noConditional: true)
                // `infer U extends X ? A : B` inside a conditional's extends
                // clause: the `extends` belongs to the conditional.
                if inExtends && isPunct("?") { pos = save }
            }
            return .opaque(.infer, raw(from: start))
        }
        return try tsPostfix()
    }

    func startsType(at offset: Int) -> Bool {
        switch kind(at: offset) {
        case .ident, .string, .number, .template: return true
        case .punct(let p): return "([{<-".utf8.contains(p)
        default: return false
        }
    }

    mutating func tsPostfix() throws -> TypeExpr {
        var base = try tsPrimary()
        while isPunct("[") {
            pos += 1
            if eat("]") {
                base = .array(base)
            } else {
                let index = try tsType()
                try expect("]")
                base = .indexed(base, index)
            }
        }
        return base
    }

    mutating func tsTypeArguments() throws -> [TypeExpr] {
        try expect("<")
        var args: [TypeExpr] = []
        while !isPunct(">") {
            args.append(try tsType())
            if !eat(",") { break }
        }
        try expect(">")
        return args
    }

    mutating func tsPrimary() throws -> TypeExpr {
        let t = current
        let start = pos
        switch t.kind {
        case .ident:
            let word = text(t)
            if word == "typeof" {
                pos += 1
                if isIdent("import") { _ = try tsImportType() } else { _ = try tsEntityName() }
                if isPunct("<") { _ = try tsTypeArguments() }
                return .opaque(.typeQuery, raw(from: start))
            }
            if word == "import", isPunct("(", at: 1) {
                return try tsImportType()
            }
            if word == "true" || word == "false" { pos += 1; return .literal(word) }
            let name = try tsEntityName()
            if isPunct("<") { return .generic(.name(name), try tsTypeArguments()) }
            return .name(name)
        case .string, .number, .template:
            pos += 1
            return .literal(text(t))
        case .punct(let p):
            switch p {
            case UInt8(ascii: "-"):
                pos += 1
                guard current.kind == .number else { throw Failure() }
                defer { pos += 1 }
                return .literal("-" + text(current))
            case UInt8(ascii: "("):
                pos += 1
                let inner = try tsType()
                try expect(")")
                return inner
            case UInt8(ascii: "["):
                return try tsTuple()
            case UInt8(ascii: "{"):
                return try tsObject()
            default:
                throw Failure()
            }
        default:
            throw Failure()
        }
    }

    mutating func tsEntityName() throws -> String {
        var name = try identifier()
        while isPunct("."), kind(at: 1) == .ident {
            pos += 1
            name += "." + (try identifier())
        }
        return name
    }

    mutating func tsImportType() throws -> TypeExpr {
        let start = pos
        guard isIdent("import") else { throw Failure() }
        pos += 1
        try expect("(")
        guard current.kind == .string else { throw Failure() }
        pos += 1
        try expect(")")
        while eat(".") { _ = try identifier() }
        if isPunct("<") { _ = try tsTypeArguments() }
        return .opaque(.importType, raw(from: start))
    }

    mutating func tsTuple() throws -> TypeExpr {
        try expect("[")
        var elements: [TypeExpr.TupleElement] = []
        while !isPunct("]") {
            var rest = false
            if current.kind == .ellipsis { pos += 1; rest = true }
            var name: String?
            var optional = false
            if current.kind == .ident, isPunct(":", at: 1) || (isPunct("?", at: 1) && isPunct(":", at: 2)) {
                name = try identifier()
                if eat("?") { optional = true }
                try expect(":")
            }
            let type = try tsType()
            if eat("?") { optional = true }
            elements.append(TypeExpr.TupleElement(name: name, type: type, isOptional: optional, isRest: rest))
            if !eat(",") { break }
        }
        try expect("]")
        return .tuple(elements)
    }

    mutating func tsObject() throws -> TypeExpr {
        let start = pos
        try expect("{")
        // Mapped type: `{ [K in T]: X }`, possibly with (+/-)readonly first.
        var probe = 0
        if isPunct("+") || isPunct("-") { probe += 1 }
        if isIdent("readonly", at: probe) { probe += 1 }
        if isPunct("[", at: probe), kind(at: probe + 1) == .ident, isIdent("in", at: probe + 2) {
            pos += probe + 1
            pos += 2
            _ = try tsType()
            if isIdent("as") { pos += 1; _ = try tsType() }
            try expect("]")
            if isPunct("+") || isPunct("-") { pos += 1 }
            _ = eat("?")
            if eat(":") { _ = try tsType() }
            _ = eat(";") || eat(",")
            try expect("}")
            return .opaque(.mapped, raw(from: start))
        }
        var members: [TypeExpr.ObjectMember] = []
        while !isPunct("}") {
            members.append(try tsMember())
            if !(eat(";") || eat(",")) { break }
        }
        try expect("}")
        return .object(members)
    }

    func startsPropertyName(at offset: Int) -> Bool {
        switch kind(at: offset) {
        case .ident, .string, .number: return true
        case .punct(let p): return p == UInt8(ascii: "[")
        default: return false
        }
    }

    mutating func tsPropertyName() throws -> String {
        switch current.kind {
        case .ident, .string, .number:
            defer { pos += 1 }
            return text(current)
        case .punct(UInt8(ascii: "[")):
            let start = pos
            pos = partner[pos] + 1
            return raw(from: start)
        default:
            throw Failure()
        }
    }

    mutating func tsSignatureType(isConstructor: Bool = false) throws -> TypeExpr {
        var fn = TypeExpr.FunctionType(returnType: .name("any"), isConstructor: isConstructor)
        fn.typeParameters = try tsTypeParametersIfAny()
        fn.parameters = try tsParameters()
        if eat(":") { fn.returnType = try tsReturnType() }
        return .function(fn)
    }

    mutating func tsMember() throws -> TypeExpr.ObjectMember {
        var readonly = false
        if isIdent("readonly"), startsPropertyName(at: 1) { pos += 1; readonly = true }
        if isPunct("(") || isPunct("<") {
            return TypeExpr.ObjectMember(kind: .call, name: "", type: try tsSignatureType())
        }
        if isIdent("new"), isPunct("(", at: 1) || isPunct("<", at: 1) {
            pos += 1
            return TypeExpr.ObjectMember(kind: .construct, name: "", type: try tsSignatureType(isConstructor: true))
        }
        if (isIdent("get") || isIdent("set")), startsPropertyName(at: 1) {
            let isGetter = isIdent("get")
            pos += 1
            let name = try tsPropertyName()
            let sig = try tsSignatureType()
            var type = TypeExpr.name("any")
            if case .function(let fn) = sig {
                type = isGetter ? fn.returnType : (fn.parameters.first?.type ?? .name("any"))
            }
            return TypeExpr.ObjectMember(kind: isGetter ? .getter : .setter, name: name, type: type, isReadonly: readonly)
        }
        if isPunct("["), kind(at: 1) == .ident, isPunct(":", at: 2) {
            pos += 1
            let key = try identifier()
            try expect(":")
            _ = try tsType()
            try expect("]")
            try expect(":")
            return TypeExpr.ObjectMember(kind: .index, name: key, type: try tsType(), isReadonly: readonly)
        }
        let name = try tsPropertyName()
        let optional = eat("?")
        if isPunct("(") || isPunct("<") {
            return TypeExpr.ObjectMember(kind: .method, name: name, type: try tsSignatureType(), isOptional: optional)
        }
        var type = TypeExpr.name("any")
        if eat(":") { type = try tsType() }
        return TypeExpr.ObjectMember(kind: .property, name: name, type: type, isOptional: optional, isReadonly: readonly)
    }
}
