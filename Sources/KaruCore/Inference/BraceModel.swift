import Foundation

// M17 T17.11d — the document's types for the statically typed brace
// languages, read from the declaration snapshot (class scopes and their
// members) and the code tokens around them: what each type is, its bodies
// (Swift extensions, Rust `impl` blocks, C# partial parts), its bases and
// its members with their modifiers, written types and signature summaries.
// Plan §8.1: members come from same-named type declarations of this file
// and — T17.14 — of the other files of the project folder
// (`BraceForeignResolver`: types not declared here, extensions / `impl`s /
// Go methods / C# partial parts of types declared here, bases).

/// One member of a document type.
struct BraceMember: Sendable {
    let name: String
    var kind: InferredMemberKind
    var isStatic: Bool
    var access: BraceAccess
    var isEnumCase = false
    /// A field's written type, a method's (first) result.
    var type: BraceWrittenType?
    var results: [BraceWrittenType?] = []
    /// Swift `let x = Foo()` fields: the initializer's live range.
    var initializer: Range<Int>?
    var detail: String?
    /// Snapshot offset of the name (`BraceModuleView.foreignLocation` for a
    /// member read from another file).
    var location: Int
    /// Read from another file of the project folder (T17.14): private /
    /// file-private members are not visible from this file.
    var isForeign = false

    var approximateBytes: Int {
        96 + name.utf8.count * 2 + (detail?.utf8.count ?? 0) + (type?.text.utf8.count ?? 0) * 2
    }
}

/// A type declared in the document.
final class BraceTypeInfo {
    struct Body {
        let scope: DeclarationQueryIndex.PositionedScope
        /// `impl Trait for T`: the trait.
        var trait: BraceWrittenType?
    }

    struct Base {
        let type: BraceWrittenType
        /// Snapshot offset whose scope resolves the base's name.
        let context: Int
        /// C++ inheritance access (`private` / `protected` bases).
        let access: BraceAccess
    }

    let id: Int
    let name: String
    /// `struct`, `class`, `enum`, `protocol`, `interface`, `trait`, `union`,
    /// `record`, `actor`; `.type` for a Go defined type without a body.
    let keyword: DeclKeyword
    /// The primary declaration's body (nil: a Go defined type).
    let primary: DeclarationQueryIndex.PositionedScope?
    /// Snapshot offset of the declared name.
    let location: Int
    /// Scopes enclosing the declaration (outermost first, module excluded).
    let containers: [DeclarationScan.ScopeRecord]
    /// Names of the enclosing class scopes (types, namespaces).
    let containerNames: [String]
    var bodies: [Body] = []
    var bases: [Base] = []
    var isPartial = false
    /// A type declared in another file of the project folder (T17.14).
    var isForeign = false
    /// Members read from other files (a foreign type's own, or the
    /// extensions / `impl`s / Go methods / partial parts of a type of this
    /// file found elsewhere), listed before this file's bodies.
    var foreignMembers: [BraceMember] = []
    /// Own members (all bodies), filled on first use.
    var members: [BraceMember]?
    var byName: [String: Int] = [:]

    init(id: Int, name: String, keyword: DeclKeyword, primary: DeclarationQueryIndex.PositionedScope?, location: Int,
         containers: [DeclarationScan.ScopeRecord], containerNames: [String]) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.primary = primary
        self.location = location
        self.containers = containers
        self.containerNames = containerNames
    }

    var isInterfaceLike: Bool { keyword == .protocol || keyword == .interface || keyword == .trait }
    var isValueType: Bool { keyword == .struct || keyword == .enum }

    var approximateBytes: Int {
        160 + name.utf8.count + containers.count * 48 + bodies.count * 64 + bases.count * 96
            + foreignMembers.reduce(0) { $0 + $1.approximateBytes }
            + (members?.reduce(0) { $0 + $1.approximateBytes } ?? 0) + byName.count * 48
    }
}

/// What the head of a class scope declares (T17.11d).
struct BraceScopeHead {
    enum Role { case primary, `extension`, namespace, other }
    var role: Role = .other
    var keyword: DeclKeyword = .none
    /// The declared / extended path (`Outer.Inner` for `extension Outer.Inner`).
    var path: [String] = []
    var trait: BraceWrittenType?
    var bases: [(BraceWrittenType, BraceAccess)] = []
    var isPartial = false
    /// Snapshot offset of the name token (primary types).
    var nameLocation: Int?
}

/// The document model of one declaration snapshot (T17.11d): the type
/// registry and its caches. Owned by `TypeInferenceService`; rebuilt for a
/// new snapshot version; its text-derived caches are dropped when the
/// journal records another edit.
final class BraceModuleView {
    let language: BraceLanguage
    let version: UInt64
    let index: DeclarationQueryIndex
    var scan: DeclarationScan { index.scan }
    /// Edits since the snapshot (live ↔ snapshot offsets).
    private(set) var journal: EditJournal
    private(set) var reader: BraceTokenReader
    private(set) var decls: BraceDeclReader
    var budget = InferenceBudget()
    /// Cross-file types of the project folder (T17.14); nil: this file only.
    var foreign: BraceForeignResolver?
    /// The context offset of what was read from another file: names in it
    /// resolve against the other files first, then this file's top level.
    static let foreignLocation = -1

    // Structural (per snapshot version).
    private var classNameCache: [String: Int?] = [:]
    private var goMethodCache: [String: [Int]] = [:]

    // Text-derived (per journal state).
    private(set) var types: [BraceTypeInfo] = []
    private var primaryCache: [String: [Int]] = [:]
    private var headCache: [Int: BraceScopeHead] = [:]
    private var scopeType: [Int: Int?] = [:]
    var bindingValues: [Int: BraceValue] = [:]
    var bindingCache: [Int: [String: DeclarationScan.ScopedBinding]] = [:]
    private var functionHeads: [Int: BraceDeclInfo] = [:]
    private var lineageCache: [Int: [(id: Int, rank: Int, access: BraceAccess)]] = [:]
    /// Written path (and C tag) → the foreign type registered for it.
    private var foreignTypeCache: [String: Int?] = [:]

    private(set) var statistics = (bodiesRead: 0, typesBuilt: 0, classNamesNanoseconds: UInt64(0),
                                   goMethodsNanoseconds: UInt64(0))

    init(language: BraceLanguage, version: UInt64, index: DeclarationQueryIndex, journal: EditJournal,
         reader: BraceTokenReader) {
        self.language = language
        self.version = version
        self.index = index
        self.journal = journal
        self.reader = reader
        decls = BraceDeclReader(reader: reader)
    }

