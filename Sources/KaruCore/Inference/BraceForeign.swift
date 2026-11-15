import Foundation

// M17 T17.14 — cross-file types of the statically typed brace languages
// (plan §8.1: members come from same-named types "in this file and the
// workspace index"). The other files of the document's project folder are
// read on the cross-file queue (`CrossFileTypeService`), each into the same
// document model the editor uses (`BraceModuleView` over a
// `BraceStaticFile`), and summarised per type name as `BraceForeignPart`s:
// a primary declaration or an extension / `impl` / Go methods / C# partial
// part, with its members (written types and signature summaries) and bases.
// Only these summaries reach the main thread.
//
// On the main thread `BraceForeignResolver` picks what a written name means
// (precision first, plan §13): one primary declaration (C# partial parts of
// one class together), chosen by qualifier (`pkg.T`, `crate::m::T`,
// `ns::T`, `a.b.T`), else by the file's imports (Java `import` / same
// package, C# `using`, C++ `using namespace`, Rust `use`), else the only
// candidate; Go's unqualified names only within the same package
// (directory). Ambiguous → unknown (usage evidence), never a guess.
// Extensions in other files merge into the chosen type (Swift extensions,
// Rust `impl`s, Go methods of the same package) — and into a type of this
// file — only when no other declaration of the name competes.
// Visibility: another file's `private` / `fileprivate` members are hidden
// (Swift, Java, Rust; C# / C++ only inside the owning class), Go names
// starting in lower case are hidden outside their package, Java
// package-private members outside theirs.

extension BraceLanguage {
    /// The language identifier (`LanguageRegistry`).
    var identifier: String {
        switch self {
        case .swift: return "swift"
        case .go: return "go"
        case .rust: return "rust"
        case .java: return "java"
        case .csharp: return "csharp"
        case .c: return "c"
        case .cpp: return "cpp"
        }
    }

    /// Index languages whose files may declare this language's types (C and
    /// C++ share headers).
    var familyIdentifiers: [String] {
        switch self {
        case .c, .cpp: return ["c", "cpp"]
        default: return [identifier]
        }
    }
}

/// A base clause read from another file.
struct BraceForeignBase: Sendable {
    var type: BraceWrittenType
    var access: BraceAccess
}

/// What one file of the project folder declares for one type name.
struct BraceForeignPart: Sendable {
    enum Role: UInt8, Sendable {
        /// The type's declaration (a C# partial part too).
        case primary
        /// A Swift extension, Rust `impl`, or Go methods without the type.
        case `extension`
    }

    /// File path relative to the project folder, and its directory.
    var path: String
    var directory: String
    var role: Role
    var keyword: DeclKeyword
    var isPartial = false
    /// C: declared as a tag (`struct point`), not as a typedef name.
    var isTag = false
    /// Enclosing types of a nested declaration.
    var typeContainers: [String] = []
    /// Namespace path: C# / C++ namespaces, Java `package`, Go `package`
    /// clause, Rust module path from the file's path.
    var namespaces: [String] = []
    /// An extension's qualifiers (`extension Outer.Inner` → `Outer`).
    var extendedQualifiers: [String] = []
    var members: [BraceMember] = []
    var bases: [BraceForeignBase] = []

    var approximateBytes: Int {
        128 + path.utf8.count + directory.utf8.count + (typeContainers + namespaces + extendedQualifiers).reduce(0) { $0 + 16 + $1.utf8.count }
            + members.reduce(0) { $0 + $1.approximateBytes } + bases.reduce(0) { $0 + 64 + $1.type.text.utf8.count * 2 }
    }
}

/// The type a written name resolved to in other files (merged parts).
struct BraceForeignType {
    let name: String
    let keyword: DeclKeyword
    let typeContainers: [String]
    let members: [BraceMember]
    let bases: [BraceForeignBase]
}

/// Imports and namespaces of the document (the disambiguation context),
/// read from its first 64 KB.
struct BraceFileContext: Equatable {
    /// Java `package`.
    var package: [String] = []
    /// Java `import a.b.C;` (dotted) and `import a.b.*;` (the package).
    var javaImports: Set<String> = []
    var javaWildcards: Set<String> = []
    /// C# `using A.B;`; C++ `using namespace a::b;` (dotted with `.`).
    var usings: Set<String> = []
    /// Namespaces declared in the file (C# / C++, dotted with `.`).
    var namespaces: Set<String> = []
    /// Rust `use a::b::C;` / `use a::{C, D};`: name → module path.
    var rustUses: [String: [String]] = [:]
    /// Go imports: alias (or the path's last component) → that last component.
    var goImports: [String: String] = [:]

