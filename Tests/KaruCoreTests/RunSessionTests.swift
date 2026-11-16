import AppKit
import Foundation
import Testing
@testable import KaruCore

// T16.3b — "run current buffer" UI: failure messages, the per-window session
// (resolve → prepare → run → panel), stdin, stop-and-rerun, lifecycle and
// module gating, the Run menu / shortcut catalog, the output panel's bounded
// storage and the Settings › Run window. Processes are /bin/sh and /bin/cat
// through an injected preparer, so no language toolchain is needed.
//
// The process-spawning suites are nested in `RunProcessTests` (which is
// `.serialized`) so they never overlap with its `stopAll` /
// `activeProcessCount == 0` checks, which are app-wide.

// MARK: - Helpers

private func isolatedDefaults() -> UserDefaults {
    let name = "RunSessionTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private let shellEnvironment: [String: String] = {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("KARU_") }
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env
}()

/// A prepared plan that runs `script` with /bin/sh (or `/bin/cat` when
/// `cat` is set) in a fresh temp directory, labelled as `language`.
private func fakePlan(_ language: RunnableLanguage, script: String, cat: Bool = false) -> RunPlan {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruRunSessionTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let run = cat
        ? RunCommand(executable: "/bin/cat", arguments: [], workingDirectory: dir)
        : RunCommand(executable: "/bin/sh", arguments: ["-c", script], workingDirectory: dir)
    return RunPlan(language: language, directory: dir, sourceFileName: "main.sh", sourceText: script,
                   compile: nil, run: run, environment: shellEnvironment)
}

/// Thread-safe record of what the injected preparer was asked to run.
private final class PrepareLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(RunnableLanguage, String)] = []
    func record(_ language: RunnableLanguage, _ text: String) {
        lock.lock(); _calls.append((language, text)); lock.unlock()
    }
    var calls: [(RunnableLanguage, String)] { lock.lock(); defer { lock.unlock() }; return _calls }
}

@MainActor
private func editorTextView(of controller: EditorWindowController) -> NSTextView? {
    func find(_ view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let hit = sub as? EditorTextView { return hit }
            if let hit = find(sub) { return hit }
        }
        return nil
    }
    return controller.window?.contentView.flatMap(find)
}

@MainActor
private func makeWindow(text: String, prepare: @escaping RunSessionController.Prepare,
                        defaults: UserDefaults = isolatedDefaults()) -> EditorWindowController {
    let controller = EditorWindowController()
    // Keep window bookkeeping away from the user's real stores.
    controller.sessionStore = SessionStore(defaults: defaults)
    controller.draftStore = DraftStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruRunSessionDrafts-\(UUID().uuidString)", isDirectory: true))
    controller.runModuleSettings = ModuleSettings(defaults: defaults, center: NotificationCenter())
    controller.runPrepare = prepare
    editorTextView(of: controller)?.string = text
    return controller
}

@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
private func panelText(_ controller: EditorWindowController) -> String {
    controller.runSession?.panel?.outputTextView.string ?? ""
}

/// The localized forms of `key` in every UI language, split at `marker` so
/// a test can match the part before a run-dependent value (the duration).
private func localizedPrefixes(_ key: L10nKey, _ args: CVarArg..., marker: String = "§") -> [String] {
    AppLanguage.allCases.map { language in
        let full = String(format: L10n.table(for: language)[key]!, arguments: args + [marker])
        return full.components(separatedBy: marker)[0]
    }
}

private func allLanguages(_ key: L10nKey) -> [String] {
    AppLanguage.allCases.map { L10n.string(key, language: $0) }
}

private func color(in storage: NSTextStorage, of needle: String) -> NSColor? {
    let range = (storage.string as NSString).range(of: needle)
    guard range.location != NSNotFound else { return nil }
    return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
}

// MARK: - Pure messages

@Suite("Run messages")
struct RunMessagesTests {
    static let allFailures: [RunFailure] = [
        .unrecognized, .notExecutable("sql"), .notExecutable("weird"), .plainTextNotExecutable,
        .toolNotFound("node"), .toolchainNotInstalled("go"), .customToolInvalid("/opt/x"),
        .customToolInvalid(""), .developerToolsMissing("clang"), .javaRuntimeMissing,
        .workspaceFailed("disk full"), .launchFailed("ENOENT"),
    ]

    @Test func everyFailureHasAnActionableMessageInAllLanguages() {
        for failure in Self.allFailures {
            for language in AppLanguage.allCases {
                let message = RunMessages.failure(failure, language: language)
                #expect(!message.isEmpty, "\(failure) / \(language)")
                #expect(!message.contains("%@") && !message.contains("%d"), "\(failure) / \(language)")
            }
        }
        // Attached values reach the message.
        #expect(RunMessages.failure(.notExecutable("sql"), language: .zhHans).hasPrefix("SQL "))
        #expect(RunMessages.failure(.notExecutable("weird"), language: .en).hasPrefix("weird "))
        #expect(RunMessages.failure(.toolNotFound("node"), language: .zhHans).contains("node"))
        #expect(RunMessages.failure(.toolNotFound("node"), language: .zhHans).contains("设置 › 运行"))
        #expect(RunMessages.failure(.toolchainNotInstalled("go"), language: .en).contains("Go"))
        #expect(RunMessages.failure(.developerToolsMissing("clang"), language: .ja).contains("clang"))
        #expect(RunMessages.failure(.customToolInvalid("/opt/x"), language: .en).contains("/opt/x"))
        #expect(RunMessages.failure(.unrecognized, language: .zhHans).contains("无法识别语言"))
    }

