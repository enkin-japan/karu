import AppKit
import Testing
@testable import KaruCore

@Suite("October optimizations", .serialized)
@MainActor
struct OptimizationTests {
    init() { _ = NSApplication.shared }
    @Test func orderedListRenumbersFollowingSiblings() throws {
        let text = "1. one\n2. two\n3. three\n4. four\n5. five"
        let caret = (text as NSString).range(of: "three").upperBound
        let edit = try #require(TodoEngine.continueOrderedList(text: text, caret: caret))
        #expect(edit.text == "1. one\n2. two\n3. three\n4. \n5. four\n6. five")
        #expect(edit.selection.location == caret + 4)
    }
    @Test func orderedListPreservesNestedAndIndependentLists() throws {
        let text = "8. 你好😀\r\n  1. child\r\n9. next\r\n10. last\r\n\r\n1. separate"
        let caret = (text as NSString).range(of: "\r\n").location
        let edit = try #require(TodoEngine.continueOrderedList(text: text, caret: caret))
        #expect(edit.text == "8. 你好😀\r\n9. \r\n  1. child\r\n10. next\r\n11. last\r\n\r\n1. separate")
        let split = try #require(TodoEngine.continueOrderedList(text: "1. abcd\n2. next", caret: 5))
        #expect(split.text == "1. ab\n2. cd\n3. next")
        #expect(TodoEngine.continueOrderedList(text: "1. \n2. next", caret: 3) == nil)
        #expect(TodoEngine.continueOrderedList(text: "1. text\n", caret: 8) == nil)
    }
    @Test func scratchpadRenumberIsOneUndoStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KaruList-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = ScratchpadController(store: ScratchpadStore(directory: dir))
        controller.show()
        defer { controller.hide() }
        let tv = try #require(controller.diagnosticTextView)
        let original = "1. one\n2. two\n3. three"
        tv.string = original
        tv.setSelectedRange(NSRange(location: 13, length: 0))
        tv.insertNewline(nil)
        #expect(tv.string == "1. one\n2. two\n3. \n4. three")
        let undo = try #require(tv.undoManager)
        undo.undo()
        #expect(tv.string == original)
        undo.redo()
        #expect(tv.string == "1. one\n2. two\n3. \n4. three")
    }
    private func kind(_ word: String, in line: String, tokens: [(range: NSRange, kind: TokenKind)]) -> TokenKind? {
        let range = (line as NSString).range(of: word)
        return tokens.first { NSLocationInRange(range.location, $0.range) }?.kind
    }
    @Test func pythonFStringsDistinguishExpressionsFromLiterals() {
        let language = PythonLanguage.make()
        let line = #"s = f"{{literal}} {name} {len(items) + 2} {value!r:>{width}.{precision}f}" # comment"#
        let tokens = language.tokenize(line: line)
        for word in ["name", "items", "value", "width", "precision"] {
            #expect(kind(word, in: line, tokens: tokens) == .symbolVariable)
        }
        #expect(kind("literal", in: line, tokens: tokens) == .string)
        #expect(kind("len", in: line, tokens: tokens) == .builtin)
        #expect(kind("2", in: line, tokens: tokens) == .number)
        #expect(kind("# comment", in: line, tokens: tokens) == .comment)
        let plain = #"r"{name}" + "{value}""#
        #expect(language.tokenize(line: plain).allSatisfy { $0.kind == .string })
    }
    @Test func pythonNestedQuotesAndMultilineFStrings() {
        let language = PythonLanguage.make()
        let nested = #"f"{data["key"]} {f'{other}'} { {'x': value} }""#
        let tokens = language.tokenize(line: nested)
        for variable in ["data", "other", "value"] { #expect(kind(variable, in: nested, tokens: tokens) == .symbolVariable) }
        #expect(kind("key", in: nested, tokens: tokens) == .string)
        let source = "# ignore \"\"\"\nx = rf\"\"\"hello\n你好 {name}\n\"\"\"\ny = 2\n"
        let offset = (source as NSString).range(of: "你好").location
        var state = PythonTokenizer.state(in: source as NSString, before: offset, language: language)
        let body = "你好 {name}\n"
        #expect(kind("name", in: body, tokens: PythonTokenizer.scan(body, language: language, state: &state)) == .symbolVariable)
        _ = PythonTokenizer.scan("\"\"\"\n", language: language, state: &state)
        let tail = "y = 2\n"
        #expect(kind("2", in: tail, tokens: PythonTokenizer.scan(tail, language: language, state: &state)) == .number)
        #expect(state.frames.isEmpty)
    }
    @Test func pythonScrollCheckpointInvalidatesAfterEditingPrefix() {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let scroll = NSScrollView(frame: frame)
        let tv = EditorTextView(frame: frame)
        tv.isVerticallyResizable = true
        tv.textContainer!.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        tv.string = "f\"\"\"\n" + String(repeating: "literal text\n", count: 30000) + "{name}\n\"\"\""
        let engine = HighlightEngine(textView: tv, scrollView: scroll)
        let hub = TextStorageObserverHub()
        hub.add(engine)
        tv.textStorage!.delegate = hub
        engine.setLanguage(identifier: "python")
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        let offset = (tv.string as NSString).range(of: "name", options: .backwards).location
        tv.scrollRangeToVisible(NSRange(location: offset, length: 0))
        engine.appearanceDidChange()
        let before = tv.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
        #expect(before === HighlightTheme().color(for: .symbolVariable))
        tv.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: "r")
        engine.appearanceDidChange()
        let after = tv.layoutManager!.temporaryAttribute(.foregroundColor, atCharacterIndex: offset, effectiveRange: nil) as? NSColor
        #expect(after === HighlightTheme().color(for: .string))
    }

    private func settings() -> (ShortcutSettings, () -> Void) {
        let suite = "KaruShortcutTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (ShortcutSettings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }
    @Test func shortcutCaptureIgnoresCapsLockAndDisplaysFunctionKeys() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .capsLock],
                                    timestamp: 0, windowNumber: 0, context: nil, characters: "S",
                                    charactersIgnoringModifiers: "S", isARepeat: false, keyCode: 1)!
        #expect(ShortcutStroke(event: event) == ShortcutStroke("s", .command))
        #expect(ShortcutStroke(String(UnicodeScalar(NSF1FunctionKey)!), .command).display == "⌘F1")
    }
    @Test func shortcutCatalogCoversMenuParametersAndNonMenuCommands() {
        let (settings, clean) = settings(); defer { clean() }
        let commands = settings.commands
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(commands.filter { $0.action == "selectLanguage:" }.count == SupportedLanguage.all.count)
        #expect(commands.contains { $0.id == "scratchpad.pin" })
        #expect(commands.contains { $0.id == "editor.insertLineBelow" })
        #expect(commands.contains { $0.scope == .global })
    }
    @Test func shortcutOverridesPersistClearAndReset() throws {
        let (settings, clean) = settings(); defer { clean() }
        let command = try #require(settings.commands.first { $0.action == "formatDocument:" })
        let binding = [ShortcutStroke("9", [.command, .control, .option])]
        #expect(settings.set(binding, for: command).isEmpty)
        #expect(ShortcutSettings(defaults: settings.defaults).binding(for: command) == binding)
        let menu = MainMenu.build(applyShortcuts: false)
        settings.apply(to: menu)
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
        let item = try #require(items(menu).first { ShortcutSettings.id(for: $0) == command.id })
        #expect(item.keyEquivalent == "9")
        #expect(item.keyEquivalentModifierMask == [.command, .control, .option])
        #expect(settings.set([], for: command).isEmpty)
        #expect(ShortcutSettings(defaults: settings.defaults).binding(for: command).isEmpty)
        #expect(settings.reset(command).isEmpty)
        #expect(settings.binding(for: command) == command.defaultBinding)
    }
    @Test func shortcutConflictsRespectScopeAndChordPrefixes() throws {
        let (settings, clean) = settings(); defer { clean() }
        let format = try #require(settings.commands.first { $0.action == "formatDocument:" })
        let save = try #require(settings.commands.first { $0.action == "saveDocument:" })
        #expect(settings.set(settings.binding(for: save), for: format).contains { $0.id == save.id })
        #expect(!settings.set([ShortcutStroke("k", .command)], for: format).isEmpty)
        let pin = try #require(settings.commands.first { $0.id == "scratchpad.pin" })
        #expect(settings.set(pin.defaultBinding, for: pin).isEmpty) // editor palette has the same key
        let global = try #require(settings.commands.first { $0.scope == .global })
        #expect(!settings.set([ShortcutStroke("s", .command, keyCode: 1)], for: global).isEmpty)
        #expect(settings.set([], for: global).isEmpty)
        #expect(!HotKeyCenter.isEnabled(in: settings.defaults))
        settings.resetAll()
        #expect(HotKeyCenter.isEnabled(in: settings.defaults))
    }
    @Test func shortcutRouterHonorsChangesAndTimesOutPrefixes() throws {
        let (settings, clean) = settings(); defer { clean() }
        let router = ShortcutRouter()
        let fold = try #require(settings.commands.first { $0.action == "foldAll:" })
        if case .prefix = router.resolve(ShortcutStroke("k", .command), scope: .editor, settings: settings, now: 1) {} else { Issue.record("Prefix not consumed") }
        if case .command(let command) = router.resolve(ShortcutStroke("0", .command), scope: .editor, settings: settings, now: 2) { #expect(command.id == fold.id) } else { Issue.record("Chord not dispatched") }
        _ = router.resolve(ShortcutStroke("k", .command), scope: .editor, settings: settings, now: 4)
        if case .command(let command) = router.resolve(ShortcutStroke("0", .command), scope: .editor, settings: settings, now: 7) { #expect(command.action == "actualSize:") } else { Issue.record("Expired chord swallowed zoom") }
        #expect(settings.set([], for: fold).isEmpty)
        _ = router.resolve(ShortcutStroke("k", .command), scope: .editor, settings: settings, now: 8)
        if case .command(let command) = router.resolve(ShortcutStroke("0", .command), scope: .editor, settings: settings, now: 9) { #expect(command.id != fold.id) }
    }
}
