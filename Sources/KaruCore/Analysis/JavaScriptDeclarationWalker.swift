import Foundation

/// JavaScript / TypeScript declaration walker (M17 T17.4a, plan §5.2 "完整").
///
/// A push machine over the token stream with an explicit frame stack — one
/// frame per bracket (`(`, `[`, `{`, template / interpolation) plus the
/// module — so it can stop between any two tokens and resume in the next
/// slice. A frame's *role* decides what its tokens mean (statements, class
/// members, object entries, parameters, destructuring patterns, a `for`
/// header, an expression, a skipped TS body). Lookahead is read from the
/// token buffer; when it is not yet available (and the text has not ended)
/// the walker waits without consuming, so decisions never depend on slicing.
///
/// - **Declarations**: `function` names (declarations and expressions) and
///   parameters; arrow functions — a parenthesised list or a single
///   identifier counts **only when followed by `=>`** (TS: `(a): T =>`), so
///   `const total = (a + b)` is a variable while `const f = (a, b) => a`
///   declares function `f` with parameters `a`, `b`; `const` / `let` / `var`
///   with multiple declarators and destructuring (object incl. renames,
///   defaults, rest, nesting; arrays with holes); `catch (e)`; `for (… of /
///   in / ;)` bindings; `class` names, methods and fields (`#private`
///   included) and — scope-only, T17.5 — `this.name = …` statements inside
///   class bodies; `import x, { a as b }`, `import * as ns`, TS `import x =`;
///   TS `interface` / `type` / `enum` / `namespace` names and generic type
///   parameters as `.type`. TS type annotations (parameters, declarators,
///   fields, return types, `as` / `satisfies`) are skipped, never bindings;
///   parameter modifiers (`private readonly x`) are skipped.
/// - **Scopes**: function (from `(` or its generics `<`), arrow (from its
///   parameter list or single parameter; an expression body ends at the next
///   `,` / `;` / closing bracket / ASI line break of its frame), class (from
///   after the name), and block scopes for `{…}` blocks, `for` headers and
///   `catch` clauses — a block scope is created **lazily**, only when a
///   block-scoped declaration (`let` / `const` / `class` / function
///   declaration / TS type) appears directly in it; `var` is function-scoped.
///   Braces come from the lexer, so braces in strings, regexes and template
///   text never count; `${…}` braces are code.
/// - **Hoisting** (applied by `DeclarationScan.visibleBindings`): `var`
///   belongs to the nearest function / arrow / module scope; function
///   declarations are block-scoped (ES2015 strict semantics) and visible
///   anywhere in their block; `let` / `const` / `class` are subject to the TDZ.
///   A named function expression's name is recorded in the enclosing scope.
/// - **ASI**: in statement frames a line break between an operand end and an
///   identifier / literal ends the statement (declarator lists, arrow bodies,
///   class field initializers).
/// - **Recovery**: a closer that matches no open frame within 16 frames is
///   ignored; one that does closes the frames above it. A `function` / `class`
///   keyword first on its line after an operand, while inside an expression
///   bracket, resynchronises to the enclosing statement frame. Frames are
///   capped (`maxFrames`); deeper openers are only counted. JSX element
///   syntax (T17.8) is read as expressions: it cannot hang the walker, but
///   `{…}` children may produce stray bindings.
struct JavaScriptDeclarationWalker: Sendable {
    typealias Kind = DeclarationScan.DeclarationKind

    static let maxFrames = 512
    static let lookaheadLimit = 4096

    enum Role: UInt8, Sendable {
        case module, block, functionBody, classBody, object, paren, bracket, params
        case objectPattern, arrayPattern, forHeader, interp, skip
    }

    enum Header: UInt8, Sendable { case `if`, `while`, `for`, `switch`, `catch`, with }

    enum Pending: Equatable, Sendable {
        case none
        case afterParams(arrow: Bool, declaration: Bool)
        case arrowBody
        case header(Header)
        case afterHeader(Header, hasScope: Bool)
        case blockKeyword
    }

    enum DeclState: UInt8, Sendable { case none, binding, afterBinding, initializer }

    /// Sub-state inside a frame (meaning depends on the role).
    enum Entry: UInt8, Sendable {
        case start, afterName, afterType, fieldInit, value, afterParam, defaultValue
        case key, afterKey, rest, target, afterTarget
    }

    struct Frame: Sendable {
        var role: Role
        /// `openScopes` height to close down to when the frame pops.
        var base: Int
        /// `openScopes` height to close down to at a statement / element boundary.
        var inline: Int
        /// Block: position of `{` while its scope is not created yet (-1 none).
        var lazyStart = -1
        var opener = 0
        var stmtStart = true
        var pending: Pending = .none
        var decl: DeclState = .none
        var declKind: Kind = .variable
        var entry: Entry = .start
        var bindKind: Kind = .parameter
        var arrow = false
        var isCatch = false
        var isDeclaration = false
        var header: Header?
        var headerScope = false
        var skipDepth = 0
        var member: DeclToken?
        /// Name index of a `const f =` whose initializer is a function: names
        /// the next arrow scope opened in this frame.
        var arrowName: Int32 = -1
    }

    /// A TS type being skipped.
    struct TypeSkip: Sendable {
        var stops: UInt64
        var stopAtInOf = false
        var asi = false
        var depth = 0
        var braceDepth = 0
        var lastOperand = false
    }

    let typescript: Bool
    private var frames: [Frame] = []
    private var openScopes: [Int32] = []
    private var typeSkip: TypeSkip?
    private var lastOperandEnd = false
    private var overflow = 0

    init(typescript: Bool) {
        self.typescript = typescript
    }

    mutating func begin(moduleScope: Int32) {
        openScopes = [moduleScope]
        frames = [Frame(role: .module, base: 1, inline: 1)]
    }

    // MARK: - Driver interface

    mutating func process(_ buffer: inout DeclTokenBuffer, _ text: NSString, final: Bool,
                          _ b: inout DeclarationBuilder) {
        while let t = buffer.peek() {
            if !final, buffer.count < 3 { break }
            let consumed = handle(t, buffer, final, text, &b)
            if consumed == 0 { break }
            let last = buffer.peek(consumed - 1) ?? t
            lastOperandEnd = Self.isOperandEnd(last)
            buffer.consume(consumed)
        }
    }

    mutating func finish(at end: Int, _ b: inout DeclarationBuilder) {
        closeDown(to: 1, at: end, &b)
        frames = [Frame(role: .module, base: 1, inline: 1)]
    }

    // MARK: - Token classes

