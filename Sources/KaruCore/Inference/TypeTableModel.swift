import Foundation

// M17 T17.10 — decoded entries of the built-in type tables (plan §8.2
// "T17.10 接口"). Type expressions are kept as normalised text; parse them
// with `TypeExpr.parse(_:syntax:)` when needed. Empty annotations decode as nil.

/// Records shared by the Python and TypeScript tables.
public enum TypeTable {
    public struct TypeParameter: Hashable, Sendable {
        public enum Kind: UInt8, Sendable { case typeVar = 0, paramSpec = 1, typeVarTuple = 2 }
        public let name: String
        /// Bound (`bound=` / TS `extends`), or the constraints joined with `|`
        /// when `boundIsConstraints`.
        public let bound: String?
        public let defaultType: String?
        public let kind: Kind
        public let boundIsConstraints: Bool
    }

    public struct Parameter: Hashable, Sendable {
        public enum Kind: UInt8, Sendable {
            /// Python before `/`; the TypeScript `this` parameter.
            case positionalOnly = 0
            case positional = 1
            /// `*args` / TS `...rest`
            case variadic = 2
            case keywordOnly = 3
            /// `**kwargs`
            case keywordVariadic = 4
        }
        public let name: String
        public let kind: Kind
        public let type: String?
        /// Python default value; TypeScript `?` or initializer.
        public let hasDefault: Bool
    }

    public struct Signature: Hashable, Sendable {
        public let isAsync: Bool
        public let typeParameters: [TypeParameter]
        public let parameters: [Parameter]
        public let returnType: String?
    }

    public struct MemberFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let readonly = MemberFlags(rawValue: 1 << 0)
        /// Python `ClassVar` / class-level property; TypeScript `static`.
        public static let classLevel = MemberFlags(rawValue: 1 << 1)
        public static let final = MemberFlags(rawValue: 1 << 2)
        public static let abstract = MemberFlags(rawValue: 1 << 3)
        public static let deprecated = MemberFlags(rawValue: 1 << 4)
        /// `name = value` without an annotation (e.g. enum members).
        public static let assigned = MemberFlags(rawValue: 1 << 5)
        /// TypeScript `name?`.
        public static let optional = MemberFlags(rawValue: 1 << 6)
    }

    public struct Member: Hashable, Sendable {
        public enum Kind: UInt8, Sendable {
            case method = 0, classMethod = 1, staticMethod = 2, property = 3, field = 4
        }
        public let name: String
        public let kind: Kind
        public let flags: MemberFlags
        /// Field / property type; nil for methods.
        public let type: String?
        /// Method overloads in declaration order (capped by the generator).
        public let overloads: [Signature]
    }

    public struct IndexSignature: Hashable, Sendable {
        public let keyName: String
        public let keyType: String
        public let valueType: String
        public let isReadonly: Bool
    }

    public struct ClassFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let `protocol` = ClassFlags(rawValue: 1 << 0)
        public static let typedDict = ClassFlags(rawValue: 1 << 1)
        public static let namedTuple = ClassFlags(rawValue: 1 << 2)
        public static let `enum` = ClassFlags(rawValue: 1 << 3)
        public static let final = ClassFlags(rawValue: 1 << 4)
        public static let typeCheckOnly = ClassFlags(rawValue: 1 << 5)
        public static let deprecated = ClassFlags(rawValue: 1 << 6)
        public static let abstract = ClassFlags(rawValue: 1 << 7)
    }

    /// A Python class or a (merged) TypeScript interface / class.
    public struct ClassDecl: Hashable, Sendable {
        /// Python nested classes use dotted names (`Outer.Inner`); TS
        /// namespace members use qualified names (`Intl.DateTimeFormat`).
        public let name: String
        public let flags: ClassFlags
        public let typeParameters: [TypeParameter]
        /// Python bases / TypeScript `extends` (and `implements`) as type text.
        public let bases: [String]
        /// Sorted by the names' UTF-8 bytes.
        public let members: [Member]
        public let callSignatures: [Signature]
        public let constructSignatures: [Signature]
        public let indexSignatures: [IndexSignature]

        /// Own member by name (binary search; does not follow bases).
        public func member(named name: String) -> Member? {
            members.sortedFirst(named: name, key: \.name)
        }
    }

    public struct Function: Hashable, Sendable {
        public let name: String
        public let flags: MemberFlags
        public let overloads: [Signature]
    }

    public struct Variable: Hashable, Sendable {
        public let name: String
        public let type: String?
        /// Python `Final`; TypeScript `const`.
        public let isConstant: Bool
    }

    public struct Alias: Hashable, Sendable {
        public let name: String
        public let typeParameters: [TypeParameter]
        public let type: String
    }
}

/// One module of the Python standard-library table (typeshed, Python 3.13,
/// darwin). Lists are sorted by name except `all` and `starImports`.
public struct PythonModuleStub: Hashable, Sendable {
    public struct Import: Hashable, Sendable {
        public let localName: String
        /// Absolute module name (relative imports are resolved; `from p import m`
        /// with a submodule `p.m` is recorded as a module import of `p.m`).
        public let module: String
        /// Imported name, or nil when the module itself is bound.
        public let originalName: String?
        /// Stub re-export: `import x as x`, `from m import y as y`, or a public
        /// `name = imported` assignment.
        public let isReexport: Bool
    }

