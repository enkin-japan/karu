import Foundation

// The flat syntax tree of the hand-written parsers (M17 T17.11a, plan §8.2
// "T17.9 结论"): one array of 16-byte nodes in post-order. A node stores its
// subtree size, so its subtree is `nodes[i - size ..< i]` (plus `i`) and its
// children are found walking back from `i - 1` (`c -= size(c) + 1`). No
// child, parent or sibling indices are stored: the structure is
// position-independent, so an incremental update only shifts the UTF-16
// offsets of reused top-level subtrees.
//
// Pure value types (no AppKit, `Sendable`): the same code runs on the main
// thread in slices and, later, on background queues (plan §3).

/// The language family a parser reads (the four identifiers with a parser).
public enum SyntaxDialect: UInt8, Sendable, Equatable {
    case python
    /// JavaScript with JSX (`.js`, `.jsx`, `.mjs`, `.cjs`): the script parser
    /// with every TypeScript-only construct off.
    case javascript
    case typescript
    /// TSX: TypeScript with JSX (`<T>expr` assertions off).
    case typescriptReact

    /// The dialect of a `LanguageDefinition` identifier, nil for languages
    /// without a parser.
    public init?(languageIdentifier: String) {
        switch languageIdentifier {
        case "python": self = .python
        case "javascript": self = .javascript
        case "typescript": self = .typescript
        case "typescriptreact": self = .typescriptReact
        default: return nil
        }
    }

    public var languageIdentifier: String {
        switch self {
        case .python: return "python"
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .typescriptReact: return "typescriptreact"
        }
    }

    /// TypeScript syntax (types, `as`, declarations …) is parsed.
    var hasTypes: Bool { self == .typescript || self == .typescriptReact }
    /// The scanner reports JSX.
    var hasJSX: Bool { self == .javascript || self == .typescriptReact }

    /// The analysis scanner profile the parser reads (the declaration
    /// walker's and completion's context checkpoints' profile).
    var lexicalProfile: LexicalProfile {
        switch self {
        case .python: return PythonLanguage.analysisProfile
        default: return JavaScriptLanguage.lexicalProfile(forIdentifier: languageIdentifier)!
        }
    }
}

/// Node kinds. The child layout of the kinds the inference needs is listed
/// in `SyntaxTree`'s documentation; `aux` / flag meanings are per kind.
public enum SyntaxKind: UInt8, Sendable {
    case module = 0, error, missing
    // Leaves / atoms
    case name, number, string, regex, keywordLit, ellipsisLit, privateName
    // Python statements
    case funcDef, classDef, decorator, block, ifStmt, elifClause, elseClause, forStmt, whileStmt
    case tryStmt, exceptClause, finallyClause, withStmt, withItem, matchStmt, caseClause
    case exprStmt, assign, augAssign, annAssign, returnStmt, raiseStmt, passStmt, breakStmt, continueStmt
    case globalStmt, nonlocalStmt, delStmt, assertStmt, importStmt, importFrom, alias, dottedName, typeAliasStmt
    case params, param, args, keywordArg
    // Expressions (shared)
    case member, `subscript`, call, binary, unary, ternary, lambda, await, yield, paren, tuple, list, dict, pair
    case set, listComp, setComp, dictComp, genExp, compFor, compIf, slice, walrus, starred, formatSpec
    // Python match patterns
    case patternCapture, patternValue, patternSequence, patternMapping, patternPair, patternClass
    case patternKeyword, patternOr, patternAs, patternStar
    // TypeScript statements / declarations
    case varDecl, declarator, funcDecl, funcExpr, arrow, classDecl, classExpr, heritage, classBody
    case method, property, indexSig, staticBlock, interfaceDecl, typeAlias, enumDecl, enumMember
    case namespaceDecl, importDecl, importSpec, exportDecl, exportSpec, forIn, forOf, doWhile
    case switchStmt, switchCase, catchClause, throwStmt, labeled, emptyStmt, debuggerStmt
    // TypeScript expressions
    case assignExpr, sequence, update, new, nonNull, asExpr, satisfiesExpr, typeAssertion, taggedTemplate
    case template, array, object, prop, computedKey, spread, elision, metaProperty, importCall
    case objectPattern, arrayPattern, patternProp, assignPattern, restElement
    // Types
    case typeRef, typeArgs, unionType, intersectionType, funcType, ctorType, objectType, propSig, methodSig
    case callSig, ctorSig, mappedType, tupleType, namedTupleMember, arrayType, indexedAccess, typeQuery
    case typeOperator, inferType, conditionalType, literalType, parenType, typePredicate, templateType
    case importType, typeParams, typeParam, optionalType, restType, qualifiedName
    // JSX
    case jsxElement, jsxName, jsxAttr, jsxSpreadAttr, jsxExprContainer, jsxText
}

