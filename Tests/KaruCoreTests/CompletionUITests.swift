import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.6 — the completion UI on a real `EditorTextView` in a window:
// manual request (`complete(_:)`, Edit ▸ Show Completions), Esc, rows (labels,
// matched ranges, adaptive width), identity selection, input-method guards,
// dismissal triggers, the accept paths and text-boundary safety.

private func isolatedDefaults() -> (UserDefaults, () -> Void) {
    let name = "CompletionUITests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return (d, { d.removePersistentDomain(forName: name) })
}

@MainActor
private func pump(_ seconds: TimeInterval = 0.05) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// An editor-like wiring: scroll view + `EditorTextView` in a window, hub →
/// controller (owning its analysis), the controller as the key handler.
@MainActor
private final class UIHarness {
    let center = NotificationCenter()
    let settings: ModuleSettings
    let cleanDefaults: () -> Void
    let scheduler = AnalysisScheduler()
    let window: NSWindow
    let scrollView: NSScrollView
    let textView: EditorTextView
    let hub = TextStorageObserverHub()
    let controller: CompletionController
    /// Keys `keyDown` passed through to the input path.
    var passedThrough: [UInt16] = []

    init(_ text: String, language: String, size: NSSize = NSSize(width: 600, height: 400)) {
        let (defaults, clean) = isolatedDefaults()
        cleanDefaults = clean
        settings = ModuleSettings(defaults: defaults, center: center)
        let frame = NSRect(origin: .zero, size: size)
        scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        textView = EditorTextView(frame: frame)
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        textView.string = text
        textView.textStorage?.delegate = hub
        controller = CompletionController(textView: textView, moduleSettings: settings, moduleCenter: center,
                                          scheduler: scheduler)
        controller.labelLanguageOverride = .en
        hub.add(controller)
        textView.completionKeyHandler = controller
        window.makeFirstResponder(textView)
        controller.setLanguage(identifier: language)
        controller.indexDocument()
        textView.currentEventProvider = { nil }
    }

    /// Typing as the editor sees it: the text is inserted, then the
    /// controller hears about the key (letters never go through the real
    /// input method here, so the machine's input source cannot interfere).
    func type(_ string: String) {
        for ch in string {
            let key = String(ch)
            textView.insertText(key, replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.textViewDidInsertKey(event(key, keyCode: 0))
        }
    }

    func event(_ key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                         keyCode: keyCode)!
    }

    /// A real `keyDown` on the text view; what passes the completion
    /// handler is recorded instead of reaching the input method.
    func press(_ key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
               asInputPath: ((NSEvent) -> Void)? = nil) {
        textView.superKeyDownForTesting = { [unowned self] event in
            self.passedThrough.append(event.keyCode)
            asInputPath?(event)
        }
        defer { textView.superKeyDownForTesting = nil }
        textView.keyDown(with: event(key, keyCode: keyCode, modifiers: modifiers))
    }

    func pressTab() { press("\t", keyCode: 48) }
    func pressReturn() { press("\r", keyCode: 36) }
    func pressEnter() { press("\u{3}", keyCode: 76) }
    func pressEsc(modifiers: NSEvent.ModifierFlags = []) { press("\u{1b}", keyCode: 53, modifiers: modifiers) }
    func pressDown() { press(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125) }
    func pressUp(modifiers: NSEvent.ModifierFlags = []) {
        press(String(UnicodeScalar(NSUpArrowFunctionKey)!), keyCode: 126, modifiers: modifiers)
    }