    static let scanLimit = 65_536

    static func parse(_ text: NSString, language: BraceLanguage) -> BraceFileContext {
        var context = BraceFileContext()
        let length = min(text.length, scanLimit)
        guard length > 0 else { return context }
        let head = text.substring(to: length)
        var inGoImportBlock = false
        for raw in head.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func words(after prefix: String) -> String? {
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            func trimmed(_ s: String) -> String {
                var t = s
                if let semi = t.firstIndex(of: ";") { t = String(t[..<semi]) }
                if let brace = t.firstIndex(of: "{"), language != .rust { t = String(t[..<brace]) }
                return t.trimmingCharacters(in: .whitespaces)
            }
            switch language {
            case .java:
                if let rest = words(after: "package ") {
                    context.package = trimmed(rest).split(separator: ".").map(String.init)
                } else if let rest = words(after: "import "), !rest.hasPrefix("static ") {
                    let path = trimmed(rest)
                    if path.hasSuffix(".*") { context.javaWildcards.insert(String(path.dropLast(2))) }
                    else { context.javaImports.insert(path) }
                }
            case .csharp:
                if let rest = words(after: "using "), !rest.hasPrefix("static "), !rest.contains("="), !rest.contains("(") {
                    context.usings.insert(trimmed(rest))
                } else if let rest = words(after: "namespace ") {
                    let name = trimmed(rest)
                    if !name.isEmpty { context.namespaces.insert(name) }
                }
            case .cpp:
                if let rest = words(after: "using namespace ") {
                    context.usings.insert(trimmed(rest).replacingOccurrences(of: "::", with: "."))
                } else if let rest = words(after: "namespace ") {
                    let name = trimmed(rest).replacingOccurrences(of: "::", with: ".")
                    if !name.isEmpty { context.namespaces.insert(name) }
                }
            case .rust:
                let rest = words(after: "use ") ?? words(after: "pub use ")
                guard let rest else { break }
                var path = rest
                if let semi = path.firstIndex(of: ";") { path = String(path[..<semi]) }
                path = path.trimmingCharacters(in: .whitespaces)
                if let open = path.firstIndex(of: "{"), let close = path.lastIndex(of: "}"), open < close {
                    let base = path[..<open].split(separator: ":").map(String.init).filter { !$0.isEmpty }
                    for item in path[path.index(after: open)..<close].split(separator: ",") {
                        let name = item.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !name.contains(" "), !name.contains(":"), name != "self" else { continue }
                        context.rustUses[name] = base
                    }
                } else if !path.contains(" ") {
                    var parts = path.split(separator: ":").map(String.init).filter { !$0.isEmpty }
                    if let name = parts.popLast(), name != "*" { context.rustUses[name] = parts }
                }
            case .go:
                var spec: String?
                if line.hasPrefix("import (") { inGoImportBlock = true; continue }
                if inGoImportBlock {
                    if line.hasPrefix(")") { inGoImportBlock = false; continue }
                    spec = line
                } else if let rest = words(after: "import ") {
                    spec = rest
                }
                guard let spec, let quote = spec.firstIndex(of: "\""),
                      let end = spec[spec.index(after: quote)...].firstIndex(of: "\"") else { break }
                let importPath = String(spec[spec.index(after: quote)..<end])
                let last = importPath.split(separator: "/").last.map(String.init) ?? importPath
                let alias = spec[..<quote].trimmingCharacters(in: .whitespaces)
                context.goImports[alias.isEmpty ? last : alias] = last
            case .swift, .c:
                break
            }
        }
        return context
    }
}