/// Bits of `SyntaxNode.flags`.
public enum SyntaxFlags {
    /// A closer was inserted by recovery (`)`, `]`, `}`, `>`, a JSX end tag …).
    public static let missingClose: UInt8 = 1
    /// A member access with no name after the dot (`x.` being typed).
    public static let missingName: UInt8 = 2
    /// `?.`, an optional `?` parameter / property.
    public static let optional: UInt8 = 4
    public static let async: UInt8 = 8
    public static let generator: UInt8 = 16
    public static let isStatic: UInt8 = 32
    /// Another missing piece was inserted (`:`, `{`, `=>`, an empty block …).
    public static let recovered: UInt8 = 64
    /// `declare` on a TS declaration; a parameter property's accessibility.
    public static let modifier: UInt8 = 128
}

/// Bits of `SyntaxNode.aux` shared by several kinds.
public enum SyntaxAux {
    /// `import type …` / `export type …` / a `type` specifier (on `importDecl`,
    /// `exportDecl`, `importSpec`, `exportSpec`).
    public static let typeOnly: UInt16 = 0x8000
}

/// 16 bytes: kind, flags, aux, UTF-16 start / end, subtree size.
public struct SyntaxNode: Sendable, Equatable {
    public var kind: SyntaxKind
    public var flags: UInt8
    /// Operator code, declaration kind, member dot gap, parameter star kind, …
    public var aux: UInt16
    public var start: Int32
    public var end: Int32
    /// Number of descendants (the subtree is `[index - size, index]`).
    public var size: Int32

    @inline(__always) public var range: NSRange { NSRange(location: Int(start), length: Int(end - start)) }
    @inline(__always) public func has(_ flag: UInt8) -> Bool { flags & flag != 0 }
}

