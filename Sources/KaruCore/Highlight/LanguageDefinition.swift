import Foundation

/// Semantic token categories a language definition can assign to a span of
/// text. Colours live in `HighlightTheme`, keeping the definitions themselves
/// free of any AppKit dependency (so they stay pure and unit-testable).
///
/// M17 T17.7 (plan §6) splits categories by syntactic position: control-flow
/// keywords, parameters, constants, escapes, regex literals, interpolation
/// delimiters and the markup kinds each have their own case (and colour).
public enum TokenKind: Hashable, Sendable, CaseIterable {
    case keyword
    /// A control-flow keyword (`if`, `return`, `import`, …): VS Code's
    /// `keyword.control` scopes.
    case controlKeyword
    /// A standard-library / built-in identifier (`print`, `console`, `printf`,
    /// …). Coloured like a function name, but classified separately so it wins
    /// over the in-document symbol pass and never gets a plain-identifier look.
    case builtin
    case string
    case number
    case comment
    case type
    case property
    case punctuation
    /// An in-document function/method name (declared with `def`, `function`,
    /// an arrow binding, or matching the brace-language call heuristic).
    case symbolFunction
    /// An in-document variable / binding name.
    case symbolVariable
    /// A parameter at its declaration: the variable colour, a kind of its own
    /// (for completion and position roles).
    case parameter
    /// A constant or enum member (`MAX_SIZE`, a JS `const` binding).
    case constant
    /// An escape sequence inside a string (`\n`, `\x41`, `\u{1F600}`).
    case escape
    /// A regular-expression literal (JS `/re/`, a Python raw string).
    case regex
    /// An interpolation opener / closer (`${`, `}`, Swift `\(` / `)`).
    case interpolationDelimiter
    /// An HTML / XML tag name (also YAML mapping keys, which VS Code scopes
    /// as tags).
    case tagName
    /// The `<`, `</`, `>`, `/>` around a tag name.
    case tagPunctuation
    /// An HTML / XML attribute name.
    case attributeName
    /// A Markdown heading (drawn bold, see `HighlightTheme.isBold`).
    case heading
    /// A string in markup and data files — HTML / XML attribute values and
    /// CDATA, YAML plain and block scalars: the string colour in Dark Modern,
    /// blue in Light Modern (`light_vs.json` scopes these apart).
    case markupValue
    case plain
}

/// How the highlighter colours identifiers the language rules leave
/// uncoloured (M17 T17.7, plan §6: "位置确定的语法角色优先于全文符号表").
///
/// In the gaps between rule tokens every identifier is classified, first
/// match wins:
/// 1. **Position role**: a declaration of the published `DeclarationScan`
///    at exactly this range (mapped through the edit journal) takes
///    `roles[kind]` — also over an overridable rule token of the same range
///    (`HighlightEngine.overridableByRoles`: a parameter named like a
///    built-in, Python's `self` parameter).
/// 2. **Symbol table**: a file-wide declared function / type / variable
///    name, each category only when enabled here.
/// 3. `otherIdentifiers` (JS / TS, C++, C#, Go, Rust: VS Code colours every
///    reference as a variable).
///
/// Pure value, `Sendable`; the defaults keep the T17.4 behaviour (whole
/// table, no roles).
public struct IdentifierPolicy: Sendable {
    public var tableFunctions: Bool
    public var tableTypes: Bool
    public var tableVariables: Bool
    public var otherIdentifiers: TokenKind?
    /// Declaration kind → colour at the declared name.
    public var roles: [DeclarationScan.DeclarationKind: TokenKind]
    /// A `.variable` declaration written after `const` (JS / TS
    /// `const x`, destructuring included; Go `const x`) is `.constant`.
    public var constDeclarationsAreConstants: Bool
    /// `$` is an identifier character (JS / TS).
    public var dollarIdentifiers: Bool

    public init(tableFunctions: Bool = true, tableTypes: Bool = true, tableVariables: Bool = true,
                otherIdentifiers: TokenKind? = nil,
                roles: [DeclarationScan.DeclarationKind: TokenKind] = [:],
                constDeclarationsAreConstants: Bool = false, dollarIdentifiers: Bool = false) {
        self.tableFunctions = tableFunctions
        self.tableTypes = tableTypes
        self.tableVariables = tableVariables
        self.otherIdentifiers = otherIdentifiers
        self.roles = roles
        self.constDeclarationsAreConstants = constDeclarationsAreConstants
        self.dollarIdentifiers = dollarIdentifiers
    }

