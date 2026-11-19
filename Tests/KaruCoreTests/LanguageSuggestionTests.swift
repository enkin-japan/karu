import AppKit
import Testing
@testable import KaruCore

/// The language-suggestion band and the language menus' suggestion section:
/// when detection has candidates but no confident answer, they are offered
/// above the editor and at the top of the toolbar's language popup. Rankings
/// come from a stub injected through `languageRanker`.
@Suite("Language suggestions")
@MainActor
struct LanguageSuggestionTests {
    /// Counts ranking calls and answers with whatever ranking is set.
    private final class StubRanker {
        var ranking: LanguageRanking
        var calls = 0
        init(_ ranking: LanguageRanking) { self.ranking = ranking }
    }

    private static func candidates(_ ids: String...) -> LanguageRanking {
        LanguageRanking(confident: nil,
                        candidates: ids.enumerated().map { LanguageGuess(identifier: $1, score: Double(10 - $0)) })
    }

    private static func confident(_ id: String) -> LanguageRanking {
        LanguageRanking(confident: id, candidates: [LanguageGuess(identifier: id, score: 1)])
    }

    /// Enough text to pass the minimum-content gate (three lines).
    private static let codeish = "first line\nsecond line\nthird line\n"
    /// A single insertion long enough (40+) to be ranked at once.
    private static let longInsertion = String(repeating: "word ", count: 10) + "\n"

    @MainActor
    private final class Fixture {
        let directory: URL
        let controller: EditorWindowController
        let stub: StubRanker
        private let suite = "LanguageSuggestionTests-\(UUID().uuidString)"

        init(_ ranking: LanguageRanking = .none) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaruSuggest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            controller = EditorWindowController()
            controller.sessionStore = SessionStore(defaults: TestDefaults.make(suite))
            controller.draftStore = DraftStore(directory: directory.appendingPathComponent("drafts", isDirectory: true))
            let stub = StubRanker(ranking)
            self.stub = stub
            controller.languageRanker = { _ in
                stub.calls += 1
                return stub.ranking
            }
        }

        var banner: LanguageSuggestionBanner { controller.languageSuggestionBanner }