    func caret(after marker: String) {
        let range = (textView.string as NSString).range(of: marker)
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    func caretAtEnd() {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    var isOpen: Bool { controller.isCompletionActive }
    var names: [String] { controller.currentSuggestionsForTesting }

    func close() {
        controller.dismissCompletion()
        textView.textStorage?.delegate = nil
        window.close()
        cleanDefaults()
    }
}

// MARK: - Manual request, Esc, menu item

@MainActor
@Suite("Completion UI — manual request and Esc", .serialized)
struct CompletionManualRequestTests {

    @Test func completeActionOpensKarusListWithAnEmptyPrefix() {
        let h = UIHarness("def render(user_count, user_config):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        #expect(!h.isOpen)
        h.textView.complete(nil)
        #expect(h.isOpen)
        #expect(h.controller.isShowingManualForTesting)
        #expect(h.controller.currentContextForTesting?.prefix == "")
        #expect(Set(h.names.prefix(2)) == ["user_count", "user_config"])
        #expect(h.textView.string == "def render(user_count, user_config):\n    \n")
    }

    @Test func optionEscapeKeyGoesThroughCompleteToKarusList() {
        let h = UIHarness("def render(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        // The real key-binding path: ⌥⎋ → interpretKeyEvents → complete:.
        h.textView.keyDown(with: h.event("\u{1b}", keyCode: 53, modifiers: .option))
        #expect(h.isOpen)
        #expect(h.names.first == "user_count")
    }

    @Test func escapeWithTheListClosedOpensNothing() {
        let h = UIHarness("def render(user_count):\n    us\n", language: "python")
        defer { h.close() }
        h.caret(after: "    us")
        let before = h.textView.string
        // The real path (cancelOperation: up the responder chain).
        h.textView.keyDown(with: h.event("\u{1b}", keyCode: 53))
        #expect(!h.isOpen)
        #expect(h.textView.string == before)
        // A key binding that routes a plain Esc to complete: still opens nothing.
        let esc = h.event("\u{1b}", keyCode: 53)
        h.textView.currentEventProvider = { esc }
        h.textView.complete(nil)
        #expect(!h.isOpen)
        #expect(h.textView.string == before)
        #expect(EditorTextView.isPlainEscape(esc))
        #expect(!EditorTextView.isPlainEscape(h.event("\u{1b}", keyCode: 53, modifiers: .option)))
    }

    @Test func escapeWithTheListOpenOnlyCloses() {
        let h = UIHarness("def render(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen)
        let before = h.textView.string
        h.pressEsc()
        #expect(!h.isOpen)
        #expect(h.passedThrough.isEmpty)
        #expect(h.textView.string == before)
        #expect(h.textView.selectedRange().location == (before as NSString).range(of: "    us").upperBound)
    }

    @Test func optionEscapeWithTheListOpenRefreshesAsManual() {
        let h = UIHarness("def render(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen && !h.controller.isShowingManualForTesting)
        // Not consumed as a dismiss: the bound shortcut (or, after a rebind,
        // the complete: key binding) makes it a manual request.
        h.pressEsc(modifiers: .option)
        #expect(h.isOpen)
        #expect(h.controller.isShowingManualForTesting)
        #expect(h.textView.string == "def render(user_count):\n    us\n")
    }

    @Test func manualPopupFallsBackToAutomaticRulesOnANewWord() {
        let h = UIHarness("x = 'note'\ndef f(user_count):\n    s = 'us\n", language: "python")
        defer { h.close() }
        h.caret(after: "s = 'us")
        h.textView.complete(nil)   // inside a string: manual only
        #expect(h.isOpen)
        h.type("e")               // same identifier: stays manual
        #expect(h.isOpen && h.controller.isShowingManualForTesting)
        h.type(" ")               // a new word inside the string: automatic rules
        #expect(!h.isOpen)
    }

    @Test func showCompletionsMenuItemTriggersTheRequestAndFollowsTheModule() throws {
        let h = UIHarness("def render(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        let menu = MainMenu.build(applyShortcuts: false)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
        let item = try #require(items(menu).first { $0.action == #selector(EditorTextView.showCompletions(_:)) })
        // In the Edit menu, titled from the table, ⌥⎋ — never ⌃Space.
        #expect(item.menu?.title == L10n.t(.menuEdit))
        #expect(item.title == L10n.t(.menuShowCompletions))
        #expect(item.keyEquivalent == "\u{1b}" && item.keyEquivalentModifierMask == [.option])
        #expect(h.textView.validateMenuItem(item))
        h.textView.perform(item.action!, with: item)
        #expect(h.isOpen)
        #expect(h.names.first == "user_count")
        h.controller.dismissCompletion()

        h.settings.setEnabled(false, for: .completion)
        #expect(!h.textView.validateMenuItem(item))
        h.textView.perform(item.action!, with: item)
        h.textView.complete(nil)
        #expect(!h.isOpen)
        h.settings.setEnabled(true, for: .completion)
        #expect(h.textView.validateMenuItem(item))
    }

    @Test func showCompletionsIsARebindableEditorCommandWithoutControlSpace() throws {
        let (defaults, clean) = isolatedDefaults()
        defer { clean() }
        let settings = ShortcutSettings(defaults: defaults)
        let command = try #require(settings.commands.first { $0.id == "menu.showCompletions:" })
        #expect(command.scope == .editor)
        #expect(command.defaultBinding == [ShortcutStroke("\u{1b}", .option)])
        #expect(command.title == L10n.t(.menuEdit) + " ▸ " + L10n.t(.menuShowCompletions))
        #expect(settings.conflicts(command.defaultBinding, for: command).isEmpty)
        // ⌃Space is the input-source switch: no command takes it by default.
        let controlSpace = ShortcutStroke(" ", .control)
        #expect(!settings.commands.contains { settings.binding(for: $0) == [controlSpace] })
        // Rebind and route the new key through the editor's shortcut router.
        let rebound = [ShortcutStroke("k", [.control, .option])]
        #expect(settings.set(rebound, for: command).isEmpty)
        #expect(settings.binding(for: command) == rebound)
        let router = ShortcutRouter()
        guard case .command(let resolved) = router.resolve(rebound[0], scope: .editor, settings: settings) else {
            Issue.record("rebound key does not resolve")
            return
        }
        #expect(resolved.action == "showCompletions:")
    }

    @Test func menuTitleIsLocalizedInThreeLanguages() throws {
        #expect(L10n.string(.menuShowCompletions, language: .zhHans) == "显示候选")
        #expect(L10n.string(.menuShowCompletions, language: .en) == "Show Completions")
        #expect(L10n.string(.menuShowCompletions, language: .ja) == "候補を表示")
        // The live menu reads the table of the UI language (set and restored
        // within one main-actor turn, as L10nOverrideTests do, without the
        // change broadcast).
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: L10n.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: L10n.defaultsKey) }
        }
        for language in AppLanguage.allCases {
            UserDefaults.standard.set(language.rawValue, forKey: L10n.defaultsKey)
            let menu = MainMenu.build(applyShortcuts: false)
            let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == L10n.string(.menuEdit, language: language) })
            #expect(edit.items.contains {
                $0.title == L10n.string(.menuShowCompletions, language: language)
                    && $0.action == #selector(EditorTextView.showCompletions(_:))
            })
        }
    }
}

