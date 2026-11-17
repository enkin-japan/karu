import AppKit

/// Which languages the toolbar's language popup and the main "Language" menu
/// list (T16.2). One shared setting drives both.
///
/// Only the *hidden* identifiers are persisted (`languages.hidden.v1`, a string
/// array), so a language added to `SupportedLanguage.all` later starts out
/// visible. A missing key means everything is visible. Plain Text (`""`) can
/// never be hidden, and the "Auto" entry is not a language at all — it is always
/// present. Unknown identifiers found in storage are ignored.
///
/// Hiding a language only trims the lists; automatic detection, shortcuts and
/// highlighting for that language are unaffected.
public struct LanguageMenuSettings {
    public static let didChangeNotification = Notification.Name("KaruLanguageMenuSettingsDidChange")
    public static let hiddenKey = "languages.hidden.v1"

    private let defaults: UserDefaults
    private let center: NotificationCenter

    public init(defaults: UserDefaults = .standard,
                center: NotificationCenter = .default) {
        self.defaults = defaults
        self.center = center
    }

    /// Every identifier that may be hidden (all supported languages except
    /// Plain Text), in `SupportedLanguage.all` order.
    public static var hideableIdentifiers: [String] {
        SupportedLanguage.all.map(\.identifier).filter { !$0.isEmpty }
    }

    /// Normalizes a stored / imported list: keeps only hideable identifiers,
    /// drops duplicates, and orders the result like `SupportedLanguage.all`.
    public static func sanitized(_ identifiers: [String]) -> [String] {
        let requested = Set(identifiers)
        return hideableIdentifiers.filter { requested.contains($0) }
    }

    /// The currently hidden identifiers (sanitized; unknown values ignored).
    public var hiddenIdentifiers: Set<String> {
        let raw = (defaults.array(forKey: Self.hiddenKey) ?? []).compactMap { $0 as? String }
        return Set(Self.sanitized(raw))
    }

    public func isVisible(_ identifier: String) -> Bool {
        identifier.isEmpty || !hiddenIdentifiers.contains(identifier)
    }

    /// Shows or hides one language. Plain Text and unknown identifiers are
    /// ignored; a no-op change neither writes nor notifies.
    public func setVisible(_ visible: Bool, for identifier: String) {
        guard Self.hideableIdentifiers.contains(identifier) else { return }
        var hidden = hiddenIdentifiers
        guard hidden.contains(identifier) == visible else { return }
        if visible { hidden.remove(identifier) } else { hidden.insert(identifier) }
        let list = Self.sanitized(Array(hidden))
        if list.isEmpty { defaults.removeObject(forKey: Self.hiddenKey) }
        else { defaults.set(list, forKey: Self.hiddenKey) }
        center.post(name: Self.didChangeNotification, object: nil)
    }

    /// Restores the default (every language visible).
    public func showAll() {
        guard defaults.object(forKey: Self.hiddenKey) != nil else { return }
        defaults.removeObject(forKey: Self.hiddenKey)
        center.post(name: Self.didChangeNotification, object: nil)
    }

    /// Visible languages in `SupportedLanguage.all` order (Plain Text always).
    public var visibleLanguages: [(title: String, identifier: String)] {
        let hidden = hiddenIdentifiers
        return SupportedLanguage.all.filter { $0.identifier.isEmpty || !hidden.contains($0.identifier) }
    }

    /// The menu layout for a window whose manually chosen language is `current`
    /// (`nil` while Auto is in charge). `suggestions` are the language
    /// identifiers detection offers for a window it could not classify on its
    /// own (best first); they head the menu in their own section.
    public func menuLayout(current: String?, suggestions: [String] = []) -> LanguageMenuLayout {
        var layout = Self.layout(hidden: hiddenIdentifiers, current: current)
        layout.suggestions = Self.suggestionEntries(suggestions)
        return layout
    }

    /// Menu entries for suggested identifiers, in order: unknown identifiers,
    /// Plain Text and duplicates are dropped. Hidden languages are kept — the
    /// visibility setting trims the list, not what detection may offer.
    public static func suggestionEntries(_ identifiers: [String]) -> [LanguageMenuEntry] {
        var seen = Set<String>()
        return identifiers.compactMap { raw in
            let id = raw.lowercased()
            guard !id.isEmpty, seen.insert(id).inserted,
                  let match = SupportedLanguage.all.first(where: { $0.identifier == id }) else { return nil }
            return LanguageMenuEntry(title: match.title, identifier: match.identifier)
        }
    }