    public let name: String
    public let isPackage: Bool
    /// `__all__` after version evaluation; nil when the stub has none.
    public let all: [String]?
    public let imports: [Import]
    /// `from m import *` sources, in order.
    public let starImports: [String]
    public let typeVars: [TypeTable.TypeParameter]
    public let aliases: [TypeTable.Alias]
    public let variables: [TypeTable.Variable]
    public let functions: [TypeTable.Function]
    public let classes: [TypeTable.ClassDecl]

    public func `class`(named name: String) -> TypeTable.ClassDecl? { classes.sortedFirst(named: name, key: \.name) }
    public func function(named name: String) -> TypeTable.Function? { functions.sortedFirst(named: name, key: \.name) }
    public func variable(named name: String) -> TypeTable.Variable? { variables.sortedFirst(named: name, key: \.name) }
    public func alias(named name: String) -> TypeTable.Alias? { aliases.sortedFirst(named: name, key: \.name) }
    public func typeVar(named name: String) -> TypeTable.TypeParameter? { typeVars.sortedFirst(named: name, key: \.name) }
    public func `import`(named name: String) -> Import? { imports.sortedFirst(named: name, key: \.localName) }
}

/// One global symbol of the TypeScript lib table. A name can carry several
/// declarations at once (e.g. `Array` is an interface and a `declare var`).
public struct TSGlobalSymbol: Hashable, Sendable {
    public enum Section: Sendable, Hashable { case es, dom }

    public let name: String
    public let section: Section
    /// Merged interface (or class, see `isClass`) declarations.
    public let interface: TypeTable.ClassDecl?
    public let isClass: Bool
    /// `declare var/let/const name: Type`.
    public let variable: TypeTable.Variable?
    public let function: TypeTable.Function?
    public let alias: TypeTable.Alias?
    /// Unqualified member names when the symbol is a namespace; members are
    /// separate symbols named `Namespace.Member`.
    public let namespaceMembers: [String]?
    /// An ES symbol that a DOM lib file augments (only `ImportMeta`); the DOM
    /// part is a separate DOM-section symbol.
    public let isDOMAugmented: Bool
}

extension Array {
    /// Binary search in an array sorted by `key`'s UTF-8 bytes (the
    /// generators sort that way; for ASCII names it equals `<`).
    func sortedFirst(named name: String, key: KeyPath<Element, String>) -> Element? {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            let candidate = self[mid][keyPath: key]
            if candidate == name { return self[mid] }
            if candidate.utf8.lexicographicallyPrecedes(name.utf8) { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }
}

// MARK: - Decoding

/// Decodes one entry blob. Strings are interned per decode so repeated texts
/// (`str`, `SupportsIndex`, `int | None`) share one heap buffer, and the
/// approximate retained size is accumulated in `cost` for the store's LRU.
struct TypeTableDecoder {
    struct Malformed: Error {}

    private let table: MappedTypeTable
    private let section: TypeTableSection
    private var p: UnsafeRawPointer
    private let end: UnsafeRawPointer
    private var interned: [Int: String] = [:]
    private(set) var cost = 0

    init(table: MappedTypeTable, section: TypeTableSection, blob: UnsafeRawBufferPointer) {
        self.table = table
        self.section = section
        self.p = blob.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!
        self.end = p + blob.count
    }

    var isAtEnd: Bool { p == end }

    mutating func varint() throws -> Int {
        var result = 0, shift = 0
        while true {
            guard p < end, shift < 63 else { throw Malformed() }
            let byte = p.load(as: UInt8.self)
            p += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func string() throws -> String {
        let id = try varint()
        if id == 0 { return "" }
        if let s = interned[id] { return s }
        guard let s = table.string(section, id) else { throw Malformed() }
        interned[id] = s
        // Swift stores up to 15 UTF-8 bytes inline; longer strings own a heap
        // buffer (header + bytes, malloc-rounded).
        if s.utf8.count > 15 { cost += (s.utf8.count + 32 + 15) & ~15 }
        return s
    }

    mutating func optionalString() throws -> String? {
        let s = try string()
        return s.isEmpty ? nil : s
    }

    mutating func count() throws -> Int {
        let n = try varint()
        // Every element takes at least one byte, so a count can never exceed
        // the remaining blob; rejects corrupt lengths before allocating.
        guard n <= end - p else { throw Malformed() }
        return n
    }

    mutating func array<T>(_ element: (inout TypeTableDecoder) throws -> T) throws -> [T] {
        let n = try count()
        if n == 0 { return [] }
        var out: [T] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try element(&self)) }
        cost += 32 + n * MemoryLayout<T>.stride
        return out
    }

    // MARK: Records

    mutating func typeParameter() throws -> TypeTable.TypeParameter {
        let name = try string(), bound = try optionalString(), def = try optionalString()
        let kind = try varint()
        return TypeTable.TypeParameter(name: name, bound: bound, defaultType: def,
                                       kind: TypeTable.TypeParameter.Kind(rawValue: UInt8(kind & 3)) ?? .typeVar,
                                       boundIsConstraints: kind & 4 != 0)
    }