// MARK: - Rows: labels, matched ranges, width, identity

@MainActor
@Suite("Completion UI — rows", .serialized)
struct CompletionRowTests {

    @Test func categoryLabelsInThreeLanguages() {
        let expected: [CompletionCategory: (String, String, String)] = [
            .parameter: ("参数", "parameter", "引数"),
            .local: ("局部", "local", "ローカル"),
            .member: ("成员", "member", "メンバー"),
            .function: ("函数", "function", "関数"),
            .type: ("类型", "type", "型"),
            .variable: ("变量", "variable", "変数"),
            .keyword: ("关键字", "keyword", "キーワード"),
            .builtin: ("内置", "builtin", "組み込み"),
            .module: ("模块", "module", "モジュール"),
            .file: ("文件", "file", "ファイル"),
            .word: ("文档词", "word", "単語"),
        ]
        #expect(Set(expected.keys) == Set(CompletionCategory.allCases))
        for (category, (zh, en, ja)) in expected {
            #expect(category.label(language: .zhHans) == zh)
            #expect(category.label(language: .en) == en)
            #expect(category.label(language: .ja) == ja)
        }
    }

    @Test func categoryFollowsKindAndWorkspaceSource() {
        func category(_ kind: CandidateKind, _ source: CandidateSource = .scope) -> CompletionCategory {
            CompletionCategory.of(Candidate(name: "x", kind: kind, source: source))
        }
        #expect(category(.parameter) == .parameter)
        #expect(category(.local) == .local)
        #expect(category(.method, .selfMember) == .member)
        #expect(category(.property, .selfMember) == .member)
        #expect(category(.member, .receiverUsage) == .member)
        #expect(category(.function, .fileDeclaration) == .function)
        #expect(category(.type, .fileDeclaration) == .type)
        #expect(category(.variable, .fileDeclaration) == .variable)
        #expect(category(.keyword, .keyword) == .keyword)
        #expect(category(.builtin, .keyword) == .builtin)
        #expect(category(.module, .scope) == .module)
        #expect(category(.word, .documentWord) == .word)
        #expect(category(.function, .workspace) == .file)
    }

    @Test func rowsShowLabelsAndAccessibilityText() throws {
        let h = UIHarness("const userCount = 1;\nfunction userTotal(userName) {\n  return \n}\n", language: "javascript")
        defer { h.close() }
        h.caret(after: "return ")
        h.type("user")
        #expect(h.isOpen)
        let candidates = h.controller.currentCandidatesForTesting
        let param = try #require(candidates.firstIndex { $0.name == "userName" })
        let cell = try #require(h.controller.cellForTesting(row: param))
        #expect(cell.nameField.stringValue == "userName")
        #expect(cell.labelField.stringValue == "parameter")
        #expect(cell.accessibilityLabel() == "userName, parameter")
        #expect(cell.isAccessibilityElement())
        let function = try #require(candidates.firstIndex { $0.name == "userTotal" })
        #expect(h.controller.cellForTesting(row: function)?.labelField.stringValue == "function")
        // Labels follow the label language.
        h.controller.dismissCompletion()
        h.controller.labelLanguageOverride = .zhHans
        h.type("N")
        #expect(h.controller.cellForTesting(row: 0)?.labelField.stringValue == "参数")
    }

