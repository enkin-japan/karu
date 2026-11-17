import Foundation

/// The seven statically typed brace languages read by `BraceDeclarationWalker`
/// (M17 T17.4b, plan §5.2 "基础版").
enum BraceLanguage: UInt8, Sendable {
    case swift, go, rust, java, csharp, c, cpp

    init?(identifier: String) {
        switch identifier {
        case "swift": self = .swift
        case "go": self = .go
        case "rust": self = .rust
        case "java": self = .java
        case "csharp": self = .csharp
        case "c": self = .c
        case "cpp": self = .cpp
        default: return nil
        }
    }

    var keywords: DeclKeywords {
        switch self {
        case .swift: return .swift
        case .go: return .go
        case .rust: return .rust
        case .java: return .java
        case .csharp: return .csharp
        case .c: return .c
        case .cpp: return .cpp
        }
    }

    /// The highlighter's lexical profile (comments, strings, raw strings,
    /// character literals): declarations are read from its code segments.
    var lexicalProfile: LexicalProfile {
        switch self {
        case .swift: return SwiftLanguage.lexicalProfile
        case .go: return GoLanguage.lexicalProfile
        case .rust: return RustLanguage.lexicalProfile
        case .java: return JavaLanguage.lexicalProfile
        case .csharp: return CSharpLanguage.lexicalProfile
        case .c: return CLanguage.lexicalProfile
        case .cpp: return CppLanguage.lexicalProfile
        }
    }

    /// Declarations start with a type (`int x`, `List<String> rows`).
    var typeLed: Bool { self == .java || self == .csharp || self == .c || self == .cpp }

    /// A line break after an operand ends a statement (Swift, Go).
    var newlineTerminated: Bool { self == .swift || self == .go }

    /// Members of an enclosing type are visible as bare names inside its
    /// methods (implicit `this` / `self`): Java, C#, C++, Swift. Go, Rust and
    /// C need a receiver.
    var implicitMembers: Bool { self == .swift || self == .java || self == .csharp || self == .cpp }

    /// Line-start `#` directives (C, C++, C#; Swift `#if` family).
    var hasDirectives: Bool { self == .c || self == .cpp || self == .csharp || self == .swift }

    /// The legacy regex path coloured every `name(` call and `class` /
    /// `struct` name in these languages; the walker keeps that colour
    /// coverage with table-only references (never declarations).
    var notesReferences: Bool { typeLed }
}

/// A set of `DeclKeyword`s as a 256-bit mask.
struct KeywordSet: Sendable {
    private var a: UInt64 = 0, b: UInt64 = 0, c: UInt64 = 0, d: UInt64 = 0

    init(_ keywords: [DeclKeyword]) {
        for k in keywords {
            let r = Int(k.rawValue)
            let bit = UInt64(1) << UInt64(r & 63)
            switch r >> 6 {
            case 0: a |= bit
            case 1: b |= bit
            case 2: c |= bit
            default: d |= bit
            }
        }
    }

    @inline(__always)
    func contains(_ k: DeclKeyword) -> Bool {
        let r = Int(k.rawValue)
        let bit = UInt64(1) << UInt64(r & 63)
        switch r >> 6 {
        case 0: return a & bit != 0
        case 1: return b & bit != 0
        case 2: return c & bit != 0
        default: return d & bit != 0
        }
    }
}

/// Declaration walker for Swift, Go, Rust, Java, C#, C and C++ (M17 T17.4b,
/// plan §5.2: "当前函数的参数和函数体内的局部声明，作用域由括号确定").
///
/// One walker with per-language rules. Like `JavaScriptDeclarationWalker`
/// it is a push machine over the code tokens with an explicit frame stack
/// (one frame per bracket plus the file), so it can stop between any two
/// tokens; a construct that needs lookahead (a parameter list, a type-led
/// declaration head, a closure parameter clause) is decided only once its
/// tokens are buffered or the text has ended, within fixed bounds, so the
/// result never depends on slicing.
///
/// - **Declarations** (code tokens only — strings, comments, character
///   literals and raw strings are never read): function / method names in
///   the enclosing scope, parameters inside the function scope, locals,
///   fields (`.property`), type names (`.class` for class / struct / record
///   / actor / union, `.type` for enum / protocol / trait / interface /
///   extension / typedef / alias). Enum cases and imports are not recorded.
///   - Swift: `func f(label inner: T, _ x: U = …)` binds `inner`, `x`;
///     `let` / `var` with tuple patterns and several bindings; `if` / `guard`
///     / `while let` / `var`, `for x in` / `for (i, v) in`, `case let
///     .foo(x)`, `catch let e`; closure parameters `{ a, b in` / `{ (a: Int)
///     in`; computed properties get a function scope.
///   - Go: receiver, parameters (`a, b int` binds both), named results;
///     `:=` (several names, also in `if` / `for` / `switch` headers and
///     `select` cases), `var` / `const` (incl. groups), struct fields,
///     interface methods, function literals.
///   - Rust: parameter patterns (`mut a`, `(x, y): (i32, i32)`; `self` is not
///     a binding), `let` patterns (tuple, struct shorthand `Point { x, y }`,
///     `Some(x)`), `if let` / `while let`, `for (i, v) in`, closures `|a, b|`,
///     struct fields, `const` / `static`. Match-arm bindings are not read.
///   - Java / C# / C / C++: a parameter is the last identifier of its item
///     before `=` after skipping generics, arrays, pointers / references,
///     annotations / attributes and modifiers (an item of one word — `int`,
///     `Foo` — binds nothing); locals and fields `Type a = …, *b;`, `var x`,
///     `auto x`, `auto [a, b]`, `var (a, b)`, `for (T x : xs)`, `foreach (var x
///     in xs)`, `catch (E e)`, try-with-resources, C# `out var x`, lambdas
///     `(a, b) ->` / `(a, b) =>` / `x =>` / C++ `[…](int a) {`; records' and
///     C# primary constructors' parameters; C# properties; `typedef` names;
///     function-like macro names and parameters.
///   - **Type-led heads are conservative**: a declaration needs `Type name`
///     followed by `=` `;` `,` `[` `{` `:` `(` (C# also `=>`, headers also `)`
///     / `in`), where `Type` is a keyword type or an identifier path with
///     optional generics, `*` / `&` / `[]` / `?` suffixes. So `f(x);`, `a = b;`,
///     `x.y = 1;`, `return a * b;` declare nothing. The C / C++ / C#
///     ambiguity `a * b;` is read as an expression when the `*` (or `&`) has
///     blanks on both sides and as a declaration otherwise (`T *p;`, `T* p;`).
///     In a block, `Type name(args);` is a C / C++ direct-initialised variable
///     (`Cache<K, V> cache(8);`); at file / type level a prototype unless its
///     first argument is a literal. Constructors / destructors declare no name.
/// - **Scopes**: a function scope starts at its parameter list (Go: at the
///   receiver, so a method's own name sits in it — Go methods are never bare
///   names) and ends with the body (or the signature for prototypes /
///   protocol and interface requirements; C# `=> expr;` at the `;`). Type
///   bodies (struct, class, enum, protocol, trait, impl, interface, record,
///   extension, union; C++ / C# namespaces) are `.class` scopes starting
///   after the type name (records: at their parameter list); Rust `mod` is a
///   `.block`. Closures and lambdas are `.lambda` scopes. Other `{}` blocks
///   and control headers (`for (…)`, `catch (…)`, `if let …`, `for x in …`,
///   `if x := …;`) get a `.block` scope only when they declare something
///   (created lazily, as in the JS walker); a Swift `guard let` binds in the
///   enclosing block.
/// - **References** (Java, C#, C, C++ only; `notesReferences`): every
///   `name(` call outside declarations (not after `new`, never a keyword)
///   and every `class` / `struct` name — and `new T(` as a type — enter the
///   colour table / completion symbols as table-only references, keeping
///   the regex path's colour coverage; a called name that is also a type is
///   a type. They are not declarations (no `locations`, no bindings).
/// - **Statements** end at `;`, at the `}` of a statement body and — in
///   Swift and Go — at a line break after an operand. Expression-bodied lambdas and statement-scoped
///   headers end with the `;` / `,` that ends them (inclusive, so a caret
///   right before it is still inside).
/// - **Recovery**: a closer that matches no open frame within 16 frames is
///   ignored; a declaration keyword starting a line after an operand inside
///   unclosed parentheses resynchronises to the statement frame; frames are
///   capped at `maxFrames`. Lookahead is bounded (`lookaheadLimit` tokens).
struct BraceDeclarationWalker: Sendable {
    typealias Kind = DeclarationScan.DeclarationKind
    typealias ScopeKind = DeclarationScan.ScopeKind

    static let maxFrames = 512
    static let lookaheadLimit = 4096
    /// Tokens buffered before deciding (unless the text has ended): only
    /// saves futile retries, decisions never depend on it.
    static let minBuffer = 8

    // MARK: - Listing

    /// Which declarations are *listed* (colour table, navigator, completion
    /// symbols); the others are scope-only (`visibleBindings`). Functions,
    /// methods and types are always listed (the regex path's coverage).
    /// Chosen per language from the VS Code Dark Modern comparison of the
    /// M17 samples (T17.4b): the table colours every occurrence of a name, so
    /// a category is listed only where VS Code paints its references too.
    /// - Swift: only file-level `let` / `var` (the regex path listed them);
    ///   VS Code leaves Swift parameter, local and property references
    ///   uncoloured (listing them: 69.5 → 64.8 %).
    /// - Rust: parameters, locals, fields; not `const` / `static` items
    ///   (VS Code leaves constant references uncoloured).
    /// - C: parameters and struct fields; not locals or globals.
    /// - Go, Java, C#, C++: everything (each category raises agreement).
    struct Listing: Sendable {
        var parameters: Bool
        var locals: Bool
        var fields: Bool
        var globals: Bool
    }

    static func listing(_ language: BraceLanguage) -> Listing {
        switch language {
        case .swift: return Listing(parameters: false, locals: false, fields: false, globals: true)
        case .rust: return Listing(parameters: true, locals: true, fields: true, globals: false)
        case .c: return Listing(parameters: true, locals: false, fields: true, globals: false)
        case .go, .java, .csharp, .cpp: return Listing(parameters: true, locals: true, fields: true, globals: true)
        }
    }

    // MARK: - Frames

    enum Role: UInt8, Sendable {
        /// The file; C++ / C# namespace bodies; C `extern "C"` bodies.
        case module
        /// Function / control bodies, bare blocks, expression braces, closures.
        case block
        /// Class / struct / enum / protocol / trait / impl / interface bodies.
        case typeBody
        /// C-family control header `( … )`.
        case header
        /// Go `var ( … )` / `const ( … )` / `type ( … )` / `import ( … )`.
        case group
        case paren, bracket, interp
    }

    enum Pending: UInt8, Sendable {
        case none
        /// A statement body follows (`{` adopts the open inline scope).
        case body
        /// A lambda / closure body follows (`{` adopts the lambda scope).
        case lambdaBody
        /// C family: a `( … )` control header follows.
        case parenHeader
        case catchHeader
    }

    enum DeclState: UInt8, Sendable {
        case none
        /// Swift `let` / `var`: a pattern follows.
        case binding
        /// After a declared name.
        case afterName
        /// Swift `: Type`.
        case typeAnnotation
        /// `= …` until a declarator `,` or the statement end.
        case initializer
        /// C family after `,` (or after a struct body): `*` / `&`, then a name.
        case declarator
    }

    enum HeaderKind: UInt8, Sendable {
        case none
        /// `if` / `while` / `for` / `switch` / `match` / `select` / `catch`:
        /// bindings go to a header scope that the body adopts.
        case scoped
        /// Swift `guard`: bindings go to the enclosing block; ends at `else`.
        case guardHeader
        /// Swift / Rust `for`: a pattern up to `in` comes first.
        case forPattern
    }

    enum GroupKind: UInt8, Sendable { case none, variable, type }

    struct Frame: Sendable {
        var role: Role
        /// `openScopes` height to close down to when the frame pops.
        var base: Int
        /// `openScopes` height to close down to at a statement boundary.
        var inline: Int
        var opener = 0
        /// Block / header: position of the opener while its scope is not created (-1 none).
        var lazyStart = -1
        var lazyKind: ScopeKind = .block
        var stmtStart = true
        /// A statement body: popping it ends the parent's statement.
        var statementLevel = false
        /// Opened right after a declared name (C# property accessors, Swift
        /// observers, C++ brace initialisers): the parent may start a new
        /// statement after it.
        var fromDeclaration = false
        /// C / C++ struct body: declarators may follow the `}`.
        var continuesStatement = false
        var pending: Pending = .none
        var decl: DeclState = .none
        var declKind: Kind = .variable
        var declName: Int32 = -1
        var angleDepth = 0
        var header: HeaderKind = .none
        var headerStart = -1
        /// Go header: at the start of a `;`-separated clause.
        var clauseStart = false
        var caseLabel = false
        var typedefStatement = false
        var isCatch = false
        /// Type body: the declared type name (constructor detection).
        var typeName: Int32 = -1
        var groupKind: GroupKind = .none
        /// Go `const ( … )` group: its names are flagged constant in the
        /// scan (VH4, the highlighter's constant colour).
        var groupConst = false
    }

    // MARK: - State

    let lang: BraceLanguage
    private let listing: Listing
    private let modifiers: KeywordSet
    private let typeWords: KeywordSet
    private let nameWords: KeywordSet
    private let strongStarters: KeywordSet
    private var frames: [Frame] = []
    private var openScopes: [Int32] = []
    private var overflow = 0

