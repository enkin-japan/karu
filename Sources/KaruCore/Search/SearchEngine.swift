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

/// Failure describing why a search could not run: an invalid regex pattern, a
/// stale match, or a Replace All that hit its time limit. `description` is
/// suitable for surfacing inline in the find bar; `kind` lets the UI tell a
/// timeout apart and show its own localized wording.
public struct SearchError: Error, Equatable {
    public enum Kind: Equatable, Sendable {
        /// The pattern did not compile, or the request could not be satisfied.
        case invalid
        /// The operation ran out of its time budget. Nothing was changed.
        case timedOut
    }

    public let description: String
    public let kind: Kind

    public init(description: String, kind: Kind = .invalid) {
        self.description = description
        self.kind = kind
    }

    /// True when the operation was stopped by its time limit.
    public var isTimeout: Bool { kind == .timedOut }
}

/// Budget for one search / replace pass. Matching stops — even in the middle of
/// catastrophic regex backtracking — once `timeLimit` seconds have elapsed or
/// `maxMatches` matches have been collected.
public struct SearchLimits: Equatable, Sendable {
    public var timeLimit: TimeInterval
    public var maxMatches: Int

    public init(timeLimit: TimeInterval, maxMatches: Int) {
        self.timeLimit = timeLimit
        self.maxMatches = maxMatches
    }

    /// Per-keystroke search in the find bar: 0.2 s, at most 50 000 matches.
    public static let interactive = SearchLimits(timeLimit: 0.2, maxMatches: 50_000)
    /// Replace All: 2 s, no match cap (every match is replaced or none is).
    public static let replaceAll = SearchLimits(timeLimit: 2.0, maxMatches: .max)
}

/// Why a search result is incomplete.
public enum SearchTruncation: Equatable, Sendable {
    /// The time limit ran out before the whole document was scanned.
    case timedOut
    /// `SearchLimits.maxMatches` matches were found; more may exist.
    case matchLimit
}

/// Result of a limit-aware search: the matches found (ascending,
/// non-overlapping) and, when the scan stopped early, why.
public struct SearchOutcome: Equatable {
    public var ranges: [NSRange]
    public var truncation: SearchTruncation?

    public init(ranges: [NSRange], truncation: SearchTruncation? = nil) {
        self.ranges = ranges
        self.truncation = truncation
    }
}

/// Result of a complete Replace All: the rewritten text and how many matches
/// were replaced.
public struct ReplaceAllOutcome: Equatable {
    public var text: String
    public var count: Int

