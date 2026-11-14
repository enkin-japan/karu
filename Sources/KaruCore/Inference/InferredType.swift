import Foundation

// M17 T17.11b — the language-neutral type model of inference (plan §8.1).
// Pure values (no AppKit, `Sendable`): a language evaluator (Python here,
// JS / TS in T17.11c) produces `InferredType`s from a syntax tree and the
// built-in type tables; `InferredMember` lists feed completion
// (`InferredMemberList.candidates`).

/// A class: from a built-in type table module or declared in the document.
public struct ClassRef: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// A class of a type-table module (Python: the stub module, e.g.
        /// `builtins`, `_io`; TS: the lib section).
        case table(String)
        /// A class declared in the current document, by qualified name
        /// (`Outer.Inner`; local classes `f.<locals>.C`). Names, not offsets,
        /// so a reference stays valid across edits elsewhere.
        case document
    }

    public let origin: Origin
    /// Qualified name within its origin.
    public let name: String

    public init(origin: Origin, name: String) {
        self.origin = origin
        self.name = name
    }

    public static func table(_ module: String, _ name: String) -> ClassRef { ClassRef(origin: .table(module), name: name) }
    public static func document(_ qualname: String) -> ClassRef { ClassRef(origin: .document, name: qualname) }

    /// The unqualified class name.
    public var shortName: String {
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// Lives only while its enclosing function is analysed (not cacheable).
    public var isLocal: Bool { name.contains("<locals>") }
}

/// One parameter of a callable signature.
public struct InferredParameter: Hashable, Sendable {
    public enum Kind: UInt8, Hashable, Sendable {
        case positionalOnly, positional, variadic, keywordOnly, keywordVariadic
    }
    public var name: String?
    public var kind: Kind
    public var type: InferredType?
    public var hasDefault: Bool

    public init(name: String?, kind: Kind, type: InferredType?, hasDefault: Bool) {
        self.name = name
        self.kind = kind
        self.type = type
        self.hasDefault = hasDefault
    }
}

/// A structural callable type (`Callable[[int], str]`, a lambda).
public struct InferredSignature: Hashable, Sendable {
    public var parameters: [InferredParameter]
    public var returnType: InferredType
    /// `Callable[..., R]`: any arguments.
    public var acceptsAnyArguments: Bool

    public init(parameters: [InferredParameter], returnType: InferredType, acceptsAnyArguments: Bool = false) {
        self.parameters = parameters
        self.returnType = returnType
        self.acceptsAnyArguments = acceptsAnyArguments
    }
}

/// A callable value: what calling it means is looked up through its target.
public struct CallableRef: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        /// A module-level function of a type-table module.
        case tableFunction(module: String, name: String)
        /// A method of a type-table class (looked up on `owner`).
        case tableMember(owner: ClassRef, name: String)
        /// A function or method declared in the document (qualified name).
        case documentFunction(String)
        case signature(InferredSignature)
    }

    public var target: Target
    /// The instance (method) or class object (classmethod) it is bound to.
    public var receiver: InferredType?

    public init(_ target: Target, receiver: InferredType? = nil) {
        self.target = target
        self.receiver = receiver
    }
}

