import Foundation

/// Single source of truth for the (display title, identifier) pairs shown in the
/// Language menu and the main-window toolbar's language popup.
///
/// Keeping this list in one place avoids the two-locations-drift the toolbar
/// work would otherwise introduce (menu vs. toolbar). Identifiers match the ones
/// the highlighter resolves (`LanguageRegistry` / `LanguageDefinition.identifier`)
/// and that `IndentSettings` keys on. The empty identifier is Plain Text — no
/// highlighting, no formatter.
public enum SupportedLanguage {
    /// Ordered `(title, identifier)` pairs. Mirrors the 15 supported languages
    /// (ARCHITECTURE.md §4) plus a Plain Text entry.
    public static let all: [(title: String, identifier: String)] = [
        ("Plain Text", ""),
        ("JSON", "json"),
        ("JSONL", "jsonl"),
        ("Markdown", "markdown"),
        ("Python", "python"),
        ("JavaScript", "javascript"),
        ("TypeScript", "typescript"),
        ("HTML", "html"),
        ("CSS", "css"),
        ("C", "c"),
        ("C++", "cpp"),
        ("C#", "csharp"),
        ("Java", "java"),
        ("Bash", "bash"),
        ("SQL", "sql"),
        ("XML", "xml"),
        ("YAML", "yaml"),
        ("TOML", "toml"),
        ("Go", "go"),
        ("Rust", "rust"),
        ("Swift", "swift"),
    ]

    /// Human-readable name for a language identifier (case-insensitive). Returns
    /// `"Plain Text"` for the empty identifier and for anything unrecognized, so
    /// the status bar always has something sensible to show.
    public static func title(forIdentifier identifier: String) -> String {
        let id = identifier.lowercased()
        if id.isEmpty { return "Plain Text" }
        return all.first { $0.identifier == id }?.title ?? "Plain Text"
    }
}