/// A complete syntax tree (or a standalone one-statement tree from
/// `ModuleSummary`'s on-demand parse).
///
/// **Layout.** `nodes` is post-order; the root (`module`) is last and spans
/// the whole text. Its children are the top-level statements. Leaves carry
/// the exact token range; inner nodes span their first to their last token
/// (an inserted closer extends to the end of input).
///
/// **Child layouts** used by the inference (children in document order;
/// optional ones may be absent, recovery may add `error` / `missing`):
/// - Python `funcDef`: decorator*, name, typeParams?, params, <return annotation>?, block
///   (flags: async). `classDef`: decorator*, name, typeParams?, args?, block.
///   `param` (aux 0 plain, 1 `*x`, 2 `**x`, 3 bare `*`, 4 `/`): name, <annotation>?, <default>?.
///   `assign`: target+, value (targets and value are the `=`-separated parts).
///   `annAssign`: target, annotation, value?. `augAssign` (aux operator): target, value.
///   `importStmt`: alias+ (alias: dottedName, name?). `importFrom` (aux level): dottedName?, alias* | name(`*`).
///   `forStmt`: target, iterable, block, elseClause?. `withItem`: expr, target?.
///   `compFor`: target, iterable, compIf*. `lambda`: params, body. `walrus`: name, value.
///   `matchStmt`: subject, block(caseClause*). `caseClause`: pattern, <guard>?, block.
///   `string`: its interpolated expressions and `formatSpec` nodes (f-strings).
/// - Script `funcDecl` / `funcExpr` (flags: async, generator): decorator*, name?, typeParams?,
///   params, <return type>?, block?. `arrow`: params, <return type>?, body (block or expression).
///   `classDecl` / `classExpr`: decorator*, name?, typeParams?, heritage* (aux 0 extends,
///   1 implements), classBody. `method` (aux 1 get, 2 set, 3 constructor): decorator*, key,
///   typeParams?, params, <return type>?, block?. `property` (aux bit 1 typed, 2 initialised):
///   decorator*, key, type?, value?. `param` (aux bit 1 rest, 2 parameter property, 4 typed,
///   8 default): decorator*, binding, type?, default?. `varDecl` (aux 0 var, 1 let, 2 const,
///   3 using): declarator+ (aux bit 1 typed, 2 initialised: binding, type?, init?).
///   Bindings are `name`, `objectPattern`, `arrayPattern` (also on the left of a
///   destructuring assignment). `importDecl`: importSpec* (aux 1 default, 2 namespace,
///   3 `= require`), source string. `exportDecl` (aux 0 declaration, 1 default, 2 other).
///   `member` (aux = gap between object and dot): object, name | privateName (no name with
///   `missingName`). `call`: callee, typeArgs?, args. `jsxElement` (aux 1 fragment,
///   2 self-closing): jsxName, attributes, children.
///
/// **Sync starts.** `syncStarts` holds the ascending offsets where a
/// top-level statement began at a lexically clean token (Python: a logical
/// line start): the only places an incremental update or an on-demand
/// statement parse may (re)start. 4 bytes per top-level statement.
public struct SyntaxTree: Sendable, Equatable {
    public let dialect: SyntaxDialect
    public internal(set) var nodes: [SyntaxNode]
    public internal(set) var syncStarts: [Int32]

    init(dialect: SyntaxDialect, nodes: [SyntaxNode], syncStarts: [Int32]) {
        self.dialect = dialect
        self.nodes = nodes
        self.syncStarts = syncStarts
    }

    // MARK: - Basics

    /// The root (`module`) node index.
    @inline(__always) public var root: Int { nodes.count - 1 }

    @inline(__always) public subscript(_ i: Int) -> SyntaxNode { nodes[i] }

    @inline(__always) public func kind(_ i: Int) -> SyntaxKind { nodes[i].kind }

    @inline(__always) public func range(_ i: Int) -> NSRange { nodes[i].range }

    /// Node indices of `i`'s subtree (descendants first, `i` last).
    @inline(__always) public func subtree(_ i: Int) -> ClosedRange<Int> { (i - Int(nodes[i].size))...i }

    /// The text length the tree was parsed from (the root's end).
    public var textLength: Int { nodes.isEmpty ? 0 : Int(nodes[root].end) }

    /// Bytes held by the node and sync-start arrays (their capacities).
    public var retainedBytes: Int {
        nodes.capacity * MemoryLayout<SyntaxNode>.stride + syncStarts.capacity * MemoryLayout<Int32>.stride
    }

    func isSyncStart(_ offset: Int32) -> Bool {
        var lo = 0, hi = syncStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if syncStarts[mid] < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo < syncStarts.count && syncStarts[lo] == offset
    }

    // MARK: - Children

    /// Children of `i`, in document order.
    public func children(_ i: Int) -> [Int] {
        var out: [Int] = []
        forEachChildReversed(i) { out.append($0) }
        out.reverse()
        return out
    }

    /// Calls `body` for each child of `i` in reverse document order (no allocation).
    @inline(__always)
    public func forEachChildReversed(_ i: Int, _ body: (Int) -> Void) {
        let lo = i - Int(nodes[i].size)
        var c = i - 1
        while c >= lo {
            body(c)
            c -= Int(nodes[c].size) + 1
        }
    }

    /// Number of children of `i`.
    public func childCount(_ i: Int) -> Int {
        var n = 0
        forEachChildReversed(i) { _ in n += 1 }
        return n
    }

    /// The first child of `i` in document order.
    public func firstChild(_ i: Int) -> Int? {
        var first: Int?
        forEachChildReversed(i) { first = $0 }
        return first
    }