    /// The T17.4 behaviour: every table category, nothing else.
    public static let tableOnly = IdentifierPolicy()

    /// Functions / methods, classes / types and parameters at their
    /// declarations (what every grammar VS Code ships colours there).
    public static let declarationRoles: [DeclarationScan.DeclarationKind: TokenKind] = [
        .function: .symbolFunction, .method: .symbolFunction,
        .class: .type, .type: .type,
        .parameter: .parameter,
    ]
}

/// A single, ordered tokenizing rule: a compiled regular expression plus the
/// `TokenKind` it produces.
///
/// Rules are matched in declaration order at each scan position (see
/// `LanguageDefinition.tokenize(line:)`), so higher-priority constructs — for
/// example comments and strings, which must win over the characters they
/// contain — are listed first.
public struct LanguageRule {
    public let regex: NSRegularExpression
    public let kind: TokenKind

    /// Compiles `pattern`. Patterns are compile-time literals owned by the
    /// language definitions and are exercised by the unit tests, so an invalid
    /// pattern is a programmer error and traps here rather than being silently
    /// dropped.
    public init(pattern: String, kind: TokenKind) {
        // swiftlint:disable:next force_try
        self.regex = try! NSRegularExpression(pattern: pattern)
        self.kind = kind
    }
}

/// An ordered rule list compiled into one regular expression (M17 T17.7):
/// the rules' patterns as capturing alternatives `(p0)|(p1)|…` in order, so
/// an anchored match at a position takes the first rule that matches there
/// — the rule loop's priority — with a single regex call instead of one per
/// rule (the per-call cost dominated the highlight pass). The matching rule
/// is the first alternative whose group participated. Rules must not use
/// backreferences (group numbers shift) or match the empty string (an empty
/// match counts as no match).
struct RuleSet: @unchecked Sendable {   // NSRegularExpression is immutable and thread-safe
    private let regex: NSRegularExpression?
    private let kinds: [TokenKind]
    /// Capture group of each rule's alternative.
    private let groups: [Int]

    init(_ rules: [LanguageRule]) {
        var pattern = ""
        var groups: [Int] = []
        var next = 1
        for (index, rule) in rules.enumerated() {
            if index > 0 { pattern += "|" }
            pattern += "(" + rule.regex.pattern + ")"
            groups.append(next)
            next += 1 + rule.regex.numberOfCaptureGroups
        }
        // swiftlint:disable:next force_try
        regex = rules.isEmpty ? nil : try! NSRegularExpression(pattern: pattern)
        kinds = rules.map(\.kind)
        self.groups = groups
    }

    var isEmpty: Bool { regex == nil }

    /// The first rule matching at `range.location` (anchored, transparent
    /// bounds, `^` only at a real line start) and its match, or nil.
    func match(in line: String, range: NSRange) -> (range: NSRange, kind: TokenKind)? {
        guard let regex,
              let match = regex.firstMatch(in: line, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                                           range: range),
              match.range.length > 0 else { return nil }
        for (index, group) in groups.enumerated() where match.range(at: group).location != NSNotFound {
            return (match.range, kinds[index])
        }
        return nil
    }
}

/// Declarative, AppKit-independent description of a language for the highlighter.
///
/// Two tokenizing paths:
/// - **Unprofiled** (`lexicalProfile == nil`): `tokenize(line:)` is a pure
///   function over a single line. Constructs spanning lines (block comments,
///   multi-line strings) are only approximated per line.
/// - **Profiled** (M17 T17.2): a `LexicalProfile` describes comments and
///   strings, and the generic `LexicalScanner` carries their state across
///   lines (`tokens(in:range:state:)`). The regex `rules` then apply only to
///   the code segments the scanner reports, and rules of kind `.string` /
///   `.comment` are skipped there — the profile is authoritative for those
///   (`.string` rules still run when the profile `keepsStringRules`: HTML /
///   XML attribute values, C's `#include <header>`, Markdown inline code;
///   `.comment` rules when it `keepsCommentRules`: Markdown block quotes).
///   Line blocks (Bash heredocs, YAML block scalars, Markdown fences) are
///   profile constructs too: their bodies are one token each.
///   JSON / JSONL are profiled too (a string-only profile), so a slice that
///   starts in the middle of a long line knows whether it is inside a string.
///
/// **Long lines** (plan §6 item 2): in a line longer than
/// `longLineThreshold` the rules never see the whole line, only the code
/// segment plus `ruleContext` units on either side (so lookarounds keep their
/// context), and a profiled range may stop at a scanner safe point
/// (`tokens(in:range:stoppingAtSafePointFrom:state:)`).
///
/// Python keeps its own `PythonTokenizer` (string prefixes, f-string fields);
/// every other registered language is profiled.
public struct LanguageDefinition {
    /// Lines longer than this (UTF-16 units) are sliced: the highlighter
    /// colours only the part of them near the viewport, and the rules see a
    /// window around each code segment instead of the whole line.
    public static let longLineThreshold = 8_192