    @Test func completionLines() {
        func result(_ completion: RunCompletion, stopped: Bool = false) -> RunResult {
            RunResult(completion: completion, duration: 0.4234, wasStopped: stopped)
        }
        #expect(RunMessages.completion(result(.finished(.exited(3))), language: .zhHans) == "进程结束 · 退出码 3 · 0.42 s")
        #expect(RunMessages.completion(result(.finished(.signaled(9))), language: .zhHans).hasPrefix("被信号 9 终止"))
        #expect(RunMessages.completion(result(.compileFailed(.exited(1))), language: .zhHans) == "编译失败 · 退出码 1")
        #expect(RunMessages.completion(result(.finished(.signaled(15)), stopped: true), language: .zhHans) == "已停止")
        #expect(RunMessages.completion(result(.compileFailed(.signaled(15)), stopped: true), language: .zhHans) == "已停止")
        #expect(RunMessages.completion(result(.cancelled), language: .zhHans) == "已取消")
        #expect(RunMessages.completion(result(.launchFailed(.launchFailed("x"))), language: .en).contains("x"))
        for language in AppLanguage.allCases {
            for origin in [ToolOrigin.custom, .managed, .loginPath, .systemPath, .fixed] {
                #expect(!RunMessages.origin(origin, language: language).isEmpty)
            }
        }
        #expect(RunMessages.header(language: .cpp, toolPath: "/usr/bin/clang++") == "▶ C++ · /usr/bin/clang++")
    }
}

// MARK: - Output panel (no processes)

@Suite("Run output panel")
@MainActor
struct RunOutputPanelTests {
    @Test func streamsGetTheirColorsAndAppendIsIncremental() {
        let panel = RunOutputPanel()
        var buffer = RunOutputBuffer(capacity: 1_000)
        let chunks = [RunOutputChunk(stream: .system, text: "▶ head\n"),
                      RunOutputChunk(stream: .stdout, text: "out\n"),
                      RunOutputChunk(stream: .stderr, text: "err\n")]
        for chunk in chunks { buffer.append(chunk) }
        panel.append(chunks, buffer: buffer)
        let storage = panel.outputTextView.textStorage!
        #expect(storage.string == "▶ head\nout\nerr\n")
        #expect(color(in: storage, of: "out") == .labelColor)
        #expect(color(in: storage, of: "err") == .systemRed)
        #expect(color(in: storage, of: "head") == .secondaryLabelColor)
        #expect(!panel.outputTextView.isEditable)
        #expect(panel.outputTextView.isSelectable)
        #expect(!panel.outputTextView.isRichText)
        #expect(panel.outputText == storage.string)
    }

    @Test func truncationAddsTheNoteAndStorageStaysBoundedByTheBuffer() {
        let panel = RunOutputPanel()
        var buffer = RunOutputBuffer(capacity: 64)
        let storage = panel.outputTextView.textStorage!
        let note = L10n.t(.runOutputTruncated) + "\n"
        for i in 0..<200 {
            let chunk = RunOutputChunk(stream: i % 3 == 0 ? .stderr : .stdout, text: "line \(i) 中\n")
            buffer.append(chunk)
            panel.append([chunk], buffer: buffer)
            if buffer.isTruncated {
                #expect(panel.showsTruncationNote)
                #expect(storage.string == note + buffer.text, "after chunk \(i)")
            } else {
                #expect(storage.string == buffer.text)
            }
        }
        #expect(buffer.isTruncated)
        #expect(storage.string.hasPrefix(note))
        #expect(color(in: storage, of: note.trimmingCharacters(in: .newlines)) == .secondaryLabelColor)
        #expect((storage.string as NSString).length <= (note as NSString).length + 64)
        // Clear empties both; the note goes away with the flag.
        buffer.clear()
        panel.render(buffer)
        #expect(storage.length == 0)
        #expect(!panel.showsTruncationNote)
    }

    @Test func inputRowOnlyWhileAcceptingInput() {
        let panel = RunOutputPanel()
        #expect(!panel.isInputRowVisible)
        panel.update(isActive: true, acceptsInput: false, info: "Python · preparing", status: .preparing, isTruncated: false)
        #expect(!panel.isInputRowVisible)
        panel.update(isActive: true, acceptsInput: true, info: "Python · /bin/sh", status: .running, isTruncated: false)
        #expect(panel.isInputRowVisible)
        panel.update(isActive: false, acceptsInput: false, info: "", status: .exited(0), isTruncated: false)
        #expect(!panel.isInputRowVisible)
    }
}

// MARK: - Menu / shortcut catalog

@Suite("Run menu")
@MainActor
struct RunMenuTests {
    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] }
    }

    @Test func runMenuFollowsLanguageMenuWithItsShortcuts() throws {
        let menu = MainMenu.build(applyShortcuts: false)
        let titles = menu.items.compactMap { $0.submenu?.title }
        let languageIndex = try #require(titles.firstIndex(of: L10n.t(.menuLanguage)))
        #expect(titles.indices.contains(languageIndex + 1))
        let runMenu = try #require(menu.items[languageIndex + 1].submenu)
        #expect(runMenu.title == L10n.t(.menuRun))
        func item(_ action: Selector) -> NSMenuItem? { runMenu.items.first { $0.action == action } }
        let run = try #require(item(#selector(EditorWindowController.runCode(_:))))
        let stop = try #require(item(#selector(EditorWindowController.stopRun(_:))))
        let output = try #require(item(#selector(EditorWindowController.toggleRunOutput(_:))))
        #expect(run.keyEquivalent == "r" && run.keyEquivalentModifierMask == [.command])
        #expect(stop.keyEquivalent == "." && stop.keyEquivalentModifierMask == [.command])
        #expect(output.keyEquivalent == "y" && output.keyEquivalentModifierMask == [.command, .shift])

        // No other menu item uses these equivalents.
        let strokes = Set([ShortcutStroke("r", .command), ShortcutStroke(".", .command),
                           ShortcutStroke("y", [.command, .shift])].map { "\($0.key)|\($0.modifiers)" })
        let clashes = items(menu).filter { item in
            guard !item.keyEquivalent.isEmpty, item.menu !== runMenu else { return false }
            let stroke = ShortcutStroke(item.keyEquivalent, item.keyEquivalentModifierMask)
            return strokes.contains("\(stroke.key)|\(stroke.modifiers)")
        }
        #expect(clashes.isEmpty, "\(clashes.map(\.title))")
    }

    @Test func runCommandsAreInTheShortcutCatalogWithoutConflicts() throws {
        let defaults = isolatedDefaults()
        let settings = ShortcutSettings(defaults: defaults)
        let expected: [(String, ShortcutStroke)] = [
            ("menu.runCode:", ShortcutStroke("r", .command)),
            ("menu.stopRun:", ShortcutStroke(".", .command)),
            ("menu.toggleRunOutput:", ShortcutStroke("y", [.command, .shift])),
        ]
        for (id, stroke) in expected {
            let command = try #require(settings.commands.first { $0.id == id }, "\(id)")
            #expect(command.scope == .editor)
            #expect(command.defaultBinding == [stroke])
            #expect(settings.conflicts([stroke], for: command).isEmpty, "\(id)")
            #expect(command.title.hasPrefix(L10n.t(.menuRun) + " ▸ "))
        }
    }
}