    private static func isOperandEnd(_ t: DeclToken) -> Bool {
        switch t.kind {
        case .literal, .rparen, .rbracket, .rbrace: return true
        case .ident:
            switch t.keyword {
            case .none, .this, .super, .true, .false, .null, .undefined: return true
            default: return isContextual(t.keyword)
            }
        default: return false
        }
    }

    /// Contextual words that may still be binding names.
    private static func isContextual(_ k: DeclKeyword) -> Bool {
        switch k {
        case .as, .from, .of, .get, .set, .static, .async, .await, .yield, .type, .interface, .namespace,
             .module, .declare, .abstract, .readonly, .public, .private, .protected, .override, .accessor,
             .satisfies, .keyof, .infer, .is, .using, .let:
            return true
        default:
            return false
        }
    }

    @inline(__always) private static func isBindable(_ t: DeclToken?) -> Bool {
        guard let t, t.kind == .ident, !t.isPrivateName else { return false }
        return t.keyword == .none || isContextual(t.keyword)
    }

    /// Starts a new statement after a line break (ASI).
    private static func isASIStarter(_ t: DeclToken) -> Bool {
        switch t.kind {
        case .literal: return true
        case .ident:
            switch t.keyword {
            case .in, .instanceof, .of, .as, .satisfies, .extends, .implements, .is: return false
            default: return true
            }
        default: return false
        }
    }

    private static func isMemberNameStart(_ t: DeclToken?) -> Bool {
        guard let t else { return false }
        return t.kind == .ident || t.kind == .literal || t.kind == .lbracket || t.kind == .star
    }

    private static func bit(_ k: DeclTokenKind) -> UInt64 { 1 << UInt64(k.rawValue) }

    // MARK: - Frames and scopes

    private var top: Int { frames.count - 1 }

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

    private mutating func openInline(_ kind: DeclarationScan.ScopeKind, at start: Int, name: Int32 = -1,
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
        closeInline(at: position, &b)
        frames[top].stmtStart = true
    }

    /// Before a block-scoped declaration: creates the lazy scope of the
    /// enclosing block or `for` header.
    private mutating func ensureBlockScope(_ b: inout DeclarationBuilder) {
        guard let index = frames.lastIndex(where: {
            $0.role == .block || $0.role == .functionBody || $0.role == .module || $0.role == .forHeader
        }) else { return }
        var frame = frames[index]
        let position: Int
        switch frame.role {
        case .forHeader where !frame.headerScope:
            position = frame.base
            let id = b.insertScope(.block, at: frame.opener)
            openScopes.insert(id, at: position)
            frame.base += 1
            frame.inline += 1
            frame.headerScope = true
        case .block where frame.lazyStart >= 0:
            position = frame.inline
            let id = b.insertScope(.block, at: frame.lazyStart)
            openScopes.insert(id, at: position)
            frame.inline += 1
            frame.lazyStart = -1
        default:
            return
        }
        frames[index] = frame
        for k in (index + 1)..<frames.count {
            frames[k].base += 1
            frames[k].inline += 1
        }
    }

    private mutating func declare(_ t: DeclToken, _ kind: Kind, _ text: NSString,
                                  _ b: inout DeclarationBuilder) -> Int32 {
        b.declare(text, t, kind: kind, listed: true)
    }

    // MARK: - Lookahead

    private enum Tri { case yes, no, needMore }

    /// Index (relative to the buffer head) of the token matching the opener
    /// at `k`, counting `(`, `[`, `{` and interpolations; `angles` also counts
    /// `<` / `>`. Nil: need more tokens (or `final` and none: -1).
    private func matching(_ k: Int, _ buf: DeclTokenBuffer, _ final: Bool, angles: Bool = false) -> Int? {
        var depth = 0
        var j = k
        while j - k < Self.lookaheadLimit {
            guard let t = buf.peek(j) else { return final ? -1 : nil }
            switch t.kind {
            case .lparen, .lbracket, .lbrace, .interpOpen: depth += 1
            case .rparen, .rbracket, .rbrace, .interpClose: depth -= 1
            case .less where angles: depth += 1
            case .greater where angles: depth -= 1
            case .semicolon where angles: return -1
            default: break
            }
            if depth <= 0 { return depth == 0 ? j : -1 }
            j += 1
        }
        return -1
    }

    /// Is the `(` at `k` an arrow function's parameter list?
    private func arrowParams(at k: Int, _ buf: DeclTokenBuffer, _ final: Bool) -> Tri {
        guard let close = matching(k, buf, final) else { return .needMore }
        guard close >= 0 else { return .no }
        guard let next = buf.peek(close + 1) else { return final ? .no : .needMore }
        if next.kind == .arrow { return .yes }
        guard next.kind == .colon else { return .no }
        // TS return type: `(…): T =>`.
        var depth = 0
        var j = close + 2
        while j - close < 512 {
            guard let t = buf.peek(j) else { return final ? .no : .needMore }
            switch t.kind {
            case .lparen, .lbracket, .lbrace, .less, .interpOpen: depth += 1
            case .rparen, .rbracket, .rbrace, .greater, .interpClose:
                depth -= 1
                if depth < 0 { return .no }
            case .arrow where depth == 0: return .yes
            case .semicolon, .comma, .assign: if depth == 0 { return .no }
            default: break
            }
            j += 1
        }
        return .no
    }

    /// Is the `<` at `k` a generic arrow function `<T>(…) =>`? Returns the
    /// index of the `>` too.
    private func genericArrow(at k: Int, _ buf: DeclTokenBuffer, _ final: Bool) -> (Tri, Int) {
        guard let close = matching(k, buf, final, angles: true) else { return (.needMore, 0) }
        guard close >= 0 else { return (.no, 0) }
        guard let open = buf.peek(close + 1) else { return (final ? .no : .needMore, 0) }
        guard open.kind == .lparen else { return (.no, 0) }
        return (arrowParams(at: close + 1, buf, final), close)
    }

    /// Declares the type parameters in the generics `k..<close` (`<…>`).
    private mutating func typeParameters(_ k: Int, _ close: Int, _ buf: DeclTokenBuffer, _ text: NSString,
                                         _ b: inout DeclarationBuilder) {
        var depth = 0
        var expectName = false
        var j = k
        while j <= close, let t = buf.peek(j) {
            switch t.kind {
            case .less:
                depth += 1
                if depth == 1 { expectName = true }
            case .greater:
                depth -= 1
            case .lparen, .lbracket, .lbrace:
                depth += 1
            case .rparen, .rbracket, .rbrace:
                depth -= 1
            case .comma where depth == 1:
                expectName = true
            case .ident where depth == 1 && expectName:
                if t.keyword == .const || t.keyword == .in { break }   // variance / const modifiers
                if Self.isBindable(t) { _ = declare(t, .type, text, &b) }
                expectName = false
            default:
                expectName = false
            }
            j += 1
        }
    }

