import AppKit
import Testing
import UniformTypeIdentifiers
@testable import KaruCore

// Settings window: one host with toolbar pages. These tests inspect structure
// only; nothing here clicks a control that writes to the real user settings.

/// Stand-in page (the real Run page needs a live `ToolchainManager`).
@MainActor
private final class StubPage: SettingsPage {
    let view = NSView()
    var onContentSizeChange: (() -> Void)?
    private(set) var deactivations = 0

    init(size: NSSize = NSSize(width: 500, height: 200)) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }

    func pageWillDeactivate() { deactivations += 1 }
}

@MainActor
private func stubRunFactory(_ id: SettingsPageID) -> SettingsPage {
    id == .run ? StubPage() : PreferencesWindowController.makeDefaultPage(id)
}

@MainActor
private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

@MainActor
private func controlIdentifiers(_ view: NSView) -> [String] {
    allViews(view).compactMap { $0.identifier?.rawValue }.filter { $0.hasPrefix("settings.") }
}

@MainActor
private func view(_ id: String, in root: NSView) -> NSView? {
    allViews(root).first { $0.identifier?.rawValue == id }
}

/// The four form pages, freshly built in the current language and laid out
/// at their fitting size.
@MainActor
private func formPages() -> [SettingsPage] {
    let pages: [SettingsPage] = [GeneralSettingsPage(), EditingSettingsPage(), CodeSettingsPage(), ScratchpadSettingsPage()]
    for page in pages {
        page.view.frame = NSRect(origin: .zero, size: page.view.fittingSize)
        page.view.layoutSubtreeIfNeeded()
    }
    return pages
}

/// Baseline of `view` in `root`'s coordinates.
@MainActor
private func baseline(of view: NSView, in root: NSView) -> CGFloat {
    let target = (view as? NSStackView)?.arrangedSubviews.first ?? view
    let offset = target.firstBaselineOffsetFromTop
    let y = target.isFlipped ? offset : target.bounds.height - offset
    return target.convert(NSPoint(x: 0, y: y), to: root).y
}

/// An isolated Run page: private defaults, notification centers and toolchain store.
@MainActor
private final class IsolatedRunPage {
    let suite = "SettingsWindowTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let root: URL
    let page: RunPreferencesController

    init() {
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsWindowTests-\(UUID().uuidString)", isDirectory: true)
        let center = NotificationCenter()
        let probes = ToolchainProbes(isExecutable: { _ in false },
                                     developerToolsInstalled: { true }, javaRuntimeInstalled: { true })
        page = RunPreferencesController(
            settings: RunSettings(defaults: defaults, center: center), center: center,
            makeLocator: { ToolchainLocator(managed: NoManagedToolchains(), probes: probes) },
            manager: ToolchainManager(store: ToolchainStore(root: root)), probes: probes,
            languageMenu: LanguageMenuSettings(defaults: defaults, center: NotificationCenter()),
            installCommandLineTools: {},
            modules: ModuleSettings(defaults: defaults, center: NotificationCenter()))
    }