// MARK: - Settings › Run

@Suite("Run settings window")
@MainActor
struct RunPreferencesTests {
    @Test func rowsBindToRunSettingsAndDetectUsesTheLocator() async throws {
        let defaults = isolatedDefaults()
        let center = NotificationCenter()
        let settings = RunSettings(defaults: defaults, center: center)
        let probes = ToolchainProbes(isExecutable: { $0 == "/opt/tools/python3" },
                                     developerToolsInstalled: { true }, javaRuntimeInstalled: { true })
        let loginPath = LoginShellPath(shell: "/bin/zsh", timeout: 1, runner: { _, _, _ in nil })
        // T16.5: an isolated (empty) toolchain store, so no real install is seen.
        let toolchainRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: toolchainRoot) }
        let manager = ToolchainManager(store: ToolchainStore(root: toolchainRoot))
        let controller = RunPreferencesController(settings: settings, center: center, makeLocator: {
            ToolchainLocator(managed: NoManagedToolchains(), loginPath: loginPath, probes: probes)
        }, manager: manager, probes: probes, installCommandLineTools: {})
        defer { controller.pageWillDeactivate() }

        #expect(controller.rows.map(\.language) == RunnableLanguage.allCases)
        for row in controller.rows {
            #expect(row.sourcePopup.numberOfItems == ToolchainSource.allCases.count)
            // The custom path row only shows for the Custom source.
            #expect(!row.pathField.isEnabled && !row.chooseButton.isEnabled)
            #expect(row.pathField.isHiddenOrHasHiddenAncestor && row.chooseButton.isHiddenOrHasHiddenAncestor)
            // T16.5 fills the slot (managed toolchain / CLT state); Bash stays empty.
            #expect(row.managedSlot.arrangedSubviews.isEmpty == (row.language == .bash))
            #expect(row.managedSlot.identifier?.rawValue == "run.managedSlot." + row.language.rawValue)
        }

        let python = try #require(controller.row(for: .python))
        python.sourcePopup.selectItem(at: ToolchainSource.allCases.firstIndex(of: .custom)!)
        _ = python.sourcePopup.target?.perform(python.sourcePopup.action, with: python.sourcePopup)
        #expect(settings.source(for: .python) == .custom)
        #expect(python.pathField.isEnabled && python.chooseButton.isEnabled)
        #expect(!python.pathField.isHiddenOrHasHiddenAncestor && !python.chooseButton.isHiddenOrHasHiddenAncestor)

        python.pathField.stringValue = "/opt/tools/python3"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                         object: python.pathField))
        #expect(settings.customPath(for: .python) == "/opt/tools/python3")

        controller.detect(.python)
        #expect(await waitUntil(timeout: 5) {
            if case .resolved = controller.detections[.python] { return true } else { return false }
        })
        #expect(python.resultLabel.stringValue.hasPrefix("/opt/tools/python3 · "))

        // A broken custom path reports the localized failure.
        settings.setCustomPath("/nope/python3", for: .python)
        controller.detect(.python)
        #expect(await waitUntil(timeout: 5) {
            if case .failed = controller.detections[.python] { return true } else { return false }
        })
        #expect(python.resultLabel.stringValue == RunMessages.failure(.customToolInvalid("/nope/python3")))

        // Flags fields write the C / C++ flags.
        controller.cppFlagsField.stringValue = "-std=c++17 -Wall"
        controller.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                         object: controller.cppFlagsField))
        #expect(settings.extraFlags(for: .cpp) == ["-std=c++17", "-Wall"])
        #expect(settings.flagsString(for: .c).isEmpty)
    }

    /// User request (2026-11-12): the language list follows Settings › Language List.
    @Test func rowsFollowLanguageList() {
        let suite = "RunPreferencesLanguageList-\(UUID().uuidString)"
        let listDefaults = UserDefaults(suiteName: suite)!
        defer { listDefaults.removePersistentDomain(forName: suite) }
        let languageMenu = LanguageMenuSettings(defaults: listDefaults, center: NotificationCenter())
        languageMenu.setVisible(false, for: "typescript")
        languageMenu.setVisible(false, for: "cpp")
        let toolchainRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunPreferencesList-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: toolchainRoot) }
        let probes = ToolchainProbes(isExecutable: { _ in false },
                                     developerToolsInstalled: { true }, javaRuntimeInstalled: { true })
        let controller = RunPreferencesController(
            settings: RunSettings(defaults: isolatedDefaults(), center: NotificationCenter()),
            center: NotificationCenter(),
            makeLocator: { ToolchainLocator(managed: NoManagedToolchains(), probes: probes) },
            manager: ToolchainManager(store: ToolchainStore(root: toolchainRoot)),
            probes: probes, languageMenu: languageMenu, installCommandLineTools: {})
        defer { controller.pageWillDeactivate() }

        #expect(!controller.isRowVisible(.typescript) && !controller.isRowVisible(.cpp))
        #expect(controller.isRowVisible(.javascript) && controller.isRowVisible(.c)
                && controller.isRowVisible(.python))
        #expect(!controller.listedLanguages.contains(.typescript) && !controller.listedLanguages.contains(.cpp))

        languageMenu.setVisible(true, for: "cpp")
        controller.applyLanguageVisibility()
        #expect(controller.isRowVisible(.cpp))
        #expect(controller.listedLanguages.contains(.cpp))
    }
}

