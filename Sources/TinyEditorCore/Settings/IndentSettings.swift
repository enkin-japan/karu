import Foundation

/// Per-language indentation configuration, backed by `UserDefaults`.
///
/// Width is looked up per language via keys of the form `indent.width.html`.
/// When no explicit override exists, a small built-in default table applies
/// (most languages default to 4; markup / data formats default to 2).
///
/// The `UserDefaults` instance is injectable so tests can run against an
/// isolated suite instead of the shared domain.
public struct IndentSettings {
    /// Fallback width used when neither a UserDefaults override nor a
    /// language-specific default is present.
    public static let defaultWidth = 4

    /// Built-in per-language default widths (keys are lowercased language ids).
    public static let languageDefaults: [String: Int] = [
        "html": 2,
        "css": 2,
        "json": 2,
        "jsonl": 2,
        "xml": 2,
        "plist": 2,
        "yaml": 2,
        "markdown": 2,
    ]

    /// UserDefaults key controlling whether indentation uses spaces or tabs.
    public static let usesSpacesKey = "indent.usesSpaces"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether indentation is emitted as spaces (`true`, default) or tabs.
    public var usesSpaces: Bool {
        if defaults.object(forKey: Self.usesSpacesKey) != nil {
            return defaults.bool(forKey: Self.usesSpacesKey)
        }
        return true
    }

    /// Indentation width (in columns) for the given language identifier.
    ///
    /// Precedence: UserDefaults override → built-in language default → global
    /// fallback (`defaultWidth`).
    public func width(for language: String) -> Int {
        let key = Self.widthKey(for: language)
        if let override = defaults.object(forKey: key) as? Int, override > 0 {
            return override
        }
        return Self.languageDefaults[language.lowercased()] ?? Self.defaultWidth
    }

    /// Whether the user has an explicit (positive) width override stored for
    /// `language`. Used to arbitrate against content-detected indentation: an
    /// explicit choice always wins, otherwise detection takes over.
    public func hasExplicitWidth(for language: String) -> Bool {
        if let override = defaults.object(forKey: Self.widthKey(for: language)) as? Int, override > 0 {
            return true
        }
        return false
    }

    /// The UserDefaults key used to store the width for `language`.
    public static func widthKey(for language: String) -> String {
        "indent.width.\(language.lowercased())"
    }
}
