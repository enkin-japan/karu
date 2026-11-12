import AppKit
import Testing
@testable import KaruCore

/// T16.2 — user-chosen language list shared by the toolbar popup and the main
/// Language menu, plus its settings-archive round trip.
@Suite("Language menu visibility", .serialized)
@MainActor
struct LanguageMenuSettingsTests {
    init() { _ = NSApplication.shared }

    private func isolated() -> (UserDefaults, () -> Void) {
        let name = "KaruLanguageMenuTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private final class PostCounter: NSObject {
        var count = 0
        init(center: NotificationCenter) {
            super.init()
            center.addObserver(self, selector: #selector(posted),
                               name: LanguageMenuSettings.didChangeNotification, object: nil)
        }
        @objc private func posted() { count += 1 }
    }

    // MARK: - Settings model

    @Test func everythingIsVisibleByDefault() {
        let (defaults, clean) = isolated(); defer { clean() }
        let settings = LanguageMenuSettings(defaults: defaults, center: NotificationCenter())
        #expect(settings.hiddenIdentifiers.isEmpty)
        #expect(settings.visibleLanguages.map(\.identifier) == SupportedLanguage.all.map(\.identifier))
        #expect(SupportedLanguage.all.allSatisfy { settings.isVisible($0.identifier) })
        #expect(defaults.object(forKey: LanguageMenuSettings.hiddenKey) == nil)
    }

    @Test func hideAndShowRoundTripPersistsHiddenIdentifiersOnly() {
        let (defaults, clean) = isolated(); defer { clean() }
        let center = NotificationCenter()
        let posts = PostCounter(center: center)
        let settings = LanguageMenuSettings(defaults: defaults, center: center)

        settings.setVisible(false, for: "python")
        settings.setVisible(false, for: "go")
        #expect(posts.count == 2)
        // Stored in SupportedLanguage order regardless of the order hidden.
        #expect(defaults.stringArray(forKey: LanguageMenuSettings.hiddenKey) == ["python", "go"])
        let reread = LanguageMenuSettings(defaults: defaults, center: center)
        #expect(!reread.isVisible("python") && !reread.isVisible("go"))
        #expect(reread.isVisible("json"))
        #expect(reread.visibleLanguages.count == SupportedLanguage.all.count - 2)
        #expect(!reread.visibleLanguages.contains { $0.identifier == "python" })

        settings.setVisible(false, for: "python") // no-op: neither writes nor notifies
        #expect(posts.count == 2)

        settings.setVisible(true, for: "python")
        #expect(posts.count == 3)
        #expect(defaults.stringArray(forKey: LanguageMenuSettings.hiddenKey) == ["go"])
        settings.setVisible(true, for: "go")
        // Back to the default: the key disappears, so future languages stay visible.
        #expect(defaults.object(forKey: LanguageMenuSettings.hiddenKey) == nil)

        settings.setVisible(false, for: "rust")
        settings.showAll()
        #expect(defaults.object(forKey: LanguageMenuSettings.hiddenKey) == nil)
        #expect(settings.hiddenIdentifiers.isEmpty)
        let before = posts.count
        settings.showAll() // already default: silent
        #expect(posts.count == before)
    }

    @Test func plainTextCanNeverBeHidden() {
        let (defaults, clean) = isolated(); defer { clean() }
        let center = NotificationCenter()
        let posts = PostCounter(center: center)
        let settings = LanguageMenuSettings(defaults: defaults, center: center)
        settings.setVisible(false, for: "")
        #expect(posts.count == 0)
        #expect(defaults.object(forKey: LanguageMenuSettings.hiddenKey) == nil)
        // Even if storage claims otherwise.
        defaults.set([""], forKey: LanguageMenuSettings.hiddenKey)
        #expect(settings.isVisible(""))
        #expect(settings.visibleLanguages.first?.identifier == "")
        #expect(!LanguageMenuSettings.hideableIdentifiers.contains(""))
    }

    @Test func unknownStoredIdentifiersAreIgnored() {
        let (defaults, clean) = isolated(); defer { clean() }
        let settings = LanguageMenuSettings(defaults: defaults, center: NotificationCenter())
        defaults.set(["cobol", "python", "", "python", 42] as [Any], forKey: LanguageMenuSettings.hiddenKey)
        #expect(settings.hiddenIdentifiers == ["python"])
        #expect(settings.visibleLanguages.count == SupportedLanguage.all.count - 1)
        // Hiding an unknown language is ignored too.
        settings.setVisible(false, for: "cobol")
        #expect(settings.hiddenIdentifiers == ["python"])
        // A value of the wrong type means "nothing hidden".
        defaults.set("python", forKey: LanguageMenuSettings.hiddenKey)
        #expect(settings.hiddenIdentifiers.isEmpty)
    }

