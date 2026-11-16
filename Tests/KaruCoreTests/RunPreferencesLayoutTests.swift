import AppKit
import Foundation
import Testing
@testable import KaruCore

// Settings › Run as "language list + detail": which languages are listed and
// selected, pane swapping, the verdict / managed section of each pane, the
// list's state symbols, and a page size that does not depend on asynchronous
// results. Private defaults, notification centers and toolchain stores only;
// the locator never spawns a login shell.

private func name(_ language: RunnableLanguage) -> String {
    RunMessages.languageName(language.identifier) + " · "
}

@MainActor
private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

/// A Run page over isolated settings, language list and toolchain store.
@MainActor
private final class RunPageFixture {
    let suite = "RunPreferencesLayoutTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let settings: RunSettings
    let languageMenu: LanguageMenuSettings
    let manager: ToolchainManager
    let page: RunPreferencesController

    init(manager: ToolchainManager? = nil, developerTools: Bool = true,
         isExecutable: @escaping @Sendable (String) -> Bool = { _ in false }) {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunPreferencesLayoutTests-\(UUID().uuidString)", isDirectory: true)
        let center = NotificationCenter()
        settings = RunSettings(defaults: defaults, center: center)
        languageMenu = LanguageMenuSettings(defaults: defaults, center: NotificationCenter())
        languageMenu.showAll()
        let manager = manager ?? ToolchainManager(store: ToolchainStore(root: root))
        self.manager = manager
        let probes = ToolchainProbes(isExecutable: isExecutable,
                                     developerToolsInstalled: { developerTools }, javaRuntimeInstalled: { true })
        let loginPath = LoginShellPath(shell: "/bin/zsh", timeout: 1, runner: { _, _, _ in nil })
        page = RunPreferencesController(
            settings: settings, center: center,
            makeLocator: { ToolchainLocator(managed: NoManagedToolchains(), loginPath: loginPath, probes: probes) },
            manager: manager, probes: probes, languageMenu: languageMenu, installCommandLineTools: {},
            modules: ModuleSettings(defaults: defaults, center: NotificationCenter()))
    }

    func cleanup() {
        page.pageWillDeactivate()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func waitForDetection(_ language: RunnableLanguage) async -> Bool {
        await waitFor {
            if case .detecting? = page.detections[language] { return false }
            return page.detections[language] != nil
        }
    }

    /// Sizes the page to its fitting size and lays it out.
    func layOut() {
        let view = page.view
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
    }
}

@Suite("RunPreferences list and detail")
@MainActor
struct RunPreferencesLayoutTests {
    /// Toolchain work runs on a utility queue that a full parallel test run
    /// can starve for well over the usual 10 s.
    static let workTimeout: TimeInterval = 30

    @Test func listShowsTheVisibleLanguagesAndKeepsOrMovesTheSelection() {
        let fixture = RunPageFixture()
        defer { fixture.cleanup() }
        let page = fixture.page
        #expect(page.listedLanguages == RunnableLanguage.allCases)
        #expect(page.listedLanguages.count == 11)
        #expect(page.selectedLanguage == .python)

        fixture.languageMenu.setVisible(false, for: "typescript")
        fixture.languageMenu.setVisible(false, for: "cpp")
        page.applyLanguageVisibility()
        #expect(page.listedLanguages == RunnableLanguage.allCases.filter { $0 != .typescript && $0 != .cpp })
        #expect(!page.isRowVisible(.typescript) && page.isRowVisible(.go))

        // A still-listed selection is kept.
        page.select(.go)
        #expect(page.selectedLanguage == .go)
        fixture.languageMenu.setVisible(true, for: "cpp")
        page.applyLanguageVisibility()
        #expect(page.listedLanguages.contains(.cpp))
        #expect(page.selectedLanguage == .go)

        // Hiding the selected language selects the first listed one.
        fixture.languageMenu.setVisible(false, for: "go")
        page.applyLanguageVisibility()
        #expect(page.selectedLanguage == .python)
        fixture.languageMenu.setVisible(false, for: "python")
        page.applyLanguageVisibility()
        #expect(page.listedLanguages.first == .javascript)
        #expect(page.selectedLanguage == .javascript)

        // Selecting an unlisted language does nothing.
        page.select(.go)
        #expect(page.selectedLanguage == .javascript)

        fixture.languageMenu.showAll()
        page.applyLanguageVisibility()
        #expect(page.listedLanguages == RunnableLanguage.allCases)
        #expect(page.selectedLanguage == .javascript)
    }