// MARK: - Panel layout (no processes)

@Suite("Run panel layout")
@MainActor
struct RunPanelLayoutTests {
    @Test func defaultHeightDragClampAndPerWindowMemory() throws {
        let controller = makeWindow(text: "x\n", prepare: { _, _, _, _ in .failure(.unrecognized) })
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let editor = try #require(controller.runPanelHost?.editor)
        let editorHeight = editor.frame.height
        #expect(editorHeight > 300)

        controller.toggleRunOutput(nil) // Show Output creates session + panel, nothing runs
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(!session.isActive)
        content.layoutSubtreeIfNeeded()
        #expect(abs(panel.frame.height - (editorHeight * 0.3).rounded()) <= 1)
        #expect(panel.frame.minY < editor.frame.minY) // below the editor (non-flipped stack)

        let total = panel.frame.height + editor.frame.height
        panel.divider.onDragBegan?()
        panel.divider.onDrag?(40)
        content.layoutSubtreeIfNeeded()
        #expect(abs(panel.frame.height - ((editorHeight * 0.3).rounded() + 40)) <= 1)
        panel.divider.onDrag?(10_000)
        content.layoutSubtreeIfNeeded()
        #expect(abs(editor.frame.height - RunSessionController.minimumEditorHeight) <= 1)
        #expect(abs(panel.frame.height + editor.frame.height - total) <= 1)
        panel.divider.onDrag?(-10_000)
        content.layoutSubtreeIfNeeded()
        #expect(abs(panel.frame.height - RunSessionController.minimumPanelHeight) <= 1)
        panel.divider.onDrag?(60 - (editorHeight * 0.3).rounded() + 100)
        content.layoutSubtreeIfNeeded()
        let chosen = panel.frame.height

        // Closing releases the session; the next panel in this window reuses the height.
        panel.closeButton.performClick(nil)
        #expect(controller.runSession == nil)
        content.layoutSubtreeIfNeeded()
        #expect(abs(editor.frame.height - editorHeight) <= 1) // editor got its space back
        controller.toggleRunOutput(nil)
        content.layoutSubtreeIfNeeded()
        #expect(abs((controller.runSession?.panel?.frame.height ?? 0) - chosen) <= 1)
    }
}

// MARK: - Session (spawns /bin/sh, /bin/cat)