    /// Pure item-list builder shared by the toolbar popup and the main menu.
    /// Lists the visible languages; when `current` names a supported language
    /// that is hidden, it is returned as `extra` so the UI can still show and
    /// select / check it instead of a wrong or blank title.
    public static func layout(hidden: Set<String>, current: String?) -> LanguageMenuLayout {
        let languages = SupportedLanguage.all
            .filter { $0.identifier.isEmpty || !hidden.contains($0.identifier) }
            .map { LanguageMenuEntry(title: $0.title, identifier: $0.identifier) }
        var extra: LanguageMenuEntry?
        if let current, !current.isEmpty, hidden.contains(current),
           let match = SupportedLanguage.all.first(where: { $0.identifier == current }) {
            extra = LanguageMenuEntry(title: match.title, identifier: match.identifier)
        }
        return LanguageMenuLayout(languages: languages, extra: extra)
    }
}

public struct LanguageMenuEntry: Equatable, Sendable {
    public let title: String
    public let identifier: String
}

/// Auto, separator, the visible languages, then — only when needed — a
/// separator and the hidden language the window is currently using. While
/// detection has suggestions for the window, a header ("Might be"), the
/// suggested languages and a separator sit between Auto's separator and the
/// visible languages (which still list the suggested ones too).
public struct LanguageMenuLayout: Equatable, Sendable {
    public let languages: [LanguageMenuEntry]
    public let extra: LanguageMenuEntry?
    /// Suggested languages, best first; empty for no suggestion section.
    public var suggestions: [LanguageMenuEntry] = []

    /// Tags marking the suggestion section's header and items, so a populated
    /// menu's signature tells them apart from the ordinary language items.
    static let suggestionHeaderTag = -1001
    static let suggestionItemTag = -1002

    /// Every supported language, no extra entry (the shortcut catalog uses this
    /// so bindings stay independent of the visibility setting).
    public static var unfiltered: LanguageMenuLayout {
        LanguageMenuSettings.layout(hidden: [], current: nil)
    }

    /// Compact description of the item sequence: `*` Auto, `-` separator,
    /// `=id` a language. Used to skip rebuilding a menu that already matches.
    /// `^title` the suggestion header, `?id` a suggested language. The header
    /// carries its (localized) title so a UI-language switch rebuilds it.
    func signature(suggestionHeader: String = "") -> [String] {
        var tokens = ["*", "-"]
        if !suggestions.isEmpty {
            tokens += ["^" + suggestionHeader] + suggestions.map { "?" + $0.identifier } + ["-"]
        }
        tokens += languages.map { "=" + $0.identifier }
        if let extra { tokens += ["-", "=" + extra.identifier] }
        return tokens
    }

    var signature: [String] { signature() }

    static func signature(of menu: NSMenu) -> [String] {
        menu.items.map { item in
            if item.isSeparatorItem { return "-" }
            if item.tag == suggestionHeaderTag { return "^" + item.title }
            if item.tag == suggestionItemTag, let id = item.representedObject as? String { return "?" + id }
            if let id = item.representedObject as? String { return "=" + id }
            return "*"
        }
    }

    /// Replaces `menu`'s items with Auto + languages (+ the hidden extra).
    /// Language items carry their identifier on `representedObject`. With
    /// suggestions, a disabled `suggestionHeader` item and one item per
    /// suggestion (identifier on `representedObject`, `suggestionAction`)
    /// follow Auto's separator, closed by a separator of their own.
    @MainActor
    func populate(_ menu: NSMenu, autoTitle: String, autoAction: Selector?, autoTag: Int = 0,
                  languageAction: Selector?, suggestionHeader: String = "",
                  suggestionAction: Selector? = nil) {
        menu.removeAllItems()
        let auto = NSMenuItem(title: autoTitle, action: autoAction, keyEquivalent: "")
        auto.tag = autoTag
        menu.addItem(auto)
        menu.addItem(.separator())
        if !suggestions.isEmpty {
            let header = NSMenuItem(title: suggestionHeader, action: nil, keyEquivalent: "")
            header.tag = Self.suggestionHeaderTag
            header.isEnabled = false
            menu.addItem(header)
            for entry in suggestions {
                let item = NSMenuItem(title: entry.title, action: suggestionAction, keyEquivalent: "")
                item.representedObject = entry.identifier
                item.tag = Self.suggestionItemTag
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        func add(_ entry: LanguageMenuEntry) {
            let item = NSMenuItem(title: entry.title, action: languageAction, keyEquivalent: "")
            item.representedObject = entry.identifier
            menu.addItem(item)
        }
        languages.forEach(add)
        if let extra {
            menu.addItem(.separator())
            add(extra)
        }
    }
}