/// An inferred type (plan §8.1). `unknown` never yields members: completion
/// falls back to usage evidence (plan §5.4).
public indirect enum InferredType: Hashable, Sendable {
    case unknown
    /// Python `None` / JS `null` and `undefined`.
    case none
    /// No value (`NoReturn`, `Never`, an empty union).
    case never
    /// An instance of a class with its generic arguments (empty: unknown).
    case instance(ClassRef, [InferredType])
    /// An instance of a built-in class with a known literal value (source
    /// text, e.g. `'r'`, `3`, `True`).
    case literal(ClassRef, String)
    /// The class object itself (`type[C]`).
    case classObject(ClassRef, [InferredType])
    /// A module (Python: a type-table module name).
    case module(String)
    case callable(CallableRef)
    /// A union (build with `InferredType.union(_:)`, which normalises).
    case anyOf([InferredType])
    /// An unsolved type variable (with its bound, if any).
    case typeVar(String, bound: InferredType?)
    /// A value that denotes a type (a type alias, a TypeVar object, `int | None`
    /// written as an expression): used where a value appears in a type position.
    case typeForm(InferredType)
    /// A special typing form used as a value (`Optional`, `Literal`, `Any` …).
    case special(String)

    // MARK: Unions

    /// The normalised union of `parts`: flattened, deduplicated, `never`
    /// dropped; a single part is itself; nothing is `never`.
    public static func union(_ parts: [InferredType]) -> InferredType {
        var flat: [InferredType] = []
        func add(_ t: InferredType) {
            switch t {
            case .anyOf(let inner): inner.forEach(add)
            case .never: break
            default: if !flat.contains(t) { flat.append(t) }
            }
        }
        parts.forEach(add)
        // A literal adds nothing to its own class (`str | Literal['a']` is `str`).
        if flat.contains(where: { if case .literal = $0 { return true }; return false }) {
            let all = flat
            flat.removeAll { t in
                guard case .literal(let ref, _) = t else { return false }
                return all.contains(.instance(ref, []))
            }
        }
        if flat.isEmpty { return .never }
        return flat.count == 1 ? flat[0] : .anyOf(flat)
    }

    /// The constituents of a union (itself otherwise).
    public var constituents: [InferredType] {
        if case .anyOf(let parts) = self { return parts }
        return [self]
    }

    /// Without `None` constituents.
    public var withoutNone: InferredType { .union(constituents.filter { $0 != .none }) }

    /// The union holds `unknown` (or is `unknown`).
    public var containsUnknown: Bool { constituents.contains(.unknown) }

    /// A literal widened to its class (`'a'` → `str`); unions widened part by part.
    public var widened: InferredType {
        switch self {
        case .literal(let ref, _): return .instance(ref, [])
        case .anyOf(let parts): return .union(parts.map(\.widened))
        default: return self
        }
    }

    /// The class of an instance or literal.
    public var instanceClass: (ClassRef, [InferredType])? {
        switch self {
        case .instance(let ref, let args): return (ref, args)
        case .literal(let ref, _): return (ref, [])
        default: return nil
        }
    }

    /// Whether any `document` class reference is local to a function
    /// (such a type cannot outlive the request).
    public var mentionsLocalClass: Bool {
        switch self {
        case .instance(let ref, let args), .classObject(let ref, let args):
            return ref.isLocal || args.contains { $0.mentionsLocalClass }
        case .literal(let ref, _): return ref.isLocal
        case .anyOf(let parts): return parts.contains { $0.mentionsLocalClass }
        case .typeForm(let t): return t.mentionsLocalClass
        case .typeVar(_, let bound): return bound?.mentionsLocalClass ?? false
        case .callable(let c):
            if case .documentFunction(let q) = c.target, q.contains("<locals>") { return true }
            return c.receiver?.mentionsLocalClass ?? false
        default: return false
        }
    }

    /// Replaces type variables by `bindings` (unbound ones stay).
    public func substituting(_ bindings: [String: InferredType]) -> InferredType {
        guard !bindings.isEmpty else { return self }
        switch self {
        case .typeVar(let name, _): return bindings[name] ?? self
        case .instance(let ref, let args): return .instance(ref, args.map { $0.substituting(bindings) })
        case .classObject(let ref, let args): return .classObject(ref, args.map { $0.substituting(bindings) })
        case .anyOf(let parts): return .union(parts.map { $0.substituting(bindings) })
        case .typeForm(let t): return .typeForm(t.substituting(bindings))
        case .callable(var c):
            if case .signature(var sig) = c.target {
                sig.returnType = sig.returnType.substituting(bindings)
                for i in sig.parameters.indices { sig.parameters[i].type = sig.parameters[i].type?.substituting(bindings) }
                c.target = .signature(sig)
            }
            c.receiver = c.receiver?.substituting(bindings)
            return .callable(c)
        default: return self
        }
    }

    /// Approximate retained bytes (cache accounting).
    public var approximateBytes: Int {
        switch self {
        case .instance(let ref, let args), .classObject(let ref, let args):
            return 48 + ref.name.utf8.count + args.reduce(0) { $0 + $1.approximateBytes }
        case .literal(let ref, let text): return 48 + ref.name.utf8.count + text.utf8.count
        case .module(let name), .special(let name): return 32 + name.utf8.count
        case .anyOf(let parts): return 32 + parts.reduce(0) { $0 + $1.approximateBytes }
        case .typeVar(let name, let bound): return 32 + name.utf8.count + (bound?.approximateBytes ?? 0)
        case .typeForm(let t): return 16 + t.approximateBytes
        case .callable(let c):
            var n = 64 + (c.receiver?.approximateBytes ?? 0)
            switch c.target {
            case .tableFunction(let m, let name): n += m.utf8.count + name.utf8.count
            case .tableMember(let owner, let name): n += owner.name.utf8.count + name.utf8.count
            case .documentFunction(let q): n += q.utf8.count
            case .signature(let sig):
                n += sig.returnType.approximateBytes + sig.parameters.reduce(0) { $0 + 32 + ($1.type?.approximateBytes ?? 0) }
            }
            return n
        default: return 16
        }
    }
}