    func cleanup() {
        page.pageWillDeactivate()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Settings window")
@MainActor
struct SettingsWindowTests {
    /// Every control identifier the six pages must expose, each exactly once.
    static let expectedIdentifiers: [String] = [
        "settings.uiLanguage", "settings.autoSave", "settings.fileDefaults",
        "settings.export", "settings.import", "settings.backupResult",
        "settings.fontSize", "settings.fontSizeStepper", "settings.indentLanguage",
        "settings.indentWidth", "settings.indentWidthStepper",
        "settings.usesSpaces", "settings.indentRainbow", "settings.autoClosePairs",
        "settings.languageList", "settings.projectFolders",
        "settings.scratchpadHotkey", "settings.scratchpadHotkeyReset",
        "settings.scratchpadFontSize", "settings.scratchpadFontSizeStepper",
    ] + FeatureModule.allCases.map { "settings.module." + $0.rawValue }

    @Test func pagesLoadLazilyAndTheToolbarListsSixPages() throws {
        let host = PreferencesWindowController(makePage: stubRunFactory)
        defer { host.close() }
        let start = host.selectedPage
        #expect(host.loadedPage(start) != nil)
        for id in SettingsPageID.allCases where id != start {
            #expect(host.loadedPage(id) == nil, "\(id) built before it was selected")
        }

        var instances: [SettingsPageID: ObjectIdentifier] = [:]
        for id in SettingsPageID.allCases {
            host.select(id)
            #expect(host.selectedPage == id)
            #expect(host.window?.title == id.title)
            let page = try #require(host.loadedPage(id))
            instances[id] = ObjectIdentifier(page)
            #expect(page.view.superview === host.window?.contentView)
            // The window's content area matches the page.
            let layout = try #require(host.window?.contentLayoutRect.size)
            #expect(abs(layout.width - page.view.fittingSize.width) <= 1, "\(id)")
            #expect(abs(layout.height - page.view.fittingSize.height) <= 1, "\(id)")
        }
        for id in SettingsPageID.allCases {
            host.select(id)
            #expect(host.loadedPage(id).map(ObjectIdentifier.init) == instances[id])
        }
        // Selecting the same page again is a no-op.
        let run = try #require(host.loadedPage(.run) as? StubPage)
        host.select(.run)
        let before = run.deactivations
        host.select(.run)
        #expect(run.deactivations == before)
        #expect(host.loadedPage(.run) === run)
        // Leaving a page deactivates it.
        host.select(.general)
        #expect(run.deactivations == before + 1)
        #expect(PreferencesWindowController.lastSelected == .general)

        let toolbar = try #require(host.window?.toolbar)
        let ids = SettingsPageID.allCases.map(\.toolbarIdentifier)
        #expect(host.toolbarSelectableItemIdentifiers(toolbar) == ids)
        #expect(toolbar.items.map(\.itemIdentifier) == ids)
        for item in toolbar.items {
            #expect(!item.label.isEmpty)
            #expect(item.image != nil)
        }
        #expect(toolbar.selectedItemIdentifier == SettingsPageID.general.toolbarIdentifier)
        #expect(!toolbar.allowsUserCustomization)
        #expect(host.window?.toolbarStyle == .preference)
        #expect(host.window?.styleMask.contains(.resizable) == false)
    }

    @Test func everySettingAppearsExactlyOnce() {
        let run = IsolatedRunPage()
        defer { run.cleanup() }
        let pages: [SettingsPage] = formPages() + [run.page, ShortcutPreferencesController()]
        let found = pages.flatMap { controlIdentifiers($0.view) }
        for id in Self.expectedIdentifiers {
            #expect(found.filter { $0 == id }.count == 1, "\(id)")
        }
        // Run's module toggle lives on the Run page, not on Code.
        #expect(controlIdentifiers(run.page.view).contains("settings.module.run"))
        #expect(Set(found).isSubset(of: Set(Self.expectedIdentifiers)), "\(Set(found).subtracting(Self.expectedIdentifiers))")
    }

    /// The Run page's widest content keeps the same margin on the right as on
    /// the left (it used to run to the window's edge).
    @Test func runPageKeepsItsTrailingMargin() {
        let run = IsolatedRunPage()
        defer { run.cleanup() }
        let view = run.page.view
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let widest = view.subviews.map(\.frame).max { $0.maxX < $1.maxX }
        #expect(widest != nil)
        #expect((widest?.maxX ?? .infinity) <= view.bounds.maxX - 20 + 0.5)
    }

    @Test func formPagesShareOneAlignmentAxis() throws {
        let pages = formPages()
        let widths = pages.map { $0.view.fittingSize.width }
        #expect(Set(widths).count == 1, "\(widths)")
        var axes: [CGFloat] = []
        for page in pages {
            let grid = try #require(allViews(page.view).compactMap { $0 as? NSGridView }.first)
            let label = try #require(grid.cell(atColumnIndex: 0, rowIndex: 0).contentView)
            let control = try #require(grid.cell(atColumnIndex: 1, rowIndex: 0).contentView)
            axes.append(control.convert(control.bounds, to: page.view).minX)
            // Labels right-aligned against the axis.
            let labelRight = label.convert(label.bounds, to: page.view).maxX
            #expect(labelRight <= axes.last! && labelRight > axes.last! - 20)
            // Label text and control text on one baseline.
            #expect(abs(baseline(of: label, in: page.view) - baseline(of: control, in: page.view)) <= 1,
                    "\(type(of: page))")
        }
        #expect(Set(axes).count == 1, "\(axes)")
    }

    @Test func numberFieldClampsRevertsAndSyncsWithItsStepper() {
        let number = SettingsForm.numberField(min: 8, max: 72, unit: "pt")
        number.setValue(13)
        var changes: [Int] = []
        number.onChange = { changes.append($0) }
        #expect(number.field.stringValue == "13" && number.stepper.integerValue == 13)

        number.field.stringValue = "99"
        number.commitText()
        #expect(number.value == 72 && number.field.stringValue == "72" && number.stepper.integerValue == 72)
        number.field.stringValue = "abc"
        number.commitText()
        #expect(number.value == 72 && number.field.stringValue == "72")
        number.field.stringValue = "3"
        number.commitText()
        #expect(number.value == 8 && number.field.stringValue == "8" && number.stepper.integerValue == 8)
        number.field.stringValue = " 20 "
        number.commitText()
        #expect(number.value == 20 && number.stepper.integerValue == 20)

        number.stepper.integerValue = 21
        _ = number.stepper.target?.perform(number.stepper.action, with: number.stepper)
        #expect(number.value == 21 && number.field.stringValue == "21")
        #expect(changes == [72, 8, 20, 21])
        // `setValue` clamps and does not report a user change.
        number.setValue(500)
        #expect(number.value == 72 && changes.count == 4)
    }

    @Test func closingReleasesTheHostAndItsPages() {
        weak var weakHost: PreferencesWindowController?
        var weakPages: [() -> AnyObject?] = []
        var closed = false
        autoreleasepool {
            let host = PreferencesWindowController(makePage: stubRunFactory)
            host.onClose = { closed = true }
            for id in SettingsPageID.allCases { host.select(id) }
            for id in SettingsPageID.allCases {
                let page = host.loadedPage(id)
                weakPages.append { [weak page] in page }
            }
            weakHost = host
            host.window?.close()
        }
        #expect(closed)
        #expect(weakHost == nil)
        for (index, page) in weakPages.enumerated() {
            #expect(page() == nil, "\(SettingsPageID.allCases[index]) still alive")
        }
    }

    @Test func sheetDoneClosesTheWindowWhenNotAttached() {
        let suite = "SettingsWindowSheets-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var closed = 0
        let list = LanguageListPreferencesController(
            settings: LanguageMenuSettings(defaults: defaults, center: NotificationCenter()), center: NotificationCenter())
        list.onClose = { closed += 1 }
        list.doneButton.performClick(nil)
        #expect(closed == 1)
        #expect(list.window?.isVisible == false)

        let fixture = IndexFixture()
        let folders = ProjectFoldersPreferencesController(index: fixture.makeIndex(), center: fixture.center) { $0(nil) }
        folders.onClose = { closed += 1 }
        folders.doneButton.performClick(nil)
        #expect(closed == 2)

        let defaultsController = DefaultApplicationPreferencesController(service: IdleAssociations(), types: [])
        defaultsController.onClose = { closed += 1 }
        defaultsController.doneButton.performClick(nil)
        #expect(closed == 3)

        for controller in [list, folders, defaultsController] as [NSWindowController] {
            let done = allViews(controller.window!.contentView!).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "settings.sheetDone" }
            #expect(done?.keyEquivalent == "\r")
            #expect(done?.title == L10n.t(.findDone))
        }
    }