    @Test func selectingSwapsThePaneAndUnselectedControlsStillAct() throws {
        let fixture = RunPageFixture()
        defer { fixture.cleanup() }
        let page = fixture.page
        for language in RunnableLanguage.allCases {
            page.select(language)
            let pane = try #require(page.panes[language])
            #expect(page.detailContainer.subviews.count == 1)
            #expect(page.detailContainer.subviews.first === pane)
            for row in page.rows {
                #expect(row.nameLabel.isDescendant(of: page.detailContainer) == (row.language == language))
            }
        }
        // Selecting launches nothing.
        #expect(page.detections.isEmpty)

        page.select(.python)
        let go = try #require(page.row(for: .go))
        #expect(!go.nameLabel.isDescendant(of: page.detailContainer))
        go.sourcePopup.selectItem(at: ToolchainSource.allCases.firstIndex(of: .custom)!)
        _ = go.sourcePopup.target?.perform(go.sourcePopup.action, with: go.sourcePopup)
        #expect(fixture.settings.source(for: .go) == .custom)
        #expect(page.pathRows[.go]?.isHidden == false)
        go.pathField.stringValue = "/opt/go/bin/go"
        page.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: go.pathField))
        #expect(fixture.settings.customPath(for: .go) == "/opt/go/bin/go")
    }

    @Test func verdictCoversEveryDetectionState() async throws {
        let fixture = RunPageFixture(isExecutable: { $0 == "/opt/tools/python3" })
        defer { fixture.cleanup() }
        let page = fixture.page
        let python = try #require(page.row(for: .python))
        let symbol = try #require(page.verdictSymbols[.python])

        // Never detected.
        #expect(python.resultLabel.stringValue == L10n.t(.runNotDetected))
        #expect(symbol.isHidden)
        #expect(page.listStatusSymbol(for: .python) == nil)
        #expect(page.listStatusText(for: .bash) == name(.bash) + L10n.t(.runNotDetected))

        // Detecting (the result cannot arrive before this synchronous check).
        fixture.settings.setSource(.custom, for: .python)
        fixture.settings.setCustomPath("/opt/tools/python3", for: .python)
        page.detect(.python)
        #expect(python.resultLabel.stringValue == L10n.t(.runDetecting))
        #expect(symbol.isHidden)
        #expect(page.listStatusSymbol(for: .python) == RunPreferencesController.busySymbol)
        #expect(page.listStatusText(for: .python) == name(.python) + L10n.t(.runDetecting))

        // Resolved: command · origin.
        #expect(await fixture.waitForDetection(.python))
        #expect(python.resultLabel.stringValue == "/opt/tools/python3 · " + RunMessages.origin(.custom))
        #expect(python.resultLabel.textColor == .secondaryLabelColor)
        #expect(symbol.isHidden)
        #expect(page.listStatusSymbol(for: .python) == RunPreferencesController.resolvedSymbol)
        #expect(page.listStatusText(for: .python) == name(.python) + python.resultLabel.stringValue)

        // Failed: message, red, warning symbol.
        fixture.settings.setCustomPath("/nope/python3", for: .python)
        page.detect(.python)
        #expect(await fixture.waitForDetection(.python))
        #expect(python.resultLabel.stringValue == RunMessages.failure(.customToolInvalid("/nope/python3")))
        #expect(python.resultLabel.textColor == .systemRed)
        #expect(!symbol.isHidden && symbol.image != nil)
        #expect(page.listStatusSymbol(for: .python) == RunPreferencesController.failedSymbol)
        #expect(page.listStatusText(for: .python) == name(.python) + python.resultLabel.stringValue)
    }

    @Test func listShowsToolchainWorkAndStatusWhenNothingWasDetected() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        // Not gated: the installing state is set synchronously when the
        // install starts, and nothing blocks a worker thread meanwhile.
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: FixtureDownloader(source: fixture.archive, chunkSize: 256))
        let run = RunPageFixture(manager: manager)
        defer { run.cleanup() }
        let page = run.page
        let js = try #require(page.managedControls[.javascript])

        // Nothing detected: the toolchain status in words, no symbol.
        #expect(page.listStatusSymbol(for: .javascript) == nil)
        #expect(page.listStatusText(for: .javascript) == name(.javascript) + js.statusLabel.stringValue)

        // Installing: busy symbol and the progress in words.
        js.actionButton.performClick(nil)
        #expect(manager.state(for: "node").isInstalling)
        #expect(page.listStatusSymbol(for: .javascript) == RunPreferencesController.busySymbol)
        #expect(page.listStatusSymbol(for: .typescript) == RunPreferencesController.busySymbol)
        #expect(page.listStatusText(for: .typescript) == name(.typescript) + js.statusLabel.stringValue)
        #expect(page.listStatusSymbol(for: .python) == nil)
        // Once installed, the affected languages are detected again and the
        // list shows that outcome instead.
        #expect(await waitFor(timeout: Self.workTimeout) { manager.state(for: "node").activity == nil })
        #expect(await run.waitForDetection(.javascript))
        #expect(page.listStatusSymbol(for: .javascript) != RunPreferencesController.busySymbol)
        #expect(page.listStatusSymbol(for: .javascript) != nil)
    }

    @Test func managedSectionShowsSharedProviderCommandLineToolsAndNothingForBash() async throws {
        let fixture = RunPageFixture(developerTools: false)
        defer { fixture.cleanup() }
        let page = fixture.page
        #expect(await waitFor { page.commandLineToolsInstalled == false })

        // A shared toolchain names its provider on a visible line in both panes.
        for language in [RunnableLanguage.javascript, .typescript] {
            let controls = try #require(page.managedControls[language])
            let provided = try #require(controls.providedByLabel)
            #expect(provided.stringValue == L10n.t(.runToolchainProvidedBy, "Node.js"))
            #expect(!provided.isHidden)
            #expect(page.row(for: language)?.managedSlot.arrangedSubviews.contains(provided) == true)
            #expect(controls.statusLabel.stringValue.hasPrefix("Node.js · "))
        }
        for language in [RunnableLanguage.c, .cpp] {
            #expect(page.managedControls[language]?.providedByLabel?.stringValue
                    == L10n.t(.runToolchainProvidedBy, "Zig"))
        }
        #expect(page.managedControls[.python]?.providedByLabel == nil)
        #expect(page.managedControls[.go]?.providedByLabel == nil)

        // Swift / Rust: Command Line Tools state and install button; Rust's hint.
        for language in [RunnableLanguage.swift, .rust] {
            let controls = try #require(page.managedControls[language])
            #expect(controls.statusLabel.stringValue == L10n.t(.runCLTMissing))
            #expect(!controls.actionButton.isHidden && controls.actionButton.title == L10n.t(.runCLTInstall))
            #expect(!controls.buttonRow.isHidden)
        }
        let hint = try #require(page.managedControls[.rust]?.hintLabel)
        #expect(hint.stringValue == L10n.t(.runRustHint))
        #expect(page.row(for: .rust)?.managedSlot.arrangedSubviews.contains(hint) == true)

        // Bash: no managed section and no separator.
        #expect(page.managedControls[.bash] == nil)
        let bash = try #require(page.panes[.bash])
        #expect(!allViews(bash).contains { ($0 as? NSBox)?.boxType == .separator })
        #expect(page.row(for: .bash)?.managedSlot.superview == nil)
        let python = try #require(page.panes[.python])
        #expect(allViews(python).contains { ($0 as? NSBox)?.boxType == .separator })
    }

    @Test func customPathRowAndFlagsRowsFollowTheirConditions() throws {
        let fixture = RunPageFixture()
        defer { fixture.cleanup() }
        let page = fixture.page
        for row in page.rows {
            #expect(page.pathRows[row.language]?.isHidden == true)
        }
        for source in ToolchainSource.allCases {
            fixture.settings.setSource(source, for: .rust)
            page.reloadState()
            #expect(page.pathRows[.rust]?.isHidden == (source != .custom), "\(source)")
        }

        #expect(!page.cFlagsField.isHiddenOrHasHiddenAncestor && !page.cppFlagsField.isHiddenOrHasHiddenAncestor)
        fixture.languageMenu.setVisible(false, for: "cpp")
        page.applyLanguageVisibility()
        #expect(!page.cFlagsField.isHiddenOrHasHiddenAncestor)
        #expect(page.cppFlagsField.isHiddenOrHasHiddenAncestor && page.cppFlagsLabel.isHiddenOrHasHiddenAncestor)
        fixture.languageMenu.setVisible(false, for: "c")
        page.applyLanguageVisibility()
        #expect(page.cFlagsField.isHiddenOrHasHiddenAncestor && page.cppFlagsField.isHiddenOrHasHiddenAncestor)
        // Flags stay visible whatever language is selected.
        fixture.languageMenu.showAll()
        page.applyLanguageVisibility()
        page.select(.bash)
        #expect(!page.cFlagsField.isHiddenOrHasHiddenAncestor && !page.cppFlagsField.isHiddenOrHasHiddenAncestor)
    }

    @Test func pageSizeDoesNotDependOnSelectionOrAsynchronousContent() async throws {
        let fixture = try ToolchainFixture()
        defer { fixture.cleanup() }
        // Not gated: the installing state is set synchronously when the
        // install starts, and nothing blocks a worker thread meanwhile.
        let manager = ToolchainManager(store: fixture.store, manifest: [fixture.entry],
                                       downloader: FixtureDownloader(source: fixture.archive, chunkSize: 256))
        let run = RunPageFixture(manager: manager)
        defer { run.cleanup() }
        let page = run.page
        var reports = 0
        page.onContentSizeChange = { reports += 1 }
        let size = page.view.fittingSize
        #expect(size.width == RunPreferencesController.pageWidth)

        for language in RunnableLanguage.allCases {
            page.select(language)
            #expect(page.view.fittingSize == size, "\(language)")
        }
        run.settings.setSource(.custom, for: .go)
        run.settings.setCustomPath("/a/very/long/path/that/does/not/exist/anywhere/on/this/machine/go", for: .go)
        page.select(.go)
        for language in RunnableLanguage.allCases { page.detect(language) }
        #expect(page.view.fittingSize == size)
        for language in RunnableLanguage.allCases {
            #expect(await run.waitForDetection(language), "\(language)")
        }
        #expect(page.view.fittingSize == size)

        // Toolchain status: installing, then installed (with its disk usage).
        page.managedControls[.javascript]?.actionButton.performClick(nil)
        #expect(manager.state(for: "node").isInstalling)
        #expect(page.view.fittingSize == size)
        #expect(await waitFor(timeout: Self.workTimeout) {
            manager.state(for: "node").installedVersion != nil && manager.state(for: "node").diskUsage != nil
        })
        #expect(page.view.fittingSize == size)

        // The flags rows can change the size: the host is asked to refit.
        let before = reports
        run.languageMenu.setVisible(false, for: "cpp")
        page.applyLanguageVisibility()
        #expect(reports > before)
        #expect(page.view.fittingSize.width == RunPreferencesController.pageWidth)
    }
}

