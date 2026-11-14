import Foundation

/// What the caret is completing (M17 T17.5, plan §5.1 / §5.5): the position
/// class from the lexical state, the identifier prefix and the whole
/// identifier around the caret, and a member access's receiver. Pure value,
/// no AppKit.
public struct CompletionContext: Sendable, Equatable {
    /// Lexical class of the caret position.
    public enum Position: Sendable, Equatable {
        /// Code, including template / f-string interpolations and Markdown
        /// fence bodies.
        case code
        /// Inside a string literal (or a heredoc / YAML block scalar body).
        case string
        case comment
        /// A document without a language.
        case plainText

        /// Auto popups are allowed here (plan §5.1).
        public var allowsAutoPopup: Bool { self == .code || self == .plainText }
    }

    /// `receiver.prefix│`: the expression before the dot.
    public struct MemberAccess: Sendable, Equatable {
        /// A call-free chain of identifiers (`obj`, `self`, `self.items`);
        /// nil when the dot follows something else (`f().`, `a[0].`).
        public let receiver: String?
        public let receiverRange: NSRange?
        /// The receiver is the language's `self` / `this` (or Python `cls`).
        public let isSelfOrThis: Bool
        /// `.`; `->` (C, C++) or `::` (Rust, C++) since T17.11d.
        public internal(set) var accessOperator = "."
    }

    public let languageIdentifier: String
    public let caret: Int
    public let position: Position
    /// The identifier text from its start to the caret.
    public let prefix: String
    public let prefixRange: NSRange
    /// The whole identifier around the caret (left part + right part): what
    /// accepting a candidate replaces (plan §1 `userCo│unt`).
    public let replacementRange: NSRange
    /// The text of `replacementRange`.
    public let identifier: String
    public let memberAccess: MemberAccess?

    /// Case-sensitive names: distinct spellings stay distinct candidates.
    /// Plain text and SQL dedupe case-insensitively.
    public var isCaseSensitive: Bool { Self.isCaseSensitive(languageIdentifier) }

    public static func isCaseSensitive(_ languageIdentifier: String) -> Bool {
        !(languageIdentifier.isEmpty || languageIdentifier == "sql")
    }

    /// The prefix starts with a letter, `_` or (JS / TS) `$`.
    public var prefixStartsIdentifier: Bool {
        IdentifierText.startsIdentifier(prefix.utf16, dollar: IdentifierText.allowsDollar(languageIdentifier))
    }

    /// Longest identifier read around the caret; a longer run yields no context.
    static let maximumIdentifierLength = 256

    /// Builds the context at `caret` (a plain caret) for a position class the
    /// caller determined from the lexical state. Nil when the identifier
    /// around the caret is unreasonably long.
    public static func make(text: NSString, caret: Int, languageIdentifier: String,
                            position: Position) -> CompletionContext? {
        guard caret >= 0, caret <= text.length else { return nil }
        let dollar = IdentifierText.allowsDollar(languageIdentifier)
        guard let start = IdentifierText.runStart(before: caret, in: text, dollar: dollar,
                                                  limit: maximumIdentifierLength) else { return nil }
        let end = IdentifierText.runEnd(after: caret, in: text, dollar: dollar, limit: maximumIdentifierLength)
        let prefixRange = NSRange(location: start, length: caret - start)
        let replacement = NSRange(location: start, length: end - start)
        let member = position == .plainText ? nil
            : memberAccess(before: start, in: text, languageIdentifier: languageIdentifier, dollar: dollar)
        return CompletionContext(languageIdentifier: languageIdentifier, caret: caret, position: position,
                                 prefix: text.substring(with: prefixRange), prefixRange: prefixRange,
                                 replacementRange: replacement, identifier: text.substring(with: replacement),
                                 memberAccess: member)
    }

    /// The same context as an ordinary (non-member) completion.
    func withoutMemberAccess() -> CompletionContext {
        CompletionContext(languageIdentifier: languageIdentifier, caret: caret, position: position, prefix: prefix,
                          prefixRange: prefixRange, replacementRange: replacementRange, identifier: identifier,
                          memberAccess: nil)
    }