    /// What an initializer starting at `k` is.
    private enum InitKind { case function, `class`, other, needMore }

    private func initializerKind(at k: Int, _ buf: DeclTokenBuffer, _ final: Bool) -> InitKind {
        guard let t = buf.peek(k) else { return final ? .other : .needMore }
        switch t.kind {
        case .ident:
            if t.keyword == .function { return .function }
            if t.keyword == .class { return .class }
            if t.keyword == .async {
                guard let n = buf.peek(k + 1) else { return final ? .other : .needMore }
                if n.keyword == .function { return .function }
                if n.kind == .lparen {
                    switch arrowParams(at: k + 1, buf, final) {
                    case .yes: return .function
                    case .no: return .other
                    case .needMore: return .needMore
                    }
                }
                if Self.isBindable(n) {
                    guard let a = buf.peek(k + 2) else { return final ? .other : .needMore }
                    return a.kind == .arrow ? .function : .other
                }
                return .other
            }
            if Self.isBindable(t) {
                guard let n = buf.peek(k + 1) else { return final ? .other : .needMore }
                return n.kind == .arrow ? .function : .other
            }
            return .other
        case .lparen:
            switch arrowParams(at: k, buf, final) {
            case .yes: return .function
            case .no: return .other
            case .needMore: return .needMore
            }
        case .less where typescript:
            switch genericArrow(at: k, buf, final).0 {
            case .yes: return .function
            case .no: return .other
            case .needMore: return .needMore
            }
        default:
            return .other
        }
    }

    // MARK: - Main dispatch

    /// Handles the head token; returns the number of tokens consumed (0:
    /// more lookahead needed).
    private mutating func handle(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                 _ b: inout DeclarationBuilder) -> Int {
        // TS type being skipped.
        if var skip = typeSkip {
            if !Self.endsTypeSkip(skip, t) {
                Self.consumeType(&skip, t)
                typeSkip = skip
                return 1
            }
            typeSkip = nil
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
        // Resynchronise at a `function` / `class` keyword starting a line
        // inside an expression bracket.
        if t.isLineStart, t.keyword == .function || t.keyword == .class, lastOperandEnd {
            var popped = 0
            while popped < 16, frames.count > 1,
                  [.paren, .bracket, .params, .objectPattern, .arrayPattern].contains(frames[top].role) {
                let frame = frames.removeLast()
                closeDown(to: frame.base, at: t.start, &b)
                popped += 1
            }
            if popped > 0 { boundary(at: t.start, &b) }
        }
        var pendingConsumed = false
        // A resolved pending state is restored when the role handler then
        // waits for lookahead (returns 0): the retry must see the same state.
        let topIndex = top
        let savedTop = frames[topIndex]
        if frames[top].pending != .none {
            let (n, ran) = handlePending(t, buf, final, text, &b)
            if let n { return n }
            pendingConsumed = ran
        }
        let consumed = roleToken(t, buf, final, text, &b, afterPending: pendingConsumed)
        if consumed == 0, frames.count - 1 == topIndex { frames[topIndex] = savedTop }
        return consumed
    }

    private mutating func roleToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                    _ b: inout DeclarationBuilder, afterPending pendingConsumed: Bool) -> Int {
        switch frames[top].role {
        case .module, .block, .functionBody:
            return statementToken(t, buf, final, text, &b, afterPending: pendingConsumed)
        case .forHeader:
            return forHeaderToken(t, buf, final, text, &b)
        case .classBody:
            return classToken(t, buf, final, text, &b)
        case .object:
            return objectToken(t, buf, final, text, &b)
        case .params:
            return paramsToken(t, buf, final, text, &b)
        case .objectPattern, .arrayPattern:
            return patternToken(t, buf, final, text, &b)
        case .paren, .bracket, .interp:
            if t.kind == .comma {
                closeInline(at: t.start, &b)
                return 1
            }
            return expressionToken(t, buf, final, text, &b)
        case .skip:
            if t.kind == .lbrace { frames[top].skipDepth += 1 }
            return 1
        }
    }

    private static func endsTypeSkip(_ skip: TypeSkip, _ t: DeclToken) -> Bool {
        if t.kind == .semicolon, skip.braceDepth == 0 { return true }
        guard skip.depth == 0 else { return false }
        if skip.stops & bit(t.kind) != 0 { return true }
        switch t.kind {
        case .rparen, .rbracket, .rbrace, .interpClose: return true
        default: break
        }
        if skip.stopAtInOf, t.keyword == .in || t.keyword == .of { return true }
        if skip.asi, t.isLineStart, skip.lastOperand, t.kind == .ident {
            switch t.keyword {
            case .extends, .keyof, .typeof, .infer, .is, .as, .satisfies, .in, .of: return false
            default: return true
            }
        }
        return false
    }

    private static func consumeType(_ skip: inout TypeSkip, _ t: DeclToken) {
        switch t.kind {
        case .lbrace:
            skip.depth += 1
            skip.braceDepth += 1
        case .rbrace:
            skip.depth = max(0, skip.depth - 1)
            skip.braceDepth = max(0, skip.braceDepth - 1)
        case .lparen, .lbracket, .less, .interpOpen:
            skip.depth += 1
        case .rparen, .rbracket, .greater, .interpClose:
            skip.depth = max(0, skip.depth - 1)
        default:
            break
        }
        switch t.kind {
        case .ident, .literal, .rparen, .rbracket, .rbrace, .greater: skip.lastOperand = true
        default: skip.lastOperand = false
        }
    }

    private mutating func startTypeSkip(_ stops: [DeclTokenKind], inOf: Bool = false, asi: Bool) {
        var mask: UInt64 = 0
        for k in stops { mask |= Self.bit(k) }
        typeSkip = TypeSkip(stops: mask, stopAtInOf: inOf, asi: asi)
    }

    // MARK: - Closers

