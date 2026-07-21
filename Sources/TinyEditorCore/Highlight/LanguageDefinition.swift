import Foundation

/// Semantic token categories a language definition can assign to a span of
/// text. Colours live in `HighlightTheme`, keeping the definitions themselves
/// free of any AppKit dependency (so they stay pure and unit-testable).
public enum TokenKind: Equatable {
    case keyword
    case string
    case number
    case comment
    case type
    case property
    case punctuation
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
/// v1 tokenizing is **line-based**: `tokenize(line:)` is a pure function over a
/// single line, which keeps colouring viewport-cheap and trivially testable.
/// The trade-off is that constructs spanning multiple lines (block comments,
/// multi-line strings) are only approximated per line; a later revision can add
/// cross-line state if a language needs it. JSON — the first language — has no
/// such constructs, so the approximation is exact for it.
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

    public init(identifier: String,
                fileExtensions: [String],
                rules: [LanguageRule],
                keywords: [String] = []) {
        self.identifier = identifier
        self.fileExtensions = fileExtensions
        self.rules = rules
        self.keywords = keywords
    }

    /// Tokenizes a single line into a list of `(range, kind)` spans.
    ///
    /// Ranges are UTF-16 offsets relative to the start of `line` (NSString
    /// semantics), so the caller can add the line's absolute offset to map them
    /// onto the text view. Positions that match no rule are left untokenized
    /// (they keep the default text colour); this is a pure function with no
    /// AppKit dependency.
    public func tokenize(line: String) -> [(range: NSRange, kind: TokenKind)] {
        let ns = line as NSString
        var tokens: [(range: NSRange, kind: TokenKind)] = []
        var location = 0

        while location < ns.length {
            var matched = false
            let searchRange = NSRange(location: location, length: ns.length - location)
            for rule in rules {
                // `.anchored` forces the match to begin exactly at `location`,
                // giving us "first rule that matches here wins" priority.
                guard let match = rule.regex.firstMatch(in: line,
                                                        options: [.anchored],
                                                        range: searchRange),
                      match.range.length > 0 else { continue }
                tokens.append((range: match.range, kind: rule.kind))
                location += match.range.length
                matched = true
                break
            }
            if !matched { location += 1 }
        }
        return tokens
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
    /// Extension (lowercased) → factory closure. Referencing this map does not
    /// build any definition; only calling a closure does.
    private static let factories: [String: () -> LanguageDefinition] = [
        "json": JSONLanguage.make,
        "jsonl": JSONLLanguage.make,
        "ndjson": JSONLLanguage.make,
        "md": MarkdownLanguage.make,
        "markdown": MarkdownLanguage.make,
        "py": PythonLanguage.make,
        "pyw": PythonLanguage.make,
        "js": JavaScriptLanguage.make,
        "mjs": JavaScriptLanguage.make,
        "cjs": JavaScriptLanguage.make,
        "ts": TypeScriptLanguage.make,
        "html": HTMLLanguage.make,
        "htm": HTMLLanguage.make,
        "css": CSSLanguage.make,
        "c": CLanguage.make,
        "h": CLanguage.make,
        "cpp": CppLanguage.make,
        "cc": CppLanguage.make,
        "cxx": CppLanguage.make,
        "hpp": CppLanguage.make,
        "hh": CppLanguage.make,
        "cs": CSharpLanguage.make,
        "java": JavaLanguage.make,
        "sh": BashLanguage.make,
        "bash": BashLanguage.make,
        "zsh": BashLanguage.make,
        "sql": SQLLanguage.make,
        "xml": XMLPlistLanguage.make,
        "plist": XMLPlistLanguage.make,
        "svg": XMLPlistLanguage.make,
        "xib": XMLPlistLanguage.make,
        "storyboard": XMLPlistLanguage.make,
    ]

    /// Extensions that have a registered definition, without building any of
    /// them. Useful for detecting supported files (and for asserting laziness).
    public static var supportedExtensions: [String] {
        Array(factories.keys)
    }

    /// Returns a freshly built definition owning `ext` (case-insensitive), or
    /// `nil` for an unregistered extension — building nothing in that case.
    public static func definition(forExtension ext: String) -> LanguageDefinition? {
        guard let factory = factories[ext.lowercased()] else { return nil }
        return factory()
    }
}