    /// A new live text state for the same snapshot: text-derived caches are
    /// dropped when the edits changed.
    func update(journal: EditJournal, reader: BraceTokenReader) {
        if journal != self.journal { dropTextDerivedCaches() }
        self.journal = journal
        self.reader = reader
        decls = BraceDeclReader(reader: reader)
    }

    /// Forgets everything read from the text (another edit, or a request cut
    /// short by its budget, whose partial results must not be reused).
    func dropTextDerivedCaches() {
        types = []
        primaryCache = [:]
        headCache = [:]
        scopeType = [:]
        bindingValues = [:]
        bindingCache = [:]
        functionHeads = [:]
        lineageCache = [:]
        anonymous = [:]
        foreignTypeCache = [:]
    }

    var approximateBytes: Int {
        var n = 256
        n += classNameCache.count * 64
        n += goMethodCache.reduce(0) { $0 + 64 + $1.value.count * 8 }
        n += types.reduce(0) { $0 + $1.approximateBytes }
        n += primaryCache.count * 64 + headCache.count * 160 + scopeType.count * 24
        n += bindingValues.count * 64 + bindingCache.reduce(0) { $0 + 48 + $1.value.count * 72 }
        n += functionHeads.count * 160
        return n
    }

    // MARK: - Offsets

    func live(_ snapshotOffset: Int) -> Int? { journal.mapFromBase(snapshotOffset) }
    func base(_ liveOffset: Int) -> Int? { journal.mapToBase(liveOffset) }

    func tick() -> Bool { budget.tick() }

    // MARK: - Scopes

    func chain(at offset: Int) -> [DeclarationQueryIndex.PositionedScope] {
        offset < 0 ? [] : index.positionedChain(at: offset)
    }

    func contains(_ scope: DeclarationScan.ScopeRecord, _ offset: Int) -> Bool { scan.contains(scope, offset) }

    func scopeName(_ record: DeclarationScan.ScopeRecord) -> String? {
        record.name >= 0 && record.name < scan.names.count ? scan.names[record.name] : nil
    }

    /// The declaration named like a function scope, nearest before its start
    /// (Go: inside it, after the receiver).
    func functionDeclaration(of scope: DeclarationScan.ScopeRecord)
        -> (location: Int, kind: DeclarationScan.DeclarationKind)? {
        guard let name = scopeName(scope) else { return nil }
        var best: (Int, DeclarationScan.DeclarationKind)?
        let to = language == .go ? min(scope.end, scope.start + 1024) : scope.start + 1
        scan.forEachDeclaration(from: max(0, scope.start - 1024), to: to) { location, n, kind in
            guard n == name, kind == .function || kind == .method else { return }
            if language == .go {
                if location >= scope.start, best == nil { best = (location, kind) }
            } else if location < scope.start {
                best = (location, kind)
            }
        }
        return best
    }

    // MARK: - Reading declarations

    /// Tokens around the declaration whose name is at snapshot `location`
    /// and the name's index in them: its line, extended by up to `extra`
    /// units while the statement continues (open brackets, a trailing
    /// operator or comma).
    func tokens(atDeclaration location: Int, extra: Int = 2048) -> ([DeclToken], Int)? {
        guard let at = live(location) else { return nil }
        return BraceSummary.tokens(reader: reader, atName: at, extra: extra)
    }

    /// The declaration info of a function / method (cached).
    func functionInfo(at location: Int, kind: DeclarationScan.DeclarationKind) -> BraceDeclInfo? {
        if let cached = functionHeads[location] { return cached }
        guard let (tk, n) = tokens(atDeclaration: location) else { return nil }
        let info = decls.read(tk, name: n, kind: kind)
        functionHeads[location] = info
        return info
    }

    // MARK: - Class scope heads

    private func isPrimaryKeyword(_ k: DeclKeyword) -> Bool {
        switch k {
        case .struct, .class, .enum, .protocol, .interface, .trait, .union, .record, .actor: return true
        default: return false
        }
    }

    /// What the class scope `scope` (snapshot) is.
    func head(of scope: DeclarationQueryIndex.PositionedScope) -> BraceScopeHead {
        if let cached = headCache[scope.record.index] { return cached }
        let head = readHead(scope)
        headCache[scope.record.index] = head
        return head
    }