    /// Context the rules see on either side of a code segment in a long line,
    /// and the rule lead-in / lead-out around a slice (`HighlightEngine`).
    public static let ruleContext = 256

    /// Stable language id (e.g. `"json"`), also used for indent-width lookup.
    public let identifier: String

    /// File extensions (lowercased, without the dot) this definition claims.
    public let fileExtensions: [String]

    /// Ordered tokenizing rules; earlier rules take priority at each position.
    public let rules: [LanguageRule]

    /// The language's reserved words / built-ins, surfaced here so the
    /// completion module can offer them as candidates without re-parsing the
    /// tokenizer rules. Each language definition passes the same word list it
    /// already uses to build its `.keyword` rule; languages with no fixed
    /// keyword set (Markdown, HTML, CSS, XML) leave this empty.
    public let keywords: [String]

    /// Built-in / standard-library identifiers (functions, types, common
    /// globals) offered to the completion module alongside `keywords`. These
    /// are *not* part of the tokenizer's `rules` and do not participate in
    /// syntax highlighting — they exist purely to widen the completion
    /// vocabulary beyond reserved words (e.g. Python's `print`, JS's
    /// `console`). Languages with no fixed built-in set leave this empty.
    public let builtins: [String]

    /// Cross-line lexical structure for the generic scanner, or nil for a
    /// line-based (unprofiled) language.
    public let lexicalProfile: LexicalProfile?

    /// The scanner compiled from `lexicalProfile` (built once per definition).
    public let lexicalScanner: LexicalScanner?

    /// Profiled languages only: a `.string` segment that ends before its line
    /// end and is followed on the same line by an anchored match of this
    /// regex is reported as `.property` (JSON object keys: `\s*:`).
    private let propertyFollower: NSRegularExpression?

    /// `rules` compiled (`RuleSet`): all of them (line-based languages, the
    /// stateless long-line fallback), and those that run in code segments —
    /// without `.comment` / `.string` rules unless the profile keeps them
    /// (Python's tokenizer, which has no profile, skips both).
    private let allRuleSet: RuleSet
    let codeRuleSet: RuleSet
    private let stringRuleSet: RuleSet

    /// Profiled languages only (T17.7): rules matched inside string segments
    /// (not inside escapes); the rest of the string stays `.string`. Printf
    /// placeholders (`%s`, `%zu`) in C, C++ and Go.
    public let stringRules: [LanguageRule]

    /// How identifiers outside rule tokens are coloured (T17.7).
    public let identifierPolicy: IdentifierPolicy

    public init(identifier: String,
                fileExtensions: [String],
                rules: [LanguageRule],
                keywords: [String] = [],
                builtins: [String] = [],
                lexicalProfile: LexicalProfile? = nil,
                propertyStringFollower: String? = nil,
                stringRules: [LanguageRule] = [],
                identifierPolicy: IdentifierPolicy = .tableOnly) {
        self.identifier = identifier
        self.fileExtensions = fileExtensions
        self.rules = rules
        self.keywords = keywords
        self.builtins = builtins
        self.lexicalProfile = lexicalProfile
        self.lexicalScanner = lexicalProfile.map(LexicalScanner.init(profile:))
        // swiftlint:disable:next force_try
        self.propertyFollower = propertyStringFollower.map { try! NSRegularExpression(pattern: $0) }
        self.stringRules = stringRules
        self.identifierPolicy = identifierPolicy
        let keepsStrings = lexicalProfile?.keepsStringRules ?? false
        let keepsComments = lexicalProfile?.keepsCommentRules ?? false
        self.allRuleSet = RuleSet(rules)
        self.codeRuleSet = RuleSet(rules.filter {
            !($0.kind == .comment && !keepsComments) && !($0.kind == .string && !keepsStrings)
        })
        self.stringRuleSet = RuleSet(stringRules)
    }

