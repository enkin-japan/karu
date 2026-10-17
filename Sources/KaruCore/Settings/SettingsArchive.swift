import AppKit
import Carbon.HIToolbox
import CoreFoundation

/// Versioned, allowlisted preferences only. Document paths, notes, session data,
/// window frames, Sparkle state and system file associations never enter this file.
@MainActor
enum SettingsArchive {
    static let maxBytes = 1_048_576
    static let didImport = Notification.Name("KaruSettingsDidImport")
    enum Failure: LocalizedError {
        case invalid, version, value(String), conflict(String)
        var errorDescription: String? {
            switch self {
            case .invalid: return L10n.t(.settingsInvalid)
            case .version: return L10n.t(.settingsVersion)
            case .value(let key): return L10n.t(.settingsInvalidValue, String(key.prefix(80)))
            case .conflict(let names): return L10n.t(.shortcutConflict, names)
            }
        }
    }
    enum Value: Codable, Equatable {
        case bool(Bool), number(Double), string(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let value = try? c.decode(Bool.self) { self = .bool(value) }
            else if let value = try? c.decode(Double.self) { self = .number(value) }
            else { self = .string(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .bool(let value): try c.encode(value)
            case .number(let value): try c.encode(value)
            case .string(let value): try c.encode(value)
            }
        }
        var object: Any {
            switch self {
            case .bool(let value): return value
            case .number(let value): return value
            case .string(let value): return value
            }
        }
    }
    struct Document: Codable {
        var format = "dev.enkin.TinyEditor.settings"
        var version = 1
        var preferences: [String: Value]
        var shortcuts: [String: [ShortcutStroke]]
    }
    static var boolKeys: Set<String> {
        Set([IndentSettings.usesSpacesKey, IndentRainbow.enabledKey, AutoClosePairs.enabledKey,
             AutoSavePolicy.enabledKey, ScratchpadStore.pinnedKey, HotKeyCenter.enabledKey]
            + FeatureModule.allCases.map(\.defaultsKey))
    }
    static var widthKeys: Set<String> {
        Set((SupportedLanguage.all.map(\.identifier) + ["plist"]).map(IndentSettings.widthKey))
    }
    static var keys: Set<String> {
        boolKeys.union(widthKeys).union([EditorFontSettings.fontSizeKey, ScratchpadStore.fontSizeKey,
            L10n.defaultsKey, HotKeyCenter.keyCodeDefaultsKey, HotKeyCenter.modifiersDefaultsKey,
            "scratchpad.hotkey.character"])
    }
    static func export(defaults: UserDefaults = .standard, commands: [ShortcutCommand]? = nil) throws -> Data {
        var values: [String: Value] = [:]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let n = value as? NSNumber {
                values[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
            } else if let string = value as? String { values[key] = .string(string) }
            else { throw Failure.value(key) }
        }
        let shortcuts = try defaults.data(forKey: ShortcutSettings.storageKey).map {
            try JSONDecoder().decode([String: [ShortcutStroke]].self, from: $0)
        } ?? [:]
        let document = Document(preferences: values, shortcuts: shortcuts)
        try validate(document, commands: commands ?? ShortcutSettings.shared.commands)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maxBytes else { throw Failure.invalid }
        return data
    }
    static func read(from url: URL) throws -> Document {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        return try decode(data)
    }