    // The last consumed token.
    private var prevEnd = false
    private var prevKind: DeclTokenKind = .semicolon
    private var prevBackslash = false
    private var prevTokenEnd = 0

    // Directive lines.
    private var inDirective = false
    private var directiveScope = false

    // Table-only references (Java, C#, C, C++).
    private var callCandidate: DeclToken?
    private var newPending = false
    private var newCandidate: DeclToken?
    private var structPending = false
    /// Calls before this offset are not references (signature tails: C++
    /// initialiser lists, C# `: base(…)`).
    private var quietUntil = -1
    private var quietFrom = -1
    /// Starts of declared names (and constructor names), ascending: never calls.
    private var declaredStarts: [Int] = []
    private var declaredHead = 0

    init(language: BraceLanguage) {
        lang = language
        listing = Self.listing(language)
        strongStarters = Self.strongStarters(language)
        switch language {
        case .swift:
            modifiers = KeywordSet([.public, .private, .static, .override, .modifier])
            typeWords = KeywordSet([])
            nameWords = KeywordSet([.modifier, .get, .set, .actor, .async])
        case .go:
            modifiers = KeywordSet([])
            typeWords = KeywordSet([])
            nameWords = KeywordSet([])
        case .rust:
            modifiers = KeywordSet([.pub])
            typeWords = KeywordSet([])
            nameWords = KeywordSet([.union])
        case .java:
            modifiers = KeywordSet([.public, .private, .protected, .static, .abstract, .modifier])
            typeWords = KeywordSet([.primitiveType, .void, .var])
            nameWords = KeywordSet([.var, .yield, .record])
        case .csharp:
            modifiers = KeywordSet([.public, .private, .protected, .static, .abstract, .override, .readonly,
                                    .const, .sealed, .unsafe, .extern, .async, .modifier, .event, .ref])
            typeWords = KeywordSet([.primitiveType, .void, .var])
            nameWords = KeywordSet([.var, .yield, .get, .set, .initializer, .when, .where, .nameof, .record,
                                    .async])
        case .c:
            modifiers = KeywordSet([.static, .extern, .inline, .const, .modifier])
            typeWords = KeywordSet([.primitiveType, .void])
            nameWords = KeywordSet([])
        case .cpp:
            modifiers = KeywordSet([.static, .extern, .inline, .const, .modifier, .virtual])
            typeWords = KeywordSet([.primitiveType, .void])
            nameWords = KeywordSet([])
        }
    }

    mutating func begin(moduleScope: Int32) {
        openScopes = [moduleScope]
        frames = [Frame(role: .module, base: 1, inline: 1)]
    }

    // MARK: - Driver interface

    /// The buffered tokens and the text, for lookahead.
    struct Ahead {
        let buf: DeclTokenBuffer
        let final: Bool
        let text: NSString
        @inline(__always) func at(_ k: Int) -> DeclToken? { buf.peek(k) }
    }

    /// Lookahead answer: the text may hold the answer but it is not buffered yet.
    static let need = -2

    mutating func process(_ buffer: inout DeclTokenBuffer, _ text: NSString, final: Bool,
                          _ b: inout DeclarationBuilder) {
        while let t = buffer.peek() {
            if !final, buffer.count < Self.minBuffer { break }
            let a = Ahead(buf: buffer, final: final, text: text)
            let consumed = handle(t, a, &b)
            if consumed == 0 { break }
            for i in 0..<consumed {
                guard let u = buffer.peek(i) else { break }
                stream(u, text, &b)
            }
            buffer.consume(consumed)
        }
    }

    mutating func finish(at end: Int, _ b: inout DeclarationBuilder) {
        closeDown(to: 1, at: end, &b)
        frames = [Frame(role: .module, base: 1, inline: 1)]
        callCandidate = nil
    }

    // MARK: - Token classes

    @inline(__always)
    private func unit(_ text: NSString, _ offset: Int) -> unichar {
        offset >= 0 && offset < text.length ? text.character(at: offset) : 0
    }

    /// A binding name: an identifier that is not a reserved word (contextual
    /// words of the language allowed) and not the wildcard `_`.
    @inline(__always)
    private func isName(_ t: DeclToken?, _ text: NSString) -> Bool {
        guard let t, t.kind == .ident else { return false }
        if t.keyword != .none, !nameWords.contains(t.keyword) { return false }
        return !(t.length == 1 && unit(text, t.start) == 95)
    }

    /// An identifier usable as (part of) a type name.
    @inline(__always)
    private func isTypeName(_ t: DeclToken?) -> Bool {
        guard let t, t.kind == .ident else { return false }
        return t.keyword == .none || nameWords.contains(t.keyword)
    }

    @inline(__always)
    private func isWildcard(_ t: DeclToken, _ text: NSString) -> Bool {
        t.kind == .ident && t.length == 1 && unit(text, t.start) == 95
    }

    private func isAmp(_ t: DeclToken, _ text: NSString) -> Bool {
        t.kind == .op && unit(text, t.start) == 38
    }

    private func isPipe(_ t: DeclToken, _ text: NSString) -> Bool {
        t.kind == .op && t.length == 1 && unit(text, t.start) == 124
    }

    private func isOperandEnd(_ t: DeclToken) -> Bool {
        switch t.kind {
        case .literal, .rparen, .rbracket, .rbrace, .interpClose: return true
        case .ident:
            switch t.keyword {
            case .none, .this, .selfValue, .super, .base, .true, .false, .null, .nil, .nullptr: return true
            default: return nameWords.contains(t.keyword)
            }
        default: return false
        }
    }

    /// Swift / Go: a token that starts a new statement after a line break.
    private func isStatementStarter(_ t: DeclToken) -> Bool {
        switch t.kind {
        case .literal, .at: return true
        case .ident:
            switch t.keyword {
            case .in, .as, .is, .where, .else, .throws, .rethrows: return false
            default: return true
            }
        default: return false
        }
    }

    /// Words that start a declaration on their own line (resynchronisation).
    @inline(__always)
    private func isStrongStarter(_ t: DeclToken) -> Bool {
        t.kind == .ident && t.keyword != .none && strongStarters.contains(t.keyword)
    }

    private static func strongStarters(_ language: BraceLanguage) -> KeywordSet {
        switch language {
        case .swift: return KeywordSet([.func, .class, .struct, .enum, .protocol, .extension, .import])
        case .go: return KeywordSet([.func, .type, .import, .package])
        case .rust: return KeywordSet([.fn, .struct, .enum, .impl, .trait, .mod, .use, .pub])
        case .java, .csharp:
            return KeywordSet([.public, .private, .protected, .class, .interface, .enum, .namespace, .import, .package])
        case .c, .cpp: return KeywordSet([.typedef, .struct, .namespace, .template])
        }
    }

    // MARK: - Frames and scopes

    private var top: Int { frames.count - 1 }

    private func isContainer(_ role: Role) -> Bool {
        role == .module || role == .block || role == .typeBody || role == .group
    }

    private mutating func push(_ frame: Frame) {
        if frames.count >= Self.maxFrames {
            overflow += 1
            return
        }
        frames.append(frame)
    }

    private func newFrame(_ role: Role, _ t: DeclToken) -> Frame {
        Frame(role: role, base: openScopes.count, inline: openScopes.count, opener: t.start)
    }

    private mutating func openInline(_ kind: ScopeKind, at start: Int, name: Int32 = -1,
                                     _ b: inout DeclarationBuilder) {
        openScopes.append(b.openScope(kind, at: start, name: name))
    }

    private mutating func closeDown(to height: Int, at position: Int, _ b: inout DeclarationBuilder) {
        while openScopes.count > max(1, height) {
            b.closeScope(openScopes.removeLast(), at: position)
        }
    }

    private mutating func closeInline(at position: Int, _ b: inout DeclarationBuilder) {
        closeDown(to: frames[top].inline, at: position, &b)
    }

    /// Statement boundary in the top frame.
    private mutating func boundary(at position: Int, _ b: inout DeclarationBuilder) {
        frames[top].decl = .none
        frames[top].pending = .none
        frames[top].header = .none
        frames[top].headerStart = -1
        frames[top].caseLabel = false
        frames[top].typedefStatement = false
        frames[top].angleDepth = 0
        closeInline(at: position, &b)
        frames[top].stmtStart = true
    }

    /// A statement / lambda body `{`: adopts the topmost inline scope (a
    /// function, lambda or header scope) when one is open, else gets a lazy
    /// block scope.
    private mutating func pushBody(_ t: DeclToken, statementLevel: Bool, lazyKind: ScopeKind = .block) {
        var frame = newFrame(.block, t)
        if openScopes.count > frames[top].inline {
            frame.base = openScopes.count - 1
        } else {
            frame.lazyStart = t.start
            frame.lazyKind = lazyKind
        }
        frame.statementLevel = statementLevel
        push(frame)
    }

    /// Creates the lazy scope a declaration directly in the nearest
    /// declaring frame belongs to; returns that frame's index.
    @discardableResult
    private mutating func ensureDeclScope(_ b: inout DeclarationBuilder) -> Int {
        var index = top
        while index > 0 {
            let role = frames[index].role
            if isContainer(role) || role == .header { break }
            index -= 1
        }
        let frame = frames[index]
        if (frame.header == .scoped || frame.header == .forPattern), frame.headerStart >= 0 {
            // Keyword-led header: a scope above the frame's statement scopes,
            // closed at the boundary or adopted by the body.
            let id = b.insertScope(.block, at: frame.headerStart)
            insertOpenScope(id, at: frame.inline, below: index)
            frames[index].headerStart = -1
            return index
        }
        guard frame.lazyStart >= 0 else { return index }
        switch frame.role {
        case .header:
            let id = b.insertScope(.block, at: frame.lazyStart)
            insertOpenScope(id, at: frame.base, below: index)
            frames[index].base += 1
            frames[index].inline += 1
        case .block:
            let id = b.insertScope(frame.lazyKind, at: frame.lazyStart)
            insertOpenScope(id, at: frame.inline, below: index)
            frames[index].inline += 1
        default:
            return index
        }
        frames[index].lazyStart = -1
        return index
    }

    private mutating func insertOpenScope(_ id: Int32, at position: Int, below index: Int) {
        openScopes.insert(id, at: min(position, openScopes.count))
        if index + 1 < frames.count {
            for k in (index + 1)..<frames.count {
                frames[k].base += 1
                frames[k].inline += 1
            }
        }
    }

    // MARK: - Declaring

    private func isListed(_ kind: Kind, global: Bool) -> Bool {
        switch kind {
        case .parameter: return listing.parameters
        case .property: return listing.fields
        case .variable: return global ? listing.globals : listing.locals
        default: return true
        }
    }

    private mutating func noteDeclared(_ start: Int) {
        if declaredHead > 1024, declaredHead * 2 > declaredStarts.count {
            declaredStarts.removeFirst(declaredHead)
            declaredHead = 0
        }
        if let last = declaredStarts.last, last >= start { return }
        declaredStarts.append(start)
    }

    /// Declares `t` in the scope the nearest declaring frame gives it.
    /// `constant`: listed like a file-level variable wherever it appears
    /// (Rust `const` / `static` items, also in traits and impls).
    /// `constDeclaration`: a Go `const` name, flagged constant in the scan
    /// (VH4; unrelated to `constant`, and only Go sets it).
    @discardableResult
    private mutating func declare(_ t: DeclToken, _ kind: Kind, _ text: NSString,
                                  _ b: inout DeclarationBuilder, constant: Bool = false,
                                  constDeclaration: Bool = false) -> Int32 {
        let owner = ensureDeclScope(&b)
        let global = constant || frames[owner].role == .module || frames[owner].role == .group && owner <= 1
        noteDeclared(t.start)
        return b.declare(text, t, kind: kind, listed: isListed(constant ? .variable : kind, global: global),
                         constant: constDeclaration)
    }

    /// The kind a variable-like binding gets in the nearest declaring frame.
    private func variableKind() -> Kind {
        var index = top
        while index > 0, !isContainer(frames[index].role), frames[index].role != .header { index -= 1 }
        return frames[index].role == .typeBody ? .property : .variable
    }

    // MARK: - Lookahead

    /// Index of the closer matching the opener at `k` (`(`, `[`, `{`,
    /// interpolations), -1 when there is none within the limit, `need` when
    /// more tokens are required.
    private func matching(_ a: Ahead, _ k: Int) -> Int {
        var depth = 0
        var j = k
        while j - k < Self.lookaheadLimit {
            guard let t = a.at(j) else { return a.final ? -1 : Self.need }
            switch t.kind {
            case .lparen, .lbracket, .lbrace, .interpOpen: depth += 1
            case .rparen, .rbracket, .rbrace, .interpClose: depth -= 1
            default: break
            }
            if depth <= 0 { return depth == 0 ? j : -1 }
            j += 1
        }
        return -1
    }

    /// Index of the `>` closing generic arguments opened at `k` (`<`), or -1
    /// when the tokens cannot be generic arguments (a comparison).
    private func matchingAngle(_ a: Ahead, _ k: Int) -> Int {
        var angle = 0
        var depth = 0
        var j = k
        while j - k < 512 {
            guard let t = a.at(j) else { return a.final ? -1 : Self.need }
            switch t.kind {
            case .less: if depth == 0 { angle += 1 }
            case .greater:
                if depth == 0 {
                    angle -= 1
                    if angle == 0 { return j }
                }
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket:
                depth -= 1
                if depth < 0 { return -1 }
            case .ident, .dot, .comma, .star, .question, .literal, .ellipsis, .thinArrow, .colon, .bang:
                break
            case .op:
                // `&` (references) may appear; `&&`, `||`, `<<`, … end it outside parentheses.
                if depth == 0, !(isAmp(t, a.text) && t.length == 1) { return -1 }
            case .lbrace, .rbrace, .semicolon, .assign, .augAssign, .arrow, .interpOpen, .interpClose:
                return -1
            default:
                if depth == 0 { return -1 }
            }
            j += 1
        }
        return -1
    }

