import Foundation

/// Pure decision logic for auto-closing brackets / quotes and wrapping a
/// selection (T12.6).
///
/// Everything here is NSTextView-independent so it can be unit-tested directly:
/// `EditorTextView` is a thin wrapper that feeds the surrounding characters in
/// and applies the returned `Decision` through the undo-aware mutation path.
/// The input-method guard (never interfere while composing CJK text) lives in
/// the wrapper, not here — this layer only ever sees committed, single
/// characters.
///
/// Following the project's "no resident data structures" rule, the pair tables
/// are tiny static constants and every entry point is a pure function.
public enum AutoClosePairs {
    /// UserDefaults key backing the on/off toggle. Defaults to **on** when unset.
    public static let enabledKey = "editor.autoClosePairs"

    /// Whether auto-closing is enabled by default (reads UserDefaults, defaults
    /// to `true` when unset). Mirrors `IndentRainbow.defaultEnabled`.
    public static var defaultEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        return true
    }

    /// Bracket pairs: opener → matching closer.
    public static let openToClose: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
    ]

    /// The closing bracket characters (the values of `openToClose`).
    public static let closers: Set<Character> = [")", "]", "}"]

    /// Symmetric quote characters (open == close).
    public static let quotes: Set<Character> = ["\"", "'", "`"]

    /// The action `EditorTextView` should take for a single typed character.
    public enum Decision: Equatable {
        /// Insert `text` at the caret, then place the caret `caretOffset` UTF-16
        /// units into it (e.g. `("()", caretOffset: 1)` leaves the caret between
        /// the parentheses).
        case insertPair(String, caretOffset: Int)
        /// The typed character already sits to the right of the caret — advance
        /// over it without inserting anything.
        case stepOver
        /// A selection is active: surround it with `prefix` / `suffix`.
        case wrap(prefix: String, suffix: String)
        /// Not an auto-close situation — insert the character normally.
        case passthrough
    }

    /// Decides what to do when `typed` (expected to be a single character) is
    /// entered, given the characters immediately before / after the caret (or the
    /// selection) and whether a selection is active.
    ///
    /// - Open bracket: selection → `wrap`; otherwise `insertPair` with the caret
    ///   centred.
    /// - Close bracket: the same closer already follows the caret → `stepOver`;
    ///   otherwise `passthrough`.
    /// - Quote: selection → `wrap`; the same quote already follows → `stepOver`;
    ///   the character before is a word character or the same quote (so `don't` /
    ///   Python `'''` don't auto-close) → `passthrough`; otherwise `insertPair`.
    public static func decide(typed: String,
                              charBefore: Character?,
                              charAfter: Character?,
                              hasSelection: Bool) -> Decision {
        guard typed.count == 1, let ch = typed.first else { return .passthrough }

        // Opening bracket.
        if let close = openToClose[ch] {
            if hasSelection {
                return .wrap(prefix: String(ch), suffix: String(close))
            }
            return .insertPair(String(ch) + String(close), caretOffset: 1)
        }

        // Closing bracket.
        if closers.contains(ch) {
            return charAfter == ch ? .stepOver : .passthrough
        }

        // Quote (symmetric).
        if quotes.contains(ch) {
            if hasSelection {
                return .wrap(prefix: String(ch), suffix: String(ch))
            }
            if charAfter == ch { return .stepOver }
            if let before = charBefore, isWordCharacter(before) || before == ch {
                return .passthrough
            }
            return .insertPair(String(ch) + String(ch), caretOffset: 1)
        }

        return .passthrough
    }

    /// Whether a backspace should delete *two* characters because the caret sits
    /// inside an empty auto-inserted pair (e.g. `(|)`, `[|]`, `"|"`).
    public static func shouldDeletePair(charBefore: Character?, charAfter: Character?) -> Bool {
        guard let before = charBefore, let after = charAfter else { return false }
        if let close = openToClose[before], close == after { return true }
        if quotes.contains(before), before == after { return true }
        return false
    }

    /// A "word" character for the词内-apostrophe rule: letters, digits, and the
    /// underscore. Uses Unicode-aware `Character` predicates so accented letters
    /// (e.g. `naïve'`) also suppress the quote pair.
    static func isWordCharacter(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }
}