    /// The last child of `i` in document order.
    public func lastChild(_ i: Int) -> Int? { nodes[i].size > 0 ? i - 1 : nil }

    /// The first child of `i` (document order) of `kind`.
    public func firstChild(_ i: Int, kind: SyntaxKind) -> Int? {
        var found: Int?
        forEachChildReversed(i) { if nodes[$0].kind == kind { found = $0 } }
        return found
    }

    // MARK: - Top level

    /// The top-level statements (children of the root), in document order.
    public var topLevelStatements: [Int] { nodes.isEmpty ? [] : children(root) }

    /// The top-level statement whose range contains `offset` (start <= offset
    /// < end; at a statement's end, the next one starting there wins, else
    /// the one ending there).
    public func topLevelStatement(at offset: Int) -> Int? {
        let statements = topLevelStatements
        var lo = 0, hi = statements.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(nodes[statements[mid]].start) <= offset { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first statement starting after `offset`.
        var k = lo - 1
        while k >= 0 {
            let n = nodes[statements[k]]
            if offset <= Int(n.end) { return statements[k] }
            if Int(n.end) < offset { break }
            k -= 1
        }
        return nil
    }

    // MARK: - Position queries

    /// The chain of nodes containing `offset`, outermost (the root) first.
    /// A node contains `offset` when `start <= offset < end`, or `<= end`
    /// with `inclusiveEnd` (a caret right after a token is "in" it). Where
    /// two siblings qualify (one ends where the next starts) the earlier
    /// one wins with `inclusiveEnd`, the later one without.
    public func path(to offset: Int, inclusiveEnd: Bool = true) -> [Int] {
        guard !nodes.isEmpty else { return [] }
        var chain = [root]
        var i = root
        while true {
            var next: Int?
            forEachChildReversed(i) { c in
                let n = nodes[c]
                let inside = Int(n.start) <= offset && (offset < Int(n.end) || (inclusiveEnd && offset == Int(n.end)))
                if inside {
                    // Reverse order: the last match assigned is the earliest
                    // child; without `inclusiveEnd` keep the first (latest).
                    if inclusiveEnd || next == nil { next = c }
                }
            }
            guard let c = next else { return chain }
            chain.append(c)
            i = c
        }
    }

    /// The innermost node containing `offset` (see `path(to:inclusiveEnd:)`).
    public func node(at offset: Int, inclusiveEnd: Bool = true) -> Int? {
        path(to: offset, inclusiveEnd: inclusiveEnd).last
    }

    /// The enclosing nodes of `offset` whose kind is in `kinds`, outermost first.
    public func enclosing(_ offset: Int, kinds: Set<SyntaxKind>, inclusiveEnd: Bool = true) -> [Int] {
        path(to: offset, inclusiveEnd: inclusiveEnd).filter { kinds.contains(nodes[$0].kind) }
    }

    // MARK: - Diagnostics

    /// Error nodes (skipped tokens) and recovered pieces (zero-width
    /// `missing` nodes, inserted closers, member accesses with no name,
    /// other inserted tokens). Valid code has neither.
    public var errorCounts: (errors: Int, recovered: Int) {
        var e = 0, m = 0
        let recoveryBits = SyntaxFlags.missingClose | SyntaxFlags.missingName | SyntaxFlags.recovered
        for n in nodes {
            if n.kind == .error { e += 1 }
            if n.kind == .missing { m += 1 }
            if n.flags & recoveryBits != 0 { m += 1 }
        }
        return (e, m)
    }

    /// The first error or recovered node (diagnostics / corpus reports).
    public var firstProblem: Int? {
        let recoveryBits = SyntaxFlags.missingClose | SyntaxFlags.missingName | SyntaxFlags.recovered
        var best: Int?
        for (i, n) in nodes.enumerated() where n.kind == .error || n.kind == .missing || n.flags & recoveryBits != 0 {
            if best == nil || n.start < nodes[best!].start { best = i }
        }
        return best
    }
}