/// The namespace path every type of a file shares (Java `package`, Go
/// `package` clause, C# file-scoped `namespace`, Rust module path).
enum BraceFileNamespace {
    static func of(text: NSString, path: String, language: BraceLanguage) -> [String] {
        switch language {
        case .rust:
            var parts = (path as NSString).deletingPathExtension.split(separator: "/").map(String.init)
            if parts.first == "src" { parts.removeFirst() }
            if let last = parts.last, ["mod", "lib", "main"].contains(last) { parts.removeLast() }
            return parts
        case .java, .go, .csharp:
            let head = text.substring(to: min(text.length, BraceFileContext.scanLimit))
            for raw in head.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let keyword = language == .csharp ? "namespace " : "package "
                guard line.hasPrefix(keyword) else { continue }
                var rest = String(line.dropFirst(keyword.count))
                if language == .csharp {
                    // File-scoped only (`namespace A.B;`); block namespaces are scopes.
                    guard let semi = rest.firstIndex(of: ";"), !rest.contains("{") else { continue }
                    rest = String(rest[..<semi])
                } else if let semi = rest.firstIndex(of: ";") {
                    rest = String(rest[..<semi])
                }
                return rest.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
            }
            return []
        case .swift, .c, .cpp:
            return []
        }
    }
}

// MARK: - Reading another file (cross-file queue)

extension BraceModuleView {
    /// What this file (a project file read from disk, no journal) declares
    /// for type `name`: its primary declarations (with this file's
    /// extensions merged), typedef / alias targets, and orphan extensions /
    /// `impl`s / Go methods of a type declared elsewhere. Members carry
    /// `foreignLocation` and no initializer ranges (offsets of this file
    /// mean nothing in the document).
    func foreignParts(named name: String, path: String, directory: String) -> [BraceForeignPart] {
        var parts: [BraceForeignPart] = []
        func exported(_ members: [BraceMember]) -> [BraceMember] {
            members.map { m in
                var copy = m
                copy.location = Self.foreignLocation
                copy.initializer = nil
                copy.isForeign = true
                return copy
            }
        }
        func part(for id: Int, role: BraceForeignPart.Role, isTag: Bool) -> BraceForeignPart {
            let t = types[id]
            var p = BraceForeignPart(path: path, directory: directory, role: role, keyword: t.keyword)
            p.isPartial = t.isPartial
            p.isTag = isTag
            for record in t.containers where record.kind == .class {
                guard let scopeName = scopeName(record) else { continue }
                if isNamespaceScope(record) {
                    p.namespaces += namespacePath(of: record, fallback: scopeName)
                } else if t.primary?.record.index != record.index {
                    p.typeContainers.append(scopeName)
                }
            }
            p.members = exported(members(of: id))
            p.bases = t.bases.map { BraceForeignBase(type: $0.type, access: $0.access) }
            return p
        }
        let primaries = primaryTypes(named: name)
        for id in primaries {
            parts.append(part(for: id, role: .primary, isTag: language == .c))
        }
        // Aliases / typedef names (C: the typedef of a tag or an anonymous struct).
        if language == .c || primaries.isEmpty, let binding = index.moduleBinding(named: name), binding.kind == .type
            || (language == .c && binding.kind == .class) {
            var written = BraceWrittenType()
            written.path = [name]
            if let id = resolveType(written, context: binding.location), !primaries.contains(id) || language == .c {
                var p = part(for: id, role: .primary, isTag: false)
                p.typeContainers = []
                parts.append(p)
            }
        }
        // Extensions / `impl`s of a type this file does not declare.
        if let nameIndex = classNameIndex(name) {
            for scope in index.classScopes(nameIndex: nameIndex) {
                let head = head(of: scope)
                guard head.role == .extension, head.path.last == name,
                      !types.contains(where: { $0.bodies.contains { $0.scope.record.index == scope.record.index } })
                else { continue }
                let containers = Array(chain(at: scope.record.start).map(\.record).dropFirst()
                    .filter { $0.index != scope.record.index })
                let id = appendType { id in
                    let info = BraceTypeInfo(id: id, name: name, keyword: .none, primary: nil, location: scope.record.start,
                                             containers: containers, containerNames: [])
                    info.bodies = [BraceTypeInfo.Body(scope: scope, trait: head.trait)]
                    info.bases = head.bases.map { BraceTypeInfo.Base(type: $0.0, context: scope.record.start, access: $0.1) }
                    if let trait = head.trait {
                        info.bases.append(BraceTypeInfo.Base(type: trait, context: scope.record.start, access: .public))
                    }
                    return info
                }
                var p = part(for: id, role: .extension, isTag: false)
                p.extendedQualifiers = Array(head.path.dropLast())
                parts.append(p)
            }
        }
        // Go methods of a type declared in another file of the package.
        if language == .go, primaries.isEmpty, !goMethods(of: name).isEmpty {
            let id = appendType { id in
                BraceTypeInfo(id: id, name: name, keyword: .type, primary: nil, location: 0, containers: [],
                              containerNames: [])
            }
            parts.append(part(for: id, role: .extension, isTag: false))
        }
        return parts
    }

