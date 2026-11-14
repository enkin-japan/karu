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
/// specific forms first — `r#"…"#` before `"…"`), then `atoms`, then the
/// `lineBlocks` openers (heredoc, block scalar; a fence only at a line start,
/// before anything else on it).
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
        /// When set, the form only opens in this context, checked like
        /// `AtomForm.precededBy` at the token start (before any prefix);
        /// otherwise the next form is tried. Text-only (YAML: a quote opens a
        /// scalar after `:`, `-`, `[`, `{`, `,`, `?` or first on its line, so
        /// `don't` and `say "hi"` inside a plain scalar stay plain).
        public var precededBy: AtomContext?

        public init(prefixes: [String] = [],
                    prefixRequired: Bool = false,
                    prefixCaseInsensitive: Bool = false,
                    delimiter: Delimiter,
                    multiline: Bool,
                    escape: Character? = "\\",
                    doubledCloseEscapes: Bool = false,
                    interpolations: [InterpolationForm] = [],
                    precededBy: AtomContext? = nil) {
            self.prefixes = prefixes
            self.prefixRequired = prefixRequired
            self.prefixCaseInsensitive = prefixCaseInsensitive
            self.delimiter = delimiter
            self.multiline = multiline
            self.escape = escape
            self.doubledCloseEscapes = doubledCloseEscapes
            self.interpolations = interpolations
            self.precededBy = precededBy
        }
    }

    /// Text before an atom or string that allows it (`AtomForm.precededBy`,
    /// `StringForm.precededBy`). Going backward from the token's first unit
    /// (its prefix, if any) over spaces, tabs, CR and LF — at most
    /// `AtomContext.reach` units — the token matches when the document start
    /// is reached, or the unit found is one of `characters`, or the
    /// identifier run (`[A-Za-z0-9_$]`, ≥ U+0080) ending there is one of
    /// `words`; otherwise (any other unit, or only whitespace within the
    /// reach) it does not. With `lineStart`, the skip stops at a line break
    /// and that allows the token (it is first on its line). Purely
    /// text-based, independent of the scanner state (JS regex literal vs
    /// division: `x = /re/` but `a / b / c`).
    public struct AtomContext: Sendable, Hashable {
        /// How far back the whitespace skip and word read may look.
        public static let reach = 256

        public var characters: String
        public var words: [String]
        public var lineStart: Bool

        public init(characters: String, words: [String] = [], lineStart: Bool = false) {
            self.characters = characters
            self.words = words
            self.lineStart = lineStart
        }
    }

    /// A single-line token consumed atomically in code, so its characters can
    /// never open a string or comment (Rust `'"'`, `'a`). `pattern` is matched
    /// anchored at a character from `firstCharacters` (optionally preceded by
    /// one of `prefixes`, word-boundary guarded like string prefixes) and must
    /// not cross a line break; it sees up to 16 units before that character
    /// for lookbehinds. With `precededBy`, the atom only matches in that
    /// context. Reported as `LexicalSegment.atom(kind)`.
    public struct AtomForm: Sendable {
        public var pattern: String
        public var firstCharacters: String
        public var kind: TokenKind
        public var prefixes: [String]
        public var precededBy: AtomContext?

        public init(pattern: String, firstCharacters: String, kind: TokenKind, prefixes: [String] = [],
                    precededBy: AtomContext? = nil) {
            self.pattern = pattern
            self.firstCharacters = firstCharacters
            self.kind = kind
            self.prefixes = prefixes
            self.precededBy = precededBy
        }
    }

    /// A construct whose extent is decided line by line (M17 T17.3 hooks):
    /// its opener sits in code, the body starts on the next line, and each
    /// body line start is checked for the end. The body is reported as
    /// `LexicalSegment.block(bodyKind)` (the rules never run in it). At most
    /// one form of each case per profile.
    ///
    /// The checks read text only: one unit before a position for the
    /// line-start test (CR, LF or CRLF, counted once; the document start
    /// counts), the opener line before a block-scalar indicator, and forward
    /// up to the end of the scanned range.
    public enum LineBlockForm: Sendable, Hashable {
        /// Bash heredoc. Opener in code: `<<` or `<<-`, optional spaces or
        /// tabs, then a delimiter word `[A-Za-z_][A-Za-z0-9_]*`, bare, quoted
        /// with `'…'` / `"…"` or after `\`; `<<<` (here-string) is no opener.
        /// The rest of the opener line stays code (strings, comments, pipes);
        /// the first line break reached in that code starts the body. A body
        /// line whose content (after leading tabs with `<<-`) is the
        /// delimiter, followed by a line break or the document end, is the
        /// terminator: reported as code, the heredoc ends after its line
        /// break unit. Only the first heredoc of a line is tracked (`cat <<A
        /// <<B` reads `<<B` as code); the body is one `bodyKind` run, also in
        /// an unquoted heredoc (no `$var` / `$(…)` inside).
        case heredoc(bodyKind: TokenKind)
        /// YAML block scalar. Opener in code: `|` or `>` with up to two
        /// indicators (`[-+]` and `[1-9]`, either order), preceded (after
        /// spaces) by `:`, `-`, `?` or first on its line. The rest of the
        /// line may only hold spaces and a `#` comment, else the scalar is
        /// dropped there (the line stays code). From the next line, blank
        /// lines stay in the body and the first line indented no deeper
        /// than the parent node (see `LexicalScanState.Frame.indentedBlock`)
        /// ends it before that line.
        case indentedBlock(bodyKind: TokenKind)
        /// Markdown fenced code block. Only at a line start in plain code: up
        /// to 3 spaces and a run of ≥ 3 backticks or ≥ 3 tildes. The opener
        /// line (the info string included) is part of the block; a backtick
        /// in a backtick fence's info string drops the fence there (the rest
        /// of the line is code). The body runs from the next line to a line
        /// of up to 3 spaces, ≥ the opener's run of the same marker and only
        /// spaces / tabs (part of the block, through its line break unit),
        /// or the document end. The info string is not kept in the state:
        /// embedded languages (T17.8) re-read the opener line.
        case fence(bodyKind: TokenKind)
    }

    public var lineComments: [String]
    /// When set, a line-comment opener counts only at the document start,
    /// right after a line break, or when the unit just before it is one of
    /// these (Bash `" \t;|&()"`: `$#`, `${#x}` and `a#b` are no comments).
    /// Reads one unit of text, never state. Nil: anywhere.
    public var lineCommentPrecededBy: String?
    public var blockComments: [BlockCommentForm]
    public var strings: [StringForm]
    public var atoms: [AtomForm]
    public var lineBlocks: [LineBlockForm]
    /// For `LanguageDefinition`: when true, regex rules of kind `.string`
    /// still run inside code segments (`.comment` rules stay skipped). For
    /// strings that exist only in a context the profile does not model:
    /// markup quotes delimit strings only inside a tag (HTML / XML attribute
    /// values stay single-line rules); C's `#include <header>`; Markdown
    /// inline code.
    public var keepsStringRules: Bool
    /// For `LanguageDefinition`: when true, regex rules of kind `.comment`
    /// still run inside code segments. For rules that only borrow the
    /// comment colour (Markdown block quotes and strikethrough).
    public var keepsCommentRules: Bool

    public init(lineComments: [String] = [],
                lineCommentPrecededBy: String? = nil,
                blockComments: [BlockCommentForm] = [],
                strings: [StringForm] = [],
                atoms: [AtomForm] = [],
                lineBlocks: [LineBlockForm] = [],
                keepsStringRules: Bool = false,
                keepsCommentRules: Bool = false) {
        self.lineComments = lineComments
        self.lineCommentPrecededBy = lineCommentPrecededBy
        self.blockComments = blockComments
        self.strings = strings
        self.atoms = atoms
        self.lineBlocks = lineBlocks
        self.keepsStringRules = keepsStringRules
        self.keepsCommentRules = keepsCommentRules
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
    /// A `LineBlockForm` body (and the parts of its opener / closer lines the
    /// form reports with it), with the form's `bodyKind`.
    case block(TokenKind)
}

