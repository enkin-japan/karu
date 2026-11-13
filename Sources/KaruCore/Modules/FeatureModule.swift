import Foundation

/// The toggleable feature modules defined by ARCHITECTURE.md §2.5.
///
/// All modules are statically compiled in; "loading/unloading" is a runtime
/// switch. Call sites gate on `ModuleSettings.isEnabled(_:)` and must release
/// all runtime state when a module is switched off, so a disabled module's
/// resident cost returns to ≈ 0.
public enum FeatureModule: String, CaseIterable, Sendable {
    case highlight
    case completion
    case format
    case run
    /// M17: in-process type inference (T17.11). In T17.1 it gates nothing yet
    /// beyond taking part in `DocumentAnalysis`'s release rule.
    case typeInference
    /// M17: project-folder cross-file index (T17.12). Same T17.1 status.
    case crossFileIndex

    /// User-facing display name for the settings UI (localized).
    public var displayName: String {
        switch self {
        case .highlight: return L10n.t(.moduleHighlight)
        case .completion: return L10n.t(.moduleCompletion)
        case .format: return L10n.t(.moduleFormat)
        case .run: return L10n.t(.moduleRun)
        case .typeInference: return L10n.t(.moduleTypeInference)
        case .crossFileIndex: return L10n.t(.moduleCrossFileIndex)
        }
    }

    var defaultsKey: String { "module.\(rawValue).enabled" }
}

/// UserDefaults-backed on/off state for feature modules. All modules default
/// to enabled. Changes are broadcast via `ModuleSettings.didChangeNotification`
/// (object: the `FeatureModule.rawValue` string) so open windows can attach or
/// tear down module state.
public struct ModuleSettings {
    public static let didChangeNotification = Notification.Name("ModuleSettingsDidChange")

    private let defaults: UserDefaults
    private let center: NotificationCenter

    public init(defaults: UserDefaults = .standard,
                center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    public func isEnabled(_ module: FeatureModule) -> Bool {
        if defaults.object(forKey: module.defaultsKey) != nil {
            return defaults.bool(forKey: module.defaultsKey)
        }
        return true
    }

    public func setEnabled(_ enabled: Bool, for module: FeatureModule) {
        guard isEnabled(module) != enabled else { return }
        defaults.set(enabled, forKey: module.defaultsKey)
        center.post(name: Self.didChangeNotification,
                    object: module.rawValue)
    }
}
