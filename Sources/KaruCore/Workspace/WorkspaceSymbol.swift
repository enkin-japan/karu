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
    ///
    /// One pass over the scan's declarations (T17.15d): they are streamed in
    /// document order (`forEachDeclaration(from:to:)`) instead of
    /// materialising `scan.declarations`, and each indexed one becomes its
    /// symbol at once (lines from one ascending sweep); a function's
    /// signature waits for its parameters, which follow its name, and is
    /// filled in afterwards. No intermediate arrays the size of the file's
    /// declarations — the allocator keeps freed blocks resident, so every
    /// transient array a large file needs stays in the footprint.
    public static func extract(from scan: DeclarationScan, text: NSString) -> [IndexedSymbol] {
        let scopes = scan.scopes
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
        /// Symbols whose signature lists a scope's parameters: (symbol, scope).
        var signed: [(symbol: Int, scope: Int)] = []
        var symbols: [IndexedSymbol] = []
        var stack: [DeclarationScan.Scope] = []
        var next = 0
        // Lines: one ascending sweep over the text (declarations arrive in
        // document order).
        var line = 1
        var cursor = 0
        let length = text.length
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: 4096) { buffer in
            let base = buffer.baseAddress!
            func advanceLine(to location: Int) {
                let target = min(location, length)
                while cursor < target {
                    let count = min(buffer.count, target - cursor)
                    text.getCharacters(base, range: NSRange(location: cursor, length: count))
                    for i in 0..<count {
                        let u = base[i]
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
            }
            scan.forEachDeclaration(from: 0, to: Int.max) { location, name, kind in
                while next < scopes.count, scopes[next].start <= location {
                    let scope = scopes[next]
                    while let top = stack.last, top.index != scope.parent { stack.removeLast() }
                    stack.append(scope)
                    next += 1
                }
                while let top = stack.last, !contains(top, location) { stack.removeLast() }
                guard let innermost = stack.last else { return }
                switch kind {
                case .parameter:
                    if innermost.kind == .function || innermost.kind == .lambda {
                        parameters[innermost.index, default: []].append(name)
                    }
                    return
                case .import, .global, .nonlocal:
                    return
                default:
                    break
                }
                let owner: Int
                var ownScope: Int?
                if innermost.kind == .module || isContainer(innermost) {
                    owner = stack.count - 1
                } else if kind == .function || kind == .method,
                          innermost.kind == .function, innermost.name == name, stack.count >= 2,
                          stack[stack.count - 2].kind == .module || isContainer(stack[stack.count - 2]) {
                    // A Go method: its scope opens at the receiver `(`, before the name.
                    owner = stack.count - 2
                    ownScope = innermost.index
                } else if kind == .property,
                          let classPosition = stack.lastIndex(where: { $0.kind == .class }) {
                    owner = classPosition
                } else {
                    return
                }
                var container: String?
                for scope in stack[...owner] where isContainer(scope) {
                    guard let part = scope.name else { continue }
                    container = container.map { $0 + "." + part } ?? part
                }
                if ownScope != nil, container == nil, let receiver = goReceiverType(text, nameLocation: location) {
                    // A Go method is filed under its receiver's base type (T17.14:
                    // cross-file members find `func (s *Server) Start` by `Server`).
                    container = receiver
                }
                advanceLine(to: location)
                if let own = ownScope {
                    signed.append((symbols.count, own))
                } else if kind == .function || kind == .method {
                    // First scope starting at or after the name.
                    var low = 0, high = scopes.count
                    while low < high {
                        let mid = (low + high) / 2
                        if scopes[mid].start < location { low = mid + 1 } else { high = mid }
                    }
                    if low < scopes.count, scopes[low].kind == .function || scopes[low].kind == .lambda,
                       scopes[low].name == name {
                        signed.append((symbols.count, scopes[low].index))
                    }
                }
                symbols.append(IndexedSymbol(name: name, kind: kind, container: container,
                                             location: location, line: line, signature: nil))
            }
        }
        for (index, scope) in signed {
            let symbol = symbols[index]
            symbols[index] = IndexedSymbol(name: symbol.name, kind: symbol.kind, container: symbol.container,
                                           location: symbol.location, line: symbol.line,
                                           signature: "(" + (parameters[scope] ?? []).joined(separator: ", ") + ")")
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