    /// Tokenizes a single line into a list of `(range, kind)` spans.
    ///
    /// Ranges are UTF-16 offsets relative to the start of `line` (NSString
    /// semantics), so the caller can add the line's absolute offset to map them
    /// onto the text view. Positions that match no rule are left untokenized
    /// (they keep the default text colour); this is a pure function with no
    /// AppKit dependency. A profiled language tokenizes the line with a fresh
    /// lexical state (`tokens(in:range:state:)`), i.e. as if it began outside
    /// every comment and string.
    public func tokenize(line: String) -> [(range: NSRange, kind: TokenKind)] {
        if identifier == "python" {
            var state = PythonTokenizer.State()
            return PythonTokenizer.scan(line, language: self, state: &state)
        }
        let ns = line as NSString
        if lexicalScanner != nil {
            var state = LexicalScanState()
            return tokens(in: ns, range: NSRange(location: 0, length: ns.length), state: &state)
        }
        var tokens: [(range: NSRange, kind: TokenKind)] = []
        applyRules(in: line, from: 0, to: ns.length, offset: 0, ruleSet: allRuleSet) {
            tokens.append($0)
        }
        return tokens
    }

    /// Tokens of `text[range]` for a profiled language, carrying the lexical
    /// `state` (the state at `range.location` on entry, at its end on return).
    ///
    /// Ranges are absolute, ascending and non-overlapping. String and comment
    /// segments become one `.string` / `.comment` token each (a multi-line
    /// string is one token; with `propertyStringFollower`, a key string is
    /// `.property`; `stringRules` matches split a string), escapes `.escape`,
    /// interpolation delimiters the profile's `interpolationDelimiterKind`,
    /// atoms their form's kind (a `.regex` atom split into regex body,
    /// escapes and flags, `regexTokens`), line-block segments one token of
    /// their body kind (also
    /// `.plain`, which keeps symbol colouring out); inside code segments the
    /// regex `rules` run line by line exactly as in `tokenize(line:)`
    /// (anchored, transparent bounds, `^` only at a real line start), limited
    /// to the segment and skipping rules of kind `.comment` and `.string`
    /// unless the profile `keepsCommentRules` / `keepsStringRules`.
    /// In a line longer than `longLineThreshold` they see the segment plus
    /// `ruleContext` units on either side.
    ///
    /// For an unprofiled language this is the plain rule loop over each line
    /// overlapping `range`, restricted to `range`; `state` is untouched.
    public func tokens(in text: NSString, range: NSRange,
                       state: inout LexicalScanState) -> [(range: NSRange, kind: TokenKind)] {
        tokens(in: text, range: range, stop: nil, state: &state).tokens
    }

    /// Like `tokens(in:range:state:)`, but a profiled language stops at the
    /// first scanner safe point at or after `target` (clamped into `range`)
    /// and returns it as `end`; tokens cover `[range.location, end)` and
    /// `state` is the state at `end`. A code segment cut at `end` is matched
    /// as if it went on (up to `ruleContext` more units of code) and clipped,
    /// so a rule token crossing `end` keeps its kind. Unprofiled: `end` is the
    /// range end.
    public func tokens(in text: NSString, range: NSRange, stoppingAtSafePointFrom target: Int,
                       state: inout LexicalScanState) -> (tokens: [(range: NSRange, kind: TokenKind)], end: Int) {
        tokens(in: text, range: range, stop: target, state: &state)
    }

