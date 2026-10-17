import AppKit
import Carbon.HIToolbox

struct ShortcutStroke: Codable, Equatable {
    let key: String
    let modifiers: UInt
    var keyCode: UInt16?
    static let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(_ key: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16? = nil) {
        self.key = key.lowercased()
        var normalized = flags.intersection(Self.mask)
        if key != key.lowercased() { normalized.insert(.shift) }
        modifiers = normalized.rawValue
        self.keyCode = keyCode
    }
    init?(event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers, !key.isEmpty else { return nil }
        self.init(key.lowercased(), event.modifierFlags, keyCode: event.keyCode)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.modifiers == rhs.modifiers }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var valid: Bool { key.utf16.count == 1 && !flags.intersection([.command, .option, .control]).isEmpty }
    @MainActor var display: String {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        return CommandPalette.shortcutString(for: item)
    }
}

enum ShortcutScope { case all, editor, scratchpad, global }
struct ShortcutCommand {
    let id: String
    let title: String
    let scope: ShortcutScope
    let action: String
    var parameter: Any?
    var tag: Int = 0
    let defaultBinding: [ShortcutStroke]
}

/// Small lazy command catalog, derived from the menu rather than a second list
/// of menu actions. Stores only user overrides; defaults evolve with the app.
@MainActor
final class ShortcutSettings {
    static let shared = ShortcutSettings()
    static let didChange = Notification.Name("KaruShortcutsDidChange")
    static let storageKey = "shortcuts.overrides.v1"
    static let globalID = "global.scratchpad"
    let defaults: UserDefaults
    private var cachedCommands: [ShortcutCommand]?
    private var overrides: [String: [ShortcutStroke]]
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([String: [ShortcutStroke]].self, from: $0)
        } ?? [:]
        overrides = overrides.filter { $0.value.count <= 2 && $0.value.allSatisfy(\.valid) }
    }

    func reloadOverridesFromDefaults() {
        overrides = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([String: [ShortcutStroke]].self, from: $0)
        } ?? [:]
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    static func id(for item: NSMenuItem) -> String {
        let action = item.action.map(NSStringFromSelector) ?? ""
        return "menu." + action + (item.representedObject.map { "|\($0)" } ?? "")
            + (item.isAlternate ? "|alternate" : "")
    }
    var commands: [ShortcutCommand] {
        if let cachedCommands { return cachedCommands }
        let sharedActions: Set<String> = ["newDocument:", "openDocument:", "performClose:", "saveDocument:",
            "showFindBar:", "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
            "showPreferences:", "hide:", "terminate:", "zoomIn:", "zoomOut:", "actualSize:",
            "orderFrontStandardAboutPanel:", "checkForUpdates:"]
        func collect(_ menu: NSMenu, parent: String) -> [ShortcutCommand] {
            menu.items.flatMap { item -> [ShortcutCommand] in
                if let submenu = item.submenu {
                    return collect(submenu, parent: parent.isEmpty ? submenu.title : parent + " ▸ " + submenu.title)
                }
                guard !item.isSeparatorItem, let selector = item.action else { return [] }
                let action = NSStringFromSelector(selector)
                if action == "toggleScratchpad:" { return [] } // Carbon owns this binding.
                var binding = item.keyEquivalent.isEmpty ? [] : [ShortcutStroke(item.keyEquivalent, item.keyEquivalentModifierMask)]
                if action == "foldAll:" { binding = [ShortcutStroke("k", .command), ShortcutStroke("0", .command)] }
                if action == "unfoldAllFolds:" { binding = [ShortcutStroke("k", .command), ShortcutStroke("j", .command)] }
                return [ShortcutCommand(id: Self.id(for: item), title: (parent.isEmpty ? item.title : parent + " ▸ " + item.title) + (item.isAlternate ? " (=)" : ""),
                    scope: sharedActions.contains(action) ? .all : .editor, action: action,
                    parameter: item.representedObject, tag: item.tag, defaultBinding: binding)]
            }
        }
        var commands = collect(MainMenu.build(applyShortcuts: false), parent: "")
        commands.append(ShortcutCommand(id: "editor.insertLineBelow", title: L10n.t(.shortcutInsertBelow), scope: .editor,
            action: "insertLineBelow:", defaultBinding: [ShortcutStroke("\r", .command)]))
        for (id, title, key) in [("todo", L10n.t(.shortcutTodo), "l"),
                                 ("check", L10n.t(.shortcutCheck), "u"),
                                 ("pin", L10n.t(.shortcutPin), "p")] {
            commands.append(ShortcutCommand(id: "scratchpad." + id, title: L10n.t(.scratchpadTitle) + " ▸ " + title,
                scope: .scratchpad, action: id, defaultBinding: [ShortcutStroke(key, [.command, .shift])]))
        }
        commands.append(ShortcutCommand(id: Self.globalID, title: L10n.t(.prefScratchpadHotkeyLabel), scope: .global,
            action: "toggleScratchpad:", defaultBinding: [ShortcutStroke("d", .option, keyCode: UInt16(HotKeyCenter.defaultKeyCode))]))
        cachedCommands = commands
        return commands
    }
    func reloadTitles() { cachedCommands = nil }
    func tooltip(id: String, title: String) -> String {
        guard let command = commands.first(where: { $0.id == id }) else { return title }
        let binding = binding(for: command).map(\.display).joined(separator: " ")
        return binding.isEmpty ? title : title + " (" + binding + ")"
    }

    func binding(for command: ShortcutCommand) -> [ShortcutStroke] {
        if command.id == Self.globalID {
            guard HotKeyCenter.isEnabled(in: defaults) else { return [] }
            let code = HotKeyCenter.storedKeyCode(in: defaults)
            let carbon = HotKeyCenter.storedModifiers(in: defaults)
            var flags: NSEvent.ModifierFlags = []
            if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
            if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
            if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
            if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            let key = defaults.string(forKey: "scratchpad.hotkey.character")
                ?? HotKeyCenter.displayString(keyCode: code, carbonModifiers: 0).lowercased()
            return [ShortcutStroke(key, flags, keyCode: UInt16(code))]
        }
        return overrides[command.id] ?? command.defaultBinding
    }
    func conflicts(_ binding: [ShortcutStroke], for command: ShortcutCommand) -> [ShortcutCommand] {
        guard !binding.isEmpty else { return [] }
        return commands.filter { other in
            guard other.id != command.id,
                  !(other.scope == .editor && command.scope == .scratchpad)
                    && !(other.scope == .scratchpad && command.scope == .editor) else { return false }
            let existing = self.binding(for: other)
            guard !existing.isEmpty else { return false }
            return Array(existing.prefix(min(existing.count, binding.count))) == Array(binding.prefix(min(existing.count, binding.count)))
        }
    }
    /// Returns the conflicting command titles; never silently steals a binding.
    @discardableResult
    func set(_ binding: [ShortcutStroke], for command: ShortcutCommand) -> [ShortcutCommand] {
        guard binding.count <= (command.scope == .global ? 1 : 2), binding.allSatisfy(\.valid) else { return [command] }
        if command.scope == .global, !binding.isEmpty, binding[0].keyCode == nil { return [command] }
        let conflicts = conflicts(binding, for: command)
        guard conflicts.isEmpty else { return conflicts }
        if command.id == Self.globalID {
            if let stroke = binding.first, let keyCode = stroke.keyCode {
                HotKeyCenter.store(keyCode: UInt32(keyCode), carbonModifiers: HotKeyCenter.carbonModifiers(from: stroke.flags), in: defaults)
                defaults.set(stroke.key, forKey: "scratchpad.hotkey.character")
            } else { defaults.set(false, forKey: HotKeyCenter.enabledKey) }
            NotificationCenter.default.post(name: HotKeyCenter.didChangeNotification, object: nil)
        } else { overrides[command.id] = binding }
        save()
        return []
    }
    @discardableResult
    func reset(_ command: ShortcutCommand) -> [ShortcutCommand] {
        let conflicts = conflicts(command.defaultBinding, for: command)
        guard conflicts.isEmpty else { return conflicts }
        if command.id == Self.globalID {
            HotKeyCenter.resetToDefault(in: defaults)
            NotificationCenter.default.post(name: HotKeyCenter.didChangeNotification, object: nil)
        } else { overrides.removeValue(forKey: command.id) }
        save(); return []
    }
    func resetAll() {
        overrides = [:]
        HotKeyCenter.resetToDefault(in: defaults)
        NotificationCenter.default.post(name: HotKeyCenter.didChangeNotification, object: nil)
        save()
    }
    private func save() {
        defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.storageKey)
        revision += 1
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
    func apply(to menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu); continue }
            guard let command = commands.first(where: { $0.id == Self.id(for: item) }) else { continue }
            let strokes = binding(for: command)
            item.keyEquivalent = strokes.count == 1 ? strokes[0].key : ""
            if strokes.count == 1 { item.keyEquivalentModifierMask = strokes[0].flags }
            if strokes.count > 1 { item.toolTip = strokes.map(\.display).joined(separator: " ") }
        }
    }
}