    public init(text: String, count: Int) {
        self.text = text
        self.count = count
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
    /// A monotonic clock in seconds. Injectable so the timeout path can be
    /// tested deterministically.
    typealias Clock = () -> TimeInterval

    /// The production clock: system uptime, which never jumps with wall time.
    static let systemClock: Clock = { ProcessInfo.processInfo.systemUptime }

    /// The clock is read on every `progressCheckStride`-th progress callback
    /// (ICU reports progress once per start position, i.e. up to once per
    /// character) and every `matchCheckStride`-th match, so a 2-million-match
    /// scan costs ~2 000 clock reads, not 2 million.
    static let progressCheckStride = 16
    static let matchCheckStride = 1024

    /// Returns every match range for `pattern` in `text`, under the
    /// interactive limits (`SearchLimits.interactive`). Kept for callers that
    /// do not care whether the result was truncated.
    ///
    /// An empty pattern yields an empty result (never an error). An invalid
    /// regular expression yields a `SearchError` carrying the compiler message.
    public static func matches(in text: String,
                               pattern: String,
                               options: SearchOptions) -> Result<[NSRange], SearchError> {
        search(in: text, pattern: pattern, options: options, limits: .interactive).map(\.ranges)
    }

    /// Limit-aware search. Returns the matches in ascending order; when the
    /// time limit or the match cap stops the scan early, `truncation` says
    /// which, and `ranges` holds the matches found up to that point.
    ///
    /// An empty pattern yields an empty, complete result. An invalid regular
    /// expression yields a `SearchError` carrying the compiler message.
    public static func search(in text: String,
                              pattern: String,
                              options: SearchOptions,
                              limits: SearchLimits = .interactive) -> Result<SearchOutcome, SearchError> {
        search(in: text, pattern: pattern, options: options, limits: limits, clock: systemClock)
    }

    static func search(in text: String,
                       pattern: String,
                       options: SearchOptions,
                       limits: SearchLimits,
                       clock: Clock) -> Result<SearchOutcome, SearchError> {
        guard !pattern.isEmpty else { return .success(SearchOutcome(ranges: [])) }
        return makeRegex(pattern: pattern, options: options).map { regex in
            var ranges: [NSRange] = []
            let truncation = enumerate(regex, in: text, reportProgress: options.regex, limits: limits, clock: clock) { match in
                ranges.append(match.range)
            }
            return SearchOutcome(ranges: ranges, truncation: truncation)
        }
    }

    /// Replaces every match of `pattern` in `text` with `template`, under the
    /// Replace All limits (`SearchLimits.replaceAll`).
    ///
    /// In regex mode `template` supports capture-group references (`$1`, `$0`,
    /// …). In plain-text mode `template` is treated literally: any `$` is
    /// escaped so `$1` inserts the characters "$1" rather than a group.
    ///
    /// An empty pattern returns `text` unchanged. Returns the fully rewritten
    /// document string, or a `SearchError` for an invalid pattern or a timeout.
    public static func replaceAll(in text: String,
                                  pattern: String,
                                  options: SearchOptions,
                                  template: String) -> Result<String, SearchError> {
        replaceAll(in: text, pattern: pattern, options: options, template: template,
                   limits: .replaceAll).map(\.text)
    }

    /// Limit-aware Replace All: the rewritten text plus the number of
    /// replacements. All or nothing — when the time limit runs out the result
    /// is a `SearchError` of kind `.timedOut` and no partial text is ever
    /// returned. A finite `limits.maxMatches` is likewise treated as a failure
    /// when exceeded (Replace All never replaces only some matches).
    ///
    /// The output is identical to `NSRegularExpression.replaceMatches`: the
    /// text between matches is copied verbatim and each match is replaced by
    /// `replacementString(for:in:offset:template:)` against the original text.
    public static func replaceAll(in text: String,
                                  pattern: String,
                                  options: SearchOptions,
                                  template: String,
                                  limits: SearchLimits) -> Result<ReplaceAllOutcome, SearchError> {
        replaceAll(in: text, pattern: pattern, options: options, template: template,
                   limits: limits, clock: systemClock)
    }

    static func replaceAll(in text: String,
                           pattern: String,
                           options: SearchOptions,
                           template: String,
                           limits: SearchLimits,
                           clock: Clock) -> Result<ReplaceAllOutcome, SearchError> {
        guard !pattern.isEmpty else { return .success(ReplaceAllOutcome(text: text, count: 0)) }
        return makeRegex(pattern: pattern, options: options).flatMap { regex in
            // One real NSString for the whole pass, so neither ICU nor the
            // per-match substring / template calls re-bridge the Swift string.
            let ns = NSString(string: text)
            let source = ns as String
            let prepared = preparedTemplate(template, options: options)
            let output = NSMutableString(capacity: ns.length)
            var cursor = 0
            var count = 0
            let truncation = enumerate(regex, in: source, reportProgress: options.regex, limits: limits, clock: clock) { match in
                let range = match.range
                if range.location > cursor {
                    output.append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                }
                output.append(regex.replacementString(for: match, in: source, offset: 0, template: prepared))
                cursor = range.location + range.length
                count += 1
            }
            switch truncation {
            case .timedOut:
                return .failure(SearchError(description: "Replace All timed out; nothing was changed.",
                                            kind: .timedOut))
            case .matchLimit:
                return .failure(SearchError(description: "Too many matches to replace; nothing was changed."))
            case nil:
                if cursor < ns.length {
                    output.append(ns.substring(from: cursor))
                }
                return .success(ReplaceAllOutcome(text: output as String, count: count))
            }
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
        let length = (text as NSString).length
        guard matchRange.location >= 0, matchRange.location <= length,
              matchRange.length >= 0, matchRange.length <= length - matchRange.location else {
            return .failure(SearchError(description: "The match is no longer in the document."))
        }
        return makeRegex(pattern: pattern, options: options).flatMap { regex in
            guard let match = regex.firstMatch(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds], range: matchRange),
                  match.range == matchRange else {
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

    /// Runs `regex` over the whole of `text`, handing each match to `body` in
    /// ascending order, and stops early on the budget. `.reportProgress` makes
    /// ICU call back periodically even while it is stuck backtracking inside a
    /// single match attempt, so setting `stop` there interrupts a catastrophic
    /// pattern on time. Returns why the scan stopped early, or `nil` if it ran
    /// to the end.
    ///
    /// `reportProgress` is off for plain-text searches: an escaped literal
    /// cannot backtrack, its scan is linear, and the per-position callbacks
    /// roughly triple the cost of a 10 MB scan (measured 17 ms → 43 ms). The
    /// time limit is then checked on match callbacks only.
    private static func enumerate(_ regex: NSRegularExpression,
                                  in text: String,
                                  reportProgress: Bool,
                                  limits: SearchLimits,
                                  clock: Clock,
                                  body: (NSTextCheckingResult) -> Void) -> SearchTruncation? {
        let length = (text as NSString).length
        let start = clock()
        var truncation: SearchTruncation?
        var found = 0
        var progressTicks = 0
        regex.enumerateMatches(in: text,
                               options: reportProgress ? [.reportProgress] : [],
                               range: NSRange(location: 0, length: length)) { result, _, stop in
            if let result {
                guard found < limits.maxMatches else {
                    truncation = .matchLimit
                    stop.pointee = true
                    return
                }
                body(result)
                found += 1
                guard found % matchCheckStride == 0 else { return }
            } else {
                progressTicks += 1
                guard progressTicks % progressCheckStride == 0 else { return }
            }
            if clock() - start >= limits.timeLimit {
                truncation = .timedOut
                stop.pointee = true
            }
        }
        return truncation
    }

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
