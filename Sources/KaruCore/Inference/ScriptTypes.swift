import Foundation

// M17 T17.11c — the JS / TS side of the type model (plan §8.1, the JS / TS
// column): well-known lib classes, TypeScript type texts (`TypeExpr`, from
// the lib table, source annotations and JSDoc) converted to `InferredType`,
// and types printed back in TypeScript syntax for signature summaries.
//
// Mapping:
// - `string` / `number` / `boolean` / `bigint` / `symbol` → instances of the
//   lib interfaces `String` / `Number` / … (their members are what a
//   primitive offers); literal types → `.literal`.
// - `null` / `undefined` / `void` → `.none`; `never` → `.never`;
//   `any` / `unknown` / `object` / `{}` → `.unknown` (no members: usage
//   evidence, plan §8.1 precision rule).
// - `T[]` → `Array<T>`; tuples → `ScriptTypes.tuple` with one argument per
//   element (members are `Array`'s of the element union).
// - Object type literals, intersections, `Record<K, V>` → `.shape`.
// - Function types → `.callable(.signature)`; type parameters in scope →
//   `.typeVar` (with their constraint), solved at calls.

enum ScriptTypes {
    static let string = ClassRef.table("es", "String")
    static let number = ClassRef.table("es", "Number")
    static let boolean = ClassRef.table("es", "Boolean")
    static let bigint = ClassRef.table("es", "BigInt")
    static let symbol = ClassRef.table("es", "Symbol")
    static let array = ClassRef.table("es", "Array")
    static let readonlyArray = ClassRef.table("es", "ReadonlyArray")
    static let promise = ClassRef.table("es", "Promise")
    static let promiseLike = ClassRef.table("es", "PromiseLike")
    static let function = ClassRef.table("es", "Function")
    static let regExp = ClassRef.table("es", "RegExp")
    static let map = ClassRef.table("es", "Map")
    static let set = ClassRef.table("es", "Set")
    static let iterator = ClassRef.table("es", "Iterator")
    static let asyncIterator = ClassRef.table("es", "AsyncIterator")
    /// A tuple `[A, B]`: one argument per element. Not a lib symbol; its
    /// members are `Array`'s (of the element union).
    static let tuple = ClassRef.table("es", "[tuple]")

    static var stringType: InferredType { .instance(string, []) }
    static var numberType: InferredType { .instance(number, []) }
    static var booleanType: InferredType { .instance(boolean, []) }

    static func arrayOf(_ element: InferredType) -> InferredType { .instance(array, [element]) }

    /// `T` of an array, read-only array or tuple (nil otherwise).
    static func arrayElement(_ t: InferredType) -> InferredType? {
        guard case .instance(let ref, let args) = t else { return nil }
        if ref == array || ref == readonlyArray { return args.first ?? .unknown }
        if ref == tuple { return args.isEmpty ? .unknown : .union(args) }
        return nil
    }

    /// A tuple's apparent type (`Array` of its element union); other types unchanged.
    static func apparent(_ t: InferredType) -> InferredType {
        if case .instance(let ref, let args) = t, ref == tuple {
            return arrayOf(args.isEmpty ? .unknown : .union(args.map(\.widened)))
        }
        return t
    }

    /// The type of a primitive / keyword type name, nil for other names.
    static func keywordType(_ name: String) -> InferredType? {
        switch name {
        case "string": return stringType
        case "number": return numberType
        case "boolean": return booleanType
        case "bigint": return .instance(bigint, [])
        case "symbol": return .instance(symbol, [])
        case "null", "undefined", "void": return InferredType.none
        case "never": return .never
        case "any", "unknown", "object": return .unknown
        case "this": return .typeVar("this", bound: nil)
        default: return nil
        }
    }

    /// The class of a literal type's text (`'a'`, `1`, `true`, template).
    static func literal(_ text: String) -> InferredType {
        if text == "true" || text == "false" { return .literal(boolean, text) }
        if let first = text.first {
            if first == "'" || first == "\"" { return .literal(string, text) }
            if first == "`" { return stringType }
            if first == "-" || first.isNumber || first == "." {
                return text.hasSuffix("n") ? .instance(bigint, []) : .literal(number, text)
            }
        }
        return .unknown
    }