    /// A namespace body's dotted name (C# `namespace A.B {`, C++
    /// `namespace a::b {` → `[A, B]`); its own name when unreadable.
    private func namespacePath(of record: DeclarationScan.ScopeRecord, fallback: String) -> [String] {
        guard let start = live(record.start) else { return [fallback] }
        let text = reader.text
        let from = max(0, start - 256)
        let before = text.substring(with: NSRange(location: from, length: start - from))
        guard let range = before.range(of: "namespace", options: .backwards) else { return [fallback] }
        let name = before[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n{"))
            .replacingOccurrences(of: "::", with: ".")
        let parts = name.split(separator: ".").map(String.init)
        return parts.isEmpty || parts.last != fallback ? [fallback] : parts
    }
}

// MARK: - Choosing (main thread)

/// The cross-file view of one document's request (T17.14): resolves
/// written type names against the parts of other files of its project
/// folder, recording whether a lookup is still loading.
final class BraceForeignResolver {
    /// `.found` parts of a type name, `.loading` (scheduled), `.missing`.
    enum Lookup {
        case loading
        case found([BraceForeignPart])
        case missing
    }

    let language: BraceLanguage
    /// The document's path relative to the project folder, and its directory.
    let documentPath: String
    let documentDirectory: String
    let context: BraceFileContext
    private let lookup: (String) -> Lookup
    /// A lookup of this request is still loading (the popup refreshes when
    /// it arrives).
    private(set) var hasPending = false
    private(set) var lookups = 0

    init(language: BraceLanguage, documentPath: String, context: BraceFileContext,
         lookup: @escaping (String) -> Lookup) {
        self.language = language
        self.documentPath = documentPath
        self.documentDirectory = (documentPath as NSString).deletingLastPathComponent
        self.context = context
        self.lookup = lookup
    }

    private func parts(_ name: String) -> [BraceForeignPart]? {
        lookups += 1
        switch lookup(name) {
        case .loading:
            hasPending = true
            return nil
        case .missing:
            return nil
        case .found(let parts):
            let others = parts.filter { $0.path != documentPath }
            return others.isEmpty ? nil : others
        }
    }

    /// The type `path` names (qualifiers first); nil when no other file
    /// declares it, more than one could be meant, or it is loading.
    func type(path: [String], tag: Bool) -> BraceForeignType? {
        guard let name = path.last, !name.isEmpty else { return nil }
        var qualifiers = Array(path.dropLast())
        if language == .rust {
            while let first = qualifiers.first, ["crate", "self", "super"].contains(first) { qualifiers.removeFirst() }
            if qualifiers.isEmpty, path.count == 1, let used = context.rustUses[name] {
                qualifiers = used.filter { !["crate", "self", "super"].contains($0) }
            }
        }
        guard let all = parts(name) else { return nil }
        let primaries = all.filter { $0.role == .primary && (language != .c || $0.isTag == tag) }
        var candidates: [BraceForeignPart]
        if !qualifiers.isEmpty {
            candidates = primaries.filter { matches($0, qualifiers) }
        } else {
            candidates = primaries.filter { $0.typeContainers.isEmpty }
            if language == .go { candidates = candidates.filter { $0.directory == documentDirectory } }
            if groups(candidates).count > 1 { candidates = candidates.filter { imported($0, name) } }
        }
        let grouped = groups(candidates)
        guard grouped.count == 1, let group = grouped.first, let first = group.first else { return nil }
        var members: [BraceMember] = []
        var bases: [BraceForeignBase] = []
        for part in group {
            members += visibleMembers(part)
            bases += part.bases
        }
        // Extensions elsewhere, when nothing else competes for the name.
        let competing = primaries.filter { p in p.typeContainers == first.typeContainers && !group.contains { $0.path == p.path } }
        if competing.isEmpty {
            for ext in all where ext.role == .extension && extends(ext, first) {
                members += visibleMembers(ext)
                bases += ext.bases
            }
        }
        return BraceForeignType(name: name, keyword: first.keyword, typeContainers: first.typeContainers,
                                members: members, bases: bases)
    }

    /// Extensions / `impl`s / Go methods / C# partial parts in other files of
    /// a type this file declares (top level or in namespaces only).
    func extensions(of name: String, isPartial: Bool, namespaces: [String])
        -> (members: [BraceMember], bases: [BraceForeignBase])? {
        switch language {
        case .swift, .rust, .go: break
        case .csharp: guard isPartial else { return nil }
        case .java, .c, .cpp: return nil
        }
        guard let all = parts(name) else { return nil }
        var picked: [BraceForeignPart]
        switch language {
        case .csharp:
            picked = all.filter { $0.role == .primary && $0.isPartial && $0.typeContainers.isEmpty
                && $0.namespaces.last == namespaces.last }
        case .go:
            picked = all.filter { $0.role == .extension && $0.directory == documentDirectory }
        default:
            // Another declaration of the name elsewhere: which type an
            // extension means is ambiguous.
            guard !all.contains(where: { $0.role == .primary && $0.typeContainers.isEmpty }) else { return nil }
            picked = all.filter { $0.role == .extension && $0.extendedQualifiers.isEmpty }
        }
        guard !picked.isEmpty else { return nil }
        return (picked.flatMap(visibleMembers), picked.flatMap(\.bases))
    }

    // MARK: Rules

    /// C# partial parts of one class form one group; any other part is its own.
    private func groups(_ parts: [BraceForeignPart]) -> [[BraceForeignPart]] {
        var out: [[BraceForeignPart]] = []
        var keys: [String: Int] = [:]
        for part in parts {
            let key = part.isPartial && language == .csharp
                ? "partial\u{1}" + (part.namespaces + part.typeContainers).joined(separator: ".")
                : part.path + "\u{1}" + part.typeContainers.joined(separator: ".")
            if let at = keys[key] { out[at].append(part) } else { keys[key] = out.count; out.append([part]) }
        }
        return out
    }

    private func matches(_ part: BraceForeignPart, _ qualifiers: [String]) -> Bool {
        if language == .go {
            guard qualifiers.count == 1 else { return false }
            let package = context.goImports[qualifiers[0]] ?? qualifiers[0]
            return part.namespaces.last == package || (part.directory as NSString).lastPathComponent == package
        }
        let full = part.namespaces + part.typeContainers
        return full.count >= qualifiers.count && Array(full.suffix(qualifiers.count)) == qualifiers
    }

    /// Several candidates: the ones the document's imports name.
    private func imported(_ part: BraceForeignPart, _ name: String) -> Bool {
        let dotted = part.namespaces.joined(separator: ".")
        switch language {
        case .java:
            if part.namespaces == context.package || context.javaWildcards.contains(dotted) { return true }
            return context.javaImports.contains((part.namespaces + part.typeContainers + [name]).joined(separator: "."))
        case .csharp, .cpp:
            return context.usings.contains(dotted) || context.namespaces.contains { $0 == dotted || $0.hasPrefix(dotted + ".") }
        default:
            return false
        }
    }

    /// An extension part extends `primary` (same package for Go, matching
    /// qualifiers for Swift).
    private func extends(_ ext: BraceForeignPart, _ primary: BraceForeignPart) -> Bool {
        switch language {
        case .go:
            return ext.directory == primary.directory
        case .swift, .rust:
            guard !ext.extendedQualifiers.isEmpty else { return true }
            let full = primary.namespaces + primary.typeContainers
            return full.count >= ext.extendedQualifiers.count
                && Array(full.suffix(ext.extendedQualifiers.count)) == ext.extendedQualifiers
        default:
            return false
        }
    }

    /// A part's members visible from the document: Go exported names
    /// outside the package, Java public ones outside the package.
    private func visibleMembers(_ part: BraceForeignPart) -> [BraceMember] {
        switch language {
        case .go where part.directory != documentDirectory:
            return part.members.filter { m in m.name.first.map { $0.isUppercase } ?? false }
        case .java where part.namespaces != context.package && part.keyword != .interface:
            // Package-private and protected members belong to the package
            // (and subclasses, which this resolver does not track).
            return part.members.filter { $0.access != .unspecified && $0.access != .protected }
        default:
            return part.members
        }
    }
}