    /// A two-unit access operator right before `start`: `->` in C / C++,
    /// `::` in Rust / C++ (T17.11d); its location and length. A `.` is
    /// handled by `memberAccess(before:…)` directly.
    static func accessOperator(before start: Int, in text: NSString,
                               languageIdentifier: String) -> (location: Int, length: Int)? {
        guard start >= 2, start <= text.length else { return nil }
        let a = text.character(at: start - 2)
        let b = text.character(at: start - 1)
        if a == 45, b == 62, languageIdentifier == "c" || languageIdentifier == "cpp" {           // ->
            return (start - 2, 2)
        }
        if a == 58, b == 58, languageIdentifier == "rust" || languageIdentifier == "cpp" {        // ::
            if start >= 3, text.character(at: start - 3) == 58 { return nil }
            return (start - 2, 2)
        }
        return nil
    }

    /// Receiver words per language.
    static func selfNames(_ languageIdentifier: String) -> Set<String> {
        switch languageIdentifier {
        case "python": return ["self", "cls"]
        case "javascript", "typescript", "typescriptreact", "java", "csharp", "cpp": return ["this"]
        case "swift", "rust": return ["self"]
        default: return []
        }
    }

    /// Longest receiver chain read back from a dot.
    static let maximumReceiverLength = 256

    /// A `.` right before `start` (not part of `..` / `...` / a number's
    /// decimal point): the member access and its receiver chain.
    static func memberAccess(before start: Int, in text: NSString, languageIdentifier: String,
                             dollar: Bool) -> MemberAccess? {
        guard start > 0 else { return nil }
        if text.character(at: start - 1) != 46 {                                    // .
            // `->` / `::` (T17.11d): the receiver is read like a `.` one.
            guard let op = accessOperator(before: start, in: text, languageIdentifier: languageIdentifier),
                  var access = memberAccess(endingAt: op.location, in: text, languageIdentifier: languageIdentifier,
                                            dollar: dollar) else { return nil }
            access.accessOperator = text.substring(with: NSRange(location: op.location, length: op.length))
            return access
        }
        return memberAccess(endingAt: start - 1, in: text, languageIdentifier: languageIdentifier, dollar: dollar)
    }

    /// The receiver chain ending at the access operator at `dot`.
    private static func memberAccess(endingAt dot: Int, in text: NSString, languageIdentifier: String,
                                     dollar: Bool) -> MemberAccess? {
        guard dot > 0 else { return MemberAccess(receiver: nil, receiverRange: nil, isSelfOrThis: false) }
        let before = text.character(at: dot - 1)
        if before == 46 { return nil }                                              // .. / ... spread, range
        // The chain `a.b.c` ending at the dot: identifiers joined by single dots.
        var chainStart = dot
        var cursor = dot
        while true {
            guard let wordStart = IdentifierText.runStart(before: cursor, in: text, dollar: dollar, limit: 128),
                  wordStart < cursor else { break }
            let units = (wordStart..<cursor).map { text.character(at: $0) }
            guard IdentifierText.startsIdentifier(units, dollar: dollar) else {
                // `1.` / `0x1F.`: a number, not a receiver.
                if chainStart == dot, units.first.map({ $0 >= 48 && $0 <= 57 }) == true { return nil }
                break
            }
            chainStart = wordStart
            if dot - chainStart > maximumReceiverLength { break }
            guard wordStart >= 2, text.character(at: wordStart - 1) == 46,
                  text.character(at: wordStart - 2) != 46 else { break }
            cursor = wordStart - 1
        }
        guard chainStart < dot else {
            return MemberAccess(receiver: nil, receiverRange: nil, isSelfOrThis: false)
        }
        // Only a chain that is not itself the tail of a call / subscript
        // (`f().a.` or `x[0].a.`) is a known receiver.
        if chainStart > 0 {
            let lead = text.character(at: chainStart - 1)
            if lead == 46 || lead == 41 || lead == 93 || lead == 63 {               // . ) ] ?
                return MemberAccess(receiver: nil, receiverRange: nil, isSelfOrThis: false)
            }
        }
        let range = NSRange(location: chainStart, length: dot - chainStart)
        let receiver = text.substring(with: range)
        return MemberAccess(receiver: receiver, receiverRange: range,
                            isSelfOrThis: selfNames(languageIdentifier).contains(receiver))
    }