    private func readHead(_ scope: DeclarationQueryIndex.PositionedScope) -> BraceScopeHead {
        var head = BraceScopeHead()
        let record = scope.record
        guard let name = scopeName(record) ?? (record.name < 0 ? "" : nil),
              let scopeStart = live(record.start) else { return head }
        // The declared name right before the scope (the scope opens at the
        // token after it); none for `impl` blocks.
        var nameLocation: Int?
        if !name.isEmpty {
            let length = name.utf16.count
            scan.forEachDeclaration(from: max(0, record.start - 512), to: record.start) { location, n, kind in
                guard n == name, kind == .class || kind == .type, location + length <= record.start else { return }
                if let from = live(location + length), let to = live(record.start), to >= from,
                   to - from < 256, isBlank(from: from, to: to) {
                    nameLocation = location
                }
            }
        }
        let anchor = nameLocation.flatMap { live($0) } ?? scopeStart
        let text = reader.text
        let scopeEnd = live(record.end).map { min($0, text.length) } ?? text.length
        var limit = min(scopeEnd, max(scopeStart, anchor) + 512)
        var tk = reader.tokens(anchor: anchor, to: limit)
        var open = tk.firstIndex { $0.kind == .lbrace && $0.start >= scopeStart }
        if open == nil, limit < scopeEnd {
            limit = min(scopeEnd, max(scopeStart, anchor) + 8192)
            tk = reader.tokens(anchor: anchor, to: limit)
            open = tk.firstIndex { $0.kind == .lbrace && $0.start >= scopeStart }
        }
        let headEnd = open ?? tk.count
        let types = decls.types
        if let nameLocation, let at = live(nameLocation) {
            let n = BraceTokens.index(atOrAfter: at, in: tk)
            guard n < tk.count, tk[n].start == at else { return head }
            head.nameLocation = nameLocation
            head.path = [name]
            var k = n + 1
            if language == .go {
                if k < headEnd, tk[k].kind == .lbracket, let m = BraceTokens.matching(tk, k, limit: headEnd) { k = m + 1 }
                guard k < headEnd else { return head }
                head.keyword = tk[k].keyword == .interface ? .interface : tk[k].keyword == .struct ? .struct : .none
                head.role = head.keyword == .none ? .other : .primary
                return head
            }
            var kw = n > 0 ? tk[n - 1].keyword : .none
            if (kw == .class || kw == .struct), n > 1, tk[n - 2].keyword == .enum { kw = .enum }
            if kw == .extension {
                head.role = .extension
                head.keyword = .extension
                // `extension Outer.Inner`
                var j = n + 1
                while j + 1 < headEnd, types.isPlainDot(tk[j]), tk[j + 1].kind == .ident {
                    head.path.append(reader.string(tk[j + 1]))
                    j += 2
                }
                k = j
            } else if kw == .namespace {
                head.role = .namespace
                head.keyword = .namespace
                return head
            } else if isPrimaryKeyword(kw) {
                head.role = .primary
                head.keyword = kw
            } else {
                return head
            }
            var info = BraceDeclInfo()
            decls.modifiers(tk, from: max(0, n - 8), to: n, into: &info)
            head.isPartial = info.isPartial
            // Generic parameters.
            if k < headEnd, tk[k].kind == .less, let m = BraceTokens.matchingAngle(tk, k, end: headEnd) { k = m + 1 }
            if k < headEnd, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: headEnd) { k = m + 1 }
            head.bases = readBases(tk, from: k, to: headEnd, keyword: head.keyword)
            return head
        }
        // `impl<…> [Trait for] Type [where …] {` (Rust).
        guard language == .rust else { return head }
        let first = BraceTokens.index(atOrAfter: scopeStart, in: tk)
        guard first > 0, tk[first - 1].keyword == .impl else { return head }
        var k = first
        if k < headEnd, tk[k].kind == .less, let m = BraceTokens.matchingAngle(tk, k, end: headEnd) { k = m + 1 }
        guard case .type(let firstType, let afterFirst)? = types.parse(tk, k, headEnd) else { return head }
        var target = firstType
        if afterFirst < headEnd, tk[afterFirst].keyword == .for,
           case .type(let implemented, _)? = types.parse(tk, afterFirst + 1, headEnd) {
            head.trait = firstType
            target = implemented
        }
        guard target.isNominal, target.name == name else { return head }
        head.role = .extension
        head.keyword = .impl
        head.path = target.path
        return head
    }

    private func isBlank(from: Int, to: Int) -> Bool {
        let text = reader.text
        var i = from
        while i < to {
            let u = text.character(at: i)
            guard u == 32 || u == 9 || u == 10 || u == 13 else { return false }
            i += 1
        }
        return true
    }

    /// Base clauses after a type name.
    private func readBases(_ tk: [DeclToken], from: Int, to: Int, keyword: DeclKeyword) -> [(BraceWrittenType, BraceAccess)] {
        var out: [(BraceWrittenType, BraceAccess)] = []
        let types = decls.types
        var k = from
        func list(_ start: Int, separators: Set<String>, cpp: Bool) -> Int {
            var j = start
            while j < to {
                var access: BraceAccess = keyword == .struct ? .public : (cpp ? .private : .public)
                while j < to, tk[j].keyword == .public || tk[j].keyword == .private || tk[j].keyword == .protected
                    || tk[j].keyword == .virtual {
                    switch tk[j].keyword {
                    case .public: access = .public
                    case .private: access = .private
                    case .protected: access = .protected
                    default: break
                    }
                    j += 1
                }
                guard case .type(let type, let e)? = types.parse(tk, j, to) else { return j }
                if type.isNominal { out.append((type, access)) }
                j = e
                guard j < to, tk[j].kind == .comma || tk[j].kind == .op && separators.contains(reader.string(tk[j]))
                else { return j }
                j += 1
            }
            return j
        }
        switch language {
        case .swift, .csharp, .cpp:
            guard k < to, tk[k].kind == .colon else { return out }
            _ = list(k + 1, separators: [], cpp: language == .cpp)
        case .rust:
            guard k < to, tk[k].kind == .colon else { return out }
            _ = list(k + 1, separators: ["+"], cpp: false)
        case .java:
            while k < to {
                if tk[k].keyword == .extends || tk[k].keyword == .implements {
                    k = list(k + 1, separators: [], cpp: false)
                } else {
                    k += 1
                }
            }
        case .go, .c:
            break
        }
        return out
    }

    // MARK: - Type registry

    func classNameIndex(_ name: String) -> Int? {
        if let cached = classNameCache[name] { return cached }
        let started = DispatchTime.now().uptimeNanoseconds
        let found = index.classNameIndex(named: name)
        statistics.classNamesNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- started
        classNameCache[name] = .some(found)
        return found
    }

    /// The types primarily declared with `name` (cached).
    func primaryTypes(named name: String) -> [Int] {
        if let cached = primaryCache[name] { return cached }
        primaryCache[name] = []
        var ids: [Int] = []
        var extensions: [(DeclarationQueryIndex.PositionedScope, BraceScopeHead)] = []
        if let nameIndex = classNameIndex(name) {
            for scope in index.classScopes(nameIndex: nameIndex) {
                guard tick() else { break }
                let head = head(of: scope)
                switch head.role {
                case .primary:
                    let chainRecords = chain(at: scope.record.start).map(\.record).filter { $0.index != scope.record.index }
                    let containers = Array(chainRecords.dropFirst())
                    let containerNames = containers.filter { $0.kind == .class }.compactMap(scopeName)
                    // C# partial parts (and Swift / Go duplicates) with the same container merge.
                    if let existing = ids.first(where: { types[$0].containerNames == containerNames
                        && types[$0].containers.map(\.index) == containers.map(\.index) }),
                       head.isPartial || types[existing].isPartial {
                        types[existing].bodies.append(BraceTypeInfo.Body(scope: scope, trait: nil))
                        types[existing].bases += head.bases.map {
                            BraceTypeInfo.Base(type: $0.0, context: scope.record.start, access: $0.1)
                        }
                        continue
                    }
                    let info = BraceTypeInfo(id: types.count, name: name, keyword: head.keyword, primary: scope,
                                             location: head.nameLocation ?? scope.record.start,
                                             containers: containers, containerNames: containerNames)
                    info.isPartial = head.isPartial
                    info.bodies = [BraceTypeInfo.Body(scope: scope, trait: nil)]
                    info.bases = head.bases.map { BraceTypeInfo.Base(type: $0.0, context: scope.record.start, access: $0.1) }
                    types.append(info)
                    ids.append(info.id)
                    statistics.typesBuilt += 1
                case .extension:
                    extensions.append((scope, head))
                default:
                    break
                }
            }
        }
        // Swift `extension Outer.Inner` lives in scopes named `Outer`.
        if language == .swift {
            for id in ids where !types[id].containerNames.isEmpty {
                guard let outer = types[id].containerNames.first, let outerIndex = classNameIndex(outer) else { continue }
                for scope in index.classScopes(nameIndex: outerIndex) {
                    let head = head(of: scope)
                    if head.role == .extension, head.path.count > 1, head.path.last == name {
                        extensions.append((scope, head))
                    }
                }
            }
        }
        if ids.isEmpty, language == .go, let binding = index.moduleBinding(named: name), binding.kind == .type,
           let goType = goDefinedType(name: name, location: binding.location) {
            ids.append(goType)
        }
        for (scope, head) in extensions {
            // The extended type: the path's qualifiers must match its containers.
            let qualifiers = Array(head.path.dropLast())
            let matches = ids.filter { id in
                let t = types[id]
                if qualifiers.isEmpty { return t.containers.allSatisfy { contains($0, scope.record.start) } }
                return t.containerNames.count >= qualifiers.count
                    && Array(t.containerNames.suffix(qualifiers.count)) == qualifiers
            }
            guard matches.count == 1 else { continue }
            let t = types[matches[0]]
            t.bodies.append(BraceTypeInfo.Body(scope: scope, trait: head.trait))
            t.bases += head.bases.map { BraceTypeInfo.Base(type: $0.0, context: scope.record.start, access: $0.1) }
            if let trait = head.trait {
                t.bases.append(BraceTypeInfo.Base(type: trait, context: scope.record.start, access: .public))
            }
        }
        // Extensions, `impl`s, Go methods and partial parts in other files (T17.14).
        if let foreign {
            for id in ids where types[id].containers.allSatisfy(isNamespaceScope) {
                let t = types[id]
                guard let parts = foreign.extensions(of: name, isPartial: t.isPartial,
                                                     namespaces: t.containerNames) else { continue }
                t.foreignMembers += parts.members
                t.bases += parts.bases.map { BraceTypeInfo.Base(type: $0.type, context: Self.foreignLocation, access: $0.access) }
            }
        }
        primaryCache[name] = budget.exhausted ? nil : ids
        return ids
    }

    /// Whether the class scope `record` is a C# / C++ namespace body (the
    /// walker opens it at the `{` after `namespace A.B`; no declaration
    /// names it).
    func isNamespaceScope(_ record: DeclarationScan.ScopeRecord) -> Bool {
        guard record.kind == .class, language == .csharp || language == .cpp, let start = live(record.start),
              start <= reader.text.length else { return false }
        let from = max(0, start - 256)
        let before = reader.text.substring(with: NSRange(location: from, length: start - from))
        guard let range = before.range(of: "namespace", options: .backwards) else { return false }
        let rest = before[range.upperBound...]
        guard let first = rest.first, first == " " || first == "\t" || first == "\n" || first == "\r" else { return false }
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == ":" || $0.isWhitespace }
    }

    /// Registers a type that is not a declaration of this file (a foreign
    /// type, or one built from another file's parts); returns its id.
    func appendType(_ info: (Int) -> BraceTypeInfo) -> Int {
        let built = info(types.count)
        types.append(built)
        return built.id
    }

    /// A Go `type Name T` without a body of its own (its methods only).
    private func goDefinedType(name: String, location: Int) -> Int? {
        guard let (tk, n) = tokens(atDeclaration: location, extra: 256), n > 0, tk[n - 1].keyword == .type
            || tk[n - 1].kind == .lparen || tk[n].isLineStart else { return nil }
        guard n + 1 < tk.count, tk[n + 1].kind != .assign, !tk[n + 1].isLineStart else { return nil }
        let containers = Array(chain(at: location).map(\.record).dropFirst())
        let info = BraceTypeInfo(id: types.count, name: name, keyword: .type, primary: nil, location: location,
                                 containers: containers, containerNames: [])
        types.append(info)
        return info.id
    }

    /// The type a class scope belongs to (a primary declaration or the type
    /// an extension / `impl` extends); nil for namespaces and unknowns.
    func type(ofScope scope: DeclarationQueryIndex.PositionedScope) -> Int? {
        if let cached = scopeType[scope.record.index] { return cached }
        var result: Int?
        let head = head(of: scope)
        if head.role == .primary || head.role == .extension, let name = head.path.last {
            for id in primaryTypes(named: name)
            where types[id].bodies.contains(where: { $0.scope.record.index == scope.record.index }) {
                result = id
            }
            // An extension / `impl` of a type declared in another file (T17.14).
            if result == nil, head.role == .extension, foreign != nil {
                var written = BraceWrittenType()
                written.path = head.path
                if let id = foreignType(written),
                   types[id].bodies.contains(where: { $0.scope.record.index == scope.record.index }) {
                    result = id
                }
            }
        }
        scopeType[scope.record.index] = result
        return result
    }

    /// The type named by `path` as seen from snapshot offset `context`.
    func resolveType(_ written: BraceWrittenType, context: Int, depth: Int = 0) -> Int? {
        guard written.isNominal, depth < 8, tick() else { return nil }
        let path = written.path
        let name = path[path.count - 1]
        if path.count == 1, name == "Self", language == .swift || language == .rust {
            return enclosingTypes(at: context).first
        }
        // A type read from another file names its types from there first.
        if context == Self.foreignLocation, let id = foreignType(written) { return id }
        var candidates = primaryTypes(named: name).filter { id in
            let t = types[id]
            if language == .c {
                // C: tags only through `struct x`, typedef names otherwise.
                guard written.tag else { return false }
                return t.keyword == .struct || t.keyword == .union || t.keyword == .enum
            }
            if path.count > 1 {
                let qualifiers = Array(path.dropLast())
                return t.containerNames.count >= qualifiers.count
                    && Array(t.containerNames.suffix(qualifiers.count)) == qualifiers
            }
            return t.containers.allSatisfy { contains($0, context) }
        }
        if candidates.count > 1 {
            // The most deeply nested visible declaration.
            let deepest = candidates.map { types[$0].containers.count }.max() ?? 0
            candidates = candidates.filter { types[$0].containers.count == deepest }
        }
        if candidates.count == 1 { return candidates[0] }
        if !candidates.isEmpty { return nil }
        // Aliases: `typedef`, `typealias`, `type X = …`, `using X = …`.
        guard path.count == 1 else { return foreignType(written) }
        if let alias = aliasTarget(name: name, tag: written.tag, context: context, depth: depth) { return alias }
        // Declared in another file of the project folder (T17.14).
        return context == Self.foreignLocation ? nil : foreignType(written)
    }

    /// The type `written` names in the other files of the project folder
    /// (T17.14), registered once per written path; nil when none, ambiguous
    /// or still loading (`foreign.hasPending`). Extension / `impl` bodies of
    /// this file are attached to it.
    func foreignType(_ written: BraceWrittenType) -> Int? {
        guard let foreign, written.isNominal else { return nil }
        let key = written.path.joined(separator: "\u{1}") + (written.tag ? "\u{2}" : "")
        if let cached = foreignTypeCache[key] { return cached }
        foreignTypeCache[key] = .some(nil)   // cycle guard
        guard let merged = foreign.type(path: written.path, tag: written.tag) else { return nil }
        let id = appendType { id in
            let info = BraceTypeInfo(id: id, name: merged.name, keyword: merged.keyword, primary: nil,
                                     location: Self.foreignLocation, containers: [],
                                     containerNames: merged.typeContainers)
            info.isForeign = true
            info.foreignMembers = merged.members
            info.bases = merged.bases.map { BraceTypeInfo.Base(type: $0.type, context: Self.foreignLocation, access: $0.access) }
            return info
        }
        foreignTypeCache[key] = .some(id)
        // This file's extensions / `impl`s of it (role `.extension`, same name).
        if let nameIndex = classNameIndex(merged.name) {
            for scope in index.classScopes(nameIndex: nameIndex) {
                let head = head(of: scope)
                guard head.role == .extension, head.path.last == merged.name,
                      head.path.count == 1 || Array(head.path.dropLast()) == Array(written.path.dropLast()) else { continue }
                types[id].bodies.append(BraceTypeInfo.Body(scope: scope, trait: head.trait))
                types[id].bases += head.bases.map { BraceTypeInfo.Base(type: $0.0, context: scope.record.start, access: $0.1) }
                if let trait = head.trait {
                    types[id].bases.append(BraceTypeInfo.Base(type: trait, context: scope.record.start, access: .public))
                }
            }
        }
        return id
    }

    private func aliasTarget(name: String, tag: Bool, context: Int, depth: Int) -> Int? {
        if language == .c, tag { return nil }
        guard let binding = index.moduleBinding(named: name) else { return nil }
        var location = binding.location
        if binding.kind != .type {
            // `typedef struct tag { … } tag;`: the module binding is the tag;
            // the typedef follows its body.
            guard language == .c, binding.kind == .class else { return nil }
            var found: Int?
            for id in primaryTypes(named: name) {
                guard let body = types[id].primary?.record else { continue }
                scan.forEachDeclaration(from: max(0, body.end - 1), to: body.end + 256) { at, n, kind in
                    if found == nil, n == name, kind == .type { found = at }
                }
            }
            guard let found else { return nil }
            location = found
        }
        guard let (tk, n) = tokens(atDeclaration: location, extra: 512) else { return nil }
        let types = decls.types
        switch language {
        case .c, .cpp:
            if n + 1 < tk.count, tk[n + 1].kind == .assign, n > 0, tk[n - 1].keyword == .using {
                guard case .type(let target, _)? = types.parse(tk, n + 2, tk.count) else { return nil }
                return resolveType(target, context: location, depth: depth + 1)
            }
            // `typedef T Name;` — find `typedef` back on the line(s) read.
            var stars = 0
            var k = n - 1
            while k >= 0, tk[k].kind == .star { stars += 1; k -= 1 }
            if k >= 0, tk[k].kind == .rbrace {
                // `typedef struct [tag] { … } Name;`: the body just closed.
                guard let liveBrace = Optional(tk[k].start), let snapshotBrace = base(liveBrace) else { return nil }
                guard stars == 0 else { return nil }
                let bodies = chain(at: snapshotBrace).filter { $0.record.kind == .class }
                guard let body = bodies.last else { return nil }
                if body.record.name >= 0, let tagName = scopeName(body.record) {
                    var written = BraceWrittenType()
                    written.path = [tagName]
                    written.tag = true
                    return resolveType(written, context: context, depth: depth + 1)
                }
                return anonymousType(name: name, scope: body, location: location)
            }
            guard let typedef = tk[..<n].lastIndex(where: { $0.keyword == .typedef }),
                  case .type(var target, let e)? = types.parse(tk, typedef + 1, n), e <= n else { return nil }
            target.pointer += stars
            guard target.pointer == 0 else { return nil }
            return resolveType(target, context: location, depth: depth + 1)
        case .swift, .rust, .go:
            guard n + 1 < tk.count, tk[n + 1].kind == .assign,
                  case .type(let target, _)? = types.parse(tk, n + 2, tk.count), target.pointer == 0,
                  !target.optional else { return nil }
            return resolveType(target, context: location, depth: depth + 1)
        case .java, .csharp:
            return nil
        }
    }

    private var anonymous: [Int: Int] = [:]

    private func anonymousType(name: String, scope: DeclarationQueryIndex.PositionedScope, location: Int) -> Int? {
        if let id = anonymous[scope.record.index] { return id }
        let containers = Array(chain(at: scope.record.start).map(\.record).dropFirst().dropLast())
        let info = BraceTypeInfo(id: types.count, name: name, keyword: .struct, primary: scope, location: location,
                                 containers: containers, containerNames: [])
        info.bodies = [BraceTypeInfo.Body(scope: scope, trait: nil)]
        types.append(info)
        anonymous[scope.record.index] = info.id
        return info.id
    }

    /// Types enclosing snapshot offset `offset`, innermost first: class
    /// scopes (types, extensions, `impl`s) and — C++ — the owner of an
    /// out-of-class member definition.
    func enclosingTypes(at offset: Int) -> [Int] {
        var out: [Int] = []
        let chain = chain(at: offset)
        for scope in chain.reversed() where scope.record.kind == .class {
            if let id = type(ofScope: scope), !out.contains(id) { out.append(id) }
        }
        if out.isEmpty, language == .cpp,
           let function = chain.last(where: { $0.record.kind == .function }),
           let owner = memberDefinitionOwner(function.record) {
            out.append(owner)
        }
        return out
    }

    /// C++ `R Owner::name(…) { … }`: the owner type.
    func memberDefinitionOwner(_ scope: DeclarationScan.ScopeRecord) -> Int? {
        guard language == .cpp, let decl = functionDeclaration(of: scope),
              let info = functionInfo(at: decl.location, kind: decl.kind), !info.owner.isEmpty else { return nil }
        var written = BraceWrittenType()
        written.path = info.owner
        return resolveType(written, context: decl.location)
    }

    // MARK: - Go methods

    /// Go: the locations of the methods whose receiver's base type is
    /// `name` (`func (r T) m` / `func (r *T[P]) m`), cached per snapshot.
    /// Each `.method` declaration's receiver is compared in the text,
    /// without allocating.
    func goMethods(of name: String) -> [Int] {
        if let cached = goMethodCache[name] { return cached }
        let started = DispatchTime.now().uptimeNanoseconds
        defer { statistics.goMethodsNanoseconds &+= DispatchTime.now().uptimeNanoseconds &- started }
        let text = reader.text
        let units = Array(name.utf16)
        var out: [Int] = []
        scan.forEachDeclaration(ofKind: .method) { location, _ in
            guard let at = live(location), at > units.count + 1 else { return }
            // `) Name`: back over blanks to the receiver's `)`.
            var k = at - 1
            while k > 0, text.character(at: k) == 32 || text.character(at: k) == 9 { k -= 1 }
            guard text.character(at: k) == 41 else { return }                        // )
            k -= 1
            while k > 0, text.character(at: k) == 32 || text.character(at: k) == 9 { k -= 1 }
            if text.character(at: k) == 93 {                                          // ] type parameters
                var depth = 0
                var steps = 0
                while k > 0, steps < 256 {
                    let u = text.character(at: k)
                    if u == 93 { depth += 1 } else if u == 91 { depth -= 1; if depth == 0 { break } }
                    k -= 1
                    steps += 1
                }
                k -= 1
            }
            // The base type name ends at `k`.
            var j = units.count - 1
            while j >= 0, k >= 0, text.character(at: k) == units[j] { j -= 1; k -= 1 }
            guard j < 0, k >= 0 else { return }
            let before = text.character(at: k)
            guard before == 42 || before == 32 || before == 9 || before == 40 else { return }   // * blank (
            out.append(location)
        }
        goMethodCache[name] = out
        return out
    }

    // MARK: - Members

    /// A type's own members (all its bodies; Go: its methods), cached.
    func members(of id: Int) -> [BraceMember] {
        let t = types[id]
        if let cached = t.members { return cached }
        var out: [BraceMember] = []
        var seen: [String: Int] = [:]
        func add(_ m: BraceMember) {
            if let first = seen[m.name] {
                // Rust: a field and a method may share a name (separate namespaces).
                guard isCallable(out[first]) != isCallable(m), !out[first..<out.count].contains(where: {
                    $0.name == m.name && isCallable($0) == isCallable(m)
                }) else { return }
                out.append(m)
            } else {
                seen[m.name] = out.count
                out.append(m)
            }
        }
        for m in t.foreignMembers { add(m) }
        for body in t.bodies {
            guard budget.exhausted == false else { break }
            for m in readBody(body, of: t) { add(m) }
        }
        if language == .go, t.containers.allSatisfy({ $0.kind == .module }) || t.containers.isEmpty {
            for location in goMethods(of: t.name) {
                guard tick() else { break }
                guard let info = functionInfo(at: location, kind: .method),
                      let (tk, n) = tokens(atDeclaration: location) else { continue }
                var m = BraceMember(name: reader.string(tk[n]), kind: .method, isStatic: false, access: .public,
                                    type: info.type, results: info.results, location: location)
                m.detail = summary(info, tokens: tk, name: n)
                add(m)
            }
        }
        // A list cut short by the budget is not kept (the request is unknown).
        if !budget.exhausted {
            t.members = out
            t.byName = seen
        }
        return out
    }

    /// Members declared in one body.
    private func readBody(_ body: BraceTypeInfo.Body, of t: BraceTypeInfo) -> [BraceMember] {
        let record = body.scope.record
        let declared = index.members(ofClassScope: body.scope)
        guard let start = live(record.start) else { return [] }
        let text = reader.text
        let end = min(text.length, live(record.end) ?? text.length)
        guard end > start, end - start <= 4 * 1024 * 1024 else { return [] }
        statistics.bodiesRead += 1
        let head = head(of: body.scope)
        let anchor = head.nameLocation.flatMap { live($0) } ?? start
        let tk = reader.tokens(anchor: min(anchor, start), to: end)
        for _ in 0..<(tk.count >> 6) { guard tick() else { return [] } }
        guard let open = tk.firstIndex(where: { $0.kind == .lbrace && $0.start >= start }) else { return [] }
        let close = BraceTokens.matching(tk, open) ?? tk.count
        let keyword = t.keyword
        let isEnum = keyword == .enum
        // Statement starts and C++ access sections at depth 0 of the body.
        var statementStart = [Int](repeating: -1, count: tk.count)
        var section = [BraceAccess](repeating: .unspecified, count: tk.count)
        var access: BraceAccess = .unspecified
        var stmt = open + 1
        var depth = 0
        var enumConstants = isEnum && (language == .java)
        // Rust fields / variants and C#, C, C++ enumerators are separated by
        // commas (Java's constants only until the first `;`).
        let commaSeparated = (language == .rust && (keyword == .struct || keyword == .enum || keyword == .union))
            || (isEnum && (language == .csharp || language == .c || language == .cpp))
        var enumCases: [Int] = []
        var embedded: [Range<Int>] = []
        var k = open + 1
        while k < close {
            let u = tk[k]
            if depth == 0 {
                if (language == .swift || language == .go), u.isLineStart, k > stmt {
                    let p = tk[k - 1]
                    if p.kind != .comma, p.kind != .assign, p.kind != .dot, p.kind != .thinArrow, p.kind != .colon,
                       p.kind != .op, p.kind != .at, !(k >= 2 && tk[k - 2].kind == .at) {
                        if language == .go, keyword == .struct || keyword == .interface {
                            embedded.append(stmt..<k)
                        }
                        stmt = k
                    }
                }
                statementStart[k] = stmt
                section[k] = access
                if language == .cpp, u.keyword == .public || u.keyword == .private || u.keyword == .protected,
                   k + 1 < close, tk[k + 1].kind == .colon {
                    access = u.keyword == .public ? .public : u.keyword == .private ? .private : .protected
                    stmt = k + 2
                    k += 2
                    continue
                }
                if enumConstants || (commaSeparated && isEnum) || (language == .swift && isEnum)
                    || (language == .rust && isEnum) {
                    // Enum cases / constants / variants.
                    var isCase = false
                    if language == .swift {
                        isCase = u.kind == .ident && u.keyword == .none && k > stmt
                            && (tk[k - 1].kind == .comma || tk[k - 1].keyword == .case)
                            && statementLeadsWithCase(tk, from: stmt, to: k)
                    } else {
                        isCase = u.kind == .ident && u.keyword == .none && k == firstNonAttribute(tk, stmt, close)
                    }
                    if isCase { enumCases.append(k) }
                }
            }
            if BraceTokens.isOpener(u.kind) {
                depth += 1
            } else if BraceTokens.isCloser(u.kind) {
                depth -= 1
                if depth == 0, u.kind == .rbrace {
                    stmt = k + 1
                } else if depth < 0 {
                    break
                }
            } else if depth == 0 {
                if u.kind == .semicolon {
                    if language == .go, keyword == .struct || keyword == .interface { embedded.append(stmt..<k) }
                    stmt = k + 1
                    if enumConstants { enumConstants = false }
                } else if u.kind == .comma, commaSeparated || enumConstants {
                    stmt = k + 1
                }
            }
            k += 1
        }
        if language == .go, keyword == .struct || keyword == .interface, stmt < close { embedded.append(stmt..<close) }

        var defaultAccess: BraceAccess
        switch language {
        case .cpp: defaultAccess = keyword == .class ? .private : .public
        case .csharp: defaultAccess = keyword == .interface || keyword == .enum ? .public : .private
        case .rust: defaultAccess = t.keyword == .trait ? .public : .private
        // Java package-private stays unspecified (visible here; another
        // package's file hides it, T17.14).
        case .java: defaultAccess = .unspecified
        default: defaultAccess = .public
        }
        if head.role == .extension, language == .rust, body.trait != nil { defaultAccess = .public }
        var out: [BraceMember] = []
        for member in declared {
            guard tick() else { break }
            guard let at = live(member.location) else { continue }
            let n = BraceTokens.index(atOrAfter: at, in: tk)
            guard n < tk.count, tk[n].start == at else { continue }
            let inBody = n > open && n < close
            guard inBody || n < open else { continue }
            let kind = member.kind
            if kind == .parameter || kind == .import { continue }
            let stmtStart: Int? = inBody && statementStart[n] >= 0 ? statementStart[n] : nil
            let info = decls.read(tk, name: n, kind: kind, statementStart: stmtStart)
            if info.isFriend { continue }
            var access = info.access
            if access == .unspecified {
                if language == .cpp, inBody, section[n] != .unspecified { access = section[n] } else { access = defaultAccess }
            }
            if !inBody { access = .public }   // record / primary-constructor parameters
            var isStatic = info.isStatic
            let memberKind: InferredMemberKind
            switch kind {
            case .function, .method:
                if language == .rust, !info.hasSelfParameter { isStatic = true }
                memberKind = isStatic ? .staticMethod : .method
            case .class, .type:
                memberKind = .nestedClass
                isStatic = true
            default:
                if language == .java, keyword == .interface { isStatic = true }
                if language == .rust, kind == .variable { isStatic = true }   // `const` in an `impl`
                memberKind = .field
            }
            var m = BraceMember(name: member.name, kind: memberKind, isStatic: isStatic, access: access,
                                type: info.type, results: info.results, location: member.location)
            if let range = info.initializer, info.type == nil {
                m.initializer = tk[range.lowerBound].start..<tk[range.upperBound - 1].end
            }
            m.detail = memberKind == .nestedClass ? nil : summary(info, tokens: tk, name: n)
            out.append(m)
        }
        for c in enumCases {
            guard let location = base(tk[c].start) else { continue }
            var m = BraceMember(name: reader.string(tk[c]), kind: .field, isStatic: true, access: .public,
                                location: location)
            m.isEnumCase = true
            out.append(m)
        }
        // Go embedded fields / interfaces: bases (an embedded struct field is
        // also a field named after its type).
        if language == .go, !embedded.isEmpty, !t.bases.contains(where: { $0.context == record.start }) {
            for range in embedded {
                guard range.count >= 1, range.count <= 6 else { continue }
                let s = range.lowerBound
                guard case .type(let type, let e)? = decls.types.parse(tk, s, range.upperBound), type.isNominal,
                      e == range.upperBound || (e + 1 == range.upperBound && tk[e].kind == .literal) else { continue }
                t.bases.append(BraceTypeInfo.Base(type: type, context: record.start, access: .public))
                if keyword == .struct, let location = base(tk[s].start) {
                    var m = BraceMember(name: type.name, kind: .field, isStatic: false, access: .public,
                                        type: type, location: location)
                    m.detail = type.text
                    out.append(m)
                }
            }
        }
        return out
    }

    private func statementLeadsWithCase(_ tk: [DeclToken], from: Int, to: Int) -> Bool {
        var k = from
        while k < to, tk[k].kind == .at || tk[k].keyword == .modifier || (k > from && tk[k - 1].kind == .at) { k += 1 }
        return k < to && tk[k].keyword == .case
    }

    /// The first token of a statement after attributes / annotations.
    private func firstNonAttribute(_ tk: [DeclToken], _ start: Int, _ end: Int) -> Int {
        var k = start
        while k < end {
            if tk[k].kind == .lbracket, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1; continue }   // [Attr]
            if tk[k].kind == .op, reader.spells(tk[k], "#"), k + 1 < end, tk[k + 1].kind == .lbracket,
               let m = BraceTokens.matching(tk, k + 1, limit: end) { k = m + 1; continue }                      // #[attr]
            if tk[k].kind == .at, k + 1 < end {
                k += 2
                if k < end, tk[k].kind == .lparen, let m = BraceTokens.matching(tk, k, limit: end) { k = m + 1 }
                continue
            }
            break
        }
        return k
    }

    // MARK: - Lineage

    /// The type and its bases, depth first in declaration order, each once
    /// (cycle guard): `(type, rank, inherited access)`.
    func lineage(of id: Int) -> [(id: Int, rank: Int, access: BraceAccess)] {
        if let cached = lineageCache[id] { return cached }
        var out: [(id: Int, rank: Int, access: BraceAccess)] = []
        var visited = Set<Int>()
        func visit(_ id: Int, _ access: BraceAccess, _ depth: Int) {
            guard depth < 16, visited.insert(id).inserted, tick() else { return }
            out.append((id, out.count, access))
            if language == .go { _ = members(of: id) }   // embedded fields are found in the body
            for base in types[id].bases {
                guard let b = resolveType(base.type, context: base.context) else { continue }
                let inherited: BraceAccess = access == .private || base.access == .private ? .private
                    : (access == .protected || base.access == .protected ? .protected : .public)
                visit(b, inherited, depth + 1)
            }
        }
        visit(id, .public, 0)
        if !budget.exhausted { lineageCache[id] = out }
        return out
    }

    func isCallable(_ m: BraceMember) -> Bool {
        m.kind == .method || m.kind == .staticMethod || m.kind == .classMethod
    }

    /// A member by name through the lineage (any visibility); `calls`: the
    /// access is called (a method is preferred over a same-named field).
    func lookupMember(_ id: Int, _ name: String, typeLevel: Bool, calls: Bool = false)
        -> (member: BraceMember, owner: Int)? {
        var fallback: (member: BraceMember, owner: Int)?
        for entry in lineage(of: id) {
            let list = members(of: entry.id)
            guard let first = types[entry.id].byName[name] else { continue }
            for m in list[first...] where m.name == name {
                guard typeLevel == (m.isStatic || m.isEnumCase || m.kind == .nestedClass) || language == .go else {
                    continue
                }
                if isCallable(m) == calls { return (m, entry.id) }
                if fallback == nil { fallback = (m, entry.id) }
            }
        }
        return fallback
    }

    // MARK: - Visibility

    /// Whether `member` of type `owner` (inherited with `inherited` access)
    /// is accessible at snapshot offset `offset`.
    func isVisible(_ member: BraceMember, owner: Int, inherited: BraceAccess, at offset: Int,
                   contextTypes: [Int]) -> Bool {
        var access = member.access
        if inherited == .private { access = .private } else if inherited == .protected, access != .private {
            access = .protected
        }
        if member.isForeign, access == .private || access == .fileprivate {
            // Read from another file (T17.14): Swift `private` / `fileprivate`,
            // Java / Rust private are file- or module-scoped; C# partial parts
            // and C++ out-of-class definitions share the class's privates.
            switch language {
            case .csharp, .cpp: return contextTypes.contains(owner)
            default: return false
            }
        }
        switch access {
        case .public, .internal, .fileprivate, .unspecified:
            return true
        case .private:
            switch language {
            case .swift, .csharp, .cpp:
                return contextTypes.contains(owner)
            case .java:
                // The whole top-level class.
                let t = types[owner]
                let outermost = t.containers.first { $0.kind == .class } ?? t.primary?.record
                guard let top = outermost else { return true }
                return contains(top, offset)
            case .rust:
                // Module privacy: inside the `mod` block holding the type.
                guard let module = types[owner].containers.last(where: { $0.kind == .block }) else { return true }
                return contains(module, offset)
            case .go, .c:
                return true
            }
        case .protected:
            if language == .java { return true }
            return contextTypes.contains { ctx in lineage(of: ctx).contains { $0.id == owner } }
        }
    }

    // MARK: - Summaries

    /// A member's signature summary in its language's syntax (plan §5.5),
    /// fitted into `InferredMemberList.detailLimit`.
    func summary(_ info: BraceDeclInfo, tokens tk: [DeclToken], name n: Int) -> String? {
        BraceSummary.signature(info, tokens: tk, reader: reader)
    }
}

