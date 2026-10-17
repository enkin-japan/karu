import AppKit
import Carbon.HIToolbox
import Testing
import UniformTypeIdentifiers
@testable import KaruCore

@Suite("Settings backup and default applications", .serialized)
@MainActor
struct SettingsManagementTests {
    init() { _ = NSApplication.shared }
    private func isolated() -> (UserDefaults, () -> Void) {
        let name = "KaruSettingsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }
    @Test func exportRoundTripExcludesPrivateAndSystemState() throws {
        let (source, cleanSource) = isolated(); defer { cleanSource() }
        let (target, cleanTarget) = isolated(); defer { cleanTarget() }
        source.set(18.5, forKey: EditorFontSettings.fontSizeKey)
        source.set(false, forKey: FeatureModule.highlight.defaultsKey)
        source.set(false, forKey: ScratchpadStore.pinnedKey)
        source.set(2, forKey: IndentSettings.widthKey(for: "swift"))
        source.set("ja", forKey: L10n.defaultsKey)
        source.set(["private-file.txt"], forKey: SessionStore.key)
        source.set("private-note", forKey: "scratchpad.content")
        source.set("private-value", forKey: "unknownCredential")
        source.set(["system association"], forKey: "LSHandlers")
        let model = ShortcutSettings(defaults: source)
        let command = try #require(model.commands.first { $0.action == "formatDocument:" })
        let custom = [ShortcutStroke("9", [.command, .option, .control])]
        #expect(model.set(custom, for: command).isEmpty)
        let data = try SettingsArchive.export(defaults: source, commands: model.commands)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("private-") && !json.contains("LSHandlers"))
        target.set("keep-my-session", forKey: SessionStore.key)
        target.set(8, forKey: IndentSettings.widthKey(for: "python"))
        target.set(true, forKey: AutoSavePolicy.enabledKey)
        let targetModel = ShortcutSettings(defaults: target)
        let doc = try SettingsArchive.decode(data, commands: targetModel.commands)
        let revision = targetModel.revision
        try SettingsArchive.apply(doc, defaults: target, shortcuts: targetModel)
        #expect(target.double(forKey: EditorFontSettings.fontSizeKey) == 18.5)
        #expect(!ModuleSettings(defaults: target).isEnabled(.highlight))
        #expect(!ScratchpadStore.isPinned(defaults: target))
        #expect(IndentSettings(defaults: target).width(for: "swift") == 2)
        #expect(!IndentSettings(defaults: target).hasExplicitWidth(for: "python"))
        #expect(target.object(forKey: AutoSavePolicy.enabledKey) == nil)
        #expect(target.string(forKey: SessionStore.key) == "keep-my-session")
        #expect(targetModel.binding(for: command) == custom)
        #expect(targetModel.revision > revision)
        #expect(try SettingsArchive.export(defaults: target, commands: targetModel.commands) == data)
    }
    @Test func invalidImportNeverPartiallyApplies() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let model = ShortcutSettings(defaults: defaults)
        defaults.set(20, forKey: EditorFontSettings.fontSizeKey)
        let invalid: [[String: SettingsArchive.Value]] = [
            [EditorFontSettings.fontSizeKey: .number(15), IndentSettings.usesSpacesKey: .number(1)],
            [EditorFontSettings.fontSizeKey: .number(100)],
            [IndentSettings.widthKey(for: "python"): .number(3.5)],
            [L10n.defaultsKey: .string("unknown")],
            [SessionStore.key: .string("untrusted-file")],
            [HotKeyCenter.keyCodeDefaultsKey: .number(999999)],
            [HotKeyCenter.keyCodeDefaultsKey: .number(2)],
            [HotKeyCenter.keyCodeDefaultsKey: .number(2), HotKeyCenter.modifiersDefaultsKey: .number(0)],
        ]
        for values in invalid {
            let before = defaults.dictionaryRepresentation()
            #expect(throws: (any Error).self) {
                try SettingsArchive.apply(.init(preferences: values, shortcuts: [:]), defaults: defaults, shortcuts: model)
            }
            #expect(NSDictionary(dictionary: before).isEqual(to: defaults.dictionaryRepresentation()))
        }
    }
    @Test func invalidFilesAndFutureSchemaAreRejected() throws {
        #expect(throws: (any Error).self) { try SettingsArchive.decode(Data("not-json".utf8)) }
        #expect(throws: (any Error).self) { try SettingsArchive.decode(Data(repeating: 32, count: SettingsArchive.maxBytes + 1)) }
        var doc = SettingsArchive.Document(preferences: [:], shortcuts: [:])
        doc.version = 99
        #expect(throws: (any Error).self) { try SettingsArchive.decode(JSONEncoder().encode(doc)) }
        doc.version = 1; doc.format = "another-app"
        #expect(throws: (any Error).self) { try SettingsArchive.decode(JSONEncoder().encode(doc)) }
    }
    @Test func settingsFilesUseBoundedReadsAndRoundTripOnDisk() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("KaruSettings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        defaults.set(16, forKey: ScratchpadStore.fontSizeKey)
        try SettingsArchive.export(defaults: defaults).write(to: file, options: .atomic)
        #expect(try SettingsArchive.read(from: file).preferences[ScratchpadStore.fontSizeKey] == .number(16))
        try Data(repeating: 32, count: SettingsArchive.maxBytes + 20).write(to: file)
        #expect(throws: (any Error).self) { try SettingsArchive.read(from: file) }
    }

    @Test func shortcutConflictsAndMalformedBindingsAreRejected() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let model = ShortcutSettings(defaults: defaults)
        let format = try #require(model.commands.first { $0.action == "formatDocument:" })
        let invalid: [[String: [ShortcutStroke]]] = [
            [format.id: [ShortcutStroke("s", .command)]],
            [format.id: [ShortcutStroke("k", .command)]],
            [format.id: [ShortcutStroke("a", [])]],
            ["unknown.command": []],
            [ShortcutSettings.globalID: []],
        ]
        for bindings in invalid {
            #expect(throws: (any Error).self) {
                try SettingsArchive.validate(.init(preferences: [:], shortcuts: bindings), commands: model.commands)
            }
        }
        let global: [String: SettingsArchive.Value] = [HotKeyCenter.keyCodeDefaultsKey: .number(1),
            HotKeyCenter.modifiersDefaultsKey: .number(Double(cmdKey)), "scratchpad.hotkey.character": .string("s")]
        #expect(throws: (any Error).self) {
            try SettingsArchive.validate(.init(preferences: global, shortcuts: [:]), commands: model.commands)
        }
    }
    @Test func unsetDefaultsRemainAutomaticAfterRestore() throws {
        let (defaults, clean) = isolated(); defer { clean() }
        let model = ShortcutSettings(defaults: defaults)
        try SettingsArchive.apply(.init(preferences: [:], shortcuts: [:]), defaults: defaults, shortcuts: model)
        #expect(ScratchpadStore.isPinned(defaults: defaults))
        #expect(ScratchpadStore.fontSize(defaults: defaults) == EditorFontSettings.defaultFontSize)
        #expect(HotKeyCenter.isEnabled(in: defaults))
        #expect(defaults.object(forKey: L10n.defaultsKey) == nil)
        #expect(!IndentSettings(defaults: defaults).hasExplicitWidth(for: "python"))
    }
    @Test func fileTypesGroupAliasesAndExcludeGenericOrMediaTypes() {
        let types = DefaultApplicationSettings.fileTypes(extensions: ["md", "markdown", "unknown", "ts", "missing"]) { ext in
            switch ext {
            case "md", "markdown": return .init(importedAs: "net.daringfireball.markdown", conformingTo: .text)
            case "unknown": return .data
            case "ts": return .movie
            default: return nil
            }
        }
        #expect(types.count == 1)
        #expect(types.first?.extensions == ["markdown", "md"])
        #expect(DefaultApplicationSettings.extensions.contains("go"))
        #expect(DefaultApplicationSettings.extensions.contains("rs"))
        #expect(DefaultApplicationSettings.extensions.contains("swift"))
    }
    private final class FakeAssociations: DefaultApplicationManaging {
        var applicationURL: URL? = URL(fileURLWithPath: "/Applications/Karu.app")
        var assigned: [String: URL] = [:]
        var calls: [String] = []
        func currentApplication(for type: UTType) -> URL? { assigned[type.identifier] }
        func setDefault(for type: UTType) async throws {
            calls.append(type.identifier)
            if type == .json { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "denied"]) }
            assigned[type.identifier] = applicationURL
        }
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @Test func defaultApplicationBatchReportsPartialFailuresWithoutChangingRealDefaults() async throws {
        let fake = FakeAssociations()
        let controller = DefaultApplicationPreferencesController(service: fake, types: [
            .init(type: .plainText, extensions: ["txt"]), .init(type: .json, extensions: ["json"])])
        let content = try #require(controller.window?.contentView)
        let table = try #require(views(content).compactMap { $0 as? NSTableView }.first)
        let apply = try #require(views(content).compactMap { $0 as? NSButton }.first { $0.action == Selector(("applySelected")) })
        table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
        apply.performClick(nil)
        #expect(!controller.windowShouldClose(controller.window!))
        try await Task.sleep(for: .milliseconds(150))
        #expect(fake.calls == [UTType.plainText.identifier, UTType.json.identifier])
        #expect(fake.assigned[UTType.plainText.identifier] == fake.applicationURL)
        #expect(fake.assigned[UTType.json.identifier] == nil)
        #expect(views(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("denied") })
        #expect(controller.windowShouldClose(controller.window!))
        controller.close()
    }
}