/// Lexical state between two positions: a stack of open constructs, innermost
/// last, capped at `maximumDepth`. Small, `Hashable` and `Sendable`, so it can
/// be stored in a checkpoint (`LexicalState.generic`) and compared in tests.
/// At a line start it holds only multi-line constructs (a line comment or a
/// single-line string never survives its line end); it is the state *before*
/// that line's line-start checks (a heredoc terminator, a fence closer or
/// opener, a block-scalar dedent), which a pass resumed there runs itself.
public struct LexicalScanState: Sendable, Hashable {
    /// Form indices refer to the profile's `blockComments` / `strings` arrays.
    /// T17.3 hooks (heredoc, YAML block scalar, fence) add cases here; the
    /// checkpoint format (`LexicalState.generic`) does not change. A line
    /// block's `inBody` is false from its opener to the first line break that
    /// ends the opener line, true in the body.
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
        /// `LineBlockForm.heredoc`: the delimiter word and whether leading
        /// tabs are stripped (`<<-`). While `inBody` is false the context is
        /// code (the rest of the opener line).
        case heredoc(terminator: String, stripTabs: Bool, inBody: Bool)
        /// `LineBlockForm.indentedBlock`. `parentIndent`: the column of the
        /// node owning the scalar — the opener line's leading spaces, then
        /// past each `- ` sequence marker and the blanks after it; when the
        /// indicator itself follows the markers (`- |`), the column of the
        /// last marker. A body line indented ≤ this ends the scalar.
        case indentedBlock(parentIndent: UInt16, inBody: Bool)
        /// `LineBlockForm.fence`: the marker unit (`` ` `` or `~`) and the
        /// opener's run length. While `inBody` is false: the info string.
        case fence(marker: UInt16, length: UInt16, inBody: Bool)
    }

    public static let maximumDepth = 64

    public internal(set) var frames: [Frame] = []

    public init() {}

    /// True outside every construct (plain code).
    public var isEmpty: Bool { frames.isEmpty }
}