    private mutating func closeToken(_ t: DeclToken, _ b: inout DeclarationBuilder) {
        if overflow > 0 {
            overflow -= 1
            return
        }
        if frames[top].role == .skip {
            // A skipped TS body swallows everything but its own braces.
            guard t.kind == .rbrace else { return }
            if frames[top].skipDepth > 0 {
                frames[top].skipDepth -= 1
                return
            }
        }
        func matches(_ role: Role) -> Bool {
            switch t.kind {
            case .rparen: return role == .paren || role == .params || role == .forHeader
            case .rbracket: return role == .bracket || role == .arrayPattern
            case .rbrace:
                return role == .block || role == .functionBody || role == .classBody || role == .object
                    || role == .objectPattern || role == .skip
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
        case .params:
            if frame.isCatch {
                frames[top].pending = .afterHeader(.catch, hasScope: frame.headerScope)
            } else {
                frames[top].pending = .afterParams(arrow: frame.arrow, declaration: frame.isDeclaration)
            }
        case .paren:
            if let header = frame.header { frames[top].pending = .afterHeader(header, hasScope: false) }
        case .forHeader:
            frames[top].pending = .afterHeader(.for, hasScope: frame.headerScope)
        case .functionBody, .classBody:
            if frame.isDeclaration { boundary(at: t.end, &b) }
        case .block:
            frames[top].stmtStart = true
        case .skip:
            if frame.isDeclaration { frames[top].stmtStart = true }
        default:
            break
        }
    }

    // MARK: - Pending constructs

    /// Returns (consumed, ran): consumed non-nil when the token was handled;
    /// `ran` when a pending state was resolved without consuming (the token
    /// then starts a statement body, so no ASI boundary applies to it).
    private mutating func handlePending(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                        _ b: inout DeclarationBuilder) -> (Int?, Bool) {
        switch frames[top].pending {
        case .none:
            return (nil, false)
        case .afterParams(let arrow, let declaration):
            if t.kind == .colon {
                startTypeSkip(arrow ? [.arrow] : [.lbrace, .semicolon], asi: !arrow)
                return (1, false)
            }
            if t.kind == .arrow, arrow {
                frames[top].pending = .arrowBody
                return (1, false)
            }
            frames[top].pending = .none
            if t.kind == .lbrace, !arrow {
                pushBody(t, declaration: declaration)
                return (1, false)
            }
            return (nil, false)
        case .arrowBody:
            frames[top].pending = .none
            if t.kind == .lbrace {
                pushBody(t, declaration: false)
                return (1, false)
            }
            return (nil, false)
        case .header(let header):
            if t.kind == .lparen {
                frames[top].pending = .none
                switch header {
                case .for:
                    push(newFrame(.forHeader, t))
                case .catch:
                    var opened = false
                    if let next = buf.peek(1), next.kind != .rparen {
                        openInline(.block, at: t.start, &b)
                        opened = true
                    }
                    var frame = newFrame(.params, t)
                    frame.isCatch = true
                    frame.headerScope = opened
                    push(frame)
                default:
                    var frame = newFrame(.paren, t)
                    frame.header = header
                    push(frame)
                }
                return (1, false)
            }
            if header == .for, t.keyword == .await { return (1, false) }
            frames[top].pending = .none
            if header == .catch, t.kind == .lbrace {
                pushBlock(t, adopt: false)
                return (1, false)
            }
            return (nil, false)
        case .afterHeader(_, let hasScope):
            frames[top].pending = .none
            if t.kind == .lbrace {
                pushBlock(t, adopt: hasScope)
                return (1, false)
            }
            frames[top].stmtStart = true
            return (nil, true)
        case .blockKeyword:
            frames[top].pending = .none
            if t.kind == .lbrace {
                pushBlock(t, adopt: false)
                return (1, false)
            }
            frames[top].stmtStart = true
            return (nil, true)
        }
    }

    private mutating func pushBody(_ t: DeclToken, declaration: Bool) {
        var frame = newFrame(.functionBody, t)
        // Adopt the function / arrow scope opened inline before the body.
        if openScopes.count > frames[top].inline { frame.base = openScopes.count - 1 }
        frame.isDeclaration = declaration
        push(frame)
    }

    private mutating func pushBlock(_ t: DeclToken, adopt: Bool) {
        var frame = newFrame(.block, t)
        if adopt, openScopes.count > frames[top].inline { frame.base = openScopes.count - 1 }
        frame.lazyStart = t.start
        push(frame)
    }

    // MARK: - Statements

    private mutating func statementToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                         _ b: inout DeclarationBuilder, afterPending: Bool) -> Int {
        if t.kind == .semicolon {
            boundary(at: t.start, &b)
            return 1
        }
        let f = frames[top]
        if !afterPending, t.isLineStart, lastOperandEnd, Self.isASIStarter(t),
           f.decl != .none || !f.stmtStart || openScopes.count > f.inline {
            boundary(at: t.start, &b)
        }
        if frames[top].decl != .none, let n = declToken(t, buf, final, text, &b) { return n }
        if frames[top].stmtStart, let n = statementStart(t, buf, final, text, &b) { return n }
        if t.kind == .colon {
            // `case x:` / `default:` / ternary at statement level.
            frames[top].stmtStart = true
            return 1
        }
        frames[top].stmtStart = false
        return expressionToken(t, buf, final, text, &b)
    }

    private mutating func startDeclaration(_ kind: Kind) {
        frames[top].decl = .binding
        frames[top].declKind = kind
        frames[top].stmtStart = false
    }

    /// Statement-initial keywords; nil when `t` is an ordinary expression start.
    private mutating func statementStart(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                         _ b: inout DeclarationBuilder) -> Int? {
        if t.kind == .lbrace {
            pushBlock(t, adopt: false)
            return 1
        }
        guard t.kind == .ident else { return nil }
        let n1 = buf.peek(1)
        switch t.keyword {
        case .const:
            if typescript, n1?.keyword == .enum { return enumDeclaration(at: 1, buf, final, text, &b) }
            startDeclaration(.variable)
            return 1
        case .let:
            guard let n1, Self.isBindable(n1) || n1.kind == .lbracket || n1.kind == .lbrace else { return nil }
            startDeclaration(.variable)
            return 1
        case .var:
            startDeclaration(.functionScopedVariable)
            return 1
        case .using:
            guard Self.isBindable(n1) else { return nil }
            startDeclaration(.variable)
            return 1
        case .function:
            return functionHeader(t, buf, final, text, &b, declaration: true)
        case .async:
            return n1?.keyword == .function ? 1 : nil
        case .class:
            return classHeader(buf, final, text, &b, declaration: true)
        case .export:
            if n1?.kind == .lbrace {
                var frame = newFrame(.skip, n1!)
                frame.isDeclaration = true
                push(frame)
                frames[top - 1].stmtStart = false
                return 2
            }
            if n1?.keyword == .default { return 2 }
            if n1?.kind == .star || n1?.kind == .assign {
                frames[top].stmtStart = false
                return 1
            }
            return 1
        case .default:
            return n1?.kind == .colon ? 2 : 1
        case .declare, .abstract:
            return n1?.kind == .ident ? 1 : nil
        case .if, .while, .switch, .with, .for, .catch:
            let header: Header
            switch t.keyword {
            case .if: header = .if
            case .while: header = .while
            case .switch: header = .switch
            case .with: header = .with
            case .for: header = .for
            default: header = .catch
            }
            frames[top].pending = .header(header)
            frames[top].stmtStart = false
            return 1
        case .else, .try, .finally, .do:
            frames[top].pending = .blockKeyword
            return 1
        case .import:
            if n1?.kind == .lparen || n1?.kind == .dot { return nil }
            return importDeclaration(buf, final, text, &b)
        case .interface where typescript && Self.isBindable(n1):
            return skippedTypeDeclaration(buf, final, text, &b)
        case .type where typescript && Self.isBindable(n1):
            guard let n2 = buf.peek(2) else { return final ? nil : 0 }
            guard n2.kind == .assign || n2.kind == .less else { return nil }
            ensureBlockScope(&b)
            _ = declare(n1!, .type, text, &b)
            frames[top].stmtStart = false
            startTypeSkip([], asi: true)
            return 2
        case .enum where typescript && Self.isBindable(n1):
            return enumDeclaration(at: 0, buf, final, text, &b)
        case .namespace where typescript, .module where typescript:
            guard let n1, Self.isBindable(n1) || n1.kind == .literal else { return nil }
            return namespaceDeclaration(buf, final, text, &b)
        case .this:
            // T17.5: `this.name = …` inside a class body's methods declares an
            // instance field — scope-only, so `visibleBindings` ignores it and
            // completion reads it as a member of the class (`this.`). The
            // statement itself is then read as an ordinary expression.
            guard frames.contains(where: { $0.role == .classBody }) else { return nil }
            guard let n1 else { return final ? nil : 0 }
            guard n1.kind == .dot, n1.end - n1.start == 1 else { return nil }
            guard let n2 = buf.peek(2) else { return final ? nil : 0 }
            guard n2.kind == .ident, !n2.isPrivateName else { return nil }
            guard let n3 = buf.peek(3) else { return final ? nil : 0 }
            if n3.kind == .assign { b.declare(text, n2, kind: .property, listed: false) }
            return nil
        default:
            if Self.isBindable(t), n1?.kind == .colon { return 2 }    // label
            return nil
        }
    }

