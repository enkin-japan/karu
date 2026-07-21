import Foundation

/// Configuration for a search / replace pass.
///
/// `regex == false` runs a plain-text (literal) search: the pattern is fed
/// through `NSRegularExpression.escapedPattern(for:)` so metacharacters lose
/// their special meaning. Case sensitivity is honored in both modes.
public struct SearchOptions: Equatable {
    /// Interpret the pattern as a regular expression when `true`; otherwise the
    /// pattern is matched literally.
    public var regex: Bool
    /// Match case exactly when `true`; case-insensitive when `false`.
    public var caseSensitive: Bool

    public init(regex: Bool = false, caseSensitive: Bool = false) {
        self.regex = regex
        self.caseSensitive = caseSensitive
    }
}

/// Failure describing why a search could not run (currently only invalid regex
/// patterns). `description` is suitable for surfacing inline in the find bar.
public struct SearchError: Error, Equatable {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Pure, AppKit-independent search / replace core.
///
/// Every entry point is one-shot: the regex is compiled, used, and discarded on
/// each call. No index or compiled pattern is retained between calls, honoring
/// the architecture's "transient, never resident" rule for whole-document
/// operations (see ARCHITECTURE.md §3.4). All ranges use UTF-16 / NSString
/// semantics so results map directly onto `NSTextView`.
public enum SearchEngine {
    /// Returns every match range for `pattern` in `text`.
    ///
    /// An empty pattern yields an empty result (never an error). An invalid
    /// regular expression yields a `SearchError` carrying the compiler message.
    public static func matches(in text: String,
                               pattern: String,
                               options: SearchOptions) -> Result<[NSRange], SearchError> {
        guard !pattern.isEmpty else { return .success([]) }
        return makeRegex(pattern: pattern, options: options).map { regex in
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            return regex.matches(in: text, options: [], range: full).map(\.range)
        }
    }

    /// Replaces every match of `pattern` in `text` with `template`.
    ///
    /// In regex mode `template` supports capture-group references (`$1`, `$0`,
    /// …). In plain-text mode `template` is treated literally: any `$` is
    /// escaped so `$1` inserts the characters "$1" rather than a group.
    ///
    /// An empty pattern returns `text` unchanged. Returns the fully rewritten
    /// document string, or a `SearchError` for an invalid pattern.
    public static func replaceAll(in text: String,
                                  pattern: String,
                                  options: SearchOptions,
                                  template: String) -> Result<String, SearchError> {
        guard !pattern.isEmpty else { return .success(text) }
        return makeRegex(pattern: pattern, options: options).map { regex in
            let mutable = NSMutableString(string: text)
            let full = NSRange(location: 0, length: mutable.length)
            regex.replaceMatches(in: mutable,
                                 options: [],
                                 range: full,
                                 withTemplate: preparedTemplate(template, options: options))
            return mutable as String
        }
    }

    /// Computes the replacement text for a single, already-known match.
    ///
    /// `matchRange` is a range previously returned by `matches(in:...)`. The
    /// regex is recompiled and re-run inside that range so capture groups are
    /// resolved against the live text; the UI applies the returned string
    /// through the text view's undo-aware insertion path.
    ///
    /// Template handling matches `replaceAll` (literal `$` escaping in plain-text
    /// mode). Returns a `SearchError` when the pattern is invalid or no match
    /// exists at `matchRange`.
    public static func replacementText(for matchRange: NSRange,
                                       in text: String,
                                       pattern: String,
                                       options: SearchOptions,
                                       template: String) -> Result<String, SearchError> {
        makeRegex(pattern: pattern, options: options).flatMap { regex in
            guard let match = regex.firstMatch(in: text, options: [], range: matchRange) else {
                return .failure(SearchError(description: "No match at the given range."))
            }
            let replacement = regex.replacementString(for: match,
                                                       in: text,
                                                       offset: 0,
                                                       template: preparedTemplate(template, options: options))
            return .success(replacement)
        }
    }

    // MARK: - Internals

    /// Compiles the effective pattern with the requested options.
    ///
    /// `.anchorsMatchLines` is always enabled so `^` / `$` bind to line
    /// boundaries in multiline documents (harmless in plain-text mode, where the
    /// pattern is fully escaped).
    private static func makeRegex(pattern: String,
                                  options: SearchOptions) -> Result<NSRegularExpression, SearchError> {
        let effective = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            return .success(try NSRegularExpression(pattern: effective, options: flags))
        } catch {
            return .failure(SearchError(description: error.localizedDescription))
        }
    }

    /// Regex-mode templates pass through verbatim; plain-text templates are
    /// escaped so `$`/`\` are inserted literally.
    private static func preparedTemplate(_ template: String, options: SearchOptions) -> String {
        options.regex ? template : NSRegularExpression.escapedTemplate(for: template)
    }
}