extension RunProcessTests {
    @Suite("Run session")
    @MainActor
    struct RunSessionTests {
        @Test func runShowsOutputWithStreamsHeaderAndExitLine() async throws {
            let controller = makeWindow(text: "print('x')\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "echo out1; echo err1 >&2; exit 3"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "python")
            #expect(controller.runSession == nil) // nothing allocated before the first run

            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(session.panel != nil)
            #expect(await waitUntil { !session.isActive && panelText(controller).contains("3") })
            let storage = try #require(session.panel?.outputTextView.textStorage)
            let text = storage.string
            #expect(text.hasPrefix("▶ Python · /bin/sh\n"))
            #expect(text.contains("out1\n") && text.contains("err1\n"))
            #expect(localizedPrefixes(.runExited, 3).contains { text.contains($0) })
            #expect(text.hasSuffix(" s\n"))
            #expect(color(in: storage, of: "out1") == .labelColor)
            #expect(color(in: storage, of: "err1") == .systemRed)
            #expect(color(in: storage, of: "▶ Python") == .secondaryLabelColor)
            // The panel mirrors the runner's bounded buffer.
            #expect(text == session.runner?.output.text)
        }

        @Test func autoPlainTextCorrectsLanguageButStaysAuto() async throws {
            let source = "#!/usr/bin/env python3\nimport sys\n\ndef main():\n    print('hi')\n\nmain()\n"
            let sniffed = try #require(LanguageSniffer.sniff(source))
            #expect(RunnableLanguage(identifier: sniffed) != nil)
            let log = PrepareLog()
            let controller = makeWindow(text: source, prepare: { language, text, _, _ in
                log.record(language, text)
                return .success(fakePlan(language, script: "echo ok"))
            })
            defer { controller.close() }
            #expect(controller.isLanguageAuto)
            #expect(controller.currentLanguageIdentifierValue == "")

            controller.runCode(nil)
            #expect(controller.currentLanguageIdentifierValue == sniffed)
            #expect(controller.isLanguageAuto)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { !session.isActive && !log.calls.isEmpty })
            #expect(log.calls.first?.0.identifier == sniffed)
            #expect(log.calls.first?.1 == source)
        }

        @Test func manualLanguageIsNeverRewritten() async throws {
            let log = PrepareLog()
            let controller = makeWindow(text: "#!/bin/bash\necho hi\nfor i in 1 2; do echo $i; done\n",
                                        prepare: { language, text, _, _ in
                log.record(language, text)
                return .success(fakePlan(language, script: "echo ok"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "javascript")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { !session.isActive && !log.calls.isEmpty })
            #expect(log.calls.first?.0 == .javascript)
            #expect(controller.currentLanguageIdentifierValue == "javascript")
            #expect(!controller.isLanguageAuto)

            // Manual Plain Text: refused with the localized message, still Plain Text.
            controller.chooseLanguage(identifier: "")
            controller.runCode(nil)
            #expect(allLanguages(.runFailPlainText).contains { panelText(controller).contains($0) })
            #expect(controller.currentLanguageIdentifierValue == "")
            #expect(!controller.isLanguageAuto)
            #expect(log.calls.count == 1)
        }

        @Test func prepareFailureIsShownInThePanel() async throws {
            let controller = makeWindow(text: "console.log(1)\n", prepare: { _, _, _, _ in
                .failure(.toolNotFound("node"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "javascript")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { !session.isActive })
            let text = panelText(controller)
            #expect(AppLanguage.allCases.contains { text.contains(RunMessages.failure(.toolNotFound("node"), language: $0)) })
            let storage = try #require(session.panel?.outputTextView.textStorage)
            #expect(color(in: storage, of: "node") == .secondaryLabelColor)
        }

        @Test func runWhileRunningStopsThenReruns() async throws {
            let log = PrepareLog()
            let controller = makeWindow(text: "echo\n", prepare: { language, _, _, _ in
                log.record(language, "")
                let first = log.calls.count == 1
                return .success(fakePlan(language, script: first ? "echo first; exec /bin/sleep 30" : "echo second"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { panelText(controller).contains("first") })
            #expect(session.isRunning)
            #expect(controller.isRunActive)

            controller.runCode(nil) // stop-and-rerun
            #expect(await waitUntil { log.calls.count == 2 && !session.isActive && panelText(controller).contains("second") })
            #expect(!panelText(controller).contains("first"))
            #expect(localizedPrefixes(.runExited, 0).contains { panelText(controller).contains($0) })
        }

        @Test func stopEndsTheRunWithStoppedLine() async throws {
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "echo ready; exec /bin/sleep 30"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { panelText(controller).contains("ready") })
            let item = NSMenuItem(title: "", action: #selector(EditorWindowController.stopRun(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(item))
            controller.stopRun(nil)
            #expect(await waitUntil { !session.isActive })
            #expect(allLanguages(.runStopped).contains { panelText(controller).hasSuffix($0 + "\n") })
            #expect(!controller.validateMenuItem(item))
        }

        @Test func stopWhilePreparingCancels() async throws {
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                Thread.sleep(forTimeInterval: 0.5)
                return .success(fakePlan(language, script: "echo should-not-run"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(session.isPreparing && controller.isRunActive)
            controller.stopRun(nil)
            #expect(!session.isActive)
            #expect(allLanguages(.runCancelled).contains { panelText(controller).contains($0) })
            try? await Task.sleep(nanoseconds: 800_000_000)
            #expect(!session.isRunning)
            #expect(!panelText(controller).contains("should-not-run"))
        }

        @Test func stdinFieldSendsLinesToCat() async throws {
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "", cat: true))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            let panel = try #require(session.panel)
            #expect(await waitUntil { session.isRunning })
            #expect(panel.isInputRowVisible)

            panel.inputField.stringValue = "hello 世界"
            panel.inputSubmitted()
            #expect(panel.inputField.stringValue.isEmpty)
            #expect(await waitUntil {
                session.runner?.output.segments.contains { $0.stream == .stdout && $0.text.contains("hello 世界\n") } ?? false
            })
            #expect(panelText(controller).contains("› hello 世界\n"))

            session.sendEOF()
            #expect(!panel.inputField.isEnabled)
            #expect(await waitUntil { !session.isActive })
            #expect(localizedPrefixes(.runExited, 0).contains { panelText(controller).contains($0) })
            #expect(!panel.isInputRowVisible)
        }

        @Test func panelIsLazyHidesKeepsRunAndCloseReleases() async throws {
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "echo started; exec /bin/sleep 30"))
            })
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            #expect(controller.runSession == nil)

            let toggle = NSMenuItem(title: "", action: #selector(EditorWindowController.toggleRunOutput(_:)), keyEquivalent: "")
            #expect(controller.validateMenuItem(toggle))
            #expect(toggle.title == L10n.t(.menuRunShowOutput))

            controller.runCode(nil)
            // Held weakly so the test itself never keeps the session alive.
            weak let session = controller.runSession
            #expect(session != nil)
            weak let firstPanel = session?.panel
            let stack = try #require(firstPanel?.superview as? NSStackView)
            #expect(stack.arrangedSubviews.contains { $0 === firstPanel })
            #expect(await waitUntil { panelText(controller).contains("started") })
            #expect(controller.validateMenuItem(toggle))
            #expect(toggle.title == L10n.t(.menuRunHideOutput))

            // Hide keeps the run; showing again re-renders from the buffer.
            // (Released views go once the autorelease pool drains, hence the waits.)
            controller.toggleRunOutput(nil)
            #expect(session?.panel == nil)
            #expect(!stack.arrangedSubviews.contains { $0 is RunOutputPanel })
            #expect(await waitUntil { firstPanel == nil })
            #expect(session?.isRunning == true)
            controller.toggleRunOutput(nil)
            #expect(panelText(controller).contains("started"))

            // Close (×) stops the run and releases panel + session.
            weak let panel = session?.panel
            panel?.closeButton.performClick(nil)
            #expect(controller.runSession == nil)
            #expect(!stack.arrangedSubviews.contains { $0 is RunOutputPanel })
            #expect(await waitUntil { panel == nil && session == nil })
            #expect(await waitUntil { RunSessionController.retiringCount == 0 && CodeRunner.activeProcessCount == 0 })
        }

        @Test func windowCloseStopsTheRun() async throws {
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "echo up; exec /bin/sleep 30"))
            })
            controller.chooseLanguage(identifier: "bash")
            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { panelText(controller).contains("up") })
            let dir = try #require(session.runner?.plan?.directory)
            #expect(CodeRunner.activeProcessCount >= 1)