    // MARK: - Shared item-list builder (toolbar popup + main menu)

    @Test func layoutListsOnlyVisibleLanguagesAndKeepsHiddenCurrent() {
        let hidden: Set<String> = ["python", "go"]
        let auto = LanguageMenuSettings.layout(hidden: hidden, current: nil)
        #expect(auto.languages.map(\.identifier)
            == SupportedLanguage.all.map(\.identifier).filter { !hidden.contains($0) })
        #expect(auto.languages.first == LanguageMenuEntry(title: "Plain Text", identifier: ""))
        #expect(auto.extra == nil)

        let manualHidden = LanguageMenuSettings.layout(hidden: hidden, current: "python")
        #expect(manualHidden.languages == auto.languages)
        #expect(manualHidden.extra == LanguageMenuEntry(title: "Python", identifier: "python"))

        // Visible, Plain Text or unsupported current languages need no extra row.
        for current in ["json", "", "cobol"] {
            #expect(LanguageMenuSettings.layout(hidden: hidden, current: current).extra == nil)
        }
        #expect(LanguageMenuLayout.unfiltered.languages.count == SupportedLanguage.all.count)
    }

    @Test func populatedMenuMatchesLayoutAndShowsHiddenCurrentAfterSeparator() {
        let layout = LanguageMenuSettings.layout(hidden: ["python", "rust"], current: "rust")
        let menu = NSMenu()
        layout.populate(menu, autoTitle: "Auto", autoAction: nil, autoTag: -1, languageAction: nil)
        let items = menu.items
        #expect(items.first?.tag == -1 && items.first?.representedObject == nil)
        #expect(items[1].isSeparatorItem)
        let languageIDs = items.compactMap { $0.representedObject as? String }
        #expect(languageIDs.first == "")
        #expect(!languageIDs.contains("python"))
        #expect(languageIDs.last == "rust")
        #expect(languageIDs.filter { $0 == "rust" }.count == 1)
        #expect(items[items.count - 2].isSeparatorItem)
        #expect(items.last?.title == "Rust")
        #expect(LanguageMenuLayout.signature(of: menu) == layout.signature)
        // A different layout is detected, so the UI rebuilds only when needed.
        #expect(LanguageMenuLayout.signature(of: menu)
            != LanguageMenuSettings.layout(hidden: ["python", "rust"], current: nil).signature)
    }

    @Test func mainMenuLanguageItemsFollowSettingsAndCatalogKeepsEveryLanguage() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let settings = LanguageMenuSettings(defaults: defaults, center: NotificationCenter())
        settings.setVisible(false, for: "sql")
        let menu = NSMenu()
        LanguageMenuController.populate(menu, layout: LanguageMenuController.currentLayout(settings: settings))
        #expect(menu.items.first?.action == #selector(EditorWindowController.selectAutoLanguage(_:)))
        let languageItems = menu.items.filter { $0.action == #selector(EditorWindowController.selectLanguage(_:)) }
        #expect(!languageItems.contains { ($0.representedObject as? String) == "sql" })
        #expect(languageItems.contains { ($0.representedObject as? String) == "" })

        // The shortcut catalog is built from an unfiltered menu.
        let catalog = MainMenu.build(applyShortcuts: false, includeHiddenLanguages: true)
        let languageMenu = try #require(catalog.items.compactMap(\.submenu).first {
            $0.items.contains { $0.action == #selector(EditorWindowController.selectLanguage(_:)) }
        })
        #expect(languageMenu.items.compactMap { $0.representedObject as? String }
            == SupportedLanguage.all.map(\.identifier))
        #expect(languageMenu.delegate == nil)
    }

    // MARK: - Settings archive

    @Test func archiveRoundTripCarriesHiddenLanguages() throws {
        let (source, cleanSource) = isolated(); defer { cleanSource() }
        let (target, cleanTarget) = isolated(); defer { cleanTarget() }
        LanguageMenuSettings(defaults: source, center: NotificationCenter()).setVisible(false, for: "python")
        LanguageMenuSettings(defaults: source, center: NotificationCenter()).setVisible(false, for: "toml")
        let model = ShortcutSettings(defaults: source)
        let data = try SettingsArchive.export(defaults: source, commands: model.commands)
        #expect(String(decoding: data, as: UTF8.self).contains(LanguageMenuSettings.hiddenKey))

        let targetModel = ShortcutSettings(defaults: target)
        let document = try SettingsArchive.decode(data, commands: targetModel.commands)
        #expect(document.preferences[LanguageMenuSettings.hiddenKey] == .array([.string("python"), .string("toml")]))
        try SettingsArchive.apply(document, defaults: target, shortcuts: targetModel)
        #expect(LanguageMenuSettings(defaults: target).hiddenIdentifiers == ["python", "toml"])
        #expect(try SettingsArchive.export(defaults: target, commands: targetModel.commands) == data)
    }

    @Test func importRejectsMalformedHiddenListWithoutPartialWrites() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let model = ShortcutSettings(defaults: defaults)
        defaults.set(20, forKey: EditorFontSettings.fontSizeKey)
        defaults.set(["go"], forKey: LanguageMenuSettings.hiddenKey)
        let key = LanguageMenuSettings.hiddenKey
        let invalid: [[String: SettingsArchive.Value]] = [
            [EditorFontSettings.fontSizeKey: .number(15), key: .array([.string("python"), .number(1)])],
            [EditorFontSettings.fontSizeKey: .number(15), key: .array([.bool(true)])],
            [EditorFontSettings.fontSizeKey: .number(15), key: .array([.array([.string("python")])])],
            [EditorFontSettings.fontSizeKey: .number(15), key: .string("python")],
            [EditorFontSettings.fontSizeKey: .array([.string("python")])],
        ]
        for values in invalid {
            let before = defaults.dictionaryRepresentation()
            var rejectedKey: String?
            do {
                try SettingsArchive.apply(.init(preferences: values, shortcuts: [:]), defaults: defaults, shortcuts: model)
            } catch SettingsArchive.Failure.value(let failing) {
                rejectedKey = failing
            } catch {
                Issue.record("unexpected error \(error)")
            }
            #expect(rejectedKey != nil)
            #expect(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()))
        }
        // The same element type error from a real file surfaces as `.value(key)`.
        let json = """
        {"format":"dev.enkin.TinyEditor.settings","version":1,"shortcuts":{},
         "preferences":{"\(key)":["python",3]}}
        """
        do {
            _ = try SettingsArchive.decode(Data(json.utf8), commands: model.commands)
            Issue.record("non-string element accepted")
        } catch SettingsArchive.Failure.value(let failing) {
            #expect(failing == key)
        }
        #expect(defaults.stringArray(forKey: key) == ["go"])
        #expect(defaults.integer(forKey: EditorFontSettings.fontSizeKey) == 20)
    }

    @Test func importDropsUnknownIdentifiersAndMissingKeyRestoresAllVisible() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let model = ShortcutSettings(defaults: defaults)
        let key = LanguageMenuSettings.hiddenKey
        let values: [String: SettingsArchive.Value] = [
            key: .array([.string("cobol"), .string(""), .string("css"), .string("css")]),
        ]
        try SettingsArchive.apply(.init(preferences: values, shortcuts: [:]), defaults: defaults, shortcuts: model)
        #expect(defaults.stringArray(forKey: key) == ["css"])

        // Only unknown / Plain Text entries: nothing is stored at all.
        try SettingsArchive.apply(.init(preferences: [key: .array([.string(""), .string("cobol")])], shortcuts: [:]),
                                  defaults: defaults, shortcuts: model)
        #expect(defaults.object(forKey: key) == nil)

        // Older archives without the key restore the default (all visible).
        defaults.set(["css", "go"], forKey: key)
        try SettingsArchive.apply(.init(preferences: [:], shortcuts: [:]), defaults: defaults, shortcuts: model)
        #expect(defaults.object(forKey: key) == nil)
        #expect(LanguageMenuSettings(defaults: defaults).hiddenIdentifiers.isEmpty)
    }

    /// Bug report (2026-11-12): the Preferences indent-width popup kept
    /// listing every language after some were unchecked.
    @MainActor @Test func indentWidthPopupFollowsLanguageList() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let settings = LanguageMenuSettings(defaults: defaults, center: NotificationCenter())
        let all = PreferencesWindowController.indentLanguages(settings: settings).map(\.id)
        #expect(all.contains("java") && all.contains("cpp") && all.contains("markdown"))
        for id in ["java", "cpp", "c", "typescript"] { settings.setVisible(false, for: id) }
        let filtered = PreferencesWindowController.indentLanguages(settings: settings).map(\.id)
        #expect(!filtered.contains("java") && !filtered.contains("cpp") && !filtered.contains("c")
                && !filtered.contains("typescript"))
        #expect(filtered.contains("markdown") && filtered.contains("python"))
        #expect(filtered.count == all.count - 4)
        // Hiding everything offered there falls back to the full list.
        for id in all { settings.setVisible(false, for: id) }
        #expect(PreferencesWindowController.indentLanguages(settings: settings).map(\.id) == all)
    }
}
