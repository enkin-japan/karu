import Foundation

/// Failure returned by ``FormatDispatch/format(text:languageIdentifier:indentWidth:)``.
public enum FormatDispatchError: Error, Equatable {
    /// The language identifier has no built-in formatter.
    case unsupportedLanguage(String)
    /// A formatter rejected the input. `line` is 1-based in the original text,
    /// matching the line numbers reported by `JSONFormatError` / `XMLFormatError`.
    case syntax(line: Int, message: String)
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
    /// original 1-based line number preserved.
    public static func format(
        text: String,
        languageIdentifier: String,
        indentWidth: Int
    ) -> Result<String, FormatDispatchError> {
        switch languageIdentifier.lowercased() {
        case "json":
            do {
                return .success(try JSONFormatter.prettyPrint(text, indentWidth: indentWidth))
            } catch let error as JSONFormatError {
                return .failure(.syntax(line: error.line, message: error.message))
            } catch {
                return .failure(.syntax(line: 1, message: "\(error)"))
            }
        case "jsonl":
            do {
                return .success(try JSONFormatter.formatJSONL(text))
            } catch let error as JSONFormatError {
                return .failure(.syntax(line: error.line, message: error.message))
            } catch {
                return .failure(.syntax(line: 1, message: "\(error)"))
            }
        case "xml", "plist":
            do {
                return .success(try XMLFormatter.prettyPrint(text, indentWidth: indentWidth))
            } catch let error as XMLFormatError {
                return .failure(.syntax(line: error.line, message: error.message))
            } catch {
                return .failure(.syntax(line: 1, message: "\(error)"))
            }
        default:
            return .failure(.unsupportedLanguage(languageIdentifier))
        }
    }
}