// MARK: - Languages (serialized: switches the UI language)

// Same pattern as `SettingsWindowLanguageTests`: the override is written and
// restored without broadcasting `L10n.didChangeNotification`, within one
// synchronous test.
@Suite("RunPreferences panes in every language", .serialized)
@MainActor
struct RunPreferencesLanguageTests {
    private func setQuietly(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    /// Labels in a pane stay inside the pane and wrap instead of truncating;
    /// every pane fits the fixed-height row. Worst cases: a long failed verdict
    /// with the custom path row shown, shared toolchains, CLT missing.
    @Test func panesWrapInsteadOfTruncatingInEveryLanguage() throws {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        let longPath = "/Users/someone/Library/Application Support/Some Very Long Tool Directory/bin/tool-with-a-long-name"
        for language in AppLanguage.allCases {
            setQuietly(language.rawValue)
            #expect(L10n.current == language)
            let run = RunPageFixture(developerTools: false)
            defer { run.cleanup() }
            let page = run.page
            for runnable in RunnableLanguage.allCases {
                run.settings.setSource(.custom, for: runnable)
            }
            page.reloadState()
            #expect(page.view.fittingSize.width == RunPreferencesController.pageWidth)
            let size = page.view.fittingSize
            for runnable in RunnableLanguage.allCases {
                page.select(runnable)
                #expect(page.view.fittingSize == size)
                run.layOut()
                let pane = try #require(page.panes[runnable])
                #expect(pane.fittingSize.height <= RunPreferencesController.middleHeight,
                        "\(language) \(runnable): \(pane.fittingSize.height)")
                // Long failure text (the CLT state is set synchronously below).
                let row = try #require(page.row(for: runnable))
                for text in [RunMessages.failure(.customToolInvalid(longPath)),
                             RunMessages.failure(.developerToolsMissing("swiftc")), L10n.t(.runNotDetected)] {
                    row.resultLabel.stringValue = text
                    page.view.needsLayout = true
                    run.layOut()
                    check(pane, in: page, "\(language) \(runnable)")
                    #expect(pane.fittingSize.height <= RunPreferencesController.middleHeight,
                            "\(language) \(runnable): \(pane.fittingSize.height)")
                }
            }
            // The page's own top-level content stays inside its insets.
            run.layOut()
            for view in page.view.subviews where !view.isHidden {
                #expect(view.frame.maxX <= page.view.bounds.maxX - RunPreferencesController.insets.right + 0.5)
            }
        }
    }

    private func check(_ pane: NSView, in page: RunPreferencesController, _ context: String) {
        let width = pane.bounds.width
        #expect(abs(width - RunPreferencesController.detailWidth) < 0.5, "\(context): \(width)")
        // Controls and the stacks / separators holding them; not the private
        // subviews AppKit puts inside a control.
        for view in allViews(pane) where !view.isHiddenOrHasHiddenAncestor && !(view.superview is NSControl) {
            guard let superview = view.superview, view !== pane else { continue }
            let frame = superview.convert(view.alignmentRect(forFrame: view.frame), to: pane)
            #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5,
                    "\(context) overflows: \((view as? NSTextField)?.stringValue ?? "\(type(of: view))")")
            guard let label = view as? NSTextField, !label.isEditable, !label.isBezeled,
                  let cell = label.cell else { continue }
            // The whole text fits the label's frame (no truncation).
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width,
                                                         height: .greatestFiniteMagnitude))
            #expect(needed.height <= label.bounds.height + 0.5 && needed.width <= label.bounds.width + 0.5,
                    "\(context) truncated: \(label.stringValue) \(needed) in \(label.bounds.size)")
        }
    }
}