// MARK: - Display

extension InferredType {
    /// Python-style text for signature summaries and field types
    /// (`list[str]`, `str | None`, `type[Client]`). Unknown generic arguments
    /// are left out (`list`), an unknown type prints as `Any`.
    public var pythonDescription: String {
        switch self {
        case .unknown: return "Any"
        case .none: return "None"
        case .never: return "Never"
        case .instance(let ref, let args):
            return Self.generic(ref.shortName, args)
        case .literal(let ref, let text):
            return ref.shortName == "bool" || ref.shortName == "int" || ref.shortName == "str" || ref.shortName == "bytes"
                ? "Literal[\(text)]" : ref.shortName
        case .classObject(let ref, let args):
            return "type[\(Self.generic(ref.shortName, args))]"
        case .module(let name): return "Module(\(name))"
        case .callable(let c):
            if case .signature(let sig) = c.target {
                if sig.acceptsAnyArguments { return "Callable[..., \(sig.returnType.pythonDescription)]" }
                let params = sig.parameters.map { $0.type?.pythonDescription ?? "Any" }.joined(separator: ", ")
                return "Callable[[\(params)], \(sig.returnType.pythonDescription)]"
            }
            return "Callable"
        case .anyOf(let parts):
            // Literals of one class print as one `Literal[a, b]`.
            var out: [String] = []
            var literals: [String: [String]] = [:]
            var literalOrder: [String] = []
            for p in parts {
                if case .literal(let ref, let text) = p, ["str", "int", "bool", "bytes"].contains(ref.shortName) {
                    if literals[ref.shortName] == nil { literalOrder.append(ref.shortName); out.append("\u{0}" + ref.shortName) }
                    literals[ref.shortName, default: []].append(text)
                } else {
                    out.append(p.pythonDescription)
                }
            }
            return out.map { item in
                guard item.hasPrefix("\u{0}") else { return item }
                return "Literal[" + (literals[String(item.dropFirst())] ?? []).joined(separator: ", ") + "]"
            }.joined(separator: " | ")
        case .typeVar(let name, _): return name
        case .typeForm(let t): return "type[\(t.pythonDescription)]"
        case .special(let name): return name
        }
    }

    private static func generic(_ name: String, _ args: [InferredType]) -> String {
        guard !args.isEmpty, !args.allSatisfy({ $0 == .unknown }) else { return name }
        return name + "[" + args.map(\.pythonDescription).joined(separator: ", ") + "]"
    }
}

// MARK: - Members

/// What a member is (drives the candidate kind and its label).
public enum InferredMemberKind: Hashable, Sendable {
    case method, classMethod, staticMethod, property, field, nestedClass
    /// Module members.
    case function, `class`, variable, submodule
}