            controller.close()
            #expect(controller.runSession == nil)
            #expect(session.panel == nil)
            #expect(await waitUntil { CodeRunner.activeProcessCount == 0 && RunSessionController.retiringCount == 0 })
            // The stopped runner still cleaned its workspace up.
            #expect(await waitUntil(timeout: 3) { !FileManager.default.fileExists(atPath: dir.path) })
        }

        @Test func moduleOffHidesEntryPointsAndReleasesTheSession() async throws {
            let defaults = isolatedDefaults()
            let modules = ModuleSettings(defaults: defaults, center: NotificationCenter())
            let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
                .success(fakePlan(language, script: "echo on; exec /bin/sleep 30"))
            }, defaults: defaults)
            defer { controller.close() }
            controller.chooseLanguage(identifier: "bash")
            func hasRunItem() -> Bool {
                controller.window?.toolbar?.items.contains { $0.itemIdentifier == EditorToolbarController.run } ?? false
            }
            func runButton() -> NSButton? {
                controller.window?.toolbar?.items.first { $0.itemIdentifier == EditorToolbarController.run }?.view as? NSButton
            }
            let runItem = NSMenuItem(title: "", action: #selector(EditorWindowController.runCode(_:)), keyEquivalent: "")
            let stopItem = NSMenuItem(title: "", action: #selector(EditorWindowController.stopRun(_:)), keyEquivalent: "")
            let toggleItem = NSMenuItem(title: "", action: #selector(EditorWindowController.toggleRunOutput(_:)), keyEquivalent: "")
            #expect(hasRunItem())
            #expect(controller.validateMenuItem(runItem))
            #expect(!controller.validateMenuItem(stopItem))
            #expect(allLanguages(.menuRunCode).contains(runButton()?.title ?? "-"))

            controller.runCode(nil)
            let session = try #require(controller.runSession)
            #expect(await waitUntil { panelText(controller).contains("on") })
            #expect(allLanguages(.menuRunStop).contains(runButton()?.title ?? "-"))
            weak let panel = session.panel

            modules.setEnabled(false, for: .run)
            controller.runModuleDidChange()
            #expect(controller.runSession == nil)
            #expect(session.panel == nil)
            #expect(await waitUntil { panel == nil })
            #expect(!hasRunItem())
            #expect(!controller.validateMenuItem(runItem))
            #expect(!controller.validateMenuItem(stopItem))
            #expect(!controller.validateMenuItem(toggleItem))
            controller.runCode(nil) // beeps, allocates nothing
            #expect(controller.runSession == nil)
            #expect(await waitUntil { CodeRunner.activeProcessCount == 0 && RunSessionController.retiringCount == 0 })

            modules.setEnabled(true, for: .run)
            controller.runModuleDidChange()
            #expect(hasRunItem())
            #expect(controller.validateMenuItem(runItem))
            #expect(controller.runSession == nil)
        }
    }
}

// MARK: - Header status (panel only, no processes)

@MainActor
private func headerStack(of panel: RunOutputPanel) -> NSStackView? {
    panel.statusLabel.superview as? NSStackView
}

/// Header views that are shown, left to right.
@MainActor
private func visibleHeaderViews(of panel: RunOutputPanel) -> [NSView] {
    headerStack(of: panel)?.arrangedSubviews.filter { !$0.isHidden } ?? []
}

/// No two visible header views overlap and none pokes past the header.
@MainActor
private func headerOverlaps(_ panel: RunOutputPanel) -> [String] {
    guard let header = headerStack(of: panel) else { return ["no header"] }
    let views = visibleHeaderViews(of: panel)
    var problems: [String] = []
    for (a, b) in zip(views, views.dropFirst()) where a.frame.maxX > b.frame.minX + 0.5 {
        problems.append("\(a) overlaps \(b)")
    }
    if let last = views.last, last.frame.maxX > header.bounds.width + 0.5 { problems.append("past the edge") }
    return problems
}

@Suite("Run panel status")
struct RunPanelStatusTests {
    private func result(_ completion: RunCompletion, stopped: Bool = false) -> RunResult {
        RunResult(completion: completion, duration: 0.1, wasStopped: stopped)
    }

    @Test func resultsMapToStatuses() {
        #expect(RunPanelStatus(result(.finished(.exited(0)))) == .exited(0))
        #expect(RunPanelStatus(result(.finished(.exited(3)))) == .exited(3))
        #expect(RunPanelStatus(result(.finished(.signaled(9)))) == .exited(137))
        #expect(RunPanelStatus(result(.compileFailed(.exited(1)))) == .exited(1))
        #expect(RunPanelStatus(result(.finished(.signaled(15)), stopped: true)) == .stopped)
        #expect(RunPanelStatus(result(.compileFailed(.signaled(15)), stopped: true)) == .stopped)
        #expect(RunPanelStatus(result(.cancelled, stopped: true)) == .stopped)
        #expect(RunPanelStatus(result(.launchFailed(.launchFailed("x")))) == .failed)
        #expect(RunPanelStatus(result(.launchFailed(.launchFailed("x")), stopped: true)) == .failed)
    }

    @Test func symbolsTintAndTextInAllLanguages() {
        let expected: [(RunPanelStatus, String?, Bool)] = [
            (.idle, nil, false), (.preparing, "arrow.triangle.2.circlepath", false), (.running, "play.circle", false),
            (.exited(0), "checkmark.circle", false), (.exited(2), "exclamationmark.triangle", true),
            (.stopped, "stop.circle", false), (.failed, "exclamationmark.triangle", true),
        ]
        for (status, symbol, problem) in expected {
            #expect(status.symbolName == symbol, "\(status)")
            #expect(status.isProblem == problem, "\(status)")
            if let symbol { #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil) }
            for language in AppLanguage.allCases {
                let text = RunMessages.status(status, language: language)
                #expect((text == nil) == (status == .idle), "\(status) / \(language)")
                #expect(!(text ?? "").contains("%"), "\(status) / \(language)")
            }
        }
        #expect(RunMessages.status(.exited(3), language: .en) == "Exited (code 3)")
        #expect(RunMessages.status(.exited(3), language: .zhHans) == "已结束（退出码 3）")
        #expect(RunMessages.status(.exited(3), language: .ja) == "終了（終了コード 3）")
    }
}

@Suite("Run panel header")
@MainActor
struct RunPanelHeaderTests {
    @Test func headerOrderControlsAndStatusRendering() throws {
        let panel = RunOutputPanel()
        let header = try #require(headerStack(of: panel))
        #expect(header.arrangedSubviews == [header.arrangedSubviews[0], panel.statusImageView, panel.statusLabel,
                                            panel.truncatedLabel, panel.infoLabel, panel.clearButton,
                                            panel.copyButton, panel.stopRerunButton, panel.closeButton])
        #expect((header.arrangedSubviews[0] as? NSTextField)?.stringValue == L10n.t(.runOutputTitle))
        for button in [panel.clearButton, panel.copyButton, panel.stopRerunButton, panel.closeButton] {
            #expect(button.target === panel && button.action != nil)
        }
        var cleared = 0, toggled = 0, closed = 0
        panel.onClear = { cleared += 1 }
        panel.onStopOrRerun = { toggled += 1 }
        panel.onClose = { closed += 1 }
        panel.clearButton.performClick(nil)
        panel.stopRerunButton.performClick(nil)
        panel.closeButton.performClick(nil)
        #expect(cleared == 1 && toggled == 1 && closed == 1)