    /// Rule tokens of `text[range]`, ignoring any lexical state (every rule,
    /// strings and comments included, like `tokenize(line:)`). The rule loop
    /// runs over up to `ruleContext` units on either side of `range`, kept
    /// within `[lineStart, lineEnd)`, and the tokens are clipped to `range`,
    /// so a token crossing a slice edge keeps its kind. The highlighter's
    /// fallback for the slice of a long line in Python and unprofiled
    /// languages; never reads the whole line.
    public func statelessRuleTokens(in text: NSString, range: NSRange,
                                    lineStart: Int, lineEnd: Int) -> [(range: NSRange, kind: TokenKind)] {
        var out: [(range: NSRange, kind: TokenKind)] = []
        guard range.length > 0 else { return out }
        let windowStart = max(lineStart, range.location - Self.ruleContext)
        let windowEnd = max(NSMaxRange(range), min(lineEnd, NSMaxRange(range) + Self.ruleContext))
        let window = text.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))
        applyRules(in: window, from: 0, to: windowEnd - windowStart,
                   offset: windowStart, ruleSet: allRuleSet) { token in
            let piece = NSIntersectionRange(token.range, range)
            if piece.length > 0 { out.append((piece, token.kind)) }
        }
        return out
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func tokens(in text: NSString, range: NSRange, stop: Int?,
                        state: inout LexicalScanState) -> (tokens: [(range: NSRange, kind: TokenKind)], end: Int) {
        let start = min(max(range.location, 0), text.length)
        let end = min(max(NSMaxRange(range), start), text.length)
        var out: [(range: NSRange, kind: TokenKind)] = []
        guard end > start else { return (out, end) }

        // One line at a time: its range, cached across the code segments that
        // share it, and (short lines only) its text.
        var lineRange = NSRange(location: NSNotFound, length: 0)
        var line: String?
        func currentLine(containing location: Int) -> NSRange {
            if !NSLocationInRange(location, lineRange) {
                lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                line = nil
            }
            return lineRange
        }
        /// The text the rules see for `[from, to)` (inside line `lr`), and its
        /// start: the whole line, or a window around the span in a long line.
        func ruleWindow(_ lr: NSRange, from: Int, to: Int) -> (String, Int) {
            if lr.length <= Self.longLineThreshold {
                if line == nil { line = text.substring(with: lr) }
                return (line!, lr.location)
            }
            let ws = max(lr.location, from - Self.ruleContext)
            let we = min(NSMaxRange(lr), to + Self.ruleContext)
            return (text.substring(with: NSRange(location: ws, length: we - ws)), ws)
        }
        /// Rule tokens of `segment`; with `continuation`, the rules match as
        /// if the code went on to it and tokens are clipped to the segment.
        func ruleTokens(_ segment: NSRange, continuation: Int? = nil) {
            var loc = segment.location
            let limit = NSMaxRange(segment)
            let matchLimit = max(limit, continuation ?? limit)
            while loc < limit {
                let lr = currentLine(containing: loc)
                let upTo = min(limit, NSMaxRange(lr))
                let matchUpTo = upTo == limit ? min(matchLimit, NSMaxRange(lr)) : upTo
                let (ls, base) = ruleWindow(lr, from: loc, to: matchUpTo)
                applyRules(in: ls, from: loc - base, to: matchUpTo - base, offset: base,
                           ruleSet: lexicalScanner != nil ? codeRuleSet : allRuleSet) { token in
                    if matchUpTo > upTo {
                        let clipped = NSIntersectionRange(token.range, NSRange(location: loc, length: upTo - loc))
                        if clipped.length > 0 { out.append((clipped, token.kind)) }
                    } else {
                        out.append(token)
                    }
                }
                loc = upTo
            }
        }

        guard let scanner = lexicalScanner else {
            ruleTokens(NSRange(location: start, length: end - start))
            return (out, end)
        }
        var segments: [(NSRange, LexicalSegment)] = []
        var stopped = end
        if let stop {
            stopped = scanner.segments(text, from: start, to: end, stoppingAtSafePointFrom: stop,
                                       state: &state) { segments.append(($0, $1)) }
        } else {
            scanner.segments(text, from: start, to: end, state: &state) { segments.append(($0, $1)) }
        }

        // A range cut inside a line: the segment that goes on past `stopped`,
        // from a short look-ahead scan on a copy of the state, so a cut code
        // segment's rules and a cut key string see what follows the cut.
        // `complete`: that segment ends inside the look-ahead window.
        var next: (range: NSRange, kind: LexicalSegment, complete: Bool)?
        if let last = segments.last?.1, stopped < text.length,
           last == .code || (last == .string && propertyFollower != nil) {
            let lr = currentLine(containing: stopped - 1)
            let window = last == .code ? Self.ruleContext : Self.longLineThreshold
            let windowEnd = min(NSMaxRange(lr), stopped + window)
            if windowEnd > stopped {
                var probe = state
                var first: (NSRange, LexicalSegment)?
                var count = 0
                scanner.segments(text, from: stopped, to: windowEnd, state: &probe) { range, kind in
                    if first == nil { first = (range, kind) }
                    count += 1
                }
                if let first { next = (first.0, first.1, count > 1) }
            }
        }

        /// A string ending at `stringEnd` is a key when the follower matches
        /// right after it on the same line.
        func isKey(_ stringEnd: Int) -> Bool {
            guard let follower = propertyFollower, stringEnd > 0 else { return false }
            let lr = currentLine(containing: stringEnd - 1)
            let lineEnd = NSMaxRange(lr)
            guard stringEnd < lineEnd else { return false }
            let (subject, base): (String, Int)
            let to: Int
            if lr.length <= Self.longLineThreshold {
                (subject, base) = ruleWindow(lr, from: stringEnd, to: lineEnd)
                to = lineEnd
            } else {
                to = min(lineEnd, stringEnd + Self.ruleContext)
                (subject, base) = (text.substring(with: NSRange(location: stringEnd, length: to - stringEnd)), stringEnd)
            }
            return follower.firstMatch(in: subject, options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                                       range: NSRange(location: stringEnd - base, length: to - stringEnd)) != nil
        }

        for (segment, kind) in segments {
            let isLast = NSMaxRange(segment) == stopped
            switch kind {
            case .code:
                var continuation: Int?
                if isLast, let next, next.kind == .code, next.range.location == stopped {
                    continuation = NSMaxRange(next.range)
                }
                ruleTokens(segment, continuation: continuation)
            case .string:
                var key = false
                if propertyFollower != nil {
                    if isLast, case .string? = state.frames.last {
                        // Cut inside the string: its real end must lie in the look-ahead.
                        if let next, next.kind == .string, next.complete, next.range.location == stopped {
                            key = isKey(NSMaxRange(next.range))
                        }
                    } else {
                        key = isKey(NSMaxRange(segment))
                    }
                }
                if key {
                    out.append((segment, .property))
                } else if stringRules.isEmpty {
                    out.append((segment, lexicalProfile?.stringKind ?? .string))
                } else {
                    stringRuleTokens(in: text, segment: segment, into: &out)
                }
            case .comment: out.append((segment, .comment))
            case .escape: out.append((segment, .escape))
            case .interpolationDelimiter:
                out.append((segment, lexicalProfile?.interpolationDelimiterKind ?? .interpolationDelimiter))
            case .atom(.regex): Self.regexTokens(in: text, atom: segment, into: &out)
            case .atom(let atomKind): out.append((segment, atomKind))
            case .block(let blockKind): out.append((segment, blockKind))
            }
        }
        return (out, stopped)
    }

    /// `segment` (a string) as `stringRules` matches with `.string` around
    /// them.
    private func stringRuleTokens(in text: NSString, segment: NSRange,
                                  into out: inout [(range: NSRange, kind: TokenKind)]) {
        let body = text.substring(with: segment)
        var last = 0
        applyRules(in: body, from: 0, to: segment.length, offset: 0, ruleSet: stringRuleSet) { token in
            if token.range.location > last {
                out.append((NSRange(location: segment.location + last, length: token.range.location - last), .string))
            }
            out.append((NSRange(location: segment.location + token.range.location, length: token.range.length),
                        token.kind))
            last = NSMaxRange(token.range)
        }
        if segment.length > last {
            out.append((NSRange(location: segment.location + last, length: segment.length - last), .string))
        }
    }

    /// A regex literal atom (`/body/flags`, T17.7) split as VS Code's
    /// JavaScript grammar scopes it (colours of the Modern themes): the
    /// delimiters and plain body `.regex`; escapes `.escape` except the class
    /// escapes `\d \D \w \W \s \S \b \B` (`.regex`); quantifiers (`*`
    /// `+` `?` `{m,n}`) `.escape`; anchors `^` `$` and the alternation `|`
    /// `.symbolFunction` (`keyword.control.anchor` / `keyword.operator.or`);
    /// group and class brackets (`(`, `(?:`, `(?<`, `)`, `[`, `[^`, `]`)
    /// `.string`, a group name `.symbolVariable`; the flags `.keyword`.
    /// Any other atom shape is one `.regex` token.
    static func regexTokens(in text: NSString, atom: NSRange,
                            into out: inout [(range: NSRange, kind: TokenKind)]) {
        let end = NSMaxRange(atom)
        guard atom.length >= 2, text.character(at: atom.location) == 47 else {   // /
            out.append((atom, .regex))
            return
        }
        // The closing `/`: the last one (flags are letters).
        var close = end - 1
        while close > atom.location, text.character(at: close) != 47 { close -= 1 }
        guard close > atom.location else { out.append((atom, .regex)); return }
        func unit(_ i: Int) -> unichar { i < close ? text.character(at: i) : 0 }
        func append(_ start: Int, _ stop: Int, _ kind: TokenKind) {
            guard stop > start else { return }
            if let lastToken = out.last, lastToken.kind == kind, NSMaxRange(lastToken.range) == start {
                out[out.count - 1].range.length += stop - start
            } else {
                out.append((NSRange(location: start, length: stop - start), kind))
            }
        }
        append(atom.location, atom.location + 1, .regex)
        var i = atom.location + 1
        var inClass = false
        while i < close {
            let c = unit(i)
            var stop = i + 1
            var kind: TokenKind = .regex
            switch c {
            case 92:                                                    // backslash
                let escaped = unit(i + 1)
                stop = min(close, i + 2)
                if (0xD800...0xDBFF).contains(escaped), stop < close { stop += 1 }
                let classEscape = [UInt16(100), 68, 119, 87, 115, 83, 98, 66].contains(escaped)   // dDwWsSbB
                kind = classEscape ? .regex : .escape
            case 91 where !inClass:                                     // [ / [^
                inClass = true
                kind = .string
                if unit(i + 1) == 94 { stop = i + 2 }
            case 93 where inClass:                                      // ]
                inClass = false
                kind = .string
            case _ where inClass:
                kind = .regex
            case 40:                                                    // ( (?: (?= (?! (?<= (?<! (?<name>
                kind = .string
                if unit(i + 1) == 63 {
                    stop = i + 2
                    if unit(stop) == 60, unit(stop + 1) != 61, unit(stop + 1) != 33 {
                        stop += 1                                       // (?<  then the name
                        append(i, stop, .string)
                        var e = stop
                        while e < close, unit(e) != 62 { e += 1 }
                        append(stop, e, .symbolVariable)
                        i = e
                        continue
                    }
                    if unit(stop) == 60 { stop += 1 }
                    if [UInt16(58), 61, 33].contains(unit(stop)) { stop += 1 }
                }
            case 41, 62:                                                // ) and a group name's >
                kind = c == 41 ? .string : .regex
                if c == 62, i > atom.location + 1, out.last?.kind == .symbolVariable { kind = .string }
            case 42, 43, 63:                                            // * + ?
                kind = .escape
            case 123:                                                   // {m,n}
                var e = i + 1
                var digits = 0
                while e < close, (48...57).contains(unit(e)) || unit(e) == 44 {
                    if unit(e) != 44 { digits += 1 }
                    e += 1
                }
                if digits > 0, e < close, unit(e) == 125 { stop = e + 1; kind = .escape }
            case 94, 36, 124:                                           // ^ $ |
                kind = .symbolFunction
            default:
                break
            }
            append(i, stop, kind)
            i = stop
        }
        append(close, close + 1, .regex)
        append(close + 1, end, .keyword)
    }

    @inline(__always)
    private static func isWordUnit(_ u: unichar) -> Bool {
        u == 95 || (48...57).contains(u) || (65...90).contains(u) || (97...122).contains(u) || u >= 128
    }

    /// The rule loop: at each position of `line[from..<to]` the first rule
    /// that matches there wins; unmatched positions advance by one unit —
    /// except that when no rule matches at a word unit (`[A-Za-z0-9_]` or
    /// ≥ U+0080), the rest of that word is skipped too (T17.7: the rules
    /// never start inside a word with another outcome — they begin with a
    /// non-word unit, a word-boundary guard, or match a word suffix only
    /// when they match the whole word — so trying each unit of an unmatched
    /// identifier only multiplied the cost by its length).
    /// Emits ranges shifted by `offset`; `ruleSet` is the rule list in use
    /// (all rules, the code-segment rules or `stringRules`).
    ///
    /// `.anchored` forces the match to begin exactly at `location`, giving
    /// "first rule that matches here wins" priority. `.withTransparentBounds`
    /// lets `\b` / lookbehind see the text *before* `location` — without it
    /// the search-range start acts as a fake word boundary, so e.g. the `in`
    /// inside `main` was tokenized as a keyword. `.withoutAnchoringBounds`
    /// keeps `^` from matching at the artificial range start for the same
    /// reason (a mid-line position is not a line start).
    private func applyRules(in line: String, from: Int, to: Int, offset: Int, ruleSet: RuleSet,
                            _ append: ((range: NSRange, kind: TokenKind)) -> Void) {
        guard !ruleSet.isEmpty else { return }
        var location = from
        let units = line as NSString
        while location < to {
            var matched = false
            if let match = ruleSet.match(in: line, range: NSRange(location: location, length: to - location)) {
                append((range: NSRange(location: match.range.location + offset, length: match.range.length),
                        kind: match.kind))
                location += match.range.length
                matched = true
            }
            if !matched {
                let unit = units.character(at: location)
                location += 1
                if Self.isWordUnit(unit) {
                    while location < to, Self.isWordUnit(units.character(at: location)) { location += 1 }
                }
            }
        }
    }
}

