import Foundation

/// The three UI languages Karu ships. `rawValue` is the tag stored in
/// UserDefaults (`app.language`); the BCP-47 form `zh-Hans` is used for Chinese.
public enum AppLanguage: String, CaseIterable, Sendable {
    case en
    case zhHans = "zh-Hans"
    case ja

    /// Native name of the language, shown verbatim in the language picker.
    /// Deliberately *not* translated (proper nouns), so a user who cannot read
    /// the current UI language can still find their own.
    public var displayName: String {
        switch self {
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .ja: return "日本語"
        }
    }
}

/// Every user-facing UI string, keyed. `CaseIterable` powers the completeness
/// test that guards against a missing translation in any of the three tables.
public enum L10nKey: String, CaseIterable, Sendable {
    // App menu (carry the app name per macOS convention).
    case appAbout, appCheckForUpdates, appSettings, appHide, appQuit
    // File menu.
    case menuFile, menuNew, menuOpen, menuClose, menuSave, menuSaveAs
    // Reopen-with-encoding submenu + its alerts.
    case menuReopenWithEncoding
    case reopenConfirmMessage, reopenConfirmInfo, reopenDiscardButton
    case encodingDecodeFailedTitle, encodingDecodeFailedMessage
    // Edit menu.
    case menuEdit, menuUndo, menuRedo, menuCut, menuCopy, menuPaste, menuSelectAll
    // Find submenu.
    case menuFind, menuFindEllipsis, menuFindNext, menuFindPrevious, menuUseSelectionForFind
    // Jump-to-symbol navigator.
    case menuJumpToSymbol, symbolFilterPlaceholder, symbolNone
    // Go-to-line panel.
    case menuGoToLine, goToLinePlaceholder
    // Title-bar rename (filename capsule) errors.
    case renameErrorTitle, renameErrorEmpty, renameErrorInvalid, renameErrorExists, renameErrorGeneric
    // Edit menu — comment toggle + line operations.
    case menuToggleComment
    case menuMoveLineUp, menuMoveLineDown, menuCopyLineUp, menuCopyLineDown, menuDeleteLine
    // Edit menu — jump to matching bracket (⌘⇧\).
    case menuJumpToMatchingBracket
    // Format menu.
    case menuFormat, menuFormatDocument
    // Convert-line-endings submenu.
    case menuConvertLineEndings
    // View menu — font zoom.
    case menuView, viewZoomIn, viewZoomOut, viewActualSize
    // View menu — command palette (⌘⇧P).
    case menuCommandPalette, commandPalettePlaceholder, commandPaletteEmpty
    // Language menu.
    case menuLanguage, languageAuto
    // Toolbar labels / tooltips.
    case toolbarIndentLabel, toolbarIndentTooltip
    case toolbarFeatureModulesTooltip, toolbarSettingsLabel
    case formatAction
    // Find bar.
    case findPlaceholder, replacePlaceholder
    case findRegexTooltip, findCaseTooltip
    case findPrevTooltip, findNextTooltip
    case findReplaceTooltip, findReplaceAll, findReplaceAllTooltip
    case findDone, findDoneTooltip
    case findNoResults, findReplacedCount, findFoundCount, findMatchPosition
    // Alerts / editor chrome.
    case formatFailedTitle, formatErrorLine
    case closeConfirmMessage, closeConfirmInfo
    case dontSave, cancel, untitled
    // iCloud download (opening a not-yet-synced ubiquitous file).
    case downloadingTitle, downloadTimeoutTitle, downloadTimeoutMessage
    // Preferences.
    case prefTitle, prefModules, prefEditor
    case prefIndentWidthLabel, prefInsertSpaces, prefIndentRainbow, prefAutoClosePairs, prefFontSizeLabel
    case prefLanguageLabel, prefLanguageSystem
    // Feature-module display names.
    case moduleHighlight, moduleCompletion, moduleFormat
    // Status bar.
    case statusLnCol, statusCharOne, statusCharMany
}

/// Lightweight, in-code localization: three string tables selected at runtime by
/// a UserDefaults preference, with live switching over a notification.
///
/// Deliberately avoids `.lproj` / `Bundle` localization: SPM resource bundles add
/// build complexity and bundle weight, and cannot switch language without a
/// relaunch. This table-based scheme keeps the bundle at one binary and flips
/// language instantly (ARCHITECTURE.md size red lines).
public enum L10n {
    /// Posted (object: nil) after `set(_:)` so menus / windows can re-pull strings.
    public static let didChangeNotification = Notification.Name("L10nDidChange")

    /// UserDefaults key holding the chosen `AppLanguage.rawValue`. Absent = follow
    /// the system.
    public static let defaultsKey = "app.language"

    /// App name embedded into the App-menu items (About / Hide / Quit). Kept here
    /// so a single literal drives every "%@"-carrying menu title.
    public static let appName = "Karu"

    private static let defaults: UserDefaults = .standard

    // MARK: - Current language

    /// The active language: the stored override, or the mapped system default.
    public static var current: AppLanguage {
        if let raw = defaults.string(forKey: defaultsKey),
           let language = AppLanguage(rawValue: raw) {
            return language
        }
        return systemDefault
    }

    /// The system's language mapped onto our three-way set.
    public static var systemDefault: AppLanguage {
        mappedLanguage(fromPreferred: Locale.preferredLanguages)
    }

    /// Maps the first preferred language code onto `AppLanguage`; anything that is
    /// neither Chinese nor Japanese falls back to English. Pure (takes the codes
    /// as input) so it is unit-testable without touching global state.
    static func mappedLanguage(fromPreferred codes: [String]) -> AppLanguage {
        guard let first = codes.first?.lowercased() else { return .en }
        if first.hasPrefix("zh") { return .zhHans }
        if first.hasPrefix("ja") { return .ja }
        return .en
    }

    /// Sets (or clears, with `nil` = follow system) the language override and
    /// broadcasts the change so open UI re-reads its strings.
    public static func set(_ language: AppLanguage?) {
        if let language {
            defaults.set(language.rawValue, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Lookup

    /// Localized string for `key` in the current language, formatting in `args`
    /// (via `String(format:)`) when the value carries `%@` / `%d` placeholders.
    public static func t(_ key: L10nKey, _ args: CVarArg...) -> String {
        format(key, language: current, args: args)
    }

    /// Same as `t`, but against an explicit language — used by tests for
    /// determinism and by pure helpers that must not read global state.
    public static func string(_ key: L10nKey, language: AppLanguage, _ args: CVarArg...) -> String {
        format(key, language: language, args: args)
    }

    /// The full table for a language (exposed for the completeness test).
    public static func table(for language: AppLanguage) -> [L10nKey: String] {
        switch language {
        case .en: return enTable
        case .zhHans: return zhHansTable
        case .ja: return jaTable
        }
    }

    private static func format(_ key: L10nKey, language: AppLanguage, args: [CVarArg]) -> String {
        let raw = table(for: language)[key] ?? enTable[key] ?? key.rawValue
        return args.isEmpty ? raw : String(format: raw, arguments: args)
    }
}
