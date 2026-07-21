import Foundation

/// Editor font size, backed by `UserDefaults` key `editor.fontSize`.
///
/// Split out as an injectable type (like ``IndentSettings``) so the default /
/// override read path can be unit tested against an isolated defaults suite.
public struct EditorFontSettings {
    /// UserDefaults key backing the editor font size.
    public static let fontSizeKey = "editor.fontSize"

    /// Font size used when no override is stored.
    public static let defaultFontSize: CGFloat = 13

    /// Clamp bounds for the preferences stepper.
    public static let minFontSize: CGFloat = 8
    public static let maxFontSize: CGFloat = 32

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The configured font size, or ``defaultFontSize`` when unset / invalid.
    public var fontSize: CGFloat {
        if defaults.object(forKey: Self.fontSizeKey) != nil {
            let value = defaults.double(forKey: Self.fontSizeKey)
            if value > 0 {
                return CGFloat(value)
            }
        }
        return Self.defaultFontSize
    }

    /// Persists a new font size (clamped to the allowed range).
    public func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, Self.minFontSize), Self.maxFontSize)
        defaults.set(Double(clamped), forKey: Self.fontSizeKey)
    }
}