/// Extension → language definition lookup.
///
/// Definitions are built **lazily**: the factory for a language is not invoked
/// until an extension it owns is first requested (ARCHITECTURE.md §3.6 —
/// languages the user never opens cost nothing). The registry deliberately
/// keeps **no** cache of built definitions: the caller (the highlight engine)
/// becomes the sole owner, so when the `highlight` module is switched off and
/// the engine drops its reference, the definition and its compiled regexes are
/// fully released — satisfying the "disabled ⇒ ≈ 0 resident" rule (§2.5). A
/// rebuild costs only a handful of tiny `NSRegularExpression`s. Batch 1
/// (T3.2) registers Markdown, JSON(L), Python, JS/Node, TypeScript, HTML,
/// CSS. Batch 2 (T3.3) adds C, C++, C#, Java, Bash, SQL, XML/plist.
public enum LanguageRegistry {
    /// Extension (lowercased) → language identifier. Referencing this map does
    /// not build any definition; the identifier then selects the factory in
    /// `identifierFactories`, so an extension and its identifier always resolve
    /// to the same definition.
    private static let extensionIdentifiers: [String: String] = [
        "json": "json",
        "jsonl": "jsonl",
        "ndjson": "jsonl",
        "md": "markdown",
        "markdown": "markdown",
        "py": "python",
        "pyw": "python",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "html": "html",
        "htm": "html",
        "css": "css",
        "c": "c",
        "h": "c",
        "cpp": "cpp",
        "cc": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "cs": "csharp",
        "java": "java",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "sql": "sql",
        "xml": "xml",
        "plist": "xml",
        "svg": "xml",
        "xib": "xml",
        "storyboard": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "go": "go",
        "rs": "rust",
        "swift": "swift",
    ]