    @Test func fileDefaultsSheetDoesNotDismissWhileBusy() async throws {
        let service = SlowAssociations()
        let controller = DefaultApplicationPreferencesController(service: service, types: [
            .init(type: .plainText, extensions: ["txt"])])
        var closed = false
        controller.onClose = { closed = true }
        let content = try #require(controller.window?.contentView)
        let table = try #require(allViews(content).compactMap { $0 as? NSTableView }.first)
        let apply = try #require(allViews(content).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.t(.fileDefaultsApply) })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        apply.performClick(nil)
        #expect(controller.busy)
        controller.doneButton.performClick(nil)
        (controller.window as? SettingsSheetWindow)?.cancelOperation(nil)
        #expect(!closed)
        service.release()
        let deadline = Date().addingTimeInterval(3)
        while controller.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!controller.busy)
        controller.doneButton.performClick(nil)
        #expect(closed)
    }
}

/// No assignment ever runs.
@MainActor
private final class IdleAssociations: DefaultApplicationManaging {
    var applicationURL: URL? { nil }
    func currentApplication(for type: UTType) -> URL? { nil }
    func setDefault(for type: UTType) async throws {}
}

/// Holds every assignment until `release()`; never touches Launch Services.
@MainActor
private final class SlowAssociations: DefaultApplicationManaging {
    private var released = false
    var applicationURL: URL? { URL(fileURLWithPath: "/Applications/Karu.app") }
    func currentApplication(for type: UTType) -> URL? { nil }
    func release() { released = true }
    func setDefault(for type: UTType) async throws {
        while !released { try await Task.sleep(for: .milliseconds(10)) }
    }
}