    static func decode(_ data: Data, commands: [ShortcutCommand]? = nil) throws -> Document {
        guard data.count <= maxBytes else { throw Failure.invalid }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw Failure.invalid }
        try validate(document, commands: commands ?? ShortcutSettings.shared.commands)
        return document
    }
    static func validate(_ doc: Document, commands: [ShortcutCommand]) throws {
        guard doc.format == "dev.enkin.TinyEditor.settings" else { throw Failure.invalid }
        guard doc.version == 1 else { throw Failure.version }
        for (key, value) in doc.preferences {
            guard keys.contains(key) else { throw Failure.value(key) }
            switch value {
            case .bool:
                guard boolKeys.contains(key) else { throw Failure.value(key) }
            case .number(let number):
                guard number.isFinite else { throw Failure.value(key) }
                if widthKeys.contains(key) {
                    guard number.rounded() == number, (2...8).contains(number) else { throw Failure.value(key) }
                } else if key == EditorFontSettings.fontSizeKey || key == ScratchpadStore.fontSizeKey {
                    guard (8...72).contains(number) else { throw Failure.value(key) }
                } else if key == HotKeyCenter.keyCodeDefaultsKey {
                    guard number.rounded() == number, (0...127).contains(number) else { throw Failure.value(key) }
                } else if key == HotKeyCenter.modifiersDefaultsKey {
                    let allowed = Double(cmdKey | shiftKey | optionKey | controlKey)
                    guard number.rounded() == number, number >= 0, number <= allowed,
                          UInt32(number) & ~UInt32(cmdKey | shiftKey | optionKey | controlKey) == 0,
                          UInt32(number) & UInt32(cmdKey | optionKey | controlKey) != 0 else { throw Failure.value(key) }
                } else { throw Failure.value(key) }
            case .string(let string):
                if key == L10n.defaultsKey {
                    guard AppLanguage(rawValue: string) != nil else { throw Failure.value(key) }
                } else if key == "scratchpad.hotkey.character" {
                    guard string.utf16.count == 1, string == string.lowercased() else { throw Failure.value(key) }
                } else { throw Failure.value(key) }
            }
        }
        let hasCode = doc.preferences[HotKeyCenter.keyCodeDefaultsKey] != nil
        guard hasCode == (doc.preferences[HotKeyCenter.modifiersDefaultsKey] != nil),
              doc.preferences["scratchpad.hotkey.character"] == nil || hasCode else { throw Failure.invalid }
        let known = Set(commands.filter { $0.scope != .global }.map(\.id))
        for (id, strokes) in doc.shortcuts {
            guard known.contains(id), strokes.count <= 2,
                  strokes.allSatisfy({ $0.valid && $0.key == $0.key.lowercased()
                      && $0.modifiers & ~ShortcutStroke.mask.rawValue == 0
                      && ($0.keyCode == nil || $0.keyCode! <= 127) }) else { throw Failure.value(id) }
        }
        func binding(_ command: ShortcutCommand) -> [ShortcutStroke] {
            guard command.scope == .global else { return doc.shortcuts[command.id] ?? command.defaultBinding }
            if doc.preferences[HotKeyCenter.enabledKey] == .bool(false) { return [] }
            guard case .number(let code) = doc.preferences[HotKeyCenter.keyCodeDefaultsKey],
                  case .number(let modifiers) = doc.preferences[HotKeyCenter.modifiersDefaultsKey] else { return command.defaultBinding }
            var flags: NSEvent.ModifierFlags = []
            let m = UInt32(modifiers)
            if m & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if m & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if m & UInt32(optionKey) != 0 { flags.insert(.option) }
            if m & UInt32(controlKey) != 0 { flags.insert(.control) }
            let key: String
            if case .string(let character) = doc.preferences["scratchpad.hotkey.character"] { key = character }
            else { key = HotKeyCenter.displayString(keyCode: UInt32(code), carbonModifiers: 0).lowercased() }
            return [ShortcutStroke(key, flags, keyCode: UInt16(code))]
        }
        for (i, command) in commands.enumerated() {
            let a = binding(command)
            guard !a.isEmpty else { continue }
            for other in commands.dropFirst(i + 1) {
                if (command.scope == .editor && other.scope == .scratchpad) || (command.scope == .scratchpad && other.scope == .editor) { continue }
                let b = binding(other)
                if !b.isEmpty, Array(a.prefix(min(a.count, b.count))) == Array(b.prefix(min(a.count, b.count))) {
                    throw Failure.conflict(command.title + ", " + other.title)
                }
            }
        }
    }
    /// Validate everything before writing anything; absent keys restore defaults
    /// (not effective indent widths, which would disable content auto-detection).
    static func apply(_ document: Document, defaults: UserDefaults = .standard,
                      shortcuts supplied: ShortcutSettings? = nil) throws {
        let shortcuts = supplied ?? .shared
        try validate(document, commands: shortcuts.commands)
        let encoded = try JSONEncoder().encode(document.shortcuts)
        for key in keys { defaults.removeObject(forKey: key) }
        for (key, value) in document.preferences { defaults.set(value.object, forKey: key) }
        defaults.set(encoded, forKey: ShortcutSettings.storageKey)
        shortcuts.reloadOverridesFromDefaults()
        guard defaults === UserDefaults.standard else { return }
        let center = NotificationCenter.default
        for module in FeatureModule.allCases { center.post(name: ModuleSettings.didChangeNotification, object: module.rawValue) }
        for name in [L10n.didChangeNotification, EditorFontSettings.didChangeNotification,
                     ScratchpadStore.fontDidChangeNotification, HotKeyCenter.didChangeNotification, didImport] {
            center.post(name: name, object: nil)
        }
    }
}
