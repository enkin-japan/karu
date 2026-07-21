import Foundation
import Testing
@testable import KaruCore

// MARK: - Table completeness (guards against a missing translation)

@Test func everyKeyIsTranslatedInAllThreeLanguages() {
    for language in AppLanguage.allCases {
        let table = L10n.table(for: language)
        for key in L10nKey.allCases {
            #expect(table[key] != nil,
                    "missing \(key) in \(language.rawValue) table")
        }
    }
}

@Test func noTableCarriesStrayKeys() {
    // Each table holds exactly the declared keys — no leftovers.
    let allKeys = Set(L10nKey.allCases)
    for language in AppLanguage.allCases {
        #expect(Set(L10n.table(for: language).keys) == allKeys,
                "\(language.rawValue) table key set diverges")
    }
}

@Test func translationsAreDistinctPerLanguageForSampleKeys() {
    // Spot-check that the three tables actually differ (not a copy/paste of en).
    #expect(L10n.string(.menuFind, language: .en) == "Find")
    #expect(L10n.string(.menuFind, language: .zhHans) == "查找")
    #expect(L10n.string(.menuFind, language: .ja) == "検索")
}

// MARK: - System-language mapping / fallback

@Test func chineseCodesMapToSimplifiedChinese() {
    #expect(L10n.mappedLanguage(fromPreferred: ["zh-Hans-CN"]) == .zhHans)
    #expect(L10n.mappedLanguage(fromPreferred: ["zh-Hant-TW"]) == .zhHans)
    #expect(L10n.mappedLanguage(fromPreferred: ["ZH"]) == .zhHans)
}

@Test func japaneseCodesMapToJapanese() {
    #expect(L10n.mappedLanguage(fromPreferred: ["ja-JP"]) == .ja)
    #expect(L10n.mappedLanguage(fromPreferred: ["ja"]) == .ja)
}

@Test func unrecognizedOrEmptyFallsBackToEnglish() {
    #expect(L10n.mappedLanguage(fromPreferred: ["fr-FR"]) == .en)
    #expect(L10n.mappedLanguage(fromPreferred: ["de", "ja"]) == .en) // only the first code counts
    #expect(L10n.mappedLanguage(fromPreferred: []) == .en)
}

// MARK: - Parameter formatting

@Test func formatSubstitutesIntegerArguments() {
    #expect(L10n.string(.statusLnCol, language: .en, 4, 9) == "Ln 4, Col 9")
    #expect(L10n.string(.findMatchPosition, language: .en, 3, 17, 42) == "3/17 · L42")
}

@Test func formatSubstitutesStringArguments() {
    #expect(L10n.string(.formatErrorLine, language: .en, 7, "unexpected token") ==
            "Line 7: unexpected token")
    #expect(L10n.string(.closeConfirmMessage, language: .en, "notes.txt") ==
            "Do you want to save the changes made to notes.txt?")
}

@Test func appNameIsInterpolatedIntoAppMenuTitles() {
    #expect(L10n.string(.appQuit, language: .en, L10n.appName) == "Quit Karu")
    #expect(L10n.string(.appQuit, language: .ja, L10n.appName) == "Karu を終了")
}

@Test func lookupWithoutArgumentsReturnsRawTemplate() {
    // No args: the "%d"-carrying template comes back verbatim (no formatting).
    #expect(L10n.string(.findFoundCount, language: .en) == "%d found")
}

// MARK: - Stored override round-trip (serialized: touches global UserDefaults)

@Suite(.serialized)
struct L10nOverrideTests {
    private func restore(_ previous: String?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    @Test func setPersistsAndClearsTheOverride() {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { restore(previous) }

        L10n.set(.ja)
        #expect(L10n.current == .ja)
        #expect(UserDefaults.standard.string(forKey: L10n.defaultsKey) == "ja")

        L10n.set(.zhHans)
        #expect(L10n.current == .zhHans)

        // Clearing (System) drops back to the mapped system default.
        L10n.set(nil)
        #expect(UserDefaults.standard.string(forKey: L10n.defaultsKey) == nil)
        #expect(L10n.current == L10n.systemDefault)
    }

    @Test func setBroadcastsChangeNotification() async {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { restore(previous) }

        await confirmation("L10n change posted") { confirmed in
            let token = NotificationCenter.default.addObserver(
                forName: L10n.didChangeNotification, object: nil, queue: nil
            ) { _ in confirmed() }
            defer { NotificationCenter.default.removeObserver(token) }
            L10n.set(.en)
        }
    }
}