/// Signature summaries fitted into the popup's detail width (consistent
/// with `InferredMemberList.shortened`: trailing parameters are dropped for
/// `, …`, the head and tail are kept short).
enum BraceSummary {
    /// Tokens around the declaration whose name starts at live offset `at`
    /// and the name's index in them: its line, extended by up to `extra`
    /// units while the statement continues (open brackets, a trailing
    /// operator or comma).
    static func tokens(reader: BraceTokenReader, atName at: Int, extra: Int = 2048) -> ([DeclToken], Int)? {
        guard at >= 0, at < reader.text.length else { return nil }
        let lineEnd = reader.lineEnd(of: at)
        var tk = reader.tokens(anchor: at, to: min(reader.text.length, lineEnd + 1))
        let n = BraceTokens.index(atOrAfter: at, in: tk)
        guard n < tk.count, tk[n].start == at, tk[n].kind == .ident else { return nil }
        if continues(tk, from: n), lineEnd + 1 < reader.text.length {
            tk = reader.tokens(anchor: at, to: min(reader.text.length, lineEnd + extra))
        }
        return (tk, n)
    }

    /// The statement from `n` does not end within `tk`.
    private static func continues(_ tk: [DeclToken], from n: Int) -> Bool {
        var depth = 0
        for t in tk[n...] {
            if BraceTokens.isOpener(t.kind) { depth += 1 } else if BraceTokens.isCloser(t.kind) { depth -= 1 }
        }
        if depth > 0 { return true }
        guard let last = tk.last else { return false }
        switch last.kind {
        case .assign, .walrus, .comma, .dot, .thinArrow, .arrow, .colon, .op, .star, .less: return true
        default: return last.keyword == .new || last.keyword == .return
        }
    }