    /// Extensions that have a registered definition, without building any of
    /// them. Useful for detecting supported files (and for asserting laziness).
    public static var supportedExtensions: [String] {
        Array(extensionIdentifiers.keys)
    }

    /// The identifier of the language owning `ext` (case-insensitive), or `nil`
    /// for an unregistered extension. Builds nothing.
    public static func identifier(forExtension ext: String) -> String? {
        extensionIdentifiers[ext.lowercased()]
    }

    /// The canonical (registered) form of `id`, or `nil` when no language has
    /// that identifier. Builds nothing.
    public static func canonicalIdentifier(_ id: String) -> String? {
        let lower = id.lowercased()
        return identifierFactories[lower] == nil ? nil : lower
    }

    /// Returns a freshly built definition owning `ext` (case-insensitive), or
    /// `nil` for an unregistered extension — building nothing in that case.
    public static func definition(forExtension ext: String) -> LanguageDefinition? {
        guard let id = identifier(forExtension: ext) else { return nil }
        return definition(forIdentifier: id)
    }

    /// Identifier (e.g. `"python"`) → factory. Keyed by the stable language id
    /// each definition declares, so a language chosen from the Language menu or
    /// inferred by the content sniffer resolves without building the wrong
    /// definitions. One representative factory per identifier keeps this lazy:
    /// only the requested language is ever built.
    private static let identifierFactories: [String: () -> LanguageDefinition] = [
        "json": JSONLanguage.make,
        "jsonl": JSONLLanguage.make,
        "markdown": MarkdownLanguage.make,
        "python": PythonLanguage.make,
        "javascript": JavaScriptLanguage.make,
        "typescript": TypeScriptLanguage.make,
        "html": HTMLLanguage.make,
        "css": CSSLanguage.make,
        "c": CLanguage.make,
        "cpp": CppLanguage.make,
        "csharp": CSharpLanguage.make,
        "java": JavaLanguage.make,
        "bash": BashLanguage.make,
        "sql": SQLLanguage.make,
        "xml": XMLPlistLanguage.make,
        "yaml": YAMLLanguage.make,
        "toml": TOMLLanguage.make,
        "go": GoLanguage.make,
        "rust": RustLanguage.make,
        "swift": SwiftLanguage.make,
    ]

    /// Returns a freshly built definition whose `identifier` matches `id`
    /// (case-insensitive), or `nil` for an unknown identifier — building only
    /// the matched language.
    public static func definition(forIdentifier id: String) -> LanguageDefinition? {
        guard let factory = identifierFactories[id.lowercased()] else { return nil }
        return factory()
    }
}