        var textView: EditorTextView {
            func find(_ view: NSView) -> EditorTextView? {
                (view as? EditorTextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return controller.window!.contentView.flatMap(find)!
        }

        /// Inserts `text` at the end in one edit, as typing / a drop does.
        func type(_ text: String) {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.insertText(text, replacementRange: NSRange(location: end, length: 0))
        }

        /// Puts enough content in the buffer to be ranked, at once.
        func fillAndRank() { type(LanguageSuggestionTests.codeish + LanguageSuggestionTests.longInsertion) }

        func file(_ name: String, _ content: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        var buttonTitles: [String] { banner.candidateButtons.map(\.title) }

        /// The toolbar popup's suggestion section: identifiers of the items
        /// between the header and the separator closing it, or nil without one.
        var menuSuggestions: [String]? {
            guard let items = controller.toolbarLanguageMenu?.items,
                  let header = items.firstIndex(where: { $0.tag == LanguageMenuLayout.suggestionHeaderTag })
            else { return nil }
            return items[(header + 1)...].prefix { !$0.isSeparatorItem }
                .compactMap { $0.representedObject as? String }
        }

        func cleanup() {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    // MARK: - What a ranking does

    @Test func candidatesWithoutConfidentShowTheBandInOrderAndKeepPlainText() throws {
        let f = try Fixture(Self.candidates("python", "swift", "go"))
        defer { f.cleanup() }
        #expect(!f.banner.isShowing)
        // Right after the save-failure band in the content stack.
        let stack = try #require(f.banner.superview as? NSStackView)
        #expect(stack.arrangedSubviews.firstIndex(of: f.banner) == 1)
        #expect(stack.arrangedSubviews.first === f.controller.saveFailureBanner)

        f.fillAndRank()
        #expect(f.stub.calls == 1)
        #expect(f.banner.isShowing)
        #expect(f.banner.candidates.map(\.identifier) == ["python", "swift", "go"])
        #expect(f.buttonTitles == ["Python", "Swift", "Go"])
        #expect(f.controller.currentLanguageIdentifierValue == "")
        #expect(f.controller.documentAnalysis.languageIdentifier == "")
        #expect(f.controller.isLanguageAuto)

        // A changed candidate list updates the buttons in place.
        f.stub.ranking = Self.candidates("rust", "python")
        f.type(Self.longInsertion)
        #expect(f.banner.isShowing)
        #expect(f.buttonTitles == ["Rust", "Python"])
    }

    @Test func confidentRankingAppliesTheLanguageAndHidesTheBand() throws {
        let f = try Fixture(Self.candidates("python", "ruby"))
        defer { f.cleanup() }
        f.fillAndRank()
        #expect(f.banner.isShowing)

        f.stub.ranking = Self.confident("python")
        f.type(Self.longInsertion)
        #expect(f.controller.currentLanguageIdentifierValue == "python")
        #expect(!f.banner.isShowing)
        #expect(f.controller.isLanguageAuto)
        // Classified: later edits rank no more.
        let calls = f.stub.calls
        f.type(Self.longInsertion)
        #expect(f.stub.calls == calls)
    }

    @Test func emptyCandidatesHideTheBand() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.fillAndRank()
        #expect(f.banner.isShowing)
        f.stub.ranking = .none
        f.type(Self.longInsertion)
        #expect(!f.banner.isShowing)
        #expect(f.menuSuggestions == nil)
    }

    // MARK: - Choosing, dismissing, overriding

    @Test func choosingACandidateAppliesItAsAManualChoice() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.fillAndRank()
        f.banner.candidateButtons[1].performClick(nil)
        #expect(f.controller.currentLanguageIdentifierValue == "swift")
        #expect(f.controller.documentAnalysis.languageIdentifier == "swift")
        #expect(!f.controller.isLanguageAuto)
        #expect(!f.banner.isShowing)
        #expect(f.menuSuggestions == nil)
    }

    @Test func otherMenuListsThePopupLanguagesWithoutAutoAndChoosesManually() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.fillAndRank()
        let menu = f.banner.makeOtherMenu(settings: LanguageMenuSettings(
            defaults: TestDefaults.make("LanguageSuggestionTests-other-\(UUID().uuidString)"),
            center: NotificationCenter()))
        #expect(menu.items.compactMap { $0.representedObject as? String } == SupportedLanguage.all.map(\.identifier))
        let rust = try #require(menu.items.first { ($0.representedObject as? String) == "rust" })
        menu.performActionForItem(at: menu.index(of: rust))
        #expect(f.controller.currentLanguageIdentifierValue == "rust")
        #expect(!f.controller.isLanguageAuto)
        #expect(!f.banner.isShowing)
    }

    @Test func dismissStaysUntilAutoIsPicked() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.fillAndRank()
        f.banner.closeButton.performClick(nil)
        #expect(!f.banner.isShowing)
        #expect(f.controller.languageSuggestionDismissed)

        // Later edits rank again but do not bring it back.
        let calls = f.stub.calls
        f.type(Self.longInsertion)
        #expect(f.stub.calls == calls + 1)
        #expect(!f.banner.isShowing)
        // The toolbar menu keeps offering the candidates.
        #expect(f.menuSuggestions == ["python", "swift"])

        f.controller.chooseAutoLanguage()
        #expect(!f.controller.languageSuggestionDismissed)
        #expect(f.banner.isShowing)
    }