    // MARK: - Lexical position

    /// Data formats whose content lives in strings (JSON keys and values, YAML
    /// / TOML / XML values): a string position there completes like plain text
    /// (auto popup, document words), as before T17.5 (plan §5.2: data formats
    /// use document words only).
    public static func stringsAreContent(_ languageIdentifier: String) -> Bool {
        ["json", "jsonl", "yaml", "toml", "xml"].contains(languageIdentifier)
    }

    /// The position class of `state`, a lexical state at the caret, read
    /// from its own frames: an embedded language's body (an HTML `<script>`
    /// / `<style>` start tag or body, a fence) is code here; inside a body
    /// of a known language `caretLanguage(of:hostIdentifier:scanner:)` asks
    /// the child's state instead (T17.8c). JSX (T17.8b):
    /// a tag and a `{…}` expression are code, an attribute string a string,
    /// children text a string (no auto popup in text).
    public static func position(of state: LexicalScanState) -> Position {
        switch state.frames.last {
        case nil, .interpolation?, .jsxExpression?: return .code
        case .lineComment?, .blockComment?: return .comment
        case .string?, .jsxText?: return .string
        case .heredoc(_, _, let inBody)?: return inBody ? .string : .code
        case .indentedBlock(_, let inBody)?: return inBody ? .string : .code
        case .fence?, .rawTextTag?, .rawText?: return .code
        case .jsxTag(_, let phase, _, _)?: return phase == 2 || phase == 3 ? .string : .code
        }
    }

    /// The language deciding a completion request at the caret (M17 T17.8c,
    /// plan §7): the host's, or — inside an embedded body — the child's.
    public struct CaretLanguage: Sendable, Equatable {
        /// The language identifier every per-language decision uses
        /// (keywords, builtins, `.` receivers, `$`, case, strings as content).
        public let identifier: String
        /// 0 for the host, else the child's index into the host profile's
        /// `embeds` plus one (as in `LexicalScanner.segments(…languages:)`).
        public let embed: Int
        /// The caret's position class, read from the child's state in a body.
        public let position: Position

        public init(identifier: String, embed: Int, position: Position) {
            self.identifier = identifier
            self.embed = embed
            self.position = position
        }

        /// Plain text, or a language without a lexical scanner.
        public static func unscanned(_ identifier: String) -> CaretLanguage {
            CaretLanguage(identifier: identifier, embed: 0, position: identifier.isEmpty ? .plainText : .code)
        }
    }

    /// The language at a caret whose host lexical state is `state` (the
    /// state of `scanner`, the host's context scanner, at the caret; T17.8c).
    /// The host frames decide: an HTML raw-text body or a Markdown fence
    /// body of a known language is the child's (its position class comes
    /// from the child's own state — nil there is its initial state);
    /// everything else — host text, a start tag, a fence's opener line, a
    /// plain or unknown-language body — is the host's, classified as before.
    /// A string position in a data format whose strings are content counts
    /// as plain text (`stringsAreContent`). Used by both the candidate
    /// engine and the completion controller.
    public static func caretLanguage(of state: LexicalScanState, hostIdentifier: String,
                                     scanner: LexicalScanner?) -> CaretLanguage {
        if let scanner, scanner.hasEmbeddedLanguages {
            let embed = LexicalScanner.embeddedLanguage(of: state)
            if embed != 0, let child = scanner.embeddedIdentifier(embed) {
                var position = self.position(of: state.embedded?.state ?? LexicalScanState())
                if position == .string, stringsAreContent(child) { position = .plainText }
                return CaretLanguage(identifier: child, embed: embed, position: position)
            }
        }
        var position = self.position(of: state)
        if position == .string, stringsAreContent(hostIdentifier) { position = .plainText }
        return CaretLanguage(identifier: hostIdentifier, embed: 0, position: position)
    }

    /// Whether a segment of `kind` is code for completion purposes.
    static func isCode(_ segment: LexicalSegment) -> Bool {
        switch segment {
        case .code: return true
        case .block(let kind): return kind == .plain
        default: return false
        }
    }
}
