import Foundation

/// Pure decision logic for "auto-save on focus loss" (T12.14).
///
/// Kept AppKit-independent so it can be unit-tested directly: the window
/// controller feeds in the current on/off preference plus the document's dirty
/// and file-URL state, and acts only on the returned `Bool`.
///
/// Following the project's "no resident data structures" rule this is a pure
/// function over a tiny UserDefaults-backed flag. The flag defaults to **off**:
/// silently writing to disk the instant a window loses focus is surprising, so
/// the user opts in explicitly (mirrors the structure of `AutoClosePairs`, but
/// with the opposite default).
public enum AutoSavePolicy {
    /// UserDefaults key backing the on/off toggle. Defaults to **off** when unset.
    public static let enabledKey = "editor.autoSaveOnFocusLoss"

    /// Whether auto-save-on-focus-loss is enabled (reads UserDefaults, defaults
    /// to `false` when unset). Mirrors `AutoClosePairs.defaultEnabled` but with
    /// the opposite default per the product decision.
    public static var defaultEnabled: Bool {
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        return false
    }

    /// Whether the editor should auto-save on focus loss: only when the feature
    /// is enabled, the document has unsaved changes, **and** it already has a
    /// file URL. An untitled document has no URL — saving it would need a
    /// storage panel, and popping a modal panel the instant the window loses
    /// focus is exactly the disruption this feature must avoid, so it is skipped.
    public static func shouldSave(enabled: Bool, isDirty: Bool, hasFileURL: Bool) -> Bool {
        enabled && isDirty && hasFileURL
    }
}
