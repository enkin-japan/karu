import Foundation

/// One declaration of a file as the project-folder index stores it (M17
/// T17.12): the file's top-level declarations and the members of its classes /
/// namespaces, extracted from the same `DeclarationScan` the editor uses.
public struct IndexedSymbol: Sendable, Equatable {
    public let name: String
    public let kind: DeclarationScan.DeclarationKind
    /// Enclosing classes / namespaces joined with "." (`Outer.Inner`); nil at
    /// the top level.
    public let container: String?
    /// UTF-16 offset of the name in the file's decoded text (as read from disk:
    /// UTF-8, a leading BOM dropped, line endings untouched).
    public let location: Int
    /// 1-based line of `location`.
    public let line: Int
    /// Export / signature summary: since T17.14 the inference layer's
    /// compact summary (`IndexSignatures`: `(a: int) -> str`, a field's type);
    /// `extract` alone gives a function's or method's parameter names,
    /// `(a, b)`. nil otherwise.
    public let signature: String?

    public init(name: String, kind: DeclarationScan.DeclarationKind, container: String?, location: Int,
                line: Int, signature: String?) {
        self.name = name
        self.kind = kind
        self.container = container
        self.location = location
        self.line = line
        self.signature = signature
    }

    public var length: Int { name.utf16.count }

    /// Which declarations are indexed, and under which container:
    /// - kinds other than parameters, imports, `global` / `nonlocal`;
    /// - whose innermost scope is the module, a class, or a named block
    ///   (a TS namespace) — locals are never indexed;
    /// - plus instance attributes (`self.x = …`, `this.x = …`: `.property`
    ///   declared inside a method), filed under the nearest enclosing class.
    /// Signatures come from the function scope that follows a function /
    /// method name (same name), listing its parameters in order. A Go
    /// method's scope opens at its receiver, before the name: the receiver
    /// leads the signature, and a top-level method is filed under its
    /// receiver's base type (`Server` for `func (s *Server) Start`).
    public static func extract(from scan: DeclarationScan, text: NSString) -> [IndexedSymbol] {
        let scopes = scan.scopes
        let declarations = scan.declarations
        guard !declarations.isEmpty else { return [] }
        let documentLength = scan.documentLength

        func contains(_ scope: DeclarationScan.Scope, _ offset: Int) -> Bool {
            scope.start <= offset
                && (offset < scope.end || scope.end >= documentLength || scope.kind == .embedded && offset == scope.end)
        }
        func isContainer(_ scope: DeclarationScan.Scope) -> Bool {
            scope.kind == .class || (scope.kind == .block && scope.name != nil)
        }

        // Parameters per function scope (by scope index), for signatures.
        var parameters: [Int: [String]] = [:]
        struct Pending {
            var name: String
            var kind: DeclarationScan.DeclarationKind
            var container: String?
            var location: Int
            /// The function scope already containing the name (Go methods).
            var ownScope: Int?
        }
        var pending: [Pending] = []
        var stack: [DeclarationScan.Scope] = []
        var next = 0
        for declaration in declarations {
            let location = declaration.location
            while next < scopes.count, scopes[next].start <= location {
                let scope = scopes[next]
                while let top = stack.last, top.index != scope.parent { stack.removeLast() }
                stack.append(scope)
                next += 1
            }
            while let top = stack.last, !contains(top, location) { stack.removeLast() }
            guard let innermost = stack.last else { continue }
            switch declaration.kind {
            case .parameter:
                if innermost.kind == .function || innermost.kind == .lambda {
                    parameters[innermost.index, default: []].append(declaration.name)
                }
                continue
            case .import, .global, .nonlocal:
                continue
            default:
                break
            }
            let owner: Int
            var ownScope: Int?
            if innermost.kind == .module || isContainer(innermost) {
                owner = stack.count - 1
            } else if declaration.kind == .function || declaration.kind == .method,
                      innermost.kind == .function, innermost.name == declaration.name, stack.count >= 2,
                      stack[stack.count - 2].kind == .module || isContainer(stack[stack.count - 2]) {
                // A Go method: its scope opens at the receiver `(`, before the name.
                owner = stack.count - 2
                ownScope = innermost.index
            } else if declaration.kind == .property,
                      let classPosition = stack.lastIndex(where: { $0.kind == .class }) {
                owner = classPosition
            } else {
                continue
            }
            let names = stack[...owner].filter(isContainer).compactMap(\.name)
            var container = names.isEmpty ? nil : names.joined(separator: ".")
            if ownScope != nil, container == nil, let receiver = goReceiverType(text, nameLocation: location) {
                // A Go method is filed under its receiver's base type (T17.14:
                // cross-file members find `func (s *Server) Start` by `Server`).
                container = receiver
            }
            pending.append(Pending(name: declaration.name, kind: declaration.kind, container: container,
                                   location: location, ownScope: ownScope))
        }

        // Lines: one ascending sweep over the text.
        var symbols: [IndexedSymbol] = []
        symbols.reserveCapacity(pending.count)
        var line = 1
        var cursor = 0
        let length = text.length
        var buffer = [unichar](repeating: 0, count: 4096)
        for item in pending {
            let target = min(item.location, length)
            while cursor < target {
                let count = min(buffer.count, target - cursor)
                text.getCharacters(&buffer, range: NSRange(location: cursor, length: count))
                for i in 0..<count {
                    let u = buffer[i]
                    if u == 10 {
                        line += 1
                    } else if u == 13 {
                        // CR, or CRLF counted at its LF.
                        let nextIndex = cursor + i + 1
                        if nextIndex >= length || text.character(at: nextIndex) != 10 { line += 1 }
                    }
                }
                cursor += count
            }
            var signature: String?
            if let own = item.ownScope {
                signature = "(" + (parameters[own] ?? []).joined(separator: ", ") + ")"
            } else if item.kind == .function || item.kind == .method {
                // First scope starting at or after the name.
                var low = 0, high = scopes.count
                while low < high {
                    let mid = (low + high) / 2
                    if scopes[mid].start < item.location { low = mid + 1 } else { high = mid }
                }
                if low < scopes.count, scopes[low].kind == .function || scopes[low].kind == .lambda,
                   scopes[low].name == item.name {
                    signature = "(" + (parameters[scopes[low].index] ?? []).joined(separator: ", ") + ")"
                }
            }
            symbols.append(IndexedSymbol(name: item.name, kind: item.kind, container: item.container,
                                         location: item.location, line: line, signature: signature))
        }
        return symbols
    }
}

