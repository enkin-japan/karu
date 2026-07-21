import CoreGraphics

/// Pure font-size zoom arithmetic (View ▸ Zoom In / Out / Actual Size). Split out
/// as a testable enum: it owns the clamp range and the step, with no UI or
/// UserDefaults dependency. The zoom itself just writes the result through the
/// shared `EditorFontSettings` key so preferences and every window stay in sync.
public enum FontZoom {
    /// Zoom clamp bounds (pt). Shared with the preferences font stepper.
    public static let minSize: CGFloat = EditorFontSettings.minFontSize
    public static let maxSize: CGFloat = EditorFontSettings.maxFontSize

    /// One zoom step, in points.
    public static let stepSize: CGFloat = 1

    /// The size restored by "Actual Size" (the editor's default font size).
    public static let defaultSize: CGFloat = EditorFontSettings.defaultFontSize

    public enum Direction {
        case increase
        case decrease
    }

    /// One zoom step from `current` in `direction`, clamped to `minSize…maxSize`.
    public static func step(current: CGFloat, direction: Direction) -> CGFloat {
        let delta = direction == .increase ? stepSize : -stepSize
        return min(max(current + delta, minSize), maxSize)
    }
}