    /// A member's signature summary in its language's syntax (plan §5.5),
    /// fitted into `InferredMemberList.detailLimit`: a function's
    /// parameters and result, a field's written type.
    static func signature(_ info: BraceDeclInfo, tokens tk: [DeclToken], reader: BraceTokenReader) -> String? {
        if !info.isFunction { return info.type?.text.isEmpty == false ? info.type?.text : nil }
        let params = info.parameters.map { r in reader.compact(from: tk[r.lowerBound].start, to: tk[r.upperBound - 1].end) }
        switch reader.language {
        case .swift, .rust:
            let tail = info.type.map { " -> " + $0.text } ?? ""
            return fit(head: "", params: params, tail: tail)
        case .go:
            var tail = ""
            if info.results.count == 1, let r = info.results[0] { tail = " " + r.text }
            else if info.results.count > 1 {
                tail = " (" + info.results.map { $0?.text ?? "?" }.joined(separator: ", ") + ")"
            }
            return fit(head: "", params: params, tail: tail)
        case .java, .csharp, .c, .cpp:
            // Type-first languages: the return type after the parameters,
            // as VS Code's Java completion shows it (`(int n) : String`),
            // so every row reads parameters first (main, T17.11d).
            var tail = info.suffix.isEmpty ? "" : " " + info.suffix
            if let type = info.type { tail += " : " + type.text }
            return fit(head: "", params: params, tail: tail)
        }
    }

    static func fit(head: String, params: [String], tail: String,
                    limit: Int = InferredMemberList.detailLimit) -> String {
        let full = head + "(" + params.joined(separator: ", ") + ")" + tail
        guard full.utf16.count > limit else { return full }
        func cut(_ s: String, _ max: Int) -> String {
            s.utf16.count <= max ? s : String(s.prefix(Swift.max(4, max - 1))) + "…"
        }
        let shortTail = cut(tail, limit / 2)
        let shortHead = cut(head, limit / 3)
        let budget = limit - shortHead.utf16.count - shortTail.utf16.count - 5   // "(" ", …" ")"
        var kept: [String] = []
        var used = 0
        for p in params {
            let cost = p.utf16.count + (kept.isEmpty ? 0 : 2)
            if used + cost > budget { break }
            kept.append(p)
            used += cost
        }
        let inner = kept.isEmpty ? "…" : kept.joined(separator: ", ") + ", …"
        return shortHead + "(" + inner + ")" + shortTail
    }
}