    mutating func signature() throws -> TypeTable.Signature {
        let flags = try varint()
        let tps = try array { try $0.typeParameter() }
        let params = try array { d -> TypeTable.Parameter in
            let name = try d.string(), kind = try d.varint(), type = try d.optionalString()
            return TypeTable.Parameter(name: name, kind: TypeTable.Parameter.Kind(rawValue: UInt8(kind & 7)) ?? .positional,
                                       type: type, hasDefault: kind & 8 != 0)
        }
        let returns = try optionalString()
        return TypeTable.Signature(isAsync: flags & 1 != 0, typeParameters: tps, parameters: params, returnType: returns)
    }

    mutating func classDecl() throws -> TypeTable.ClassDecl {
        let name = try string()
        let flags = try varint()
        let tps = try array { try $0.typeParameter() }
        let bases = try array { try $0.string() }
        let members = try array { d -> TypeTable.Member in
            let name = try d.string(), kindFlags = try d.varint(), type = try d.optionalString()
            let overloads = try d.array { try $0.signature() }
            return TypeTable.Member(name: name, kind: TypeTable.Member.Kind(rawValue: UInt8(kindFlags & 0xF)) ?? .field,
                                    flags: TypeTable.MemberFlags(rawValue: UInt32(truncatingIfNeeded: kindFlags >> 4)),
                                    type: type, overloads: overloads)
        }
        let calls = try array { try $0.signature() }
        let constructs = try array { try $0.signature() }
        let indexes = try array { d -> TypeTable.IndexSignature in
            TypeTable.IndexSignature(keyName: try d.string(), keyType: try d.string(),
                                     valueType: try d.string(), isReadonly: try d.varint() & 1 != 0)
        }
        return TypeTable.ClassDecl(name: name, flags: TypeTable.ClassFlags(rawValue: UInt32(truncatingIfNeeded: flags)),
                                   typeParameters: tps, bases: bases, members: members, callSignatures: calls,
                                   constructSignatures: constructs, indexSignatures: indexes)
    }

    mutating func function() throws -> TypeTable.Function {
        let name = try string()
        return try functionBody(name: name)
    }

    mutating func functionBody(name: String) throws -> TypeTable.Function {
        let flags = try varint()
        let overloads = try array { try $0.signature() }
        return TypeTable.Function(name: name, flags: TypeTable.MemberFlags(rawValue: UInt32(truncatingIfNeeded: flags)),
                                  overloads: overloads)
    }

    mutating func aliasBody(name: String) throws -> TypeTable.Alias {
        let tps = try array { try $0.typeParameter() }
        return TypeTable.Alias(name: name, typeParameters: tps, type: try string())
    }

    // MARK: Entries

    mutating func pythonModule(name: String) throws -> PythonModuleStub {
        let flags = try varint()
        let all = try array { try $0.string() }
        let imports = try array { d -> PythonModuleStub.Import in
            let local = try d.string(), module = try d.string(), original = try d.optionalString()
            return PythonModuleStub.Import(localName: local, module: module, originalName: original,
                                           isReexport: try d.varint() & 1 != 0)
        }
        let stars = try array { try $0.string() }
        let typeVars = try array { try $0.typeParameter() }
        let aliases = try array { d -> TypeTable.Alias in try d.aliasBody(name: try d.string()) }
        let variables = try array { d -> TypeTable.Variable in
            TypeTable.Variable(name: try d.string(), type: try d.optionalString(), isConstant: try d.varint() & 1 != 0)
        }
        let functions = try array { try $0.function() }
        let classes = try array { try $0.classDecl() }
        guard isAtEnd else { throw Malformed() }
        cost += MemoryLayout<PythonModuleStub>.stride
        return PythonModuleStub(name: name, isPackage: flags & 1 != 0, all: flags & 2 != 0 ? all : nil,
                                imports: imports, starImports: stars, typeVars: typeVars, aliases: aliases,
                                variables: variables, functions: functions, classes: classes)
    }

    mutating func tsSymbol(name: String, section: TSGlobalSymbol.Section) throws -> TSGlobalSymbol {
        let flags = try varint()
        let interface = flags & 1 != 0 ? try classDecl() : nil
        var variable: TypeTable.Variable?
        if flags & 2 != 0 {
            variable = TypeTable.Variable(name: name, type: try optionalString(), isConstant: try varint() & 1 != 0)
        }
        let function = flags & 4 != 0 ? try functionBody(name: name) : nil
        let alias = flags & 8 != 0 ? try aliasBody(name: name) : nil
        let namespace = flags & 16 != 0 ? try array { try $0.string() } : nil
        guard isAtEnd else { throw Malformed() }
        cost += MemoryLayout<TSGlobalSymbol>.stride
        return TSGlobalSymbol(name: name, section: section, interface: interface, isClass: flags & 32 != 0,
                              variable: variable, function: function, alias: alias, namespaceMembers: namespace,
                              isDOMAugmented: flags & 64 != 0)
    }
}