    @Test func loadingAnotherDocumentClearsTheDismissal() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("one", Self.codeish))
        #expect(f.banner.isShowing)
        f.banner.closeButton.performClick(nil)
        #expect(!f.banner.isShowing)

        f.controller.load(url: try f.file("two", Self.codeish))
        #expect(!f.controller.languageSuggestionDismissed)
        #expect(f.banner.isShowing)
    }

    // A file with an extension is decided by the extension alone (user
    // decision 2026-11-17): no content detection, no band, no menu section.

    @Test func aFileWithAnUnregisteredExtensionIsNeitherRankedNorOffered() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("notes.txt", Self.codeish))
        #expect(f.stub.calls == 0)
        #expect(!f.banner.isShowing)
        #expect(f.menuSuggestions == nil)
        #expect(f.controller.documentAnalysis.languageIdentifier.isEmpty)

        // Typing in it does not start detection either.
        f.type(Self.longInsertion)
        #expect(f.stub.calls == 0)
        #expect(!f.controller.hasPendingLanguageRanking)
        #expect(!f.banner.isShowing)
    }

    @Test func aConfidentRankingDoesNotOverrideAnUnregisteredExtension() throws {
        let f = try Fixture(Self.confident("python"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("script.conf", Self.codeish))
        #expect(f.stub.calls == 0)
        #expect(f.controller.documentAnalysis.languageIdentifier.isEmpty)

        // Picking Auto again re-reads the extension; it still does not guess.
        f.controller.chooseAutoLanguage()
        #expect(f.stub.calls == 0)
        #expect(f.controller.documentAnalysis.languageIdentifier.isEmpty)
        #expect(!f.banner.isShowing)
    }

    @Test func renamingToAnUnregisteredExtensionWithdrawsTheBand() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("notes", Self.codeish))
        #expect(f.banner.isShowing)
        f.controller.renameFile(to: "notes.txt")
        #expect(!f.banner.isShowing)
        #expect(f.menuSuggestions == nil)
    }

    @Test func manualOverrideStopsRankingAndTheBand() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.controller.chooseLanguage(identifier: "")   // Plain Text, by hand
        f.fillAndRank()
        f.type(Self.longInsertion)
        #expect(f.stub.calls == 0)
        #expect(!f.banner.isShowing)
        #expect(!f.controller.hasPendingLanguageRanking)
    }

    @Test func manualChoiceWhileTheBandShowsHidesIt() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.fillAndRank()
        #expect(f.banner.isShowing)
        f.controller.chooseLanguage(identifier: "")
        #expect(!f.banner.isShowing)
        #expect(f.menuSuggestions == nil)
    }

    @Test func loadingAFileWithAKnownExtensionShowsNoBand() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("main.go", "package main\n\nfunc main() {}\n"))
        #expect(f.stub.calls == 0)
        #expect(!f.banner.isShowing)
        #expect(f.controller.currentLanguageIdentifierValue == "go")
        #expect(f.menuSuggestions == nil)
    }

    @Test func loadingAFileWithoutAnExtensionRanksAtOnce() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("script", "x = 1\n"))
        #expect(f.stub.calls == 1)
        #expect(f.banner.isShowing)
        #expect(f.menuSuggestions == ["python", "swift"])

        // A confident ranking on load applies the language, as before.
        f.stub.ranking = Self.confident("python")
        f.controller.load(url: try f.file("other", "x = 1\n"))
        #expect(f.controller.currentLanguageIdentifierValue == "python")
        #expect(!f.banner.isShowing)
    }

    @Test func recoveredUntitledDraftRanksAtOnce() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.controller.applyRecoveredDraft(id: UUID(), content: Self.codeish)
        #expect(f.stub.calls == 1)
        #expect(f.banner.isShowing)
    }

    @Test func saveAsToAKnownExtensionHidesTheBand() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.controller.load(url: try f.file("notes", Self.codeish))
        #expect(f.banner.isShowing)
        f.controller.renameFile(to: "notes.py")
        #expect(f.controller.currentLanguageIdentifierValue == "python")
        #expect(!f.banner.isShowing)
    }

    // MARK: - When ranking runs

    @Test func typingIsDebouncedWhileALargeInsertionRanksAtOnce() async throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.type("ab\ncd\n")
        for character in "efgh\nij" { f.type(String(character)) }
        // No ranking per keystroke: one pending, none run.
        #expect(f.stub.calls == 0)
        #expect(f.controller.hasPendingLanguageRanking)

        let deadline = Date().addingTimeInterval(60)
        while f.stub.calls == 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(f.stub.calls == 1)
        #expect(f.banner.isShowing)
        // Nothing else was queued behind it.
        #expect(!f.controller.hasPendingLanguageRanking)
        try? await Task.sleep(for: .milliseconds(700))
        #expect(f.stub.calls == 1)

        // A 40+ character insertion ranks immediately and drops the pending one.
        f.type("k")
        #expect(f.controller.hasPendingLanguageRanking)
        f.type(Self.longInsertion)
        #expect(f.stub.calls == 2)
        #expect(!f.controller.hasPendingLanguageRanking)
    }

    @Test func closingTheWindowCancelsAPendingRanking() throws {
        let f = try Fixture(Self.candidates("python"))
        defer { f.cleanup() }
        f.type(Self.codeish)
        f.type("x")
        #expect(f.controller.hasPendingLanguageRanking)
        f.controller.close()
        #expect(!f.controller.hasPendingLanguageRanking)
    }

    // MARK: - Toolbar language popup

    @Test func toolbarMenuSectionFollowsTheRanking() throws {
        let f = try Fixture(.none)
        defer { f.cleanup() }
        f.fillAndRank()
        #expect(f.menuSuggestions == nil)

        f.stub.ranking = Self.candidates("python", "swift")
        f.type(Self.longInsertion)
        #expect(f.menuSuggestions == ["python", "swift"])
        let items = try #require(f.controller.toolbarLanguageMenu?.items)
        // Auto, separator, header (disabled), candidates, separator, full list.
        #expect(items[0].tag == -1)
        #expect(items[1].isSeparatorItem)
        #expect(items[2].tag == LanguageMenuLayout.suggestionHeaderTag)
        #expect(items[2].title == L10n.t(.languageSuggestionLabel))
        #expect(!items[2].isEnabled)
        #expect(items[5].isSeparatorItem)
        #expect((items[6].representedObject as? String) == "")
        // The candidates stay in the normal list too.
        #expect(items[6...].contains { ($0.representedObject as? String) == "python" })

        // Choosing a suggestion from the popup is a manual choice.
        let popupItem = items[3]
        #expect((popupItem.representedObject as? String) == "python")
        f.banner.closeButton.performClick(nil)
        #expect(f.menuSuggestions == ["python", "swift"])   // still there after dismissal

        f.controller.chooseLanguage(identifier: "python")
        #expect(f.menuSuggestions == nil)                   // gone once a language is applied
    }

    @Test func mainMenuLayoutCarriesTheSuggestionSection() {
        let layout = LanguageMenuSettings.layout(hidden: [], current: nil)
        var withSuggestions = layout
        withSuggestions.suggestions = LanguageMenuSettings.suggestionEntries(["python", "cobol", "", "python", "go"])
        #expect(withSuggestions.suggestions.map(\.identifier) == ["python", "go"])
        let menu = NSMenu()
        LanguageMenuController.populate(menu, layout: withSuggestions)
        let suggested = menu.items.filter { $0.action == #selector(EditorWindowController.selectSuggestedLanguage(_:)) }
        #expect(suggested.compactMap { $0.representedObject as? String } == ["python", "go"])
        let header = L10n.t(.languageSuggestionLabel)
        #expect(LanguageMenuLayout.signature(of: menu) == withSuggestions.signature(suggestionHeader: header))
        #expect(LanguageMenuLayout.signature(of: menu) != layout.signature(suggestionHeader: header))
    }

    // MARK: - Focus and width

    @Test func theBandNeverTakesKeyboardFocus() throws {
        let f = try Fixture(Self.candidates("python", "swift"))
        defer { f.cleanup() }
        let window = try #require(f.controller.window)
        window.makeFirstResponder(f.textView)
        f.fillAndRank()
        #expect(f.banner.isShowing)
        #expect(window.firstResponder === f.textView)
        for button in f.banner.candidateButtons + [f.banner.otherButton, f.banner.closeButton] {
            #expect(button.refusesFirstResponder)
            #expect(!button.acceptsFirstResponder)
        }
        f.banner.closeButton.performClick(nil)
        #expect(window.firstResponder === f.textView)
        f.controller.chooseAutoLanguage()
        f.banner.candidateButtons[0].performClick(nil)
        #expect(window.firstResponder === f.textView)
    }

    @Test func narrowWidthDropsTrailingCandidatesFirst() throws {
        let banner = LanguageSuggestionBanner()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 30))
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
        ])
        banner.show(candidates: LanguageMenuSettings.suggestionEntries(["typescriptreact", "javascript", "python"]))
        container.layoutSubtreeIfNeeded()
        #expect(banner.visibleCandidateIdentifiers == ["typescriptreact", "javascript", "python"])

        // Room for roughly the fixed part and one candidate.
        let fixed = banner.fittingSize.width
            - banner.candidateButtons.reduce(0) { $0 + $1.fittingSize.width + 8 }
        let first = banner.candidateButtons[0].fittingSize.width + 8
        container.setFrameSize(NSSize(width: fixed + first + 20, height: 30))
        container.layoutSubtreeIfNeeded()
        #expect(banner.visibleCandidateIdentifiers == ["typescriptreact"])
        #expect(!banner.otherButton.isHidden && !banner.closeButton.isHidden)
        #expect(banner.closeButton.frame.maxX <= banner.bounds.width)
        #expect(banner.otherButton.convert(banner.otherButton.bounds, to: banner).maxX
                <= banner.closeButton.frame.minX)

        // Too narrow for any candidate: label, Other… and close remain.
        container.setFrameSize(NSSize(width: fixed + 4, height: 30))
        container.layoutSubtreeIfNeeded()
        #expect(banner.visibleCandidateIdentifiers.isEmpty)
        #expect(!banner.otherButton.isHidden && !banner.closeButton.isHidden)

        // Widening brings them back.
        container.setFrameSize(NSSize(width: 900, height: 30))
        container.layoutSubtreeIfNeeded()
        #expect(banner.visibleCandidateIdentifiers.count == 3)
    }

    @Test func visibleCandidateCountKeepsTheLeadingOnes() {
        let count = LanguageSuggestionBanner.visibleCandidateCount
        #expect(count(300, 200, [40, 40, 40], 8) == 2)
        #expect(count(200, 200, [40], 8) == 0)
        #expect(count(1000, 200, [40, 40, 40], 8) == 3)
    }

    @Test func stringsFollowTheUILanguage() {
        for language in AppLanguage.allCases {
            for key in [L10nKey.languageSuggestionLabel, .languageSuggestionOther,
                        .languageSuggestionDismiss, .languageSuggestionAccessibility] {
                #expect(!L10n.string(key, language: language).isEmpty)
            }
        }
        #expect(L10n.string(.languageSuggestionLabel, language: .zhHans) == "可能是")
        let banner = LanguageSuggestionBanner()
        #expect(banner.closeButton.toolTip == L10n.t(.languageSuggestionDismiss))
        #expect(banner.otherButton.title == L10n.t(.languageSuggestionOther))
    }
}