    @Test func matchedRangesAreBoldOnTheirUTF16Ranges() throws {
        let h = UIHarness("function f(userDisplayName) {\n  return \n}\n", language: "javascript")
        defer { h.close() }
        h.caret(after: "return ")
        h.type("udn")
        #expect(h.names.first == "userDisplayName")
        let candidate = try #require(h.controller.currentCandidatesForTesting.first)
        #expect(candidate.matchedRanges == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1),
                                           NSRange(location: 11, length: 1)])
        let cell = try #require(h.controller.cellForTesting(row: 0))
        let name = cell.nameField.attributedStringValue
        #expect(name.string == "userDisplayName")
        for i in 0..<name.length {
            let font = name.attribute(.font, at: i, effectiveRange: nil) as? NSFont
            let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
            #expect(bold == [0, 4, 11].contains(i), "unit \(i)")
        }
    }

    @Test func matchedRangesOnNonBMPNames() throws {
        // 𝑥 (U+1D465) is a letter outside the BMP: two UTF-16 units.
        let h = UIHarness("function f(𝑥_value_name) {\n  return \n}\n", language: "javascript")
        defer { h.close() }
        h.caret(after: "return ")
        h.type("𝑥_v")
        let candidate = try #require(h.controller.currentCandidatesForTesting.first)
        #expect(candidate.name == "𝑥_value_name")
        #expect(candidate.matchedRanges == [NSRange(location: 0, length: 4)])
        let name = try #require(h.controller.cellForTesting(row: 0)).nameField.attributedStringValue
        var effective = NSRange()
        let font = name.attribute(.font, at: 0, effectiveRange: &effective) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(effective == NSRange(location: 0, length: 4))

        // The builder applies ranges as given, after a non-BMP character too,
        // and drops / clamps ranges outside the name.
        let row = CompletionRowContent(
            candidate: Candidate(name: "a𝑥bc", kind: .local, source: .scope,
                                 matchedRanges: [NSRange(location: 1, length: 2), NSRange(location: 4, length: 9),
                                                 NSRange(location: 40, length: 1)]),
            language: .en)
        #expect(row.matchedRanges == [NSRange(location: 1, length: 2), NSRange(location: 4, length: 1)])
        let text = CompletionListMetrics.attributedName(row)
        for i in 0..<text.length {
            let bold = (text.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?
                .fontDescriptor.symbolicTraits.contains(.bold) == true
            #expect(bold == (i == 1 || i == 2 || i == 4), "unit \(i)")
        }
    }

    @Test func widthAdaptsToTheWidestRowAndClamps() throws {
        let short = UIHarness("def f(ab_x, ab_y):\n    \n", language: "python")
        short.caret(after: "):\n    ")
        short.type("ab")
        #expect(short.isOpen)
        let shortWidth = try #require(short.controller.panelForTesting).frame.width
        let shortRows = short.controller.currentCandidatesForTesting.map { CompletionRowContent(candidate: $0, language: .en) }
        short.close()
        // Shared columns (T17.15a): the widest name plus the widest label
        // (`AttributeError` and "parameter" here), at least the minimum.
        let shortColumns = CompletionListMetrics.columns(rows: shortRows)
        let shortNatural = shortColumns.name + CompletionListMetrics.gap + shortColumns.label
            + CompletionListMetrics.leadingPadding + CompletionListMetrics.trailingPadding + CompletionListMetrics.border
        #expect(shortColumns.detail == 0)
        #expect(shortWidth == max(CompletionListMetrics.minimumWidth, ceil(shortNatural)))
        #expect(shortWidth < CompletionListMetrics.minimumWidth + 20)

        let medium = "ab_" + String(repeating: "m", count: 30)
        let mid = UIHarness("def f(\(medium)):\n    \n", language: "python")
        mid.caret(after: "):\n    ")
        mid.type("ab")
        let midWidth = try #require(mid.controller.panelForTesting).frame.width
        mid.close()
        let natural = CompletionListMetrics.nameWidth(medium) + CompletionListMetrics.gap
            + CompletionListMetrics.labelWidth("parameter") + CompletionListMetrics.leadingPadding
            + CompletionListMetrics.trailingPadding + CompletionListMetrics.border
        #expect(midWidth > CompletionListMetrics.minimumWidth && midWidth < CompletionListMetrics.maximumWidth)
        #expect(abs(midWidth - ceil(natural)) < 1)

        let long = "ab_" + String(repeating: "verylongname_", count: 12)
        let wide = UIHarness("def f(\(long)):\n    \n", language: "python")
        defer { wide.close() }
        wide.caret(after: "):\n    ")
        wide.type("ab")
        let panel = try #require(wide.controller.panelForTesting)
        let screenWidth = (wide.window.screen ?? NSScreen.main)?.visibleFrame.width ?? 10_000
        #expect(panel.frame.width == min(CompletionListMetrics.maximumWidth,
                                         screenWidth - 2 * CompletionListMetrics.screenMargin))
        // The long name truncates in the middle; the label stays whole.
        let cell = try #require(wide.controller.cellForTesting(row: 0))
        cell.frame = NSRect(x: 0, y: 0, width: panel.frame.width - 2, height: CompletionListMetrics.rowHeight)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.nameField.lineBreakMode == .byTruncatingMiddle)
        let inset = CompletionListMetrics.textInset
        #expect(cell.labelField.frame.width >= CompletionListMetrics.labelWidth("parameter") + 2 * inset)
        #expect(cell.labelField.frame.maxX - inset <= cell.bounds.maxX - CompletionListMetrics.trailingPadding + 0.5)
        #expect(cell.nameField.frame.maxX - inset <= cell.labelField.frame.minX + inset - CompletionListMetrics.gap + 0.5)

        // The screen clamp.
        let rows = [CompletionRowContent(candidate: Candidate(name: long, kind: .local, source: .scope), language: .en)]
        #expect(CompletionListMetrics.panelWidth(rows: rows, scroller: 0, screenWidth: 300) == CGFloat(292))
        #expect(CompletionListMetrics.panelWidth(rows: rows, scroller: 0, screenWidth: nil) == CGFloat(480))
    }

    /// T17.15a: the category label sits in a fixed right-hand column —
    /// the same x on every row whatever the summary's length —, the details
    /// start at one column and stop `gap` before it, names never run into
    /// them, and VoiceOver still reads name, label, detail.
    @Test func labelsLineUpInAFixedColumnWhateverTheDetail() throws {
        func row(_ name: String, _ kind: CandidateKind, _ detail: String?, _ language: AppLanguage) -> CompletionRowContent {
            var candidate = Candidate(name: name, kind: kind, source: kind == .member ? .inferredType : .scope)
            candidate.detail = detail
            return CompletionRowContent(candidate: candidate, language: language)
        }
        for language in [AppLanguage.en, .zhHans, .ja] {
            let rows = [
                row("total", .member, "(tax: float = 0.1, *, rounded: bool = True) -> float", language),
                row("id", .member, "int", language),
                row("user_name", .parameter, nil, language),
                row("render_invoice_with_header", .function, "(invoice: Invoice, title: str, footer: str | None = None, "
                    + "copies: int = 1) -> list[str]", language),
                row("x", .local, nil, language),
                row("label", .member, "", language),
            ]
            let columns = CompletionListMetrics.columns(rows: rows)
            #expect(columns.detail == CompletionListMetrics.maximumDetailWidth)        // the long summary is capped
            let width = CompletionListMetrics.panelWidth(columns: columns, scroller: 0, screenWidth: nil)
            #expect(width >= CompletionListMetrics.minimumWidth && width <= CompletionListMetrics.maximumWidth)
            let inset = CompletionListMetrics.textInset
            let gap = CompletionListMetrics.gap
            var labelX: Set<CGFloat> = []
            var detailX: Set<CGFloat> = []
            for content in rows {
                let cell = CompletionCellView(frame: NSRect(x: 0, y: 0, width: width - 2,
                                                            height: CompletionListMetrics.rowHeight))
                cell.configure(content, columns: columns)
                cell.layoutSubtreeIfNeeded()
                labelX.insert(cell.labelField.frame.minX)
                #expect(cell.labelField.stringValue == content.label)
                #expect(cell.labelField.frame.width >= CompletionListMetrics.labelWidth(content.label) + 2 * inset)
                #expect(cell.labelField.frame.maxX - inset <= cell.bounds.maxX - CompletionListMetrics.trailingPadding + 0.5)
                if let detail = content.detail, !detail.isEmpty {
                    #expect(!cell.detailField.isHidden && cell.detailField.stringValue == detail)
                    detailX.insert(cell.detailField.frame.minX)
                    #expect(cell.detailField.frame.maxX - inset <= cell.labelField.frame.minX + inset - gap + 0.5)
                    #expect(cell.nameField.frame.maxX - inset <= cell.detailField.frame.minX + inset - gap + 0.5)
                    #expect(cell.detailField.lineBreakMode == .byTruncatingTail)
                } else {
                    #expect(cell.detailField.isHidden)
                    #expect(cell.nameField.frame.maxX - inset <= cell.labelField.frame.minX + inset - gap + 0.5)
                }
                #expect(cell.accessibilityLabel() == content.accessibilityLabel)
            }
            #expect(labelX.count == 1, "label column x per row: \(labelX)")
            #expect(detailX.count == 1, "detail column x per row: \(detailX)")
        }
        #expect(row("total", .member, "() -> float", .en).accessibilityLabel == "total, member, () -> float")

        // The same through the controller's popup: an inferred member list.
        let h = UIHarness("""
        class Invoice:
            amount: float = 0.0
            def total(self, tax: float = 0.1, *, rounded: bool = True, currency: str = "EUR") -> float:
                return self.amount
            def id(self) -> int:
                return 1

        def f(invoice: Invoice):
            \n
        """, language: "python")
        defer { h.close() }
        h.caret(after: "Invoice):\n    ")
        h.type("invoice.")
        let panel = try #require(h.controller.panelForTesting)
        let count = h.controller.currentCandidatesForTesting.count
        #expect(count >= 3)
        var xs: Set<CGFloat> = []
        for index in 0..<count {
            let cell = try #require(h.controller.cellForTesting(row: index))
            cell.frame = NSRect(x: 0, y: 0, width: panel.frame.width - 2, height: CompletionListMetrics.rowHeight)
            cell.layoutSubtreeIfNeeded()
            xs.insert(cell.labelField.frame.minX)
        }
        #expect(xs.count == 1, "\(xs)")
    }

    @Test func selectionSurvivesARefreshByIdentityNotRow() throws {
        let h = UIHarness("def f(user_a, user_b, user_cc, user_cd):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("user_")
        let names = h.names
        let target = try #require(names.firstIndex(of: "user_cd"))
        #expect(target >= 2)
        h.controller.selectRowForTesting(target)
        h.type("c")
        // The list shrank (user_cc, user_cd): the row index moved, the
        // selected candidate did not.
        #expect(h.controller.selectedCandidateForTesting?.name == "user_cd")
        #expect(h.controller.tableViewForTesting?.selectedRow != target)
        // ↓ / ↑ move the selection; the caret does not move.
        let caret = h.textView.selectedRange()
        h.pressUp()
        #expect(h.controller.selectedCandidateForTesting?.name == "user_cc")
        h.pressDown()
        #expect(h.controller.selectedCandidateForTesting?.name == "user_cd")
        #expect(h.textView.selectedRange() == caret)
        #expect(h.passedThrough.isEmpty)
    }
}