    // MARK: - Main dispatch

    /// Handles the head token; returns the number of tokens consumed (0:
    /// more lookahead needed; nothing was declared or opened then).
    private mutating func handle(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        // Directive lines.
        if inDirective {
            if t.isLineStart, !prevBackslash {
                inDirective = false
                if directiveScope {
                    directiveScope = false
                    closeInline(at: prevTokenEnd, &b)
                }
            } else {
                return 1
            }
        }
        if t.isLineStart, t.kind == .op, lang.hasDirectives, unit(text, t.start) == 35 {
            return directive(t, a, &b)
        }
        switch t.kind {
        case .rparen, .rbracket, .rbrace, .interpClose:
            closeToken(t, &b)
            return 1
        case .lparen, .lbracket, .lbrace, .interpOpen:
            if overflow > 0 || frames.count >= Self.maxFrames {
                overflow += 1
                return 1
            }
        default:
            break
        }
        // Resynchronise at a declaration keyword starting a line inside
        // unclosed expression brackets.
        if t.isLineStart, prevEnd, isStrongStarter(t) {
            var popped = 0
            while popped < 16, frames.count > 1,
                  frames[top].role == .paren || frames[top].role == .bracket || frames[top].role == .header {
                let frame = frames.removeLast()
                closeDown(to: frame.base, at: t.start, &b)
                popped += 1
            }
            if popped > 0 { boundary(at: t.start, &b) }
        }
        // Swift / Go: a line break after an operand ends the statement.
        if lang.newlineTerminated, t.isLineStart, prevEnd, isStatementStarter(t), isContainer(frames[top].role) {
            let f = frames[top]
            if f.decl != .none || !f.stmtStart || openScopes.count > f.inline || f.header != .none
                || f.pending != .none {
                boundary(at: t.start, &b)
            }
        }
        let topIndex = top
        let saved = frames[topIndex]
        if frames[top].pending != .none, let n = handlePending(t, a, &b) { return n }
        let consumed = roleToken(t, a, &b)
        if consumed == 0, frames.count - 1 == topIndex { frames[topIndex] = saved }
        return consumed
    }