        // Idle: no status at all.
        #expect(panel.status == .idle)
        #expect(panel.statusImageView.isHidden && panel.statusLabel.isHidden && panel.truncatedLabel.isHidden)
        #expect(!panel.statusImageView.isAccessibilityElement())

        panel.update(isActive: true, acceptsInput: true, info: "Python · /bin/sh", status: .running, isTruncated: false)
        #expect(!panel.statusImageView.isHidden && panel.statusImageView.image != nil)
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusRunning))
        #expect(panel.statusLabel.textColor == .labelColor)
        #expect(panel.statusImageView.contentTintColor == .secondaryLabelColor)
        #expect(panel.stopRerunButton.title == L10n.t(.menuRunStop))
        #expect(panel.isInputRowVisible)

        panel.update(isActive: false, acceptsInput: false, info: "Python · /bin/sh", status: .exited(4), isTruncated: true)
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusExited, 4))
        #expect(panel.statusLabel.toolTip == L10n.t(.runStatusExited, 4))
        #expect(panel.statusImageView.contentTintColor == .systemRed)
        #expect(!panel.truncatedLabel.isHidden && panel.truncatedLabel.stringValue == L10n.t(.runStatusTruncated))
        #expect(panel.truncatedLabel.textColor == .secondaryLabelColor)
        #expect(panel.stopRerunButton.title == L10n.t(.runRerun))
        #expect(!panel.isInputRowVisible)

        panel.update(isActive: false, acceptsInput: false, info: "", status: .failed, isTruncated: false)
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusFailed))
        #expect(panel.statusImageView.contentTintColor == .systemRed)
        #expect(panel.truncatedLabel.isHidden)
    }

    @Test func truncationMarkerFollowsTheBuffer() {
        let panel = RunOutputPanel()
        var buffer = RunOutputBuffer(capacity: 32)
        for i in 0..<20 {
            let chunk = RunOutputChunk(stream: .stdout, text: "line \(i)\n")
            buffer.append(chunk)
            panel.append([chunk], buffer: buffer)
            #expect(panel.showsTruncatedStatus == buffer.isTruncated, "after chunk \(i)")
            #expect(panel.truncatedLabel.isHidden == !buffer.isTruncated)
        }
        #expect(panel.showsTruncatedStatus)
        buffer.clear()
        panel.render(buffer)
        #expect(!panel.showsTruncatedStatus && panel.truncatedLabel.isHidden)
    }

    @Test func narrowHeaderTruncatesInfoFirstThenStatus() {
        let panel = RunOutputPanel()
        panel.update(isActive: false, acceptsInput: false,
                     info: "JavaScript · /Users/someone/.local/share/karu/toolchains/node/bin/node",
                     status: .exited(137), isTruncated: true)
        let fixed: [NSView] = [panel.clearButton, panel.copyButton, panel.stopRerunButton, panel.closeButton,
                               visibleHeaderViews(of: panel)[0], panel.statusImageView]
        var sawStatusTruncate = false
        for width in stride(from: 800, through: 360, by: -20) {
            panel.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 180)
            panel.layoutSubtreeIfNeeded()
            for view in fixed {
                #expect(view.frame.width + 0.5 >= view.fittingSize.width, "\(width): \(view)")
            }
            #expect(headerOverlaps(panel).isEmpty, "\(width): \(headerOverlaps(panel))")
            let statusShort = panel.statusLabel.frame.width + 0.5 < panel.statusLabel.fittingSize.width
            let markerShort = panel.truncatedLabel.frame.width + 0.5 < panel.truncatedLabel.fittingSize.width
            if markerShort || statusShort {
                // Info has given way completely (a label bottoms out at its
                // 4 pt cell inset) before either status label does.
                #expect(panel.infoLabel.frame.width <= 4.5, "\(width)")
            }
            if statusShort {
                sawStatusTruncate = true
                #expect(panel.truncatedLabel.frame.width <= 4.5, "\(width)")
            }
        }
        // At the narrowest width tried, the status text did have to give way.
        #expect(sawStatusTruncate)
        #expect(panel.statusLabel.toolTip == L10n.t(.runStatusExited, 137))
    }
}

// Serialized and quiet language switching, as in `SettingsWindowLanguageTests`.
@Suite("Run panel header languages", .serialized)
@MainActor
struct RunPanelHeaderLanguageTests {
    private func setQuietly(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    @Test func headerFitsAtTheDefaultWidthInEveryLanguage() {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        for language in AppLanguage.allCases {
            setQuietly(language.rawValue)
            for isActive in [false, true] {
                let panel = RunOutputPanel()
                panel.update(isActive: isActive, acceptsInput: isActive, info: "JavaScript · /usr/local/bin/node",
                             status: isActive ? .preparing : .exited(137), isTruncated: true)
                // The editor window's default content width.
                panel.frame = NSRect(x: 0, y: 0, width: 800, height: 180)
                panel.layoutSubtreeIfNeeded()
                #expect(headerOverlaps(panel).isEmpty, "\(language): \(headerOverlaps(panel))")
                for view in visibleHeaderViews(of: panel) where view !== panel.infoLabel {
                    #expect(view.frame.width + 0.5 >= view.fittingSize.width,
                            "\(language) \(isActive): \((view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? "\(view)")")
                }
                #expect(panel.statusLabel.stringValue
                        == L10n.string(isActive ? .runPreparing : .runStatusExited, language: language, 137))
            }
        }
    }

    @Test func liveLanguageSwitchRerendersTheStatus() {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        setQuietly(AppLanguage.en.rawValue)
        let panel = RunOutputPanel()
        panel.update(isActive: false, acceptsInput: false, info: "", status: .stopped, isTruncated: true)
        #expect(panel.statusLabel.stringValue == "Stopped")
        #expect(panel.truncatedLabel.stringValue == "Output truncated")

        // What the `L10n.didChangeNotification` observer runs on a live switch.
        setQuietly(AppLanguage.ja.rawValue)
        panel.languageDidChange()
        #expect(panel.statusLabel.stringValue == L10n.string(.runStatusStopped, language: .ja))
        #expect(panel.statusLabel.toolTip == L10n.string(.runStatusStopped, language: .ja))
        #expect(panel.truncatedLabel.stringValue == L10n.string(.runStatusTruncated, language: .ja))
        setQuietly(AppLanguage.zhHans.rawValue)
        panel.languageDidChange()
        #expect(panel.statusLabel.stringValue == "已停止")
    }
}