// MARK: - Input methods

@MainActor
@Suite("Completion UI — input methods", .serialized)
struct CompletionIMETests {

    private func mark(_ h: UIHarness, _ text: String) {
        h.textView.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func compositionStartClosesThePopupAndNothingReopensUntilCommit() {
        let h = UIHarness("def f(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen)
        mark(h, "e")
        #expect(h.textView.hasMarkedText())
        #expect(!h.isOpen)
        // No request opens a popup while composing.
        h.controller.requestCompletion(manual: true)
        h.textView.complete(nil)
        h.textView.showCompletions(nil)
        h.controller.textViewDidInsertKey(h.event("e", keyCode: 0))
        #expect(!h.isOpen)
        // Commit (the composed text stays), then typing triggers again.
        h.textView.unmarkText()
        #expect(!h.textView.hasMarkedText())
        #expect(h.textView.string == "def f(user_count):\n    use\n")
        #expect(!h.isOpen)
        h.type("r")
        #expect(h.isOpen)
        #expect(h.names.first == "user_count")
    }

    @Test func keysPassToTheInputMethodWhileComposing() {
        let h = UIHarness("def f(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("us")
        mark(h, "ceshi")
        let text = h.textView.string
        h.pressDown()
        h.pressUp()
        h.press(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124)
        h.press("1", keyCode: 18)
        h.pressTab()
        h.pressEsc()
        h.pressReturn()
        h.pressEnter()
        // Every key reached the input path; Karu consumed none and opened nothing.
        #expect(h.passedThrough == [125, 126, 124, 18, 48, 53, 36, 76])
        #expect(!h.isOpen)
        #expect(h.textView.string == text)
    }

    @Test func theKeyThatCommitsDoesNotOpenAPopup() {
        let h = UIHarness("def f(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        // IME-03: Return commits the raw letters; the input method inserts
        // them while handling the key. Karu neither accepts nor opens.
        mark(h, "user_c")
        h.press("\r", keyCode: 36, asInputPath: { [unowned h] _ in
            h.textView.insertText("user_c", replacementRange: NSRange(location: NSNotFound, length: 0))
        })
        #expect(h.passedThrough == [36])
        #expect(!h.textView.hasMarkedText())
        #expect(h.textView.string == "def f(user_count):\n    user_c\n")
        #expect(!h.isOpen)
        // The next ordinary key triggers again (IME-09).
        h.type("o")
        #expect(h.isOpen)
        #expect(h.names.first == "user_count")
        // IME-04: Space picks the characters; no popup right after.
        h.controller.dismissCompletion()
        h.type(" + ")
        mark(h, "ceshi")
        h.press(" ", keyCode: 49, asInputPath: { [unowned h] _ in
            h.textView.insertText("测试", replacementRange: NSRange(location: NSNotFound, length: 0))
        })
        #expect(h.textView.string == "def f(user_count):\n    user_co + 测试\n")
        #expect(!h.isOpen)
    }

    @Test func aKeyThatStartsACompositionClosesTheOpenPopup() {
        let h = UIHarness("def f(user_count):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen)
        // IME-08: the input method turns the key into marked text.
        h.press("c", keyCode: 8, asInputPath: { _ in })
        #expect(h.isOpen)   // a key the input method ignored: the popup refreshes
        h.press("c", keyCode: 8, asInputPath: { [unowned h] _ in
            h.textView.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
        })
        #expect(h.textView.hasMarkedText())
        #expect(!h.isOpen)
    }
}

// MARK: - Dismissal

@MainActor
@Suite("Completion UI — dismissal", .serialized)
struct CompletionDismissalTests {

    private func opened(_ text: String = "def f(user_count):\n    \n") -> UIHarness {
        let h = UIHarness(text, language: "python")
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen)
        return h
    }

    @Test func caretMovedByArrowsOrMouseCloses() {
        let h = opened()
        defer { h.close() }
        h.press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123,
                asInputPath: { [unowned h] _ in h.textView.moveLeft(nil) })
        #expect(h.passedThrough == [123])
        #expect(!h.isOpen)
        // A click (or any selection change without an edit) closes it too.
        h.textView.moveRight(nil)
        h.type("e")
        #expect(h.isOpen)
        h.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!h.isOpen)
        // ACC-11: then Return is only a newline — no stale candidate is written.
        h.pressReturn()
        #expect(h.passedThrough.last == 36)
        #expect(h.textView.string == "def f(user_count):\n    use\n")
    }

    @Test func modifiedNavigationAndReturnCloseAndPassThrough() {
        // `routed`: an editor command bound to the key (⌥↓ Move Line Down,
        // ⌘⏎ Insert Line Below) takes it on the way; the rest reach the
        // input path. Either way completion does not consume them.
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        for (key, code, flags, routed) in [(up, UInt16(126), NSEvent.ModifierFlags.command, false),
                                           (down, 125, .command, false),
                                           (down, 125, .option, true),
                                           ("\r", 36, .shift, false), ("\r", 36, .command, true),
                                           ("\t", 48, .shift, false)] {
            let h = opened()
            h.press(key, keyCode: code, modifiers: flags)
            #expect(h.passedThrough == (routed ? [] : [code]), "\(code) \(flags)")
            #expect(!h.isOpen, "\(code) \(flags)")
            #expect(h.textView.string == "def f(user_count):\n    us\n")
            h.close()
        }
    }

    @Test func anEditNoKeyRefreshedClosesOnTheNextTurn() async {
        let h = opened()
        defer { h.close() }
        // ACC-16 / paste / undo / menu commands: a newline arrives without
        // the keystroke refresh.
        h.textView.insertNewline(nil)
        await pump()
        #expect(!h.isOpen)
        // Typing keeps it open across the same check.
        h.type("us")
        #expect(h.isOpen)
        await pump()
        #expect(h.isOpen)
    }

    @Test func focusLossAndWindowResigningKeyClose() {
        let h = opened()
        defer { h.close() }
        h.window.makeFirstResponder(nil)
        #expect(!h.isOpen)
        h.window.makeFirstResponder(h.textView)
        #expect(!h.isOpen)   // does not reappear on its own
        h.type("e")
        #expect(h.isOpen)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
        #expect(!h.isOpen)
    }

    @Test func languageSwitchCloses() {
        let h = opened()
        defer { h.close() }
        h.controller.setLanguage(identifier: "javascript")
        #expect(!h.isOpen)
    }

    @Test func moduleOffCloses() {
        let h = opened()
        defer { h.close() }
        h.settings.setEnabled(false, for: .completion)
        #expect(!h.isOpen)
        h.type("e")
        #expect(!h.isOpen)
        h.settings.setEnabled(true, for: .completion)
        h.type("r")
        #expect(h.isOpen)
    }

    @Test func scrollingTheAnchorOutOfViewCloses() throws {
        let filler = (0..<200).map { "x\($0) = \($0)" }.joined(separator: "\n")
        let h = UIHarness("def f(user_count):\n    \n" + filler + "\n", language: "python",
                          size: NSSize(width: 500, height: 300))
        defer { h.close() }
        h.textView.layoutManager?.ensureLayout(for: h.textView.textContainer!)
        h.caret(after: "):\n    ")
        h.type("us")
        #expect(h.isOpen)
        let clip = h.scrollView.contentView
        let before = try #require(h.controller.panelForTesting).frame
        // A small scroll keeps the anchor visible: the panel follows it
        // (text moves up by 10 pt on screen).
        clip.scroll(to: NSPoint(x: 0, y: 10))
        #expect(h.isOpen)
        let after = try #require(h.controller.panelForTesting).frame
        #expect(abs((after.minY - before.minY) - 10) < 1.5)
        // Far down: the anchor left the visible rect.
        clip.scroll(to: NSPoint(x: 0, y: 2000))
        #expect(!h.isOpen)
    }
}

// MARK: - Accept paths and text-boundary safety

@MainActor
@Suite("Completion UI — accept and safety", .serialized)
struct CompletionAcceptTests {

    /// `function badge(userCount) { return us│xyz }` → typing `e`, then
    /// `accept` replaces the whole `usexyz` with `userCount` as one undo step.
    private func acceptWholeIdentifier(_ accept: (UIHarness) -> Void) throws {
        let h = UIHarness("function badge(userCount) {\n  return usxyz;\n}\n", language: "javascript")
        defer { h.close() }
        let undo = try #require(h.textView.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        h.caret(after: "return us")
        undo.beginUndoGrouping()
        h.type("e")
        undo.endUndoGrouping()
        #expect(h.controller.currentContextForTesting?.identifier == "usexyz")
        #expect(h.names.first == "userCount")
        undo.beginUndoGrouping()
        accept(h)
        undo.endUndoGrouping()
        #expect(h.textView.string == "function badge(userCount) {\n  return userCount;\n}\n")
        #expect(h.textView.selectedRange() == NSRange(location: ("function badge(userCount) {\n  return userCount" as NSString).length, length: 0))
        #expect(!h.isOpen)
        #expect(h.passedThrough.isEmpty)
        undo.undo()
        #expect(h.textView.string == "function badge(userCount) {\n  return usexyz;\n}\n")
        undo.redo()
        #expect(h.textView.string == "function badge(userCount) {\n  return userCount;\n}\n")
    }

    @Test func tabAccepts() throws { try acceptWholeIdentifier { $0.pressTab() } }
    @Test func returnAccepts() throws { try acceptWholeIdentifier { $0.pressReturn() } }
    @Test func keypadEnterAccepts() throws { try acceptWholeIdentifier { $0.pressEnter() } }
    @Test func doubleClickAccepts() throws { try acceptWholeIdentifier { $0.controller.sendDoubleClickForTesting() } }

    @Test func doubleClickAcceptsTheChosenRow() throws {
        let h = UIHarness("def f(user_a, user_b):\n    \n", language: "python")
        defer { h.close() }
        h.caret(after: "):\n    ")
        h.type("user")
        let row = try #require(h.names.firstIndex(of: "user_b"))
        #expect(row == 1)
        h.controller.selectRowForTesting(row)
        h.controller.sendDoubleClickForTesting()
        #expect(h.textView.string == "def f(user_a, user_b):\n    user_b\n")
    }

    @Test func emojiAroundTheIdentifierStaysIntact() {
        // SAFE-04: an emoji before the identifier on the line, and one right after it.
        let h = UIHarness("const countValue = 1;\nconst s = '🎉' + co🎉;\n", language: "javascript")
        defer { h.close() }
        h.caret(after: "'🎉' + co")
        h.type("u")
        #expect(h.controller.currentContextForTesting?.identifier == "cou")
        #expect(h.names.first == "countValue")
        h.pressTab()
        #expect(h.textView.string == "const countValue = 1;\nconst s = '🎉' + countValue🎉;\n")
        #expect(h.textView.selectedRange().location == ("const countValue = 1;\nconst s = '🎉' + countValue" as NSString).length)
    }

    @Test func combiningMarksStayWhole() {
        // SAFE-05: an identifier holding combining marks (e + U+0301) is
        // replaced whole; a combining mark on the line before is untouched.
        let name = "re\u{301}sume\u{301}_total"
        let h = UIHarness("\(name) = 1\nnote = 'cafe\u{301}'\nx = \n", language: "python")
        defer { h.close() }
        h.caret(after: "x = ")
        h.type("re\u{301}")
        #expect(h.names.first == name)
        h.pressReturn()
        #expect(h.textView.string == "\(name) = 1\nnote = 'cafe\u{301}'\nx = \(name)\n")
    }

    @Test func crlfAndMissingTrailingNewlineAreKept() {
        // SAFE-06: CRLF line endings stay CRLF.
        let crlf = UIHarness("count_value = 1\r\ny = 2\r\nz = co\r\nw = 3", language: "python")
        crlf.caret(after: "z = co")
        crlf.type("u")
        crlf.pressTab()
        #expect(crlf.textView.string == "count_value = 1\r\ny = 2\r\nz = count_value\r\nw = 3")
        crlf.close()
        // SAFE-07: the last line without a newline.
        let tail = UIHarness("count_value = 1\nz = co", language: "python")
        defer { tail.close() }
        tail.caretAtEnd()
        tail.type("u")
        tail.pressReturn()
        #expect(tail.textView.string == "count_value = 1\nz = count_value")
    }

    @Test func emptyDocumentOpensNothing() {
        // SAFE-08.
        let h = UIHarness("", language: "")
        defer { h.close() }
        h.type("ab")
        #expect(!h.isOpen)
        #expect(h.textView.string == "ab")
        h.textView.complete(nil)
        #expect(!h.isOpen || h.names.allSatisfy { $0 != "ab" })
    }
}

// MARK: - Screenshots (opt-in)

/// `KARU_T176_SHOTS=<dir> swift test --filter CompletionScreenshots` renders
/// the open popup over the editor in light / dark and zh-Hans / en.
@MainActor
@Suite("CompletionScreenshots", .serialized)
struct CompletionScreenshots {
    @Test func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["KARU_T176_SHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let source = """
        import os


        def render(user_count, user_config, user_display_name):
            user_cache = {}
            for user_index in range(user_count):
                print(user_index)
            label = "user"
            return
        """ + " \n"
        for (appearance, look) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for language in [AppLanguage.zhHans, .en] {
                let h = UIHarness(source, language: "python", size: NSSize(width: 620, height: 260))
                h.window.appearance = NSAppearance(named: appearance)
                h.controller.labelLanguageOverride = language
                h.caret(after: "return ")
                h.type("us")
                let panel = try #require(h.controller.panelForTesting)
                panel.appearance = NSAppearance(named: appearance)
                h.controller.selectRowForTesting(1)
                panel.contentView?.layoutSubtreeIfNeeded()
                let content = try #require(h.window.contentView)
                content.layoutSubtreeIfNeeded()
                let scale: CGFloat = 2
                let size = content.bounds.size
                func bitmap(_ view: NSView) -> NSBitmapImageRep {
                    var rep: NSBitmapImageRep!
                    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                        rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                        view.cacheDisplay(in: view.bounds, to: rep)
                    }
                    return rep
                }
                let editor = bitmap(content)
                let popup = bitmap(try #require(panel.contentView))
                let panelInWindow = h.window.convertFromScreen(panel.frame)
                let canvas = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                canvas.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    NSColor.textBackgroundColor.setFill()
                    NSRect(origin: .zero, size: size).fill()
                }
                editor.draw(in: NSRect(origin: .zero, size: size))
                popup.draw(in: panelInWindow)
                NSGraphicsContext.restoreGraphicsState()
                let png = try #require(canvas.representation(using: .png, properties: [:]))
                let name = "completion-\(look)-\(language.rawValue).png"
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                h.close()
            }
        }
    }
}