    private mutating func roleToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        switch frames[top].role {
        case .module, .block, .typeBody:
            return containerToken(t, a, &b)
        case .header:
            return headerFrameToken(t, a, &b)
        case .group:
            return groupToken(t, a, &b)
        case .paren, .bracket, .interp:
            if t.kind == .comma {
                closeInline(at: t.end, &b)
                return 1
            }
            return expressionToken(t, a, &b)
        }
    }

    // MARK: - References (table only)

    /// Runs over every consumed token in order: table-only references and
    /// the previous-token state.
    private mutating func stream(_ t: DeclToken, _ text: NSString, _ b: inout DeclarationBuilder) {
        if lang.notesReferences {
            if let candidate = callCandidate {
                if t.kind == .lparen { b.noteReference(text, candidate, kind: .function) }
                callCandidate = nil
            }
            if structPending {
                structPending = false
                if isName(t, text) { b.noteReference(text, t, kind: .type) }
            }
            var typePosition = false
            if newPending {
                if t.kind == .ident, t.keyword == .none {
                    newCandidate = t
                    typePosition = true
                } else if t.kind == .dot, newCandidate != nil {
                    typePosition = true
                } else {
                    if let candidate = newCandidate,
                       t.kind == .lparen || t.kind == .less || t.kind == .lbrace || t.kind == .lbracket {
                        b.noteReference(text, candidate, kind: .type)
                    }
                    newPending = false
                    newCandidate = nil
                }
            }
            if t.kind == .ident {
                switch t.keyword {
                case .new:
                    newPending = true
                    newCandidate = nil
                case .class, .struct:
                    structPending = true
                case .none:
                    if !typePosition, !(t.start >= quietFrom && t.start < quietUntil), !isDeclared(t.start) {
                        callCandidate = t
                    }
                default:
                    break
                }
            }
        }
        if lang == .swift, prevEnd, t.start == prevTokenEnd,
           t.kind == .question || t.kind == .bang || t.kind == .greater
            || t.kind == .op && t.length == 2 && unit(text, t.start) == 63 && unit(text, t.start + 1) == 63 {
            // Swift: a postfix `?` / `!` (also `??`, a double optional) or a
            // closing `>` written right after an operand (`Int?`, `value!`,
            // `Set<Int>`) ends an operand too, so a line break after it ends
            // the statement. A binary or ternary operator has a blank before
            // it. Without this the next line's declaration was read as a
            // continuation: a property became a local, a type or method
            // after it went missing.
            prevEnd = true
        } else {
            prevEnd = isOperandEnd(t)
        }
        prevKind = t.kind
        prevBackslash = t.kind == .op && unit(text, t.start) == 92
        prevTokenEnd = t.end
    }

    private mutating func isDeclared(_ start: Int) -> Bool {
        while declaredHead < declaredStarts.count, declaredStarts[declaredHead] < start { declaredHead += 1 }
        return declaredHead < declaredStarts.count && declaredStarts[declaredHead] == start
    }

    // MARK: - Directives

    /// A line-start `#`: skips the directive line(s); C / C++
    /// `#define NAME(params)` declares a function-like macro and its
    /// parameters (scope: the directive).
    private mutating func directive(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        guard let word = a.at(1) else { return a.final ? 1 : 0 }
        let name = word.kind == .ident && word.length <= 12 && !word.isLineStart
            ? text.substring(with: NSRange(location: word.start, length: word.length)) : ""
        if lang == .swift {
            // Only the conditional-compilation family; `#selector(…)` is code.
            guard ["if", "else", "elseif", "endif", "warning", "error", "sourceLocation"].contains(name) else {
                return expressionStatement()
            }
        }
        if (lang == .c || lang == .cpp), name == "define", let macro = a.at(2), macro.kind == .ident,
           !macro.isLineStart, let open = a.at(3), open.kind == .lparen, open.start == macro.end {
            let close = matching(a, 3)
            if close == Self.need { return 0 }
            if close > 3 {
                declare(macro, .function, text, &b)
                openInline(.function, at: open.start, name: -1, &b)
                var j = 4
                while j < close, let p = a.at(j) {
                    if p.isLineStart { break }
                    if isName(p, text) { declare(p, .parameter, text, &b) }
                    j += 1
                }
                directiveScope = true
                inDirective = true
                return close + 1
            }
        }
        inDirective = true
        return 1
    }

    // MARK: - Closers

    private mutating func closeToken(_ t: DeclToken, _ b: inout DeclarationBuilder) {
        if overflow > 0 {
            overflow -= 1
            return
        }
        func matches(_ role: Role) -> Bool {
            switch t.kind {
            case .rparen: return role == .paren || role == .header || role == .group
            case .rbracket: return role == .bracket
            case .rbrace: return role == .block || role == .typeBody || role == .module
            default: return role == .interp
            }
        }
        var index = top
        let floor = t.kind == .interpClose ? 1 : max(1, top - 16)
        while index >= floor, !matches(frames[index].role) { index -= 1 }
        guard index >= 1, index >= floor else { return }
        while frames.count - 1 > index {
            let frame = frames.removeLast()
            closeDown(to: frame.base, at: t.start, &b)
        }
        let frame = frames.removeLast()
        closeDown(to: frame.base, at: t.end, &b)
        afterPop(frame, t, &b)
    }

    private mutating func afterPop(_ frame: Frame, _ t: DeclToken, _ b: inout DeclarationBuilder) {
        switch frame.role {
        case .header:
            frames[top].pending = .body
        case .block, .typeBody, .module:
            if frame.continuesStatement {
                frames[top].decl = .declarator
                frames[top].declKind = frames[top].typedefStatement ? .type
                    : (frames[top].role == .typeBody ? .property : .variable)
                frames[top].stmtStart = false
            } else if frame.statementLevel {
                boundary(at: t.end, &b)
            } else if frame.fromDeclaration {
                frames[top].stmtStart = true
            } else if frames[top].role == .typeBody, frame.role == .block, frames[top].decl == .none {
                // Braces of a member the walker did not recognise (an
                // indexer, an anonymous initialiser): the member ends here.
                boundary(at: t.end, &b)
            }
        case .group:
            boundary(at: t.end, &b)
        default:
            break
        }
    }

    // MARK: - Pending constructs

    private mutating func handlePending(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let pending = frames[top].pending
        frames[top].pending = .none
        switch pending {
        case .none:
            return nil
        case .body:
            if t.kind == .lbrace {
                pushBody(t, statementLevel: true)
                return 1
            }
            if lang == .csharp, t.keyword == .when, let open = a.at(1), open.kind == .lparen {
                // Exception filter `catch (E e) when (…) {`.
                let close = matching(a, 1)
                if close == Self.need {
                    frames[top].pending = .body
                    return 0
                }
                if close > 1 {
                    frames[top].pending = .body
                    return close + 1
                }
            }
            frames[top].stmtStart = true
            return nil
        case .lambdaBody:
            if t.kind == .lbrace {
                pushBody(t, statementLevel: false)
                return 1
            }
            return nil
        case .parenHeader, .catchHeader:
            if t.kind == .lparen {
                var frame = newFrame(.header, t)
                frame.lazyStart = t.start
                frame.isCatch = pending == .catchHeader
                push(frame)
                return 1
            }
            if t.kind == .lbrace {
                pushBody(t, statementLevel: true)
                return 1
            }
            frames[top].stmtStart = true
            return nil
        }
    }

    // MARK: - Containers (file, blocks, type bodies)

    private mutating func containerToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        if frames[top].header != .none, let n = headerToken(t, a, &b) { return n }
        if t.kind == .semicolon {
            boundary(at: t.end, &b)
            return 1
        }
        if frames[top].decl != .none, let n = declToken(t, a, &b) { return n }
        if frames[top].stmtStart, let n = statementStart(t, a, &b) { return n }
        if frames[top].caseLabel, t.kind == .colon || (lang == .java && t.kind == .thinArrow) {
            frames[top].caseLabel = false
            frames[top].stmtStart = true
            return 1
        }
        if lang == .rust, frames[top].role == .typeBody, t.kind == .comma {
            frames[top].stmtStart = true
            return 1
        }
        frames[top].stmtStart = false
        return expressionToken(t, a, &b)
    }

    /// A keyword-led control header in progress (Swift, Go, Rust).
    private mutating func headerToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let header = frames[top].header
        switch t.kind {
        case .lbrace where header != .guardHeader:
            frames[top].header = .none
            frames[top].headerStart = -1
            pushBody(t, statementLevel: true)
            return 1
        case .semicolon where lang == .go:
            frames[top].clauseStart = true
            return 1
        case .semicolon:
            return nil
        default:
            break
        }
        if header == .guardHeader, t.keyword == .else {
            frames[top].header = .none
            frames[top].pending = .body
            return 1
        }
        if header == .forPattern {
            frames[top].header = .scoped
            if let n = forPattern(t, a, &b) { return n }
        }
        if lang == .go, frames[top].clauseStart {
            frames[top].clauseStart = false
            if let n = goShortVariables(at: 0, a, &b) {
                if n == 0 { frames[top].clauseStart = true }
                return n
            }
        }
        if lang == .rust, t.keyword == .let { return rustLet(a, &b) }
        if t.kind == .comma { return 1 }
        return expressionToken(t, a, &b)
    }

    /// `for` pattern up to `in` (Swift, Rust); nil when the header is not
    /// a pattern (plain expression follows).
    private mutating func forPattern(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        var k = 0
        while let u = a.at(k), u.kind == .ident,
              [.case, .try, .await, .let, .var, .mut].contains(u.keyword) {
            k += 1
        }
        let start = k
        var depth = 0
        var j = k
        while j - k < 256 {
            guard let u = a.at(j) else {
                if a.final { return nil }
                frames[top].header = .forPattern
                return 0
            }
            switch u.kind {
            case .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket, .rbrace:
                depth -= 1
                if depth < 0 { return nil }
            case .semicolon: return nil
            default: break
            }
            if depth == 0, u.kind == .ident, u.keyword == .in {
                for p in patternBindings(a, start, j, rust: lang == .rust) {
                    if let token = a.at(p) { declare(token, .variable, text, &b) }
                }
                return j + 1
            }
            if depth == 0, u.kind == .lbrace { return nil }
            j += 1
        }
        return nil
    }

    // MARK: - Declarator states

    private mutating func declToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let f = frames[top]
        switch f.decl {
        case .none:
            return nil
        case .binding:
            if isName(t, text) {
                frames[top].declName = declare(t, f.declKind, text, &b)
                frames[top].decl = .afterName
                return 1
            }
            if isWildcard(t, text) {
                frames[top].decl = .afterName
                return 1
            }
            if t.kind == .lparen {
                let close = matching(a, 0)
                if close == Self.need { return 0 }
                guard close > 0 else {
                    frames[top].decl = .none
                    return nil
                }
                for p in patternBindings(a, 1, close, rust: false) {
                    if let token = a.at(p) { declare(token, f.declKind, text, &b) }
                }
                frames[top].decl = .afterName
                frames[top].declName = -1
                return close + 1
            }
            frames[top].decl = .none
            return nil
        case .afterName:
            switch t.kind {
            case .assign:
                frames[top].decl = .initializer
                return 1
            case .comma:
                closeInline(at: t.end, &b)
                frames[top].decl = lang == .swift ? .binding : .declarator
                return 1
            case .colon:
                if lang == .swift {
                    frames[top].decl = .typeAnnotation
                    frames[top].angleDepth = 0
                } else {
                    frames[top].decl = .initializer
                }
                return 1
            case .lbracket:
                push(newFrame(.bracket, t))
                return 1
            case .lparen:
                push(newFrame(.paren, t))
                return 1
            case .lbrace:
                openAccessor(t, &b)
                return 1
            case .arrow where lang == .csharp:
                frames[top].decl = .initializer
                return 1
            default:
                if lang == .csharp, t.keyword == .in {
                    frames[top].decl = .initializer
                    return 1
                }
                frames[top].decl = .none
                return nil
            }
        case .typeAnnotation:
            switch t.kind {
            case .less:
                frames[top].angleDepth += 1
                return 1
            case .greater:
                frames[top].angleDepth = max(0, f.angleDepth - 1)
                return 1
            case .assign where f.angleDepth == 0:
                frames[top].decl = .initializer
                return 1
            case .comma where f.angleDepth == 0:
                frames[top].decl = .binding
                return 1
            case .lbrace:
                openAccessor(t, &b)
                return 1
            default:
                return expressionToken(t, a, &b)
            }
        case .initializer:
            if t.kind == .comma {
                closeInline(at: t.end, &b)
                frames[top].decl = lang == .swift ? .binding : .declarator
                return 1
            }
            return expressionToken(t, a, &b)
        case .declarator:
            if t.kind == .star || isAmp(t, text) { return 1 }
            if isName(t, text) {
                frames[top].declName = declare(t, f.declKind, text, &b)
                frames[top].decl = .afterName
                return 1
            }
            frames[top].decl = .none
            return nil
        }
    }

    /// `{` right after a declared name or its type: Swift computed property /
    /// observers (a function scope named after the property), C# property
    /// accessors, C++ brace initialisers.
    private mutating func openAccessor(_ t: DeclToken, _ b: inout DeclarationBuilder) {
        if lang == .swift {
            let name = frames[top].declName
            frames[top].decl = .none
            openInline(.function, at: t.start, name: name, &b)
            var frame = newFrame(.block, t)
            frame.base = openScopes.count - 1
            frame.statementLevel = true
            push(frame)
            return
        }
        var frame = newFrame(.block, t)
        frame.lazyStart = t.start
        frame.fromDeclaration = true
        push(frame)
    }

    // MARK: - Statement starts

    private mutating func statementStart(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        switch t.kind {
        case .lbrace:
            if lang == .swift { return nil }   // a closure expression
            pushBody(t, statementLevel: true)
            return 1
        case .at where lang == .swift || lang == .java:
            // Attribute / annotation: `@name`, `@a.b`, optional `( … )`.
            guard let n = a.at(1) else { return a.final ? 1 : 0 }
            if n.keyword == .interface { return 1 }   // Java `@interface`
            guard n.kind == .ident else { return 1 }
            let k = annotationEnd(a, from: 2)
            if k == Self.need { return 0 }
            guard let p = a.at(k) else { return k }
            if p.kind == .lparen, !p.isLineStart || lang == .java {
                let close = matching(a, k)
                if close == Self.need { return 0 }
                if close > 0 { return close + 1 }
            }
            return k
        case .less where lang == .java && role == .typeBody:
            return typeLedHeadStatement(a, &b)   // `<T> T pick(…)`
        case .lbracket where lang == .csharp && role != .block:
            let close = matching(a, 0)
            if close == Self.need { return 0 }
            return close > 0 ? close + 1 : nil
        case .lbracket where lang == .cpp:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            guard n.kind == .lbracket else { return nil }
            let close = matching(a, 0)
            if close == Self.need { return 0 }
            return close > 0 ? close + 1 : nil
        case .op where lang == .rust && unit(text, t.start) == 35:
            // Attribute `#[…]` / `#![…]`.
            var k = 1
            if a.at(k)?.kind == .bang { k += 1 }
            guard let open = a.at(k) else { return a.final ? 1 : 0 }
            guard open.kind == .lbracket else { return 1 }
            let close = matching(a, k)
            if close == Self.need { return 0 }
            return close > 0 ? close + 1 : 1
        case .literal where lang == .rust:
            // Loop label `'outer:`.
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            return n.kind == .colon ? 2 : nil
        case .op where (lang == .cpp || lang == .csharp) && unit(text, t.start) == 126:
            // Destructor `~Name(…)` in a type body.
            guard role == .typeBody else { return nil }
            guard let n = a.at(1), let p = a.at(2) else { return a.final ? nil : 0 }
            guard isName(n, text), p.kind == .lparen else { return nil }
            return functionDeclaration(name: nil, suppress: n, paren: 2, generic: -1, kind: .method,
                                       style: .typeLed, scopeAt: 2, a, &b)
        case .ident:
            break
        default:
            return nil
        }
        switch lang {
        case .swift: return swiftStatement(t, a, &b)
        case .go: return goStatement(t, a, &b)
        case .rust: return rustStatement(t, a, &b)
        default: return typeLedStatement(t, a, &b)
        }
    }

    private mutating func startHeader(_ kind: HeaderKind, _ t: DeclToken) {
        frames[top].header = kind
        frames[top].headerStart = kind == .guardHeader ? -1 : t.start
        frames[top].clauseStart = true
        frames[top].stmtStart = false
    }

    private mutating func expressionStatement() -> Int {
        frames[top].stmtStart = false
        return 1
    }

    // MARK: Swift

    private mutating func swiftStatement(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        let k = t.keyword
        if modifiers.contains(k) {
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            // `private(set)` / `fileprivate(set)`.
            if n.kind == .lparen, n.start == t.end, let inner = a.at(2), inner.kind == .ident,
               let close = a.at(3), close.kind == .rparen {
                return 4
            }
            // Contextual modifiers (`open`, `lazy`, `final`, …) only before a keyword.
            if k == .modifier { return n.kind == .ident && n.keyword != .none ? 1 : nil }
            return 1
        }
        if k == .class, let n = a.at(1),
           [.func, .var, .let, .subscript, .initializer, .modifier, .static, .override, .public, .private,
            .class].contains(n.keyword) {
            return 1
        }
        switch k {
        case .func:
            guard let n = a.at(1) else { return a.final ? 1 : 0 }
            let kind: Kind = role == .typeBody ? .method : .function
            if isName(n, text) {
                var paren = 2
                var generic = -1
                if a.at(2)?.kind == .less {
                    let close = matchingAngle(a, 2)
                    if close == Self.need { return 0 }
                    if close > 0 {
                        generic = 2
                        paren = close + 1
                    }
                }
                guard let p = a.at(paren) else { return a.final ? 2 : 0 }
                guard p.kind == .lparen else {
                    declare(n, kind, text, &b)
                    return expressionStatementCount(2)
                }
                return functionDeclaration(name: n, paren: paren, generic: generic, kind: kind, style: .swift, a, &b)
            }
            // Operator function `func ==(…)`.
            var j = 1
            while j < 6, let u = a.at(j), u.kind != .lparen { j += 1 }
            guard let p = a.at(j) else { return a.final ? 1 : 0 }
            guard p.kind == .lparen else { return expressionStatement() }
            return functionDeclaration(name: nil, paren: j, generic: -1, kind: kind, style: .swift, a, &b)
        case .initializer, .subscript:
            var j = 1
            while let u = a.at(j), u.kind == .question || u.kind == .bang { j += 1 }
            var generic = -1
            if a.at(j)?.kind == .less {
                let close = matchingAngle(a, j)
                if close == Self.need { return 0 }
                if close > 0 {
                    generic = j
                    j = close + 1
                }
            }
            guard let p = a.at(j) else { return a.final ? nil : 0 }
            guard p.kind == .lparen else { return nil }
            return functionDeclaration(name: nil, paren: j, generic: generic, kind: .method, style: .swift, a, &b)
        case .deinit:
            frames[top].pending = .body
            frames[top].stmtStart = false
            return 1
        case .var, .let:
            frames[top].decl = .binding
            frames[top].declKind = role == .typeBody ? .property : .variable
            frames[top].stmtStart = false
            return 1
        case .class, .struct, .enum, .protocol, .extension, .actor:
            return typeDeclaration(t, a, &b)
        case .typealias:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            guard isName(n, text) else { return expressionStatement() }
            declare(n, .type, text, &b)
            return expressionStatementCount(2)
        case .case where role == .typeBody:
            return expressionStatement()   // enum cases are not recorded
        case .case, .default:
            frames[top].caseLabel = true
            return expressionStatement()
        case .if, .while, .switch, .catch:
            startHeader(.scoped, t)
            return 1
        case .guard:
            startHeader(.guardHeader, t)
            return 1
        case .for:
            startHeader(.forPattern, t)
            return 1
        case .do, .repeat, .defer, .else:
            frames[top].pending = .body
            frames[top].stmtStart = false
            return 1
        default:
            if isName(t, text) {
                guard let n = a.at(1) else { return a.final ? nil : 0 }
                if n.kind == .colon { return 2 }   // label
            }
            return nil
        }
    }

    private mutating func expressionStatementCount(_ n: Int) -> Int {
        frames[top].stmtStart = false
        return n
    }

    // MARK: Go

    private mutating func goStatement(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        if role == .typeBody { return goMember(t, a, &b) }
        switch t.keyword {
        case .func:
            return goFunction(a, &b)
        case .var, .const:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .lparen {
                var frame = newFrame(.group, n)
                frame.groupKind = .variable
                frame.groupConst = t.keyword == .const
                frames[top].stmtStart = false
                push(frame)
                return 2
            }
            let end = identifierList(a, from: 1)
            if end == Self.need { return 0 }
            var j = 1
            let constDeclaration = t.keyword == .const
            while j < end, let u = a.at(j) {
                if isName(u, text) { declare(u, .variable, text, &b, constDeclaration: constDeclaration) }
                j += 1
            }
            return expressionStatementCount(max(1, end))
        case .type:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .lparen {
                var frame = newFrame(.group, n)
                frame.groupKind = .type
                frames[top].stmtStart = false
                push(frame)
                return 2
            }
            return goTypeSpec(at: 1, a, &b)
        case .import, .package:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .lparen {
                frames[top].stmtStart = false
                push(newFrame(.group, n))
                return 2
            }
            return expressionStatement()
        case .if, .for, .switch, .select:
            startHeader(.scoped, t)
            return 1
        case .else:
            frames[top].pending = .body
            frames[top].stmtStart = false
            return 1
        case .case:
            frames[top].caseLabel = true
            frames[top].stmtStart = false
            if let n = goShortVariables(at: 1, a, &b) { return n }
            return 1
        case .default:
            frames[top].caseLabel = true
            return expressionStatement()
        case .go, .defer, .return, .break, .continue, .goto, .fallthrough:
            return expressionStatement()
        default:
            guard isName(t, text) else { return nil }
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .colon { return 2 }   // label
            return goShortVariables(at: 0, a, &b)
        }
    }

    /// End index (exclusive) of `name, name, …` from `k`.
    private func identifierList(_ a: Ahead, from k: Int) -> Int {
        var j = k
        while j - k < 128 {
            guard let u = a.at(j) else { return a.final ? j : Self.need }
            guard u.kind == .ident || isWildcard(u, a.text) else { return j }
            guard let c = a.at(j + 1) else { return a.final ? j + 1 : Self.need }
            if c.kind != .comma { return j + 1 }
            j += 2
        }
        return j
    }

    /// `a, b := …` from `k`: declares the names; nil when not one.
    private mutating func goShortVariables(at k: Int, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        guard let first = a.at(k) else { return a.final ? nil : 0 }
        guard isName(first, text) || isWildcard(first, text) else { return nil }
        let end = identifierList(a, from: k)
        if end == Self.need { return 0 }
        guard let op = a.at(end) else { return a.final ? nil : 0 }
        guard op.kind == .walrus else { return nil }
        var j = k
        while j < end, let u = a.at(j) {
            if isName(u, text) { declare(u, .variable, text, &b) }
            j += 1
        }
        frames[top].stmtStart = false
        return end + 1
    }

    /// Struct fields and interface methods.
    private mutating func goMember(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        guard isName(t, text) else { return nil }
        guard let n = a.at(1) else { return a.final ? nil : 0 }
        if n.kind == .lparen, !n.isLineStart {
            return functionDeclaration(name: t, paren: 1, generic: -1, kind: .method, style: .go, a, &b)
        }
        let end = identifierList(a, from: 0)
        if end == Self.need { return 0 }
        guard let type = a.at(end) else { return a.final ? nil : 0 }
        if type.isLineStart || type.kind == .dot || type.kind == .literal || type.kind == .semicolon
            || type.kind == .rbrace {
            return nil   // embedded type
        }
        var j = 0
        while j < end, let u = a.at(j) {
            if isName(u, text) { declare(u, .property, text, &b) }
            j += 1
        }
        return expressionStatementCount(end)
    }

    /// `Name [T any] struct {` / `Name interface {` / `Name = T` / `Name T`.
    private mutating func goTypeSpec(at k: Int, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        guard let name = a.at(k) else { return a.final ? nil : 0 }
        guard isName(name, text) else { return expressionStatement() }
        var j = k + 1
        if let g = a.at(j), g.kind == .lbracket, let inner = a.at(j + 1), inner.kind == .ident,
           let after = a.at(j + 2), after.kind == .ident || after.kind == .comma {
            let close = matching(a, j)
            if close == Self.need { return 0 }
            if close > 0 { j = close + 1 }
        }
        guard let body = a.at(j) else { return a.final ? nil : 0 }
        if body.keyword == .struct || body.keyword == .interface {
            guard let brace = a.at(j + 1) else { return a.final ? nil : 0 }
            let index = declare(name, body.keyword == .struct ? .class : .type, text, &b)
            guard brace.kind == .lbrace, frames.count < Self.maxFrames else { return expressionStatementCount(j + 1) }
            openInline(.class, at: a.at(k + 1)?.start ?? brace.start, name: index, &b)
            frames[top].stmtStart = false
            var frame = newFrame(.typeBody, brace)
            frame.base = openScopes.count - 1
            frame.statementLevel = true
            frame.typeName = index
            push(frame)
            return j + 2
        }
        declare(name, .type, text, &b)
        return expressionStatementCount(k + 1)
    }

    /// `func [(recv)] Name[T](params) results {`.
    private mutating func goFunction(_ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        guard let n = a.at(1) else { return a.final ? 1 : 0 }
        var receiver = -1
        var nameAt = 1
        if n.kind == .lparen {
            let close = matching(a, 1)
            if close == Self.need { return 0 }
            guard close > 0 else { return expressionStatement() }
            receiver = 1
            nameAt = close + 1
        }
        guard let name = a.at(nameAt) else { return a.final ? 1 : 0 }
        guard isName(name, text) else { return expressionStatement() }
        var paren = nameAt + 1
        if a.at(paren)?.kind == .lbracket {
            let close = matching(a, paren)
            if close == Self.need { return 0 }
            if close > 0 { paren = close + 1 }
        }
        guard let p = a.at(paren) else { return a.final ? nameAt + 1 : 0 }
        guard p.kind == .lparen else {
            declare(name, receiver >= 0 ? .method : .function, text, &b)
            return expressionStatementCount(nameAt + 1)
        }
        return functionDeclaration(name: name, paren: paren, generic: -1,
                                   kind: receiver >= 0 ? .method : .function, style: .go,
                                   scopeAt: receiver >= 0 ? receiver : paren, receiver: receiver, a, &b)
    }

    // MARK: Rust

    private mutating func rustStatement(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        switch t.keyword {
        case .pub:
            guard let n = a.at(1) else { return a.final ? 1 : 0 }
            if n.kind == .lparen {
                let close = matching(a, 1)
                if close == Self.need { return 0 }
                if close > 0 { return close + 1 }
            }
            return 1
        case .unsafe, .async:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .lbrace || n.keyword == .move { return nil }
            return 1
        case .extern:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if n.kind == .literal { return 2 }
            return n.keyword == .crate ? expressionStatement() : 1
        case .const, .static:
            guard var n = a.at(1) else { return a.final ? nil : 0 }
            if [.fn, .unsafe, .async, .extern].contains(n.keyword) { return 1 }
            var k = 1
            if n.keyword == .mut, let m = a.at(2) {
                n = m
                k = 2
            }
            if isName(n, text) { declare(n, .variable, text, &b, constant: true) }
            return expressionStatementCount(k + 1)
        case .fn:
            guard let n = a.at(1) else { return a.final ? 1 : 0 }
            guard isName(n, text) else { return expressionStatement() }
            var paren = 2
            var generic = -1
            if a.at(2)?.kind == .less {
                let close = matchingAngle(a, 2)
                if close == Self.need { return 0 }
                if close > 0 {
                    generic = 2
                    paren = close + 1
                }
            }
            guard let p = a.at(paren) else { return a.final ? 2 : 0 }
            let kind: Kind = role == .typeBody ? .method : .function
            guard p.kind == .lparen else {
                declare(n, kind, text, &b)
                return expressionStatementCount(2)
            }
            return functionDeclaration(name: n, paren: paren, generic: generic, kind: kind, style: .rust, a, &b)
        case .let:
            return rustLet(a, &b)
        case .struct, .enum, .trait:
            return typeDeclaration(t, a, &b)
        case .union:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            return isName(n, text) ? typeDeclaration(t, a, &b) : nil
        case .impl:
            return rustImpl(t, a, &b)
        case .mod:
            guard let n = a.at(1), let brace = a.at(2) else { return a.final ? nil : 0 }
            guard isName(n, text), brace.kind == .lbrace, frames.count < Self.maxFrames else {
                return expressionStatement()
            }
            openInline(.block, at: brace.start, name: -1, &b)
            frames[top].stmtStart = false
            var frame = newFrame(.module, brace)
            frame.base = openScopes.count - 1
            frame.statementLevel = true
            push(frame)
            return 3
        case .type:
            guard let n = a.at(1) else { return a.final ? nil : 0 }
            if isName(n, text) { declare(n, .type, text, &b) }
            return expressionStatementCount(2)
        case .use:
            return expressionStatement()
        case .if, .while, .match:
            startHeader(.scoped, t)
            return 1
        case .for:
            startHeader(.forPattern, t)
            return 1
        case .loop, .else:
            frames[top].pending = .body
            frames[top].stmtStart = false
            return 1
        case .return, .break, .continue:
            return expressionStatement()
        default:
            if role == .typeBody, isName(t, text) {
                guard let n = a.at(1) else { return a.final ? nil : 0 }
                if n.kind == .colon {
                    declare(t, .property, text, &b)
                    return expressionStatementCount(1)
                }
            }
            return nil
        }
    }

    /// `let PATTERN` (statements, `if let` / `while let` headers, let
    /// chains): declares the pattern's bindings, consumes the pattern.
    private mutating func rustLet(_ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        var depth = 0
        var j = 1
        while j < 256 {
            guard let u = a.at(j) else {
                if !a.final { return 0 }
                break
            }
            switch u.kind {
            case .lparen, .lbracket, .lbrace: depth += 1
            case .rparen, .rbracket, .rbrace: depth -= 1
            default: break
            }
            if depth < 0 { break }
            if depth == 0 {
                if u.kind == .assign || u.kind == .colon || u.kind == .semicolon { break }
                if u.kind == .ident, u.keyword == .else { break }
            }
            j += 1
        }
        for p in patternBindings(a, 1, j, rust: true) {
            if let token = a.at(p) { declare(token, .variable, text, &b) }
        }
        frames[top].stmtStart = false
        return j
    }

    /// `impl<…> [Trait for] Type [where …] {`: a class scope named after
    /// the implementing type (nothing is declared).
    private mutating func rustImpl(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        var j = 1
        var depth = 0
        var angle = 0
        var typeName: DeclToken?
        while j < 512 {
            guard let u = a.at(j) else { return a.final ? expressionStatement() : 0 }
            switch u.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket: depth -= 1
            case .semicolon, .rbrace: return expressionStatementCount(j)
            case .less: angle += 1
            case .greater: angle -= 1
            case .ident where depth == 0 && angle == 0:
                if u.keyword == .for {
                    typeName = nil
                } else if u.keyword == .none, typeName == nil || a.at(j - 1)?.kind == .dot {
                    typeName = u
                } else if u.keyword == .where {
                    angle = 1000
                }
            case .lbrace where depth == 0:
                guard frames.count < Self.maxFrames, let first = a.at(1) else { return expressionStatementCount(j) }
                openInline(.class, at: first.start, name: typeName.map { b.intern(a.text, $0) } ?? -1, &b)
                frames[top].stmtStart = false
                var frame = newFrame(.typeBody, u)
                frame.base = openScopes.count - 1
                frame.statementLevel = true
                push(frame)
                return j + 1
            default: break
            }
            j += 1
        }
        return expressionStatement()
    }

    // MARK: Type declarations (all languages but Go)

    /// `class` / `struct` / `enum` / `protocol` / `extension` / `trait` /
    /// `interface` / `record` / `union` / `namespace` with a body: declares
    /// the name, opens a class scope after it and pushes the type body.
    /// Nil for C / C++ elaborated uses (`struct point p;`).
    private mutating func typeDeclaration(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let keyword = t.keyword
        var k = 1
        if lang == .cpp, keyword == .enum, let n = a.at(1), n.keyword == .class || n.keyword == .struct { k = 2 }
        guard let nameToken = a.at(k) else { return a.final ? nil : 0 }
        let cFamily = lang == .c || lang == .cpp
        if !isName(nameToken, text) {
            // Anonymous C / C++ struct / union / enum body.
            guard cFamily, nameToken.kind == .lbrace, keyword != .namespace,
                  frames.count < Self.maxFrames else { return nil }
            openInline(.class, at: nameToken.start, name: -1, &b)
            frames[top].stmtStart = false
            var frame = newFrame(.typeBody, nameToken)
            frame.base = openScopes.count - 1
            frame.continuesStatement = true
            push(frame)
            return k + 1
        }
        // Find the body.
        var j = k + 1
        var depth = 0
        var brace = -1
        var params = -1
        while j - k < 1024 {
            guard let u = a.at(j) else {
                if !a.final { return 0 }
                break
            }
            if depth == 0 {
                if u.kind == .lbrace { brace = j; break }
                if u.kind == .semicolon || u.kind == .assign && !cFamily { break }
                if u.kind == .lparen, params < 0, j == k + 1 || a.at(j - 1)?.kind == .greater {
                    params = j
                }
                if cFamily, j == k + 1 {
                    // Only `{`, `:`, `final`, `<`, `::` continue a definition.
                    if !(u.kind == .colon || u.kind == .less || u.kind == .dot
                         || u.kind == .ident && (u.keyword == .modifier || isFinal(u, text))) {
                        return nil
                    }
                }
                if lang == .swift || lang == .rust, u.isLineStart, j > k + 1, u.kind != .lbrace,
                   u.kind != .ident || u.keyword != .where {
                    break
                }
            }
            switch u.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket:
                depth -= 1
                if depth < 0 { j = k + 1024 }
            case .rbrace: j = k + 1024
            default: break
            }
            j += 1
        }
        if keyword == .namespace {
            guard brace > 0, frames.count < Self.maxFrames, let open = a.at(brace) else {
                return expressionStatement()   // C# file-scoped `namespace X;`
            }
            var last = nameToken
            var p = k + 1
            while p < brace, let d = a.at(p), d.kind == .dot, let n = a.at(p + 1), isName(n, text) {
                last = n
                p += 2
            }
            openInline(.class, at: open.start, name: b.intern(text, last), &b)
            frames[top].stmtStart = false
            var frame = newFrame(.module, open)
            frame.base = openScopes.count - 1
            frame.statementLevel = true
            push(frame)
            return brace + 1
        }
        let kind: Kind
        switch keyword {
        case .class, .struct, .record, .actor, .union: kind = .class
        default: kind = .type
        }
        let index = declare(nameToken, kind, text, &b)
        if brace < 0, params > 0, keyword == .record, let open = a.at(params) {
            // Positional record without a body: its parameters are properties.
            let close = matching(a, params)
            if close > params, let last = a.at(close) {
                openInline(.class, at: open.start, name: index, &b)
                declareParameters(a, params, close, style: .typeLed, kind: .property, &b)
                closeInline(at: last.end, &b)
                return expressionStatementCount(close + 1)
            }
        }
        guard brace > 0, frames.count < Self.maxFrames, let open = a.at(brace), let after = a.at(k + 1) else {
            return expressionStatementCount(k + 1)
        }
        openInline(.class, at: after.start, name: index, &b)
        if params > 0, lang == .java || lang == .csharp {
            let close = matching(a, params)
            if close > params, close < brace {
                declareParameters(a, params, close, style: .typeLed,
                                  kind: keyword == .record ? .property : .parameter, &b)
            }
        }
        frames[top].stmtStart = false
        var frame = newFrame(.typeBody, open)
        frame.base = openScopes.count - 1
        frame.statementLevel = !cFamily
        frame.continuesStatement = cFamily
        frame.typeName = index
        push(frame)
        if cFamily { quiet(from: after.start, to: open.start) }
        return brace + 1
    }

    private func isFinal(_ t: DeclToken, _ text: NSString) -> Bool {
        t.length == 5 && text.substring(with: NSRange(location: t.start, length: 5)) == "final"
    }

    private mutating func quiet(from start: Int, to end: Int) {
        quietFrom = start
        quietUntil = end
    }

    // MARK: Type-led languages (Java, C#, C, C++)

    private func isModifier(_ t: DeclToken, role: Role, next: DeclToken?) -> Bool {
        guard t.kind == .ident else { return false }
        if modifiers.contains(t.keyword) {
            // C++ access specifiers `public:`.
            if let next, next.kind == .colon { return false }
            return true
        }
        if t.keyword == .new, lang == .csharp, role == .typeBody { return next?.kind == .ident }
        if t.keyword == .default, lang == .java, role == .typeBody {
            if let next { return next.kind == .ident || next.kind == .less }
        }
        return false
    }

    private mutating func typeLedStatement(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        guard let n = a.at(1) else { return a.final ? typeLedHeadStatement(a, &b) : 0 }
        if isModifier(t, role: role, next: n) { return 1 }
        switch t.keyword {
        case .if, .while, .switch, .for, .foreach, .lock, .fixed:
            frames[top].pending = .parenHeader
            frames[top].stmtStart = false
            return 1
        case .catch:
            frames[top].pending = .catchHeader
            frames[top].stmtStart = false
            return 1
        case .using:
            if lang == .csharp {
                if role == .block {
                    if n.kind == .lparen {
                        frames[top].pending = .parenHeader
                        frames[top].stmtStart = false
                    }
                    return 1   // `using var x = …;` keeps the statement start
                }
                return expressionStatement()
            }
            // C++ `using X = …;` aliases a type; `using namespace …;`.
            if isName(n, text), let eq = a.at(2), eq.kind == .assign {
                declare(n, .type, text, &b)
                return expressionStatementCount(2)
            }
            return expressionStatement()
        case .try:
            if lang == .java, n.kind == .lparen {
                frames[top].pending = .parenHeader
            } else {
                frames[top].pending = .body
            }
            frames[top].stmtStart = false
            return 1
        case .do, .else, .finally:
            frames[top].pending = .body
            frames[top].stmtStart = false
            return 1
        case .checked, .unsafe:
            if n.kind == .lbrace {
                frames[top].pending = .body
                frames[top].stmtStart = false
                return 1
            }
            return t.keyword == .unsafe ? 1 : nil
        case .return, .throw, .break, .continue, .goto, .yield, .assert, .delete, .await, .new:
            return expressionStatement()
        case .case:
            frames[top].caseLabel = true
            return expressionStatement()
        case .default:
            frames[top].caseLabel = true
            return expressionStatement()
        case .public, .private, .protected:
            return n.kind == .colon ? 2 : 1
        case .class, .struct, .interface, .enum, .record, .union, .namespace:
            if t.keyword == .record, lang == .java || lang == .csharp, !isName(n, text) { break }
            if let consumed = typeDeclaration(t, a, &b) { return consumed }
        case .typedef:
            frames[top].typedefStatement = true
            return 1
        case .template:
            guard n.kind == .less else { return 1 }
            let close = matchingAngle(a, 1)
            if close == Self.need { return 0 }
            return close > 0 ? close + 1 : 1
        case .package, .import:
            return expressionStatement()
        case .extern:
            if n.kind == .literal {
                guard let brace = a.at(2) else { return a.final ? 2 : 0 }
                if brace.kind == .lbrace, frames.count < Self.maxFrames {
                    frames[top].stmtStart = false
                    var frame = newFrame(.module, brace)
                    frame.statementLevel = true
                    push(frame)
                    return 3
                }
                return 2
            }
            return 1
        default:
            break
        }
        // Label `name:`.
        if role != .typeBody, isName(t, text), n.kind == .colon { return 2 }
        return typeLedHeadStatement(a, &b)
    }

    private enum Head {
        case need, no
        case variable(Int)
        case function(name: Int, paren: Int, generic: Int)
        case constructor(name: Int, paren: Int)
        case operatorFunction(paren: Int)
        case structured(Int)
    }

    /// Classifies a type-led statement head (see the type comment).
    private func typeLedHead(_ a: Ahead, role: Role, typeName: Int32, _ b: DeclarationBuilder) -> Head {
        let text = a.text
        var k = 0
        // Prefix: modifiers, annotations, attributes, template headers.
        var guardSteps = 0
        while guardSteps < 64 {
            guardSteps += 1
            guard let t = a.at(k) else { return a.final ? .no : .need }
            if t.kind == .ident, isModifier(t, role: role, next: a.at(k + 1)) || t.keyword == .typedef {
                k += 1
                continue
            }
            if t.kind == .at, lang == .java {
                guard let n = a.at(k + 1) else { return a.final ? .no : .need }
                guard n.kind == .ident, n.keyword != .interface else { break }
                k = annotationEnd(a, from: k + 2)
                if k == Self.need { return .need }
                if a.at(k)?.kind == .lparen {
                    let close = matching(a, k)
                    if close == Self.need { return .need }
                    if close < 0 { return .no }
                    k = close + 1
                }
                continue
            }
            if t.kind == .lbracket,
               lang == .csharp && role != .block || lang == .cpp && a.at(k + 1)?.kind == .lbracket {
                let close = matching(a, k)
                if close == Self.need { return .need }
                if close < 0 { return .no }
                k = close + 1
                continue
            }
            if t.keyword == .template, a.at(k + 1)?.kind == .less {
                let close = matchingAngle(a, k + 1)
                if close == Self.need { return .need }
                if close < 0 { return .no }
                k = close + 1
                continue
            }
            if t.kind == .less, lang == .java {
                let close = matchingAngle(a, k)
                if close == Self.need { return .need }
                if close < 0 { return .no }
                k = close + 1
                continue
            }
            break
        }
        // Type.
        guard let first = a.at(k) else { return a.final ? .no : .need }
        var keywordType = false
        var autoOrVar = false
        var lastTypeIdent = -1
        var previousTypeIdent = -1
        var parts = 0
        if (lang == .c || lang == .cpp),
           first.keyword == .struct || first.keyword == .union || first.keyword == .enum || first.keyword == .class {
            k += 1
            if lang == .cpp, first.keyword == .enum, let n = a.at(k), n.keyword == .class || n.keyword == .struct {
                k += 1
            }
            guard let n = a.at(k) else { return a.final ? .no : .need }
            guard isTypeName(n) else { return .no }
            lastTypeIdent = k
            k += 1
            parts = 1
        } else if first.keyword == .typename {
            k += 1
        }
        if parts == 0, let d = a.at(k), d.keyword == .decltype, a.at(k + 1)?.kind == .lparen {
            let close = matching(a, k + 1)
            if close == Self.need { return .need }
            if close < 0 { return .no }
            k = close + 1
            parts = 1
            keywordType = true
        }
        if parts == 0 {
            while let t = a.at(k), t.kind == .ident, typeWords.contains(t.keyword) || t.keyword == .const {
                if typeWords.contains(t.keyword) {
                    keywordType = true
                    parts = 1
                    let w = text.character(at: t.start)
                    if t.keyword == .var || w == 97 && t.length == 4 { autoOrVar = true }   // var / auto
                }
                k += 1
            }
            if parts > 0, a.at(k) == nil, !a.final { return .need }
        }
        if parts == 0 {
            if a.at(k)?.kind == .dot { k += 1 }   // C++ leading `::`
            guard let t = a.at(k) else { return a.final ? .no : .need }
            guard isTypeName(t) else { return .no }
            lastTypeIdent = k
            k += 1
            parts = 1
            while true {
                guard let u = a.at(k) else { return a.final ? .no : .need }
                if u.kind == .less {
                    let close = matchingAngle(a, k)
                    if close == Self.need { return .need }
                    if close < 0 { break }
                    k = close + 1
                    continue
                }
                if u.kind == .dot, let v = a.at(k + 1), isTypeName(v) {
                    parts += 1
                    previousTypeIdent = lastTypeIdent
                    lastTypeIdent = k + 1
                    k += 2
                    continue
                }
                if u.kind == .dot, a.at(k + 1) == nil, !a.final { return .need }
                break
            }
        }
        // Suffixes.
        var pointers = 0
        var pointer: DeclToken?
        var suffixed = false
        while let u = a.at(k) {
            if u.kind == .star || isAmp(u, text) {
                pointers += 1
                pointer = u
                k += 1
                continue
            }
            if u.kind == .question, lang == .csharp {
                k += 1
                suffixed = true
                continue
            }
            if u.kind == .lbracket, lang == .java || lang == .csharp {
                var j = k + 1
                while let v = a.at(j), v.kind == .comma { j += 1 }
                guard let close = a.at(j) else { return a.final ? .no : .need }
                if close.kind == .rbracket {
                    k = j + 1
                    suffixed = true
                    continue
                }
                break
            }
            if u.kind == .ident, u.keyword == .const || u.keyword == .modifier, lang == .c || lang == .cpp {
                k += 1
                continue
            }
            break
        }
        guard let nameToken = a.at(k) else { return a.final ? .no : .need }
        if isName(nameToken, text) {
            var nameAt = k
            if lang == .cpp {
                // Qualified name `A::B::name`, `A<T>::name`; `A::~A` destructors.
                while true {
                    var dot = nameAt + 1
                    if let l = a.at(dot), l.kind == .less {
                        let close = matchingAngle(a, dot)
                        if close == Self.need { return .need }
                        guard close > 0, let d = a.at(close + 1), d.kind == .dot else { break }
                        dot = close + 1
                    }
                    if !a.final, a.at(dot + 3) == nil { return .need }
                    guard let d = a.at(dot), d.kind == .dot, let n2 = a.at(dot + 1) else { break }
                    if isName(n2, text) {
                        nameAt = dot + 1
                    } else if n2.kind == .op, unit(text, n2.start) == 126, let n3 = a.at(dot + 2), isName(n3, text) {
                        guard let p = a.at(dot + 3) else { return a.final ? .no : .need }
                        return p.kind == .lparen ? .constructor(name: dot + 2, paren: dot + 3) : .no
                    } else if n2.keyword == .operator {
                        return operatorHead(a, dot + 1)
                    } else {
                        break
                    }
                }
            }
            if !keywordType, parts == 1, pointers == 1, !suffixed, let p = pointer, lang != .java,
               isBlank(unit(text, p.start - 1)), isBlank(unit(text, p.end)) {
                return .no   // `a * b;` / `a & b;`
            }
            if lang == .java, pointers > 0 { return .no }
            guard let f = a.at(nameAt + 1) else { return a.final ? .variable(nameAt) : .need }
            switch f.kind {
            case .lparen:
                return .function(name: nameAt, paren: nameAt + 1, generic: -1)
            case .less where lang != .c:
                let close = matchingAngle(a, nameAt + 1)
                if close == Self.need { return .need }
                guard close > 0 else { return .no }
                guard let p = a.at(close + 1) else { return a.final ? .no : .need }
                return p.kind == .lparen ? .function(name: nameAt, paren: close + 1, generic: nameAt + 1) : .no
            case .assign, .semicolon, .comma, .lbracket, .lbrace, .colon:
                return .variable(nameAt)
            case .rparen where role == .header:
                return .variable(nameAt)
            case .arrow where lang == .csharp:
                return .variable(nameAt)
            case .ident where lang == .csharp && role == .header && f.keyword == .in:
                return .variable(nameAt)
            default:
                return .no
            }
        }
        if nameToken.keyword == .operator, lang == .cpp || lang == .csharp {
            return operatorHead(a, k)
        }
        if nameToken.kind == .lbracket, lang == .cpp, autoOrVar { return .structured(k) }
        if nameToken.kind == .lparen, lang == .csharp, autoOrVar { return .structured(k) }
        if nameToken.kind == .lparen, !keywordType, pointers == 0, !suffixed, lastTypeIdent >= 0 {
            guard let ident = a.at(lastTypeIdent) else { return .no }
            let identName = text.substring(with: NSRange(location: ident.start, length: ident.length))
            if role == .typeBody, typeName >= 0, Int(typeName) < b.names.count, b.names[Int(typeName)] == identName {
                return .constructor(name: lastTypeIdent, paren: k)
            }
            if lang == .cpp, parts >= 2, previousTypeIdent >= 0, let owner = a.at(previousTypeIdent),
               owner.length == ident.length,
               text.substring(with: NSRange(location: owner.start, length: owner.length)) == identName {
                return .constructor(name: lastTypeIdent, paren: k)
            }
        }
        return .no
    }

    private func isBlank(_ u: unichar) -> Bool { u == 32 || u == 9 }

    /// Index after an annotation path `name(.name)*` starting at `k`, or `need`.
    private func annotationEnd(_ a: Ahead, from start: Int) -> Int {
        var k = start
        while true {
            guard let d = a.at(k) else { return a.final ? k : Self.need }
            guard d.kind == .dot else { return k }
            guard let n = a.at(k + 1) else { return a.final ? k : Self.need }
            guard n.kind == .ident else { return k }
            k += 2
        }
    }

    /// The `(` of the parameter list after `operator` at `k`: -1 none, `need`.
    private func operatorParen(_ a: Ahead, _ k: Int) -> Int {
        for j in (k + 1)...(k + 6) where a.at(j) == nil {
            if !a.final { return Self.need }
            break
        }
        if a.at(k + 1)?.kind == .lparen, a.at(k + 2)?.kind == .rparen, a.at(k + 3)?.kind == .lparen { return k + 3 }
        var j = k + 1
        while j < k + 6, let u = a.at(j) {
            if u.kind == .lparen { return j }
            j += 1
        }
        return -1
    }

    private func operatorHead(_ a: Ahead, _ k: Int) -> Head {
        let paren = operatorParen(a, k)
        if paren == Self.need { return .need }
        return paren > 0 ? .operatorFunction(paren: paren) : .no
    }

    private mutating func typeLedHeadStatement(_ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let role = frames[top].role
        switch typeLedHead(a, role: role, typeName: frames[top].typeName, b) {
        case .need:
            return 0
        case .no:
            return nil
        case .variable(let nameAt):
            guard let name = a.at(nameAt) else { return nil }
            let kind: Kind = frames[top].typedefStatement ? .type : variableKind()
            frames[top].declName = declare(name, kind, text, &b)
            frames[top].declKind = kind
            frames[top].decl = .afterName
            frames[top].stmtStart = false
            return nameAt + 1
        case .structured(let open):
            let close = matching(a, open)
            if close == Self.need { return 0 }
            guard close > open else { return nil }
            var j = open + 1
            while j < close, let u = a.at(j) {
                if isName(u, text) { declare(u, variableKind(), text, &b) }
                j += 1
            }
            frames[top].declKind = variableKind()
            frames[top].decl = .afterName
            frames[top].stmtStart = false
            return close + 1
        case .function(let nameAt, let paren, let generic):
            guard let name = a.at(nameAt) else { return nil }
            let close = matching(a, paren)
            if close == Self.need { return 0 }
            if (lang == .c || lang == .cpp) && role != .typeBody, close > paren {
                // `Type name(args);` in a block is a direct-initialised
                // variable; at file level a prototype unless it starts with a literal.
                let tail = signatureTail(a, from: close + 1)
                if tail.need { return 0 }
                let firstArgument = a.at(paren + 1)
                let looksLikeArguments = firstArgument?.kind == .literal
                if tail.body < 0, tail.arrow < 0, role == .block || role == .header || looksLikeArguments {
                    frames[top].declName = declare(name, variableKind(), text, &b)
                    frames[top].declKind = variableKind()
                    frames[top].decl = .afterName
                    frames[top].stmtStart = false
                    return nameAt + 1
                }
            }
            let kind: Kind = role == .typeBody ? .method : .function
            return functionDeclaration(name: name, paren: paren, generic: generic, kind: kind, style: .typeLed,
                                       scopeAt: generic >= 0 ? generic : paren, a, &b)
        case .constructor(let nameAt, let paren):
            guard let name = a.at(nameAt) else { return nil }
            return functionDeclaration(name: nil, suppress: name, paren: paren, generic: -1, kind: .method,
                                       style: .typeLed, scopeAt: paren, a, &b)
        case .operatorFunction(let paren):
            return functionDeclaration(name: nil, paren: paren, generic: -1, kind: .method, style: .typeLed,
                                       scopeAt: paren, a, &b)
        }
    }

    // MARK: - Header frames (C family)

    private mutating func headerFrameToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        if t.kind == .semicolon {
            frames[top].decl = .none
            closeInline(at: t.end, &b)
            frames[top].stmtStart = true
            return 1
        }
        if frames[top].decl != .none, let n = declToken(t, a, &b) { return n }
        if t.kind == .comma {
            closeInline(at: t.end, &b)
            return 1
        }
        if frames[top].stmtStart {
            if frames[top].isCatch {
                // `catch (E e)` / `catch (A | B e)`: the last word before `)`.
                var j = 0
                var depth = 0
                while j < 256 {
                    guard let u = a.at(j) else {
                        if !a.final { return 0 }
                        break
                    }
                    if u.kind == .lparen || u.kind == .lbracket { depth += 1 }
                    if u.kind == .rparen || u.kind == .rbracket {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    j += 1
                }
                frames[top].stmtStart = false
                declareParameterItem(a, 0, j, style: .typeLed, kind: .parameter, &b)
                return max(1, j)
            }
            switch typeLedHead(a, role: .header, typeName: -1, b) {
            case .need:
                return 0
            case .variable(let nameAt):
                guard let name = a.at(nameAt) else { break }
                frames[top].declName = declare(name, .variable, text, &b)
                frames[top].declKind = .variable
                frames[top].decl = .afterName
                frames[top].stmtStart = false
                return nameAt + 1
            case .structured(let open):
                let close = matching(a, open)
                if close == Self.need { return 0 }
                guard close > open else { break }
                var j = open + 1
                while j < close, let u = a.at(j) {
                    if isName(u, text) { declare(u, .variable, text, &b) }
                    j += 1
                }
                frames[top].declKind = .variable
                frames[top].decl = .afterName
                frames[top].stmtStart = false
                return close + 1
            default:
                break
            }
            frames[top].stmtStart = false
        }
        return expressionToken(t, a, &b)
    }

    // MARK: - Go groups

    private mutating func groupToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        if t.kind == .semicolon {
            boundary(at: t.end, &b)
            return 1
        }
        if frames[top].stmtStart {
            frames[top].stmtStart = false
            switch frames[top].groupKind {
            case .variable:
                guard isName(t, text) || isWildcard(t, text) else { break }
                let end = identifierList(a, from: 0)
                if end == Self.need {
                    frames[top].stmtStart = true
                    return 0
                }
                var j = 0
                let constDeclaration = frames[top].groupConst
                while j < end, let u = a.at(j) {
                    if isName(u, text) { declare(u, .variable, text, &b, constDeclaration: constDeclaration) }
                    j += 1
                }
                return max(1, end)
            case .type:
                if let n = goTypeSpec(at: 0, a, &b) {
                    if n == 0 { frames[top].stmtStart = true }
                    return n
                }
            case .none:
                return 1
            }
        }
        return expressionToken(t, a, &b)
    }

    // MARK: - Functions

    enum ParamStyle { case typeLed, lambda, swift, go, rust }

    /// Signature tail after a parameter list: the body `{`, a C# `=>`, or
    /// where the signature ends without a body.
    private struct Tail {
        var need = false
        var body = -1
        var arrow = -1
        var end = -1
    }

    private func signatureTail(_ a: Ahead, from start: Int) -> Tail {
        var tail = Tail()
        var depth = 0
        var initList = false
        var j = start
        while j - start < 1024 {
            guard let u = a.at(j) else {
                if a.final { tail.end = j } else { tail.need = true }
                return tail
            }
            if depth == 0 {
                if lang.newlineTerminated, u.isLineStart, j > start, !isSignatureContinuation(u) {
                    tail.end = j
                    return tail
                }
                switch u.kind {
                case .lbrace:
                    let previous = j > start ? a.at(j - 1) : nil
                    if initList, let previous, previous.kind == .ident
                        || lang == .go && (previous.keyword == .interface || previous.keyword == .struct) {
                        let close = matching(a, j)
                        if close == Self.need { tail.need = true; return tail }
                        if close < 0 { tail.end = j; return tail }
                        j = close + 1
                        continue
                    }
                    if lang == .go, let previous, previous.keyword == .interface || previous.keyword == .struct {
                        let close = matching(a, j)
                        if close == Self.need { tail.need = true; return tail }
                        if close < 0 { tail.end = j; return tail }
                        j = close + 1
                        continue
                    }
                    tail.body = j
                    return tail
                case .semicolon, .rbrace, .rparen, .rbracket, .interpClose:
                    tail.end = j
                    return tail
                case .arrow where lang == .csharp:
                    tail.arrow = j
                    return tail
                case .colon where lang == .cpp:
                    initList = true
                case .comma where lang == .go || lang == .swift:
                    tail.end = j
                    return tail
                default:
                    break
                }
            }
            switch u.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket: depth -= 1
            default: break
            }
            j += 1
        }
        tail.end = j
        return tail
    }

    private func isSignatureContinuation(_ t: DeclToken) -> Bool {
        switch t.kind {
        case .lbrace, .thinArrow, .dot, .comma, .colon, .question, .bang: return true
        case .ident: return t.keyword == .throws || t.keyword == .rethrows || t.keyword == .async || t.keyword == .where
        default: return false
        }
    }

    /// A function / method / initializer head from its parameter list: the
    /// name (when given) in the enclosing scope, a function scope from
    /// `scopeAt` (default: the generics or the `(`), the parameters, Go
    /// results; then the body `{` (pushed), a C# `=>` body or the end of a
    /// bodiless signature.
    private mutating func functionDeclaration(name: DeclToken?, suppress: DeclToken? = nil, paren: Int,
                                              generic: Int, kind: Kind, style: ParamStyle,
                                              scopeAt: Int = -1, receiver: Int = -1,
                                              _ a: Ahead, _ b: inout DeclarationBuilder) -> Int? {
        let text = a.text
        let close = matching(a, paren)
        if close == Self.need { return 0 }
        guard close > paren else {
            if let name {
                declare(name, kind, text, &b)
                return expressionStatementCount(1)
            }
            return nil
        }
        var paramsEnd = close
        var results = -1
        if style == .go, let r = a.at(close + 1), r.kind == .lparen {
            let rclose = matching(a, close + 1)
            if rclose == Self.need { return 0 }
            if rclose > close + 1 {
                results = close + 1
                paramsEnd = rclose
            }
        }
        let tail = signatureTail(a, from: paramsEnd + 1)
        if tail.need { return 0 }
        // Decided: declare and open.
        let start = scopeAt >= 0 ? scopeAt : (generic >= 0 ? generic : paren)
        guard let scopeToken = a.at(start) else { return nil }
        var nameIndex: Int32 = -1
        if receiver >= 0 {
            openInline(.function, at: scopeToken.start, name: -1, &b)
            let scope = openScopes[openScopes.count - 1]
            let rclose = matching(a, receiver)
            if rclose > receiver { declareParameters(a, receiver, rclose, style: .go, kind: .parameter, &b) }
            if let name {
                nameIndex = declare(name, kind, text, &b)
                b.nameScope(scope, nameIndex)
            }
        } else {
            if let name { nameIndex = declare(name, kind, text, &b) }
            if let suppress { noteDeclared(suppress.start) }
            openInline(.function, at: scopeToken.start, name: nameIndex, &b)
        }
        declareParameters(a, paren, close, style: style, kind: .parameter, &b)
        if results >= 0 { declareParameters(a, results, paramsEnd, style: .go, kind: .parameter, &b) }
        frames[top].stmtStart = false
        frames[top].decl = .none
        if tail.body >= 0, let brace = a.at(tail.body) {
            if let after = a.at(paramsEnd + 1) { quiet(from: after.start, to: brace.start) }
            pushBody(brace, statementLevel: true)
            return tail.body + 1
        }
        if tail.arrow >= 0 {
            frames[top].decl = .initializer
            return tail.arrow + 1
        }
        let end = max(paramsEnd + 1, tail.end)
        if let after = a.at(paramsEnd + 1), end > paramsEnd + 1, let last = a.at(end - 1) {
            quiet(from: after.start, to: last.end)
        }
        let lastEnd = a.at(end - 1)?.end ?? scopeToken.end
        closeInline(at: lastEnd, &b)
        if lang.newlineTerminated { boundary(at: lastEnd, &b) }
        return end
    }

    // MARK: - Parameters and patterns

    /// Declares the bindings of the list between `open` and `close`
    /// (exclusive), split at depth-0 commas.
    private mutating func declareParameters(_ a: Ahead, _ open: Int, _ close: Int, style: ParamStyle, kind: Kind,
                                            _ b: inout DeclarationBuilder) {
        let text = a.text
        var items: [(Int, Int)] = []
        var depth = 0
        var angle = 0
        var start = open + 1
        var j = open + 1
        while j < close, let t = a.at(j) {
            switch t.kind {
            case .lparen, .lbracket, .lbrace, .interpOpen: depth += 1
            case .rparen, .rbracket, .rbrace, .interpClose: depth -= 1
            case .less where style != .go: angle += 1
            case .greater where style != .go: angle = max(0, angle - 1)
            case .comma where depth == 0 && angle == 0:
                items.append((start, j))
                start = j + 1
            default: break
            }
            j += 1
        }
        if start < close { items.append((start, close)) }
        if style == .go {
            // Either every item is named or none is: `a, b int` names both.
            var named = false
            for (s, e) in items where e - s >= 2 {
                if let first = a.at(s), isName(first, text) || isWildcard(first, text),
                   let second = a.at(s + 1), second.kind != .dot {
                    named = true
                }
            }
            guard named else { return }
            for (s, _) in items {
                if let first = a.at(s), isName(first, text) { declare(first, kind, text, &b) }
            }
            return
        }
        for (s, e) in items { declareParameterItem(a, s, e, style: style, kind: kind, &b) }
    }

    /// One parameter item `[s, e)`.
    private mutating func declareParameterItem(_ a: Ahead, _ s: Int, _ e: Int, style: ParamStyle, kind: Kind,
                                               _ b: inout DeclarationBuilder) {
        let text = a.text
        switch style {
        case .swift:
            var depth = 0
            var colon = -1
            var j = s
            while j < e, let t = a.at(j) {
                switch t.kind {
                case .lparen, .lbracket, .less: depth += 1
                case .rparen, .rbracket, .greater: depth -= 1
                case .colon where depth == 0:
                    colon = j
                default: break
                }
                if colon >= 0 { break }
                j += 1
            }
            if colon > s {
                if let t = a.at(colon - 1), isName(t, text) { declare(t, kind, text, &b) }
            } else if colon < 0, e - s == 1, let t = a.at(s), isName(t, text) {
                declare(t, kind, text, &b)
            }
        case .rust:
            var depth = 0
            var colon = e
            var j = s
            while j < e, let t = a.at(j) {
                switch t.kind {
                case .lparen, .lbracket, .lbrace, .less: depth += 1
                case .rparen, .rbracket, .rbrace, .greater: depth -= 1
                case .colon where depth == 0:
                    colon = j
                default: break
                }
                if colon < e { break }
                j += 1
            }
            for p in patternBindings(a, s, colon, rust: true) {
                if let token = a.at(p) { declare(token, kind, text, &b) }
            }
        case .typeLed, .lambda:
            var depth = 0
            var units = 0
            var last = -1
            var annotation = false
            var afterDot = false
            var j = s
            while j < e, let t = a.at(j) {
                if depth == 0, t.kind == .assign { break }
                switch t.kind {
                case .lparen, .lbracket, .lbrace, .less:
                    depth += 1
                    annotation = false
                case .rparen, .rbracket, .rbrace, .greater:
                    depth -= 1
                case .at where depth == 0:
                    annotation = true
                case .dot where depth == 0:
                    afterDot = true
                    j += 1
                    continue
                case .ident where depth == 0:
                    if annotation {
                        if a.at(j + 1)?.kind != .dot { annotation = false }
                        break
                    }
                    if afterDot {
                        last = -1
                        break
                    }
                    let keyword = t.keyword
                    if keyword != .none, !typeWords.contains(keyword), !nameWords.contains(keyword) { break }
                    units += 1
                    last = isName(t, text) ? j : -1
                default:
                    break
                }
                afterDot = false
                j += 1
            }
            if last >= 0, units >= (style == .lambda ? 1 : 2), let t = a.at(last) {
                declare(t, kind, text, &b)
            }
        case .go:
            break
        }
    }

    /// Binding names of a destructuring pattern `[s, e)`: identifiers that are
    /// not keywords, paths, constructors / variants (followed by `(` / `{`,
    /// Rust: capitalised), struct-pattern field names or labels (followed by
    /// `:`), or the wildcard.
    private func patternBindings(_ a: Ahead, _ s: Int, _ e: Int, rust: Bool) -> [Int] {
        let text = a.text
        var out: [Int] = []
        var j = s
        while j < e, let t = a.at(j) {
            defer { j += 1 }
            guard isName(t, text) else { continue }
            if j > s, let previous = a.at(j - 1), previous.kind == .dot { continue }
            if let next = j + 1 < e ? a.at(j + 1) : nil {
                switch next.kind {
                case .lparen, .lbrace, .dot, .colon: continue
                case .bang where rust: continue
                default: break
                }
            }
            if rust {
                let u = unit(text, t.start)
                if u >= 65 && u <= 90 { continue }
            }
            out.append(j)
        }
        return out
    }

    // MARK: - Expressions

    private mutating func expressionToken(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        switch t.kind {
        case .lparen:
            if lang == .java || lang == .csharp, !prevEnd {
                let close = matching(a, 0)
                if close == Self.need { return 0 }
                if close > 0 {
                    guard let arrow = a.at(close + 1) else { return a.final ? pushParen(t) : 0 }
                    if lang == .java && arrow.kind == .thinArrow || lang == .csharp && arrow.kind == .arrow {
                        openInline(.lambda, at: t.start, &b)
                        declareParameters(a, 0, close, style: .lambda, kind: .parameter, &b)
                        frames[top].pending = .lambdaBody
                        return close + 2
                    }
                }
            }
            return pushParen(t)
        case .lbracket:
            if lang == .cpp, !prevEnd, let n = cppLambda(a) {
                if n.need { return 0 }
                openInline(.lambda, at: t.start, &b)
                if n.paramsOpen >= 0 {
                    declareParameters(a, n.paramsOpen, n.paramsClose, style: .typeLed, kind: .parameter, &b)
                }
                frames[top].pending = .lambdaBody
                return n.body
            }
            push(newFrame(.bracket, t))
            return 1
        case .lbrace:
            if lang == .swift {
                let head = swiftClosureHead(a)
                if head.need { return 0 }
                if head.inIndex > 0, frames.count < Self.maxFrames {
                    openInline(.lambda, at: t.start, &b)
                    var frame = newFrame(.block, t)
                    frame.base = openScopes.count - 1
                    push(frame)
                    if head.listOpen >= 0 {
                        declareParameters(a, head.listOpen, head.listClose, style: .swift, kind: .parameter, &b)
                    } else if head.namesStart > 0 {
                        var j = head.namesStart
                        while j < head.inIndex, let u = a.at(j) {
                            if u.kind == .thinArrow { break }
                            if isName(u, text) { declare(u, .parameter, text, &b) }
                            j += 1
                        }
                    }
                    return head.inIndex + 1
                }
                pushBody(t, statementLevel: false, lazyKind: .lambda)
                return 1
            }
            var frame = newFrame(.block, t)
            frame.lazyStart = t.start
            push(frame)
            return 1
        case .interpOpen:
            push(newFrame(.interp, t))
            return 1
        case .less:
            guard lang != .go, prevKind == .ident, prevEnd else { return 1 }
            let close = matchingAngle(a, 0)
            if close == Self.need { return 0 }
            return close > 0 ? close + 1 : 1
        case .op where lang == .rust && !prevEnd && isPipe(t, text):
            return rustClosure(a, &b)
        case .ident:
            switch t.keyword {
            case .func where lang == .go:
                return goFunctionLiteral(t, a, &b)
            case .let where lang == .swift, .var where lang == .swift:
                return swiftPatternBinding(a, &b)
            case .let where lang == .rust:
                return rustLet(a, &b)
            case .out where lang == .csharp:
                guard let type = a.at(1), let name = a.at(2), let after = a.at(3) else { return a.final ? 1 : 0 }
                if typeWords.contains(type.keyword) || isTypeName(type), isName(name, text),
                   after.kind == .comma || after.kind == .rparen {
                    declare(name, .variable, text, &b)
                    return 3
                }
                return 1
            default:
                break
            }
            if (lang == .java || lang == .csharp), isName(t, text), !frames[top].caseLabel,
               t.keyword != .get, t.keyword != .set, t.keyword != .initializer {
                guard let n = a.at(1) else { return a.final ? 1 : 0 }
                if lang == .java && n.kind == .thinArrow || lang == .csharp && n.kind == .arrow {
                    openInline(.lambda, at: t.start, &b)
                    declare(t, .parameter, text, &b)
                    frames[top].pending = .lambdaBody
                    return 2
                }
            }
            return 1
        default:
            return 1
        }
    }

    private mutating func pushParen(_ t: DeclToken) -> Int {
        push(newFrame(.paren, t))
        return 1
    }

    private struct CppLambda {
        var need = false
        var paramsOpen = -1
        var paramsClose = -1
        /// Tokens to consume (up to, not including, the body `{`).
        var body = 0
    }

    /// `[captures](params) mutable -> T {` / `[captures] {`.
    private func cppLambda(_ a: Ahead) -> CppLambda? {
        let close = matching(a, 0)
        if close == Self.need { return CppLambda(need: true) }
        guard close > 0 else { return nil }
        var out = CppLambda()
        var j = close + 1
        guard let p = a.at(j) else { return a.final ? nil : CppLambda(need: true) }
        if p.kind == .lparen {
            let pclose = matching(a, j)
            if pclose == Self.need { return CppLambda(need: true) }
            guard pclose > j else { return nil }
            out.paramsOpen = j
            out.paramsClose = pclose
            j = pclose + 1
        }
        var depth = 0
        while j - close < 64 {
            guard let u = a.at(j) else { return a.final ? nil : CppLambda(need: true) }
            if depth == 0, u.kind == .lbrace {
                out.body = j
                return out
            }
            switch u.kind {
            case .lparen: depth += 1
            case .rparen:
                depth -= 1
                if depth < 0 { return nil }
            case .ident, .thinArrow, .dot, .less, .greater, .star, .comma, .literal: break
            case .op where isAmp(u, a.text): break
            default:
                if depth == 0 { return nil }
            }
            j += 1
        }
        return nil
    }

    private struct ClosureHead {
        var need = false
        var inIndex = -1
        var listOpen = -1
        var listClose = -1
        var namesStart = -1
    }

    /// Swift `{ [captures] params in`: `a, b in`, `(a: Int, b) -> T in`,
    /// `[weak self] in`.
    private func swiftClosureHead(_ a: Ahead) -> ClosureHead {
        let text = a.text
        var out = ClosureHead()
        var j = 1
        guard let first = a.at(1) else { return ClosureHead(need: !a.final) }
        if first.kind == .lbracket {
            let close = matching(a, 1)
            if close == Self.need { return ClosureHead(need: true) }
            guard close > 1 else { return out }
            j = close + 1
        }
        guard let t = a.at(j) else { return ClosureHead(need: !a.final) }
        if t.kind == .ident, t.keyword == .in {
            out.inIndex = j > 1 ? j : -1
            return out
        }
        var k = j
        if t.kind == .lparen {
            let close = matching(a, j)
            if close == Self.need { return ClosureHead(need: true) }
            guard close > j else { return out }
            out.listOpen = j
            out.listClose = close
            k = close + 1
        } else if isName(t, text) || isWildcard(t, text) {
            out.namesStart = j
            k = j + 1
            while let c = a.at(k), c.kind == .comma, let n = a.at(k + 1), isName(n, text) || isWildcard(n, text) {
                k += 2
            }
            if a.at(k) == nil, !a.final { return ClosureHead(need: true) }
        } else {
            return out
        }
        // Optional `throws` / `async` / `-> Type`, then `in`.
        var depth = 0
        while k - j < 64 {
            guard let u = a.at(k) else { return a.final ? ClosureHead() : ClosureHead(need: true) }
            if depth == 0, u.kind == .ident, u.keyword == .in {
                out.inIndex = k
                return out
            }
            switch u.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket:
                depth -= 1
                if depth < 0 { return ClosureHead() }
            case .thinArrow, .dot, .less, .greater, .question, .bang, .comma, .colon: break
            case .ident:
                if u.keyword != .none, ![.throws, .rethrows, .async, .modifier].contains(u.keyword) {
                    return ClosureHead()
                }
                if out.listOpen < 0, k > j, !(a.at(k - 1).map { [.thinArrow, .dot, .less, .comma, .colon].contains($0.kind) } ?? false),
                   u.keyword == .none {
                    return ClosureHead()
                }
            default:
                return ClosureHead()
            }
            k += 1
        }
        return ClosureHead()
    }

    /// Swift `let` / `var` in a pattern (`if let x`, `case let .a(x)`,
    /// `.some(let x)`, `catch let e`).
    private mutating func swiftPatternBinding(_ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        let text = a.text
        guard let n = a.at(1) else { return a.final ? 1 : 0 }
        if isName(n, text) {
            declare(n, .variable, text, &b)
            return 2
        }
        guard n.kind == .lparen || n.kind == .dot else { return 1 }
        var depth = 0
        var j = 1
        while j < 128 {
            guard let u = a.at(j) else {
                if !a.final { return 0 }
                break
            }
            switch u.kind {
            case .lparen, .lbracket: depth += 1
            case .rparen, .rbracket: depth -= 1
            default: break
            }
            if depth < 0 { break }
            if depth == 0 {
                switch u.kind {
                case .assign, .colon, .comma, .lbrace, .semicolon, .rbrace: break
                case .ident where u.keyword == .in || u.keyword == .where: break
                default:
                    j += 1
                    continue
                }
                break
            }
            j += 1
        }
        for p in patternBindings(a, 1, j, rust: false) {
            if let token = a.at(p) { declare(token, .variable, text, &b) }
        }
        return j
    }

    /// Rust `|params| body` / `|params| -> T { … }`.
    private mutating func rustClosure(_ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        var depth = 0
        var j = 1
        var close = -1
        while j < 256 {
            guard let u = a.at(j) else { return a.final ? 1 : 0 }
            if depth == 0, isPipe(u, a.text) {
                close = j
                break
            }
            switch u.kind {
            case .lparen, .lbracket, .less: depth += 1
            case .rparen, .rbracket, .greater:
                depth -= 1
                if depth < 0 { return 1 }
            case .semicolon, .lbrace, .rbrace: return 1
            default: break
            }
            j += 1
        }
        guard close > 0 else { return 1 }
        var end = close + 1
        if let arrow = a.at(close + 1), arrow.kind == .thinArrow {
            var k = close + 2
            var d = 0
            while k - close < 64 {
                guard let u = a.at(k) else { return a.final ? close + 1 : 0 }
                if d == 0, u.kind == .lbrace { break }
                if u.kind == .lparen || u.kind == .lbracket { d += 1 }
                if u.kind == .rparen || u.kind == .rbracket { d -= 1 }
                if u.kind == .semicolon || d < 0 { break }
                k += 1
            }
            end = k
        }
        guard let open = a.at(0) else { return 1 }
        openInline(.lambda, at: open.start, &b)
        declareParameters(a, 0, close, style: .rust, kind: .parameter, &b)
        frames[top].pending = .lambdaBody
        return end
    }

    /// Go `func(params) results { … }` literal; a `func(…) T` type binds nothing.
    private mutating func goFunctionLiteral(_ t: DeclToken, _ a: Ahead, _ b: inout DeclarationBuilder) -> Int {
        guard let p = a.at(1) else { return a.final ? 1 : 0 }
        guard p.kind == .lparen else { return 1 }
        let close = matching(a, 1)
        if close == Self.need { return 0 }
        guard close > 1 else { return 1 }
        var results = -1
        var resultsClose = -1
        var j = close + 1
        if let r = a.at(j), r.kind == .lparen, !r.isLineStart {
            let rclose = matching(a, j)
            if rclose == Self.need { return 0 }
            guard rclose > j else { return 1 }
            results = j
            resultsClose = rclose
            j = rclose + 1
        }
        // The body `{` must follow the (result) type on the same line.
        var depth = 0
        while j - close < 64 {
            guard let u = a.at(j) else { return a.final ? 1 : 0 }
            if u.isLineStart, u.kind != .lbrace { return 1 }
            if depth == 0 {
                if u.kind == .lbrace {
                    if let previous = a.at(j - 1), previous.keyword == .interface || previous.keyword == .struct {
                        let skip = matching(a, j)
                        if skip == Self.need { return 0 }
                        if skip < 0 { return 1 }
                        j = skip + 1
                        continue
                    }
                    break
                }
                switch u.kind {
                case .ident, .dot, .star, .lbracket, .rbracket, .ellipsis, .lparen: break
                default: return 1
                }
            }
            if u.kind == .lparen || u.kind == .lbracket { depth += 1 }
            if u.kind == .rparen || u.kind == .rbracket { depth -= 1 }
            j += 1
        }
        guard j - close < 64 else { return 1 }
        openInline(.lambda, at: t.start, &b)
        declareParameters(a, 1, close, style: .go, kind: .parameter, &b)
        if results >= 0 { declareParameters(a, results, resultsClose, style: .go, kind: .parameter, &b) }
        frames[top].pending = .lambdaBody
        return j
    }
}
