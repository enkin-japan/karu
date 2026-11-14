import Foundation

/// Declarative description of a language's cross-line lexical structure for
/// the generic `LexicalScanner` (M17 T17.2, plan §4 "接口（T17.2 定稿）").
///
/// A profile says where comments and strings begin and end, nothing more:
/// keywords, numbers and other single-line categories stay in the language's
/// regex `rules`, which the highlighter applies only inside the code segments
/// the scanner reports. Pure value, no AppKit, `Sendable`.
///
/// Recognition order in code, at each candidate position: line comments, then
/// block comments, then `strings` (in declaration order, so list the more
/// specific forms first — `r#"…"#` before `"…"`), then `atoms`.
public struct LexicalProfile: Sendable {
    /// `/* … */`-style comment. `nests`: an inner opener increments a depth
    /// that the closer decrements (Rust, Swift).
    public struct BlockCommentForm: Sendable, Hashable {
        public var open: String
        public var close: String
        public var nests: Bool

        public init(open: String, close: String, nests: Bool = false) {
            self.open = open
            self.close = close
            self.nests = nests
        }
    }

    /// How a string opens and what closes it.
    public enum Delimiter: Sendable, Hashable {
        /// Literal opener and closer (`"`…`"`, `` ` ``…`` ` ``, `"""`…`"""`).
        case fixed(open: String, close: String)
        /// A run of N ≥ `minimum` `quote`s opens; a run of exactly N closes
        /// (C# raw strings). Shorter or longer runs inside are content.
        case repeatedQuote(quote: Character, minimum: Int)
        /// `lead` + n·`hash` + `quote` opens, `quote` + n·`hash` closes, n ≥ 0
        /// (Rust `r#"…"#`: lead `r`; Swift `#"…"#`: lead empty). With
        /// `hashesApplyToEscapes` the escape character only escapes when
        /// followed by the same n hashes, and escape-led interpolation openers
        /// get them too (Swift `\#(…)`).
        case hashed(lead: String, hash: Character, quote: String, hashesApplyToEscapes: Bool)
        /// C++ raw string `R"delim(` … `)delim"` (delimiter ≤ 16 units, none of
        /// space, `(`, `)`, `\`, CR, LF).
        case cppRaw
    }

    /// Embedded code inside a string (`${…}`, `\(…)`, `{…}`). The text inside
    /// is scanned as code; `(`, `[`, `{` and their closers are counted so a
    /// nested closer does not end it early. Strings inside may themselves
    /// contain interpolations.
    public struct InterpolationForm: Sendable, Hashable {
        public var open: String
        public var close: Character
        /// Text that looks like `open` but is literal content (`{{`).
        public var escapedOpen: String?

        public init(open: String, close: Character, escapedOpen: String? = nil) {
            self.open = open
            self.close = close
            self.escapedOpen = escapedOpen
        }
    }

    public struct StringForm: Sendable, Hashable {
        /// Literal prefixes directly before the opener (`b`, `rb`, `f`). A
        /// prefix counts only at a word boundary: the UTF-16 unit before it
        /// must not be an identifier character (`[A-Za-z0-9_]` or ≥ U+0080).
        public var prefixes: [String]
        /// When true the form only matches with one of `prefixes`.
        public var prefixRequired: Bool
        public var prefixCaseInsensitive: Bool
        public var delimiter: Delimiter
        /// False: the string ends at the end of its line unless the line ends
        /// with the escape character (continuation).
        public var multiline: Bool
        /// Escape character (`\`); nil for raw strings.
        public var escape: Character?
        /// The closer written twice is an escaped closer (C# `@"a""b"`, SQL `'it''s'`).
        public var doubledCloseEscapes: Bool
        public var interpolations: [InterpolationForm]

        public init(prefixes: [String] = [],
                    prefixRequired: Bool = false,
                    prefixCaseInsensitive: Bool = false,
                    delimiter: Delimiter,
                    multiline: Bool,
                    escape: Character? = "\\",
                    doubledCloseEscapes: Bool = false,
                    interpolations: [InterpolationForm] = []) {
            self.prefixes = prefixes
            self.prefixRequired = prefixRequired
            self.prefixCaseInsensitive = prefixCaseInsensitive
            self.delimiter = delimiter
            self.multiline = multiline
            self.escape = escape
            self.doubledCloseEscapes = doubledCloseEscapes
            self.interpolations = interpolations
        }
    }

    /// A single-line token consumed atomically in code, so its characters can
    /// never open a string or comment (Rust `'"'`, `'a`). `pattern` is matched
    /// anchored at a character from `firstCharacters` (optionally preceded by
    /// one of `prefixes`, word-boundary guarded like string prefixes) and must
    /// not cross a line break. Reported as `LexicalSegment.atom(kind)`.
    public struct AtomForm: Sendable {
        public var pattern: String
        public var firstCharacters: String
        public var kind: TokenKind
        public var prefixes: [String]

        public init(pattern: String, firstCharacters: String, kind: TokenKind, prefixes: [String] = []) {
            self.pattern = pattern
            self.firstCharacters = firstCharacters
            self.kind = kind
            self.prefixes = prefixes
        }
    }

    public var lineComments: [String]
    public var blockComments: [BlockCommentForm]
    public var strings: [StringForm]
    public var atoms: [AtomForm]

    public init(lineComments: [String] = [],
                blockComments: [BlockCommentForm] = [],
                strings: [StringForm] = [],
                atoms: [AtomForm] = []) {
        self.lineComments = lineComments
        self.blockComments = blockComments
        self.strings = strings
        self.atoms = atoms
    }
}

/// What the scanner reports for a span of text.
public enum LexicalSegment: Sendable, Hashable {
    /// Code, including the inside of an interpolation (rules apply here).
    case code
    case string
    case comment
    /// An interpolation opener or closer (`${`, `}`).
    case interpolationDelimiter
    /// An `AtomForm` match, with the form's kind.
    case atom(TokenKind)
}

/// Lexical state between two positions: a stack of open constructs, innermost
/// last, capped at `maximumDepth`. Small, `Hashable` and `Sendable`, so it can
/// be stored in a checkpoint (`LexicalState.generic`) and compared in tests.
/// At a line start it holds only multi-line constructs (a line comment or a
/// single-line string never survives its line end).
public struct LexicalScanState: Sendable, Hashable {
    /// Form indices refer to the profile's `blockComments` / `strings` arrays.
    /// T17.3 hooks (heredoc, YAML block scalar, JS regex) add cases here; the
    /// checkpoint format (`LexicalState.generic`) does not change.
    public enum Frame: Sendable, Hashable {
        /// Inside a line comment (only between line starts).
        case lineComment
        case blockComment(form: UInt8, depth: UInt32)
        /// `count`: the quote run length N (`repeatedQuote`) or the number of
        /// hashes (`hashed`), else 0. `delimiter`: the resolved `cppRaw`
        /// delimiter, else nil.
        case string(form: UInt8, count: UInt16, delimiter: String?)
        /// Code inside interpolation `interpolation` of string form `form`;
        /// `depth` counts unclosed `(`, `[`, `{`.
        case interpolation(form: UInt8, interpolation: UInt8, depth: UInt32)
    }

    public static let maximumDepth = 64

    public internal(set) var frames: [Frame] = []

    public init() {}

    /// True outside every construct (plain code).
    public var isEmpty: Bool { frames.isEmpty }
}