/// One member of an inferred type, as completion lists it.
public struct InferredMember: Hashable, Sendable {
    public let name: String
    public let kind: InferredMemberKind
    /// Ordering bucket: 0 = declared on the receiver's class (or the module
    /// itself), n = inherited from the n-th class of the MRO.
    public let rank: Int
    /// Compact signature summary or type (plan §5.5); nil when none.
    public var detail: String?

    public init(name: String, kind: InferredMemberKind, rank: Int, detail: String?) {
        self.name = name
        self.kind = kind
        self.rank = rank
        self.detail = detail
    }

    var approximateBytes: Int { 48 + name.utf8.count + (detail?.utf8.count ?? 0) }
}

/// Member lists → completion candidates (the seam every language shares).
public enum InferredMemberList {
    /// Longest detail kept (UTF-16 units); longer summaries are shortened.
    public static let detailLimit = 48

    /// Intersection of several constituents' member lists (unions, plan
    /// §13 precision rule): a name survives only when every list has it;
    /// kind, rank and detail come from the first list.
    public static func intersection(_ lists: [[InferredMember]]) -> [InferredMember] {
        guard var result = lists.first else { return [] }
        for other in lists.dropFirst() {
            let names = Set(other.map(\.name))
            result.removeAll { !names.contains($0.name) }
        }
        return result
    }

    /// Ranking depth inside the inferred set (plan §5.3: declared before
    /// inherited, private `_x` after public, dunders last).
    static func depth(of member: InferredMember) -> Int {
        let name = member.name
        var privacy = 0
        if name.hasPrefix("__") && name.hasSuffix("__") && name.count > 4 {
            privacy = 2_000
        } else if name.hasPrefix("_") {
            privacy = 1_000
        }
        return privacy + min(member.rank, 999)
    }

    static func candidateKind(_ kind: InferredMemberKind) -> CandidateKind {
        switch kind {
        case .method, .classMethod, .staticMethod: return .method
        case .property, .field: return .property
        case .nestedClass, .class: return .type
        case .function: return .function
        case .variable: return .variable
        case .submodule: return .module
        }
    }

    /// The members as `inferredType` candidates (ranked by the engine).
    public static func candidates(_ members: [InferredMember]) -> [Candidate] {
        members.map { m in
            var c = Candidate(name: m.name, kind: candidateKind(m.kind), source: .inferredType, scopeDepth: depth(of: m))
            c.detail = m.detail.map { shortened($0) }
            return c
        }
    }

    /// `detail` fitted into `detailLimit`: a signature keeps its return
    /// type and drops trailing parameters (`(a: int, …) -> str`); other
    /// text is cut at the end.
    public static func shortened(_ detail: String, limit: Int = detailLimit) -> String {
        let units = detail.utf16.count
        guard units > limit else { return detail }
        if detail.hasPrefix("("), let arrow = detail.range(of: ") -> ", options: .backwards) {
            var tail = String(detail[arrow.lowerBound...])          // ") -> R"
            if tail.utf16.count > limit / 2 {
                tail = String(tail.prefix(max(6, limit / 2 - 1))) + "…"
            }
            let params = String(detail[detail.index(after: detail.startIndex)..<arrow.lowerBound])
            let budget = limit - tail.utf16.count - 4                // "(" + ", …"
            var kept: [String] = []
            var used = 0
            for part in splitTopLevel(params) {
                let cost = part.utf16.count + (kept.isEmpty ? 0 : 2)
                if used + cost > budget { break }
                kept.append(part)
                used += cost
            }
            let head = kept.isEmpty ? "(…" : "(" + kept.joined(separator: ", ") + ", …"
            return head + tail
        }
        return String(detail.prefix(max(1, limit - 1))) + "…"
    }

    /// Splits a parameter list at top-level commas (outside brackets).
    static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in text {
            switch ch {
            case "[", "(", "{": depth += 1
            case "]", ")", "}": depth -= 1
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            default: break
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }
}