// MARK: - Header status through a session

extension RunPanelLayoutTests {
    @Test func showOutputWithoutRunningHasNoStatus() throws {
        let controller = makeWindow(text: "x\n", prepare: { _, _, _, _ in .failure(.unrecognized) })
        defer { controller.close() }
        controller.toggleRunOutput(nil)
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(session.panelStatus == .idle)
        #expect(panel.status == .idle)
        #expect(panel.statusLabel.isHidden && panel.statusImageView.isHidden && panel.truncatedLabel.isHidden)
    }
}

extension RunProcessTests.RunSessionTests {
    @Test func statusFollowsARunToExitZero() async throws {
        let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
            Thread.sleep(forTimeInterval: 0.3)
            return .success(fakePlan(language, script: "", cat: true))
        })
        defer { controller.close() }
        controller.chooseLanguage(identifier: "bash")
        controller.runCode(nil)
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(panel.status == .preparing)
        #expect(panel.statusLabel.stringValue == L10n.t(.runPreparing))
        #expect(await waitUntil { panel.status == .running })
        #expect(panel.isInputRowVisible)
        session.sendEOF()
        #expect(await waitUntil { !session.isActive })
        #expect(panel.status == .exited(0))
        #expect(panel.status.symbolName == "checkmark.circle")
        #expect(panel.statusImageView.contentTintColor == .secondaryLabelColor)
        #expect(panel.truncatedLabel.isHidden)
    }

    @Test func statusShowsNonZeroExitStopAndCompilePhase() async throws {
        let log = PrepareLog()
        let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
            log.record(language, "")
            switch log.calls.count {
            case 1: return .success(fakePlan(language, script: "exit 5"))
            case 2: return .success(fakePlan(language, script: "echo ready; exec /bin/sleep 30"))
            default:
                var plan = fakePlan(language, script: "echo never")
                plan.compile = RunCommand(executable: "/bin/sh", arguments: ["-c", "exec /bin/sleep 30"],
                                          workingDirectory: plan.directory)
                return .success(plan)
            }
        })
        defer { controller.close() }
        controller.chooseLanguage(identifier: "bash")
        controller.runCode(nil)
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(await waitUntil { !session.isActive && panel.status != .preparing })
        #expect(panel.status == .exited(5))
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusExited, 5))
        #expect(panel.status.symbolName == "exclamationmark.triangle")
        #expect(panel.statusImageView.contentTintColor == .systemRed)

        // A new run resets the status; Stop shows Stopped.
        controller.runCode(nil)
        #expect(panel.status == .preparing)
        #expect(await waitUntil { panelText(controller).contains("ready") })
        #expect(panel.status == .running)
        controller.stopRun(nil)
        #expect(await waitUntil { !session.isActive })
        #expect(panel.status == .stopped)
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusStopped))

        // Compiling reads as Preparing (the process is live); stopping it reads Stopped.
        controller.runCode(nil)
        #expect(await waitUntil { session.isRunning })
        #expect(session.runner?.phase == .compiling)
        #expect(panel.status == .preparing)
        controller.stopRun(nil)
        #expect(await waitUntil { !session.isActive })
        #expect(panel.status == .stopped)
    }

    @Test func statusShowsFailuresAndStopWhilePreparing() async throws {
        let log = PrepareLog()
        let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
            log.record(language, "")
            if log.calls.count == 1 { return .failure(.toolNotFound("node")) }
            Thread.sleep(forTimeInterval: 0.5)
            return .success(fakePlan(language, script: "echo should-not-run"))
        })
        defer { controller.close() }
        controller.chooseLanguage(identifier: "javascript")
        controller.runCode(nil)
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(await waitUntil { !session.isActive })
        #expect(panel.status == .failed)
        #expect(panel.statusLabel.stringValue == L10n.t(.runStatusFailed))
        #expect(panel.statusImageView.contentTintColor == .systemRed)

        // Stop during preparation: Stopped.
        controller.runCode(nil)
        #expect(panel.status == .preparing)
        controller.stopRun(nil)
        #expect(panel.status == .stopped)

        // A resolve failure (manual Plain Text) is a failure to start too.
        controller.chooseLanguage(identifier: "")
        controller.runCode(nil)
        #expect(panel.status == .failed)
        #expect(log.calls.count == 2)
    }

    @Test func truncatedOutputShowsTheMarkerWithTheStatus() async throws {
        let controller = makeWindow(text: "x\n", prepare: { language, _, _, _ in
            .success(fakePlan(language, script: "/usr/bin/head -c 1200000 /dev/zero | /usr/bin/tr '\\0' 'a'"))
        })
        defer { controller.close() }
        controller.chooseLanguage(identifier: "bash")
        controller.runCode(nil)
        let session = try #require(controller.runSession)
        let panel = try #require(session.panel)
        #expect(await waitUntil { !session.isActive && panel.status != .preparing })
        #expect(session.runner?.output.isTruncated == true)
        #expect(panel.status == .exited(0))
        #expect(panel.showsTruncatedStatus && !panel.truncatedLabel.isHidden && !panel.statusLabel.isHidden)

        panel.clearButton.performClick(nil)
        #expect(session.runner?.output.isTruncated == false)
        #expect(!panel.showsTruncatedStatus && panel.truncatedLabel.isHidden)
        #expect(panel.status == .exited(0))
    }
}