/// Per-text-view, transient prefix state. Key events are never intercepted in
/// other apps or in settings/search fields. Menus retain native single-key routing.
@MainActor
final class ShortcutRouter {
    private var prefix: ShortcutStroke?
    private var deadline: TimeInterval = 0
    private var revision = -1
    enum Result { case none, prefix, command(ShortcutCommand) }
    func reset() { prefix = nil; deadline = 0 }
    func resolve(_ stroke: ShortcutStroke, scope: ShortcutScope, settings suppliedSettings: ShortcutSettings? = nil,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Result {
        let settings = suppliedSettings ?? .shared
        if revision != settings.revision || now > deadline { prefix = nil }
        revision = settings.revision
        let commands = settings.commands.filter { $0.scope == .all || $0.scope == scope }
        if let first = prefix {
            prefix = nil
            if let command = commands.first(where: { settings.binding(for: $0) == [first, stroke] }) { return .command(command) }
            if stroke.key == "\u{1b}" { return .prefix }
        }
        if let command = commands.first(where: { settings.binding(for: $0) == [stroke] }) { return .command(command) }
        if commands.contains(where: { let b = settings.binding(for: $0); return b.count == 2 && b.first == stroke }) {
            prefix = stroke; deadline = now + 2; return .prefix
        }
        return .none
    }
    func handle(_ event: NSEvent, scope: ShortcutScope, sender: Any?, preferMenu: Bool = false, perform: ((ShortcutCommand) -> Bool)? = nil) -> Bool {
        guard let stroke = ShortcutStroke(event: event) else { return false }
        switch resolve(stroke, scope: scope) {
        case .none: return false
        case .prefix: return true
        case .command(let command):
            if preferMenu, command.scope == .all, ShortcutSettings.shared.binding(for: command).count == 1 { return false }
            if let perform, perform(command) { return true }
            let item = NSMenuItem(title: command.title, action: Selector(command.action), keyEquivalent: "")
            item.representedObject = command.parameter; item.tag = command.tag
            NSApp.sendAction(Selector(command.action), to: nil, from: item)
            return true
        }
    }
}