    /// `const` / `let` / `var` declarator lists. Nil: not consumed here.
    private mutating func declToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                    _ b: inout DeclarationBuilder) -> Int? {
        let f = frames[top]
        switch f.decl {
        case .none:
            return nil
        case .binding:
            if Self.isBindable(t) {
                var kind = f.declKind
                if let n1 = buf.peek(1), n1.kind == .assign {
                    switch initializerKind(at: 2, buf, final) {
                    case .needMore: return 0
                    case .function: kind = .function
                    case .class: kind = .class
                    case .other: break
                    }
                } else if buf.peek(1) == nil, !final {
                    return 0
                }
                if f.declKind == .variable { ensureBlockScope(&b) }
                let name = declare(t, kind, text, &b)
                frames[top].decl = .afterBinding
                frames[top].arrowName = kind == .function ? name : -1
                return 1
            }
            if t.kind == .lbracket || t.kind == .lbrace {
                if f.declKind == .variable { ensureBlockScope(&b) }
                frames[top].decl = .afterBinding
                var frame = newFrame(t.kind == .lbrace ? .objectPattern : .arrayPattern, t)
                frame.bindKind = f.declKind
                frame.entry = .key
                push(frame)
                return 1
            }
            frames[top].decl = .none
            return nil
        case .afterBinding:
            switch t.kind {
            case .colon:
                startTypeSkip([.assign, .comma, .semicolon], inOf: true, asi: true)
                return 1
            case .bang:
                return 1
            case .assign:
                frames[top].decl = .initializer
                return 1
            case .comma:
                frames[top].decl = .binding
                return 1
            default:
                if t.keyword == .in || t.keyword == .of {
                    frames[top].decl = .none
                    return 1
                }
                frames[top].decl = .none
                return nil
            }
        case .initializer:
            if t.kind == .comma {
                closeInline(at: t.start, &b)
                frames[top].decl = .binding
                return 1
            }
            return expressionToken(t, buf, final, text, &b)
        }
    }

    private mutating func forHeaderToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool,
                                         _ text: NSString, _ b: inout DeclarationBuilder) -> Int {
        if t.kind == .semicolon {
            frames[top].decl = .none
            closeInline(at: t.start, &b)
            frames[top].stmtStart = false
            return 1
        }
        if frames[top].decl != .none, let n = declToken(t, buf, final, text, &b) { return n }
        if frames[top].stmtStart, t.kind == .ident {
            switch t.keyword {
            case .const, .let, .using:
                startDeclaration(.variable)
                return 1
            case .var:
                startDeclaration(.functionScopedVariable)
                return 1
            default:
                break
            }
        }
        frames[top].stmtStart = false
        return expressionToken(t, buf, final, text, &b)
    }

    // MARK: - Declarations with lookahead

    /// `function [*] [name] [<T>] (` — consumes through the `(`.
    private mutating func functionHeader(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool,
                                         _ text: NSString, _ b: inout DeclarationBuilder,
                                         declaration: Bool) -> Int {
        var k = 1
        if buf.peek(k)?.kind == .star { k += 1 }
        var nameToken: DeclToken?
        if let n = buf.peek(k), Self.isBindable(n) {
            nameToken = n
            k += 1
        }
        var generics: (Int, Int)?
        if typescript, buf.peek(k)?.kind == .less {
            guard let close = matching(k, buf, final, angles: true) else { return 0 }
            if close > 0 {
                generics = (k, close)
                k = close + 1
            }
        }
        guard let open = buf.peek(k) else {
            if !final { return 0 }
            if let nameToken { _ = declare(nameToken, .function, text, &b) }
            return k
        }
        var name: Int32 = takeArrowName()
        if let nameToken {
            if declaration { ensureBlockScope(&b) }
            name = declare(nameToken, .function, text, &b)
        }
        guard open.kind == .lparen || generics != nil else {
            frames[top].stmtStart = false
            return k
        }
        let scopeStart = generics.flatMap { buf.peek($0.0)?.start } ?? open.start
        openInline(.function, at: scopeStart, name: name, &b)
        if let (g0, g1) = generics { typeParameters(g0, g1, buf, text, &b) }
        frames[top].stmtStart = false
        guard open.kind == .lparen else { return k }
        var frame = newFrame(.params, open)
        frame.isDeclaration = declaration
        frame.entry = .start
        push(frame)
        return k + 1
    }

    /// `class [name] [<T>] [extends …] [implements …] {` — consumes through `{`.
    private mutating func classHeader(_ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                      _ b: inout DeclarationBuilder, declaration: Bool) -> Int {
        var k = 1
        var nameToken: DeclToken?
        if let n = buf.peek(k), Self.isBindable(n), n.keyword != .implements {
            nameToken = n
            k += 1
        }
        // Find the body `{` at depth 0. TS: an object type inside generics
        // (`class R<T extends { id: string }>`, `extends Base<{ a: T }>`) is
        // not the body, so `<` / `>` count as brackets there (T17.11c).
        var depth = 0
        var angles = 0
        var j = k
        var brace = -1
        while j - k < 1024 {
            guard let t = buf.peek(j) else {
                if !final { return 0 }
                break
            }
            if depth == 0, angles == 0, t.kind == .lbrace { brace = j; break }
            switch t.kind {
            case .lparen, .lbracket, .lbrace, .interpOpen: depth += 1
            case .rparen, .rbracket, .rbrace, .interpClose: depth -= 1
            case .less where typescript && depth == 0: angles += 1
            case .greater where typescript && depth == 0 && angles > 0: angles -= 1
            case .semicolon: j = k + 1024
            default: break
            }
            if depth < 0 { break }
            j += 1
        }
        var name: Int32 = -1
        if let nameToken {
            if declaration { ensureBlockScope(&b) }
            name = declare(nameToken, .class, text, &b)
        }
        frames[top].stmtStart = false
        guard brace >= 0, let braceToken = buf.peek(brace) else { return k }
        let scopeStart = buf.peek(k)?.start ?? braceToken.start
        openInline(.class, at: scopeStart, name: name, &b)
        if typescript, buf.peek(k)?.kind == .less, let close = matching(k, buf, final, angles: true), close > 0 {
            typeParameters(k, close, buf, text, &b)
        }
        var frame = newFrame(.classBody, braceToken)
        frame.base = openScopes.count - 1
        frame.isDeclaration = declaration
        frame.entry = .start
        push(frame)
        return brace + 1
    }

    /// `import …` up to its module specifier (or `;`).
    private mutating func importDeclaration(_ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                            _ b: inout DeclarationBuilder) -> Int {
        // Find the extent first.
        var end = -1
        var j = 1
        while j < Self.lookaheadLimit {
            guard let t = buf.peek(j) else {
                if !final { return 0 }
                break
            }
            if t.kind == .semicolon { end = j; break }
            if t.kind == .literal { end = j + 1; break }
            if j > 1, t.isLineStart, t.kind == .ident, t.keyword != .from, t.keyword != .as,
               let previous = buf.peek(j - 1), previous.kind != .comma, previous.kind != .lbrace,
               previous.keyword != .import, previous.keyword != .as, previous.kind != .star {
                end = j
                break
            }
            j += 1
        }
        if end < 0 { end = j }
        var k = 1
        if let t = buf.peek(k), t.keyword == .type, let n = buf.peek(k + 1),
           Self.isBindable(n) || n.kind == .lbrace || n.kind == .star {
            k += 1
        }
        var inBraces = false
        while k < end, let t = buf.peek(k) {
            switch t.kind {
            case .lbrace: inBraces = true
            case .rbrace: inBraces = false
            case .star:
                if let a = buf.peek(k + 1), a.keyword == .as, let n = buf.peek(k + 2), Self.isBindable(n) {
                    _ = declare(n, .import, text, &b)
                    k += 2
                }
            case .ident:
                if t.keyword == .from, !inBraces { k = end; continue }
                if inBraces, t.keyword == .type, let n = buf.peek(k + 1), n.kind == .ident { break }
                if let a = buf.peek(k + 1), a.keyword == .as, k + 2 < end {
                    if let n = buf.peek(k + 2), Self.isBindable(n) { _ = declare(n, .import, text, &b) }
                    k += 3
                    continue
                }
                if Self.isBindable(t) {
                    _ = declare(t, .import, text, &b)
                    if !inBraces, buf.peek(k + 1)?.kind == .assign {        // TS `import x = require(…)`
                        k = end
                        continue
                    }
                }
            case .literal:
                if inBraces, let a = buf.peek(k + 1), a.keyword == .as, let n = buf.peek(k + 2),
                   Self.isBindable(n) {
                    _ = declare(n, .import, text, &b)
                    k += 3
                    continue
                }
            default:
                break
            }
            k += 1
        }
        frames[top].stmtStart = false
        return max(1, end)
    }

    /// TS `interface Name … {` with a skipped body.
    private mutating func skippedTypeDeclaration(_ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                                 _ b: inout DeclarationBuilder) -> Int {
        var j = 2
        var brace = -1
        var depth = 0
        while j < 1024 {
            guard let t = buf.peek(j) else {
                if !final { return 0 }
                break
            }
            if t.kind == .lbrace, depth == 0 { brace = j; break }
            if t.kind == .semicolon { break }
            switch t.kind {
            case .lparen, .lbracket, .less: depth += 1
            case .rparen, .rbracket, .greater: depth = max(0, depth - 1)
            default: break
            }
            j += 1
        }
        ensureBlockScope(&b)
        if let name = buf.peek(1) { _ = declare(name, .type, text, &b) }
        frames[top].stmtStart = false
        guard brace >= 0, let braceToken = buf.peek(brace) else { return 2 }
        var frame = newFrame(.skip, braceToken)
        frame.isDeclaration = true
        push(frame)
        return brace + 1
    }

    /// TS `[const] enum Name {` with a skipped body; `at` is the `enum` index.
    private mutating func enumDeclaration(at k: Int, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                          _ b: inout DeclarationBuilder) -> Int {
        guard let name = buf.peek(k + 1), let brace = buf.peek(k + 2) else { return final ? k + 1 : 0 }
        guard Self.isBindable(name) else { return k + 1 }
        ensureBlockScope(&b)
        _ = declare(name, .type, text, &b)
        frames[top].stmtStart = false
        guard brace.kind == .lbrace else { return k + 2 }
        var frame = newFrame(.skip, brace)
        frame.isDeclaration = true
        push(frame)
        return k + 3
    }

    /// TS `namespace A.B {` / `module 'm' {`: a named block scope.
    private mutating func namespaceDeclaration(_ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                               _ b: inout DeclarationBuilder) -> Int {
        var j = 1
        var brace = -1
        while j < 64 {
            guard let t = buf.peek(j) else {
                if !final { return 0 }
                break
            }
            if t.kind == .lbrace { brace = j; break }
            if t.kind != .ident, t.kind != .dot, t.kind != .literal { break }
            j += 1
        }
        var name: Int32 = -1
        if let n = buf.peek(1), Self.isBindable(n) {
            ensureBlockScope(&b)
            name = declare(n, .type, text, &b)
        }
        frames[top].stmtStart = false
        guard brace >= 0, let braceToken = buf.peek(brace) else { return 2 }
        openInline(.block, at: braceToken.start, name: name, &b)
        var frame = newFrame(.block, braceToken)
        frame.base = openScopes.count - 1
        frame.isDeclaration = true
        push(frame)
        return brace + 1
    }

    // MARK: - Expressions

    private mutating func takeArrowName() -> Int32 {
        let name = frames[top].arrowName
        frames[top].arrowName = -1
        return name
    }

    private mutating func expressionToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool,
                                          _ text: NSString, _ b: inout DeclarationBuilder) -> Int {
        if frames[top].arrowName >= 0, t.keyword != .async, t.kind != .lparen, t.kind != .less, t.kind != .ident {
            frames[top].arrowName = -1
        }
        switch t.kind {
        case .ident:
            switch t.keyword {
            case .function:
                return functionHeader(t, buf, final, text, &b, declaration: false)
            case .class:
                return classHeader(buf, final, text, &b, declaration: false)
            case .as, .satisfies:
                if typescript {
                    startTypeSkip([.comma, .assign], asi: true)
                    return 1
                }
            default:
                break
            }
            if Self.isBindable(t), t.keyword != .async || buf.peek(1)?.kind == .arrow,
               let n = buf.peek(1), n.kind == .arrow {
                openInline(.lambda, at: t.start, name: takeArrowName(), &b)
                _ = declare(t, .parameter, text, &b)
                frames[top].pending = .arrowBody
                return 2
            }
            return 1
        case .lparen:
            switch arrowParams(at: 0, buf, final) {
            case .needMore:
                return 0
            case .yes:
                openInline(.lambda, at: t.start, name: takeArrowName(), &b)
                var frame = newFrame(.params, t)
                frame.arrow = true
                push(frame)
            case .no:
                push(newFrame(.paren, t))
            }
            return 1
        case .less:
            guard typescript, !lastOperandEnd else { return 1 }
            let (answer, close) = genericArrow(at: 0, buf, final)
            switch answer {
            case .needMore:
                return 0
            case .no:
                return 1
            case .yes:
                guard let open = buf.peek(close + 1) else { return 1 }
                openInline(.lambda, at: t.start, name: takeArrowName(), &b)
                typeParameters(0, close, buf, text, &b)
                var frame = newFrame(.params, open)
                frame.arrow = true
                push(frame)
                return close + 2
            }
        case .lbracket:
            push(newFrame(.bracket, t))
            return 1
        case .lbrace:
            var frame = newFrame(.object, t)
            frame.entry = .key
            push(frame)
            return 1
        case .interpOpen:
            push(newFrame(.interp, t))
            return 1
        default:
            return 1
        }
    }

    // MARK: - Class bodies

    private static let modifierKeywords: Set<DeclKeyword> = [
        .static, .public, .private, .protected, .readonly, .abstract, .override, .declare, .accessor,
        .async, .get, .set,
    ]

    private func isConstructor(_ t: DeclToken, _ text: NSString) -> Bool {
        t.length == 11 && text.substring(with: NSRange(location: t.start, length: 11)) == "constructor"
    }

    private mutating func classToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                     _ b: inout DeclarationBuilder) -> Int {
        switch frames[top].entry {
        case .afterName:
            switch t.kind {
            case .question, .bang:
                return 1
            case .lparen, .less:
                var k = 0
                var generics: (Int, Int)?
                if t.kind == .less {
                    guard let close = matching(0, buf, final, angles: true) else { return 0 }
                    if close > 0, buf.peek(close + 1) == nil, !final { return 0 }
                    guard close > 0, buf.peek(close + 1)?.kind == .lparen else {
                        frames[top].entry = .start
                        return 1
                    }
                    generics = (0, close)
                    k = close + 1
                }
                var name: Int32 = -1
                if let m = frames[top].member, m.kind == .ident, !isConstructor(m, text) {
                    name = declare(m, .method, text, &b)
                }
                frames[top].member = nil
                frames[top].entry = .start
                openInline(.function, at: t.start, name: name, &b)
                if let (g0, g1) = generics { typeParameters(g0, g1, buf, text, &b) }
                guard let open = buf.peek(k) else { return k + 1 }
                var frame = newFrame(.params, open)
                frame.entry = .start
                push(frame)
                return k + 1
            case .colon:
                declareField(text, &b)
                frames[top].entry = .afterType
                startTypeSkip([.assign, .semicolon], asi: true)
                return 1
            case .assign:
                declareField(text, &b)
                frames[top].entry = .fieldInit
                return 1
            case .semicolon:
                declareField(text, &b)
                frames[top].entry = .start
                return 1
            default:
                declareField(text, &b)
                frames[top].entry = .start
                return classToken(t, buf, final, text, &b)
            }
        case .afterType:
            switch t.kind {
            case .assign:
                frames[top].entry = .fieldInit
                return 1
            case .semicolon:
                frames[top].entry = .start
                return 1
            default:
                frames[top].entry = .start
                return classToken(t, buf, final, text, &b)
            }
        case .fieldInit:
            if t.kind == .semicolon {
                closeInline(at: t.start, &b)
                frames[top].entry = .start
                return 1
            }
            if t.isLineStart, lastOperandEnd, Self.isMemberNameStart(t) || t.kind == .at {
                closeInline(at: t.start, &b)
                frames[top].entry = .start
                return classToken(t, buf, final, text, &b)
            }
            return expressionToken(t, buf, final, text, &b)
        default:
            break
        }
        // Member start.
        closeInline(at: t.start, &b)
        switch t.kind {
        case .semicolon, .star:
            return 1
        case .at:
            var k = 1
            while let n = buf.peek(k), n.kind == .ident || n.kind == .dot { k += 1 }
            if buf.peek(k) == nil, !final { return 0 }
            return k
        case .lbracket:
            frames[top].member = nil
            frames[top].entry = .afterName
            push(newFrame(.bracket, t))
            return 1
        case .ident, .literal:
            if t.keyword == .static, buf.peek(1)?.kind == .lbrace { return 1 }
            if Self.modifierKeywords.contains(t.keyword) {
                guard let n = buf.peek(1) else { return final ? 1 : 0 }
                if Self.isMemberNameStart(n) || n.isPrivateName { return 1 }
            }
            frames[top].member = t
            frames[top].entry = .afterName
            return 1
        case .lbrace:
            pushBlock(t, adopt: false)          // `static { … }`
            return 1
        default:
            return 1
        }
    }

    private mutating func declareField(_ text: NSString, _ b: inout DeclarationBuilder) {
        if let m = frames[top].member, m.kind == .ident { _ = declare(m, .property, text, &b) }
        frames[top].member = nil
    }

    // MARK: - Object literals

    private mutating func objectToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                      _ b: inout DeclarationBuilder) -> Int {
        switch frames[top].entry {
        case .value:
            if t.kind == .comma {
                closeInline(at: t.start, &b)
                frames[top].entry = .key
                return 1
            }
            return expressionToken(t, buf, final, text, &b)
        case .afterKey:
            if t.kind == .colon {
                frames[top].entry = .value
                return 1
            }
            if t.kind == .lparen || t.kind == .less { return objectMethod(t, buf, final, text, &b) }
            frames[top].entry = .value
            return expressionToken(t, buf, final, text, &b)
        default:
            break
        }
        switch t.kind {
        case .comma:
            return 1
        case .ellipsis:
            frames[top].entry = .value
            return 1
        case .lbracket:
            frames[top].entry = .afterKey
            push(newFrame(.bracket, t))
            return 1
        case .star:
            return 1
        case .ident, .literal:
            guard let n = buf.peek(1) else { return final ? 1 : 0 }
            if t.kind == .ident, t.keyword == .get || t.keyword == .set || t.keyword == .async,
               n.kind == .ident || n.kind == .literal || n.kind == .lbracket || n.kind == .star {
                return 1
            }
            if n.kind == .lparen || n.kind == .less {
                frames[top].entry = .afterKey
                return 1
            }
            if n.kind == .colon {
                frames[top].entry = .value
                return 2
            }
            frames[top].entry = .value
            return 1
        default:
            frames[top].entry = .value
            return expressionToken(t, buf, final, text, &b)
        }
    }

    private mutating func objectMethod(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                       _ b: inout DeclarationBuilder) -> Int {
        var k = 0
        var generics: (Int, Int)?
        if t.kind == .less {
            guard let close = matching(0, buf, final, angles: true) else { return 0 }
            if close > 0, buf.peek(close + 1) == nil, !final { return 0 }
            guard close > 0, buf.peek(close + 1)?.kind == .lparen else {
                frames[top].entry = .value
                return 1
            }
            generics = (0, close)
            k = close + 1
        }
        frames[top].entry = .value
        openInline(.function, at: t.start, &b)
        if let (g0, g1) = generics { typeParameters(g0, g1, buf, text, &b) }
        guard let open = buf.peek(k) else { return k + 1 }
        var frame = newFrame(.params, open)
        frame.entry = .start
        push(frame)
        return k + 1
    }

    // MARK: - Parameters

    private static let parameterModifiers: Set<DeclKeyword> = [.public, .private, .protected, .readonly, .override]

    private mutating func paramsToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                      _ b: inout DeclarationBuilder) -> Int {
        switch frames[top].entry {
        case .afterParam:
            switch t.kind {
            case .question:
                return 1
            case .colon:
                startTypeSkip([.comma, .assign], asi: false)
                return 1
            case .assign:
                frames[top].entry = .defaultValue
                return 1
            case .comma:
                closeInline(at: t.start, &b)
                frames[top].entry = .start
                return 1
            default:
                frames[top].entry = .defaultValue
                return expressionToken(t, buf, final, text, &b)
            }
        case .defaultValue:
            if t.kind == .comma {
                closeInline(at: t.start, &b)
                frames[top].entry = .start
                return 1
            }
            return expressionToken(t, buf, final, text, &b)
        default:
            break
        }
        switch t.kind {
        case .comma, .ellipsis:
            return 1
        case .at:
            var k = 1
            while let n = buf.peek(k), n.kind == .ident || n.kind == .dot { k += 1 }
            if buf.peek(k) == nil, !final { return 0 }
            return k
        case .lbrace, .lbracket:
            frames[top].entry = .afterParam
            var frame = newFrame(t.kind == .lbrace ? .objectPattern : .arrayPattern, t)
            frame.bindKind = frames[top].bindKind
            frame.entry = .key
            push(frame)
            return 1
        case .ident:
            if Self.parameterModifiers.contains(t.keyword) {
                guard let n = buf.peek(1) else { return final ? 1 : 0 }
                if Self.isBindable(n) || n.kind == .lbrace || n.kind == .lbracket { return 1 }
            }
            if t.keyword == .this {
                frames[top].entry = .afterParam
                return 1
            }
            if Self.isBindable(t) {
                _ = declare(t, frames[top].bindKind, text, &b)
                frames[top].entry = .afterParam
                return 1
            }
            frames[top].entry = .defaultValue
            return expressionToken(t, buf, final, text, &b)
        default:
            frames[top].entry = .defaultValue
            return expressionToken(t, buf, final, text, &b)
        }
    }

    // MARK: - Destructuring patterns

    private mutating func patternToken(_ t: DeclToken, _ buf: DeclTokenBuffer, _ final: Bool, _ text: NSString,
                                       _ b: inout DeclarationBuilder) -> Int {
        let object = frames[top].role == .objectPattern
        let kind = frames[top].bindKind
        switch frames[top].entry {
        case .afterTarget:
            switch t.kind {
            case .assign:
                frames[top].entry = .defaultValue
            case .comma:
                closeInline(at: t.start, &b)
                frames[top].entry = .key
            default:
                break
            }
            return 1
        case .defaultValue:
            if t.kind == .comma {
                closeInline(at: t.start, &b)
                frames[top].entry = .key
                return 1
            }
            return expressionToken(t, buf, final, text, &b)
        case .afterKey:
            frames[top].entry = t.kind == .colon ? .target : .afterTarget
            return 1
        case .rest, .target:
            frames[top].entry = .afterTarget
            if Self.isBindable(t) {
                _ = declare(t, kind, text, &b)
                return 1
            }
            if t.kind == .lbrace || t.kind == .lbracket {
                var frame = newFrame(t.kind == .lbrace ? .objectPattern : .arrayPattern, t)
                frame.bindKind = kind
                frame.entry = .key
                push(frame)
            }
            return 1
        default:
            break
        }
        // Key (object) / element (array) start.
        switch t.kind {
        case .comma:
            return 1
        case .ellipsis:
            frames[top].entry = .rest
            return 1
        case .lbracket where object:
            frames[top].entry = .afterKey
            push(newFrame(.bracket, t))
            return 1
        case .lbrace, .lbracket:
            frames[top].entry = .afterTarget
            var frame = newFrame(t.kind == .lbrace ? .objectPattern : .arrayPattern, t)
            frame.bindKind = kind
            frame.entry = .key
            push(frame)
            return 1
        case .ident, .literal:
            if object {
                guard let n = buf.peek(1) else { return final ? 1 : 0 }
                if n.kind == .colon {
                    frames[top].entry = .target
                    return 2
                }
            }
            if Self.isBindable(t) { _ = declare(t, kind, text, &b) }
            frames[top].entry = .afterTarget
            return 1
        default:
            frames[top].entry = .afterTarget
            return 1
        }
    }
}
