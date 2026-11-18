import Foundation

/// Failure returned by ``FormatDispatch/format(text:languageIdentifier:indentWidth:)``.
public enum FormatDispatchError: Error, Equatable {
    /// The language identifier has no built-in formatter.
    case unsupportedLanguage(String)
    /// A formatter rejected the input. `line` is 1-based in the original text,
    /// matching the line numbers reported by `JSONFormatError` / `XMLFormatError`.
    case syntax(line: Int, message: String)
    /// Nesting went past the formatter's depth limit at 1-based `line`
    /// (`FormatLimits`). The text was not formatted.
    case nestingTooDeep(line: Int, limit: Int)
    /// The formatted result would exceed `limitBytes` UTF-8 bytes
    /// (`FormatLimits`). The text was not formatted.
    case outputTooLarge(limitBytes: Int)
}

/// Pure, AppKit-independent mapping from a document's language identifier to the
/// built-in formatter that handles it (JSON / JSONL / XML / plist per
/// ARCHITECTURE.md §2, "排版整理仅内置").
///
/// Kept free of any `NSTextView` dependency so the language dispatch and error
/// line passthrough can be unit tested without a running app.
public enum FormatDispatch {

    /// Language identifiers this dispatcher can format. Used by the menu's
    /// `validateMenuItem` to grey out "Format Document" for other languages.
    public static func supports(languageIdentifier: String) -> Bool {
        switch languageIdentifier.lowercased() {
        case "json", "jsonl", "xml", "plist":
            return true
        default:
            return false
        }
    }

    /// Formats `text` according to `languageIdentifier`.
    ///
    /// - `json`  → pretty-printed with `indentWidth` spaces per level.
    /// - `jsonl` → each non-empty line re-emitted as one compact JSON value.
    /// - `xml` / `plist` → pretty-printed with `indentWidth` spaces per level.
    /// - anything else → `.failure(.unsupportedLanguage)`.
    ///
    /// Formatter syntax errors are surfaced as `.syntax(line:message:)` with the
    /// original 1-based line number preserved. Input nested deeper than the
    /// formatters allow, or whose result would be too large, is refused with
    /// `.nestingTooDeep` / `.outputTooLarge` (`FormatLimits`); the caller's text
    /// is never changed on failure.
    public static func format(
        text: String,
        languageIdentifier: String,
        indentWidth: Int
    ) -> Result<String, FormatDispatchError> {
        switch languageIdentifier.lowercased() {
        case "json":
            return run { try JSONFormatter.prettyPrint(text, indentWidth: indentWidth) }
        case "jsonl":
            return run { try JSONFormatter.formatJSONL(text) }
        case "xml", "plist":
            return run { try XMLFormatter.prettyPrint(text, indentWidth: indentWidth) }
        default:
            return .failure(.unsupportedLanguage(languageIdentifier))
        }
    }

    /// Runs one formatter and maps what it throws onto `FormatDispatchError`:
    /// syntax errors keep their 1-based line, limit errors keep their numbers.
    private static func run(_ body: () throws -> String) -> Result<String, FormatDispatchError> {
        do {
            return .success(try body())
        } catch let error as JSONFormatError {
            return .failure(.syntax(line: error.line, message: error.message))
        } catch let error as XMLFormatError {
            return .failure(.syntax(line: error.line, message: error.message))
        } catch FormatLimitError.nestingTooDeep(let line, let limit) {
            return .failure(.nestingTooDeep(line: line, limit: limit))
        } catch FormatLimitError.outputTooLarge(let limitBytes) {
            return .failure(.outputTooLarge(limitBytes: limitBytes))
        } catch {
            return .failure(.syntax(line: 1, message: "\(error)"))
        }
    }
}