/// The base type name of the Go method receiver ending right before the
/// method name at `nameLocation` (`func (s *Server[T]) Name` → `Server`).
func goReceiverType(_ text: NSString, nameLocation: Int) -> String? {
    func isBlank(_ u: unichar) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }
    func isIdentifier(_ u: unichar) -> Bool {
        (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u > 127
    }
    var k = min(nameLocation, text.length) - 1
    while k > 0, isBlank(text.character(at: k)) { k -= 1 }
    guard k > 0, text.character(at: k) == 41 else { return nil }                 // )
    k -= 1
    while k > 0, isBlank(text.character(at: k)) { k -= 1 }
    if k > 0, text.character(at: k) == 93 {                                        // ] type parameters
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
    let end = k + 1
    while k >= 0, isIdentifier(text.character(at: k)) { k -= 1 }
    let start = k + 1
    guard end > start, start < text.length, !(text.character(at: start) >= 48 && text.character(at: start) <= 57) else {
        return nil
    }
    return text.substring(with: NSRange(location: start, length: end - start))
}

/// A symbol found by a workspace-index query (value type; T17.14 consumes it).
public struct WorkspaceSymbol: Sendable, Equatable, Hashable {
    /// The project folder (standardized path) the symbol belongs to.
    public let folder: String
    /// File path relative to `folder`.
    public let relativePath: String
    public let languageIdentifier: String
    public let name: String
    public let kind: DeclarationScan.DeclarationKind
    public let container: String?
    public let location: Int
    public let line: Int
    public let signature: String?

    public var path: String { (folder as NSString).appendingPathComponent(relativePath) }
    public var range: NSRange { NSRange(location: location, length: name.utf16.count) }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(folder)
        hasher.combine(relativePath)
        hasher.combine(name)
        hasher.combine(location)
    }
}

/// A workspace-symbol search hit: the symbol and how its name matched.
public struct WorkspaceSymbolMatch: Sendable, Equatable {
    public let symbol: WorkspaceSymbol
    public let tier: MatchTier
    /// Matched UTF-16 ranges of the name (for highlighting).
    public let ranges: [NSRange]
}