    /// The unquoted value of a string literal's text.
    static func unquoted(_ text: String) -> String? {
        guard text.count >= 2, let first = text.first, first == "'" || first == "\"" || first == "`",
              text.last == first else { return nil }
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - Converter

/// Converts a TypeScript `TypeExpr` to an `InferredType`. Names that are
/// not keywords or type parameters go through `resolve` (the scope's type
/// namespace: document declarations, then the lib); `resolve` receives the
/// converted type arguments.
@MainActor
struct ScriptTypeConverter {
    let resolve: @MainActor (String, [InferredType]) -> InferredType
    /// Type parameters in scope → their constraint (nil: none).
    var typeParams: [String: InferredType?]
    private var depth = 0

    init(typeParams: [String: InferredType?] = [:], resolve: @escaping @MainActor (String, [InferredType]) -> InferredType) {
        self.typeParams = typeParams
        self.resolve = resolve
    }

    mutating func type(_ expr: TypeExpr) -> InferredType {
        depth += 1
        defer { depth -= 1 }
        guard depth < 24 else { return .unknown }
        switch expr {
        case .name(let n):
            if let bound = typeParams[n] { return .typeVar(n, bound: bound) }
            if let k = ScriptTypes.keywordType(n) { return k }
            return resolve(n, [])
        case .generic(let base, let args):
            guard case .name(let n) = base else { return .unknown }
            let converted = args.map { type($0) }
            if typeParams[n] != nil { return .unknown }
            return resolve(n, converted)
        case .union(let parts):
            return .union(parts.map { type($0) })
        case .intersection(let parts):
            let converted = parts.map { type($0) }.filter { $0 != .unknown }
            guard !converted.isEmpty else { return .unknown }
            if converted.count == 1 { return converted[0] }
            return .shape(ObjectShape(extends: converted))
        case .function(let fn):
            if fn.isConstructor { return .unknown }
            let saved = typeParams
            for p in fn.typeParameters where typeParams[p] == nil { typeParams[p] = .some(nil) }
            defer { typeParams = saved }
            return .callable(CallableRef(.signature(signature(fn))))
        case .array(let element):
            return ScriptTypes.arrayOf(type(element))
        case .tuple(let elements):
            return .instance(ScriptTypes.tuple, elements.map { e in
                let t = type(e.type)
                if e.isRest { return ScriptTypes.arrayElement(t) ?? .unknown }
                return e.isOptional ? .union([t, .none]) : t
            })
        case .literal(let text):
            return ScriptTypes.literal(text)
        case .object(let members):
            return .shape(shape(members))
        case .indexed(let object, let index):
            return indexed(type(object), index)
        case .list, .ellipsis, .unpacked, .opaque:
            return .unknown
        }
    }

    mutating func signature(_ fn: TypeExpr.FunctionType) -> InferredSignature {
        var params: [InferredParameter] = []
        for p in fn.parameters {
            if p.name == "this" { continue }
            params.append(InferredParameter(name: p.name, kind: p.isRest ? .variadic : .positional,
                                            type: p.type.map { type($0) }, hasDefault: p.isOptional))
        }
        return InferredSignature(parameters: params, returnType: type(fn.returnType))
    }

    mutating func shape(_ members: [TypeExpr.ObjectMember]) -> ObjectShape {
        var out = ObjectShape()
        for m in members {
            switch m.kind {
            case .property, .getter:
                let name = ScriptTypes.unquoted(m.name) ?? m.name
                guard !name.hasPrefix("[") else { continue }
                out.members.append(ObjectShape.Member(name: name, type: type(m.type), isOptional: m.isOptional))
            case .method:
                let name = ScriptTypes.unquoted(m.name) ?? m.name
                guard !name.hasPrefix("["), out.member(named: name) == nil else { continue }
                out.members.append(ObjectShape.Member(name: name, type: type(m.type), isOptional: m.isOptional,
                                                      isMethod: true))
            case .index:
                out.indexValue = type(m.type)
            case .call:
                if case .callable(let c) = type(m.type), case .signature(let sig) = c.target { out.call = sig }
            case .construct, .setter:
                continue
            }
        }
        return out
    }

    /// `T[K]` for a literal key or `number` on arrays.
    private mutating func indexed(_ object: InferredType, _ index: TypeExpr) -> InferredType {
        if case .literal(let text) = index, let key = ScriptTypes.unquoted(text) {
            if case .shape(let s) = object, let m = s.member(named: key) { return m.type }
            return .unknown
        }
        if case .name("number") = index, let element = ScriptTypes.arrayElement(object) { return element }
        return .unknown
    }
}

// MARK: - TypeScript text

enum ScriptTypeText {
    /// TypeScript text of `expr`, names in `replacing` substituted (type
    /// parameters → the receiver's arguments in summaries).
    static func text(_ expr: TypeExpr, replacing: [String: String] = [:]) -> String {
        func t(_ e: TypeExpr) -> String { text(e, replacing: replacing) }
        func operand(_ e: TypeExpr) -> String {
            switch e {
            case .union, .intersection, .function: return "(" + t(e) + ")"
            case .name(let n) where replacing[n].map({ $0.contains(" ") }) ?? false: return "(" + t(e) + ")"
            default: return t(e)
            }
        }
        switch expr {
        case .name(let n): return replacing[n] ?? n
        case .generic(let base, let args): return t(base) + "<" + args.map(t).joined(separator: ", ") + ">"
        case .union(let parts): return parts.map(t).joined(separator: " | ")
        case .intersection(let parts): return parts.map(operand).joined(separator: " & ")
        case .function(let fn):
            let tps = fn.typeParameters.isEmpty ? "" : "<" + fn.typeParameters.joined(separator: ", ") + ">"
            let params = fn.parameters.filter { $0.name != "this" }.map { p -> String in
                (p.isRest ? "..." : "") + (p.name ?? "_") + (p.isOptional ? "?" : "") + (p.type.map { ": " + t($0) } ?? "")
            }
            return (fn.isConstructor ? "new " : "") + tps + "(" + params.joined(separator: ", ") + ") => " + t(fn.returnType)
        case .array(let e): return operand(e) + "[]"
        case .tuple(let elements):
            return "[" + elements.map { e in
                (e.isRest ? "..." : "") + (e.name.map { $0 + (e.isOptional ? "?: " : ": ") } ?? "") + t(e.type)
                    + (e.isOptional && e.name == nil ? "?" : "")
            }.joined(separator: ", ") + "]"
        case .literal(let s): return s
        case .object(let members):
            let parts = members.prefix(4).map { m -> String in
                switch m.kind {
                case .index: return "[\(m.name): string]: " + t(m.type)
                case .call, .construct: return t(m.type)
                default: return m.name + (m.isOptional ? "?" : "") + ": " + t(m.type)
                }
            }
            return "{ " + parts.joined(separator: "; ") + (members.count > 4 ? "; …" : "") + " }"
        case .indexed(let o, let i): return operand(o) + "[" + t(i) + "]"
        case .ellipsis: return "..."
        case .list(let items): return "[" + items.map(t).joined(separator: ", ") + "]"
        case .unpacked(let e): return "..." + t(e)
        case .opaque(_, let s): return s
        }
    }

    /// Like `text`, with function types' parameter lists cut after the
    /// first parameter (`(value: T, …) => U`) for compact summaries.
    /// `elideReturn`: the function's return type prints as `…` too.
    static func compact(_ expr: TypeExpr, replacing: [String: String] = [:], elideReturn: Bool = false) -> String {
        switch expr {
        case .function(let fn):
            let params = fn.parameters.filter { $0.name != "this" }
            let head = params.first.map { p in
                (p.isRest ? "..." : "") + (p.name ?? "_") + (p.isOptional ? "?" : "") + (p.type.map { ": " + text($0, replacing: replacing) } ?? "")
            } ?? ""
            let more = params.count > 1 ? ", …" : ""
            return "(" + head + more + ") => " + (elideReturn ? "…" : text(fn.returnType, replacing: replacing))
        case .union(let parts):
            return parts.map { p -> String in
                if case .function = p { return "(" + compact(p, replacing: replacing, elideReturn: elideReturn) + ")" }
                return text(p, replacing: replacing)
            }.joined(separator: " | ")
        default:
            return text(expr, replacing: replacing)
        }
    }

    /// `text` with type-parameter names replaced (lib summaries).
    static func substituted(_ text: String, _ bindings: [String: String]) -> String {
        guard !bindings.isEmpty, bindings.keys.contains(where: { text.contains($0) }),
              let expr = TypeExpr.parse(text, syntax: .typescript) else { return text }
        return Self.text(expr, replacing: bindings)
    }

    /// Source text without comments, whitespace runs collapsed (type
    /// annotations read from the document).
    static func cleaned(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.utf16.count)
        var it = Array(source.unicodeScalars)[...]
        var quote: Unicode.Scalar?
        var lastSpace = false
        while let c = it.first {
            it = it.dropFirst()
            if let q = quote {
                out.unicodeScalars.append(c)
                if c == "\\", let n = it.first { out.unicodeScalars.append(n); it = it.dropFirst() }
                else if c == q { quote = nil }
                continue
            }
            if c == "/", let n = it.first, n == "/" {
                while let x = it.first, x != "\n" { it = it.dropFirst() }
                continue
            }
            if c == "/", let n = it.first, n == "*" {
                it = it.dropFirst()
                while let x = it.first {
                    it = it.dropFirst()
                    if x == "*", it.first == "/" { it = it.dropFirst(); break }
                }
                continue
            }
            if c == "'" || c == "\"" || c == "`" { quote = c }
            if c == " " || c == "\n" || c == "\t" || c == "\r" {
                if !lastSpace, !out.isEmpty { out.append(" ") }
                lastSpace = true
                continue
            }
            lastSpace = false
            out.unicodeScalars.append(c)
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}

// MARK: - Display

extension InferredType {
    /// TypeScript-style text for summaries (`string`, `Item[]`,
    /// `Promise<Response>`, `{ host: string; port: number }`, `'a' | 'b'`).
    /// An unknown type prints as `any`; unknown generic arguments are left out.
    public var tsDescription: String { tsText(depth: 0) }

    private func tsText(depth: Int) -> String {
        guard depth < 6 else { return "…" }
        func sub(_ t: InferredType) -> String { t.tsText(depth: depth + 1) }
        func operand(_ t: InferredType) -> String {
            switch t {
            case .anyOf, .callable: return "(" + sub(t) + ")"
            default: return sub(t)
            }
        }
        switch self {
        case .unknown: return "any"
        case .none: return "undefined"
        case .never: return "never"
        case .instance(let ref, let args):
            if ref == ScriptTypes.string { return "string" }
            if ref == ScriptTypes.number { return "number" }
            if ref == ScriptTypes.boolean { return "boolean" }
            if ref == ScriptTypes.bigint { return "bigint" }
            if ref == ScriptTypes.symbol { return "symbol" }
            if ref == ScriptTypes.tuple { return "[" + args.map(sub).joined(separator: ", ") + "]" }
            if ref == ScriptTypes.array, let element = args.first { return operand(element) + "[]" }
            guard !args.isEmpty, !args.allSatisfy({ $0 == .unknown }) else { return ref.shortName }
            return ref.shortName + "<" + args.map(sub).joined(separator: ", ") + ">"
        case .literal(_, let text): return text
        case .classObject(let ref, _): return "typeof " + ref.shortName
        case .module(let name):
            guard name.hasPrefix("§") else { return "typeof " + name }
            // An imported module (T17.13): its file's name, or the namespace.
            let (key, ns) = ScriptTypeTables.splitModuleValue(name)
            if !ns.isEmpty { return "typeof " + ns }
            let file = (key as NSString).lastPathComponent
            return "typeof import(\"" + (file.components(separatedBy: ".").first ?? file) + "\")"
        case .callable(let c):
            guard case .signature(let sig) = c.target else { return "Function" }
            let params = sig.parameters.map { p in
                (p.kind == .variadic ? "..." : "") + (p.name ?? "_") + (p.hasDefault ? "?" : "") + ": " + (p.type.map(sub) ?? "any")
            }
            return "(" + params.joined(separator: ", ") + ") => " + sub(sig.returnType)
        case .anyOf(let parts):
            let nonNone = parts.filter { $0 != .none }
            return (nonNone.map(sub) + (nonNone.count < parts.count ? ["undefined"] : [])).joined(separator: " | ")
        case .typeVar(let name, _): return name
        case .typeForm(let t): return sub(t)
        case .special(let name): return name
        case .shape(let shape):
            var parts = shape.members.prefix(3).map { m in m.name + (m.isOptional ? "?" : "") + ": " + sub(m.type) }
            if let v = shape.indexValue, parts.isEmpty { parts.append("[key: string]: " + sub(v)) }
            let more = shape.members.count > 3 || !shape.extends.isEmpty
            if parts.isEmpty { return shape.extends.isEmpty ? "{}" : shape.extends.map(operand).joined(separator: " & ") }
            return "{ " + parts.joined(separator: "; ") + (more ? "; …" : "") + " }"
        }
    }
}