// MARK: - Languages (serialized: switches the UI language)

// Same pattern as `L10nOverrideTests`: main actor, synchronous, the override is
// set and restored within one test so no other main-actor test ever runs while
// a different language is active. Unlike there, the override is written
// *without* broadcasting `L10n.didChangeNotification`, and restored the same
// way: the broadcast reaches every live editor window of the suites running in
// parallel, and in a full run that re-work starved the main actor for ~10 s
// (toolchain and scheduler tests then timed out). Nothing outside this
// synchronous test ever observes the temporary language, so no re-sync is
// needed; the live-switch path is driven through the observers' handlers.
@Suite(.serialized)
@MainActor
struct SettingsWindowLanguageTests {
    private func setQuietly(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    @Test func nothingTruncatesInAnyLanguage() throws {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        let equalRows = [("settings.export", "settings.import"),
                         ("settings.languageList", "settings.projectFolders"),
                         ("settings.scratchpadHotkey", "settings.scratchpadHotkeyReset")]

        for language in AppLanguage.allCases {
            setQuietly(language.rawValue)
            #expect(L10n.current == language)
            let pages = formPages()
            let widths = Set(pages.map { $0.view.fittingSize.width })
            #expect(widths.count == 1, "\(language): \(widths)")
            for page in pages {
                for view in allViews(page.view) where !view.isHiddenOrHasHiddenAncestor {
                    let isLabel = (view as? NSTextField).map { !$0.isEditable && !$0.isBezeled } ?? false
                    guard view is NSButton || isLabel else { continue }
                    #expect(view.frame.width + 0.5 >= view.fittingSize.width,
                            "\(language) \(type(of: page)): \((view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? "")")
                    // Nothing pokes past the page's right inset.
                    let right = view.convert(view.bounds, to: page.view).maxX
                    #expect(right <= page.view.bounds.width - SettingsForm.insets.right + 0.5,
                            "\(language) \(type(of: page)) overflows: \(right)")
                }
                for (a, b) in equalRows {
                    guard let first = view(a, in: page.view), let second = view(b, in: page.view) else { continue }
                    #expect(abs(first.frame.width - second.frame.width) < 0.5, "\(language) \(a) / \(b)")
                }
            }
            // Row labels come out in the current language.
            let general = try #require(pages.first)
            let languageLabel = allViews(general.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == L10n.string(.prefLanguageLabel, language: language) }
            #expect(languageLabel != nil, "\(language)")
        }
    }

    @Test func liveLanguageSwitchRetitlesTheWindowAndRefitsPages() throws {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        setQuietly(AppLanguage.en.rawValue)
        let host = PreferencesWindowController(makePage: stubRunFactory)
        defer { host.close() }
        host.select(.scratchpad)
        let page = try #require(host.loadedPage(.scratchpad) as? ScratchpadSettingsPage)
        let enWidth = page.view.fittingSize.width

        // What the `L10n.didChangeNotification` observers run on a live switch.
        setQuietly(AppLanguage.ja.rawValue)
        host.languageDidChange()
        page.languageDidChange()
        #expect(host.window?.title == L10n.string(.scratchpadTitle, language: .ja))
        #expect(host.window?.toolbar?.items.first?.label == L10n.string(.settingsTabGeneral, language: .ja))
        let label = allViews(page.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == L10n.string(.prefScratchpadHotkeyLabel, language: .ja) }
        #expect(label != nil)
        let jaWidth = page.view.fittingSize.width
        #expect(jaWidth == SettingsForm.labelColumnWidth() + SettingsForm.controlColumnWidth
                + SettingsForm.columnSpacing + SettingsForm.insets.left + SettingsForm.insets.right)
        #expect(jaWidth != enWidth)
        // The page reported its new size and the window followed.
        let layout = try #require(host.window?.contentLayoutRect.size)
        #expect(abs(layout.width - jaWidth) <= 1)
    }
}
