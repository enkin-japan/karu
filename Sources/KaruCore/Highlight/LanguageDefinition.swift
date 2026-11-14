import Foundation

/// Semantic token categories a language definition can assign to a span of
/// text. Colours live in `HighlightTheme`, keeping the definitions themselves
/// free of any AppKit dependency (so they stay pure and unit-testable).
public enum TokenKind: Hashable, Sendable {
    case keyword
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
    case plain
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

/// Declarative, AppKit-independent description of a language for the highlighter.
///
/// Two tokenizing paths:
/// - **Unprofiled** (`lexicalProfile == nil`): `tokenize(line:)` is a pure
///   function over a single line. Constructs spanning lines (block comments,
///   multi-line strings) are only approximated per line. JSON / JSONL have no
///   such constructs, so the approximation is exact for them.
/// - **Profiled** (M17 T17.2): a `LexicalProfile` describes comments and
///   strings, and the generic `LexicalScanner` carries their state across
///   lines (`tokens(in:range:state:)`). The regex `rules` then apply only to
///   the code segments the scanner reports, and rules of kind `.string` /
///   `.comment` are skipped there — the profile is authoritative for those.
///
/// Python keeps its own `PythonTokenizer` (string prefixes, f-string fields).
public struct LanguageDefinition {
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

    public init(identifier: String,
                fileExtensions: [String],
                rules: [LanguageRule],
                keywords: [String] = [],
                builtins: [String] = [],
                lexicalProfile: LexicalProfile? = nil) {
        self.identifier = identifier
        self.fileExtensions = fileExtensions
        self.rules = rules
        self.keywords = keywords
        self.builtins = builtins
        self.lexicalProfile = lexicalProfile
        self.lexicalScanner = lexicalProfile.map(LexicalScanner.init(profile:))
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
        applyRules(in: line, from: 0, to: ns.length, offset: 0, skipStringsAndComments: false) {
            tokens.append($0)
        }
        return tokens
    }

    /// Tokens of `text[range]` for a profiled language, carrying the lexical
    /// `state` (the state at `range.location` on entry, at its end on return).
    ///
    /// Ranges are absolute, ascending and non-overlapping. String and comment
    /// segments become one `.string` / `.comment` token each (a multi-line
    /// string is one token), interpolation delimiters `.punctuation`, atoms
    /// their form's kind; inside code segments the regex `rules` run line by
    /// line exactly as in `tokenize(line:)` (anchored, transparent bounds, `^`
    /// only at a real line start), limited to the segment and skipping rules
    /// of kind `.string` / `.comment`.
    ///
    /// For an unprofiled language this is the plain rule loop over each line
    /// overlapping `range`, restricted to `range`; `state` is untouched.
    public func tokens(in text: NSString, range: NSRange,
                       state: inout LexicalScanState) -> [(range: NSRange, kind: TokenKind)] {
        let start = min(max(range.location, 0), text.length)
        let end = min(max(NSMaxRange(range), start), text.length)
        var out: [(range: NSRange, kind: TokenKind)] = []
        guard end > start else { return out }

        // One line at a time is substringed for the rules, cached across the
        // code segments that share it.
        var lineRange = NSRange(location: NSNotFound, length: 0)
        var line = ""
        func withLine(containing location: Int) -> (NSRange, String) {
            if !NSLocationInRange(location, lineRange) {
                lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                line = text.substring(with: lineRange)
            }
            return (lineRange, line)
        }
        func ruleTokens(_ segment: NSRange) {
            var loc = segment.location
            let limit = NSMaxRange(segment)
            while loc < limit {
                let (lr, ls) = withLine(containing: loc)
                let upTo = min(limit, NSMaxRange(lr))
                applyRules(in: ls, from: loc - lr.location, to: upTo - lr.location, offset: lr.location,
                           skipStringsAndComments: lexicalScanner != nil) { token in
                    out.append(token)
                }
                loc = upTo
            }
        }

        guard let scanner = lexicalScanner else {
            ruleTokens(NSRange(location: start, length: end - start))
            return out
        }
        var segments: [(NSRange, LexicalSegment)] = []
        scanner.segments(text, from: start, to: end, state: &state) { segments.append(($0, $1)) }
        for (segment, kind) in segments {
            switch kind {
            case .code: ruleTokens(segment)
            case .string: out.append((segment, .string))
            case .comment: out.append((segment, .comment))
            case .interpolationDelimiter: out.append((segment, .punctuation))
            case .atom(let atomKind): out.append((segment, atomKind))
            }
        }
        return out
    }

    /// The rule loop: at each position of `line[from..<to]` the first rule
    /// that matches there wins; unmatched positions advance by one unit.
    /// Emits ranges shifted by `offset`.
    private func applyRules(in line: String, from: Int, to: Int, offset: Int,
                            skipStringsAndComments: Bool,
                            _ append: ((range: NSRange, kind: TokenKind)) -> Void) {
        var location = from
        while location < to {
            var matched = false
            let searchRange = NSRange(location: location, length: to - location)
            for rule in rules {
                if skipStringsAndComments, rule.kind == .string || rule.kind == .comment { continue }
                // `.anchored` forces the match to begin exactly at `location`,
                // giving us "first rule that matches here wins" priority.
                // `.withTransparentBounds` lets `\b` / lookbehind see the text
                // *before* `location` — without it the search-range start acts
                // as a fake word boundary, so e.g. the `in` inside `main` was
                // tokenized as a keyword. `.withoutAnchoringBounds` keeps `^`
                // from matching at the artificial range start for the same
                // reason (a mid-line position is not a line start).
                guard let match = rule.regex.firstMatch(
                          in: line,
                          options: [.anchored, .withTransparentBounds, .withoutAnchoringBounds],
                          range: searchRange),
                      match.range.length > 0 else { continue }
                append((range: NSRange(location: match.range.location + offset, length: match.range.length),
                        kind: rule.kind))
                location += match.range.length
                matched = true
                break
            }
            if !matched { location += 1 }
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
