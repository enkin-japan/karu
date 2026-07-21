import AppKit
import Foundation
import Testing
@testable import KaruCore

// Exercises the command palette's pure fuzzy-matching / ranking (T12.8). The
// panel UI itself is a thin AppKit shell over `fuzzyScore` + `filter`; the menu
// enumeration is covered separately with a small hand-built menu tree.

// MARK: - Fuzzy score: subsequence membership

@Test func fuzzyScoreRejectsNonSubsequences() {
    #expect(CommandPalette.fuzzyScore(query: "xyz", candidate: "Open File") == nil)
    // Out-of-order characters are not a subsequence.
    #expect(CommandPalette.fuzzyScore(query: "eo", candidate: "Open") == nil)
}

@Test func fuzzyScoreEmptyQueryMatchesEverything() {
    #expect(CommandPalette.fuzzyScore(query: "", candidate: "Anything") == 0)
}

@Test func fuzzyScoreMatchesCaseInsensitively() {
    #expect(CommandPalette.fuzzyScore(query: "OPN", candidate: "Open") != nil)
    #expect(CommandPalette.fuzzyScore(query: "open", candidate: "OPEN") != nil)
}

// MARK: - Ranking: prefix > word-start > scattered

@Test func prefixHitOutranksScatteredHit() {
    // "op" is a prefix of "Open" but only scattered inside "Reopen".
    let prefix = CommandPalette.fuzzyScore(query: "op", candidate: "Open")!
    let scattered = CommandPalette.fuzzyScore(query: "op", candidate: "Reopen")!
    #expect(prefix > scattered)
}

@Test func wordStartHitOutranksMidWordScatteredHit() {
    // "c" at a word start ("… Comment") should beat "c" buried mid-word.
    let wordStart = CommandPalette.fuzzyScore(query: "com", candidate: "Toggle Comment")!
    let midWord = CommandPalette.fuzzyScore(query: "com", candidate: "Welcome Home")!
    #expect(wordStart > midWord)
}

@Test func consecutiveRunOutranksGaps() {
    let consecutive = CommandPalette.fuzzyScore(query: "form", candidate: "Format")!
    let gappy = CommandPalette.fuzzyScore(query: "form", candidate: "Foo Random Mix")!
    #expect(consecutive > gappy)
}

// MARK: - filter: ordering + exclusion

@MainActor
@Test func filterSortsByScoreAndDropsNonMatches() {
    let commands = [
        CommandPalette.Command(title: "Reopen", shortcut: "", menu: nil, index: 0),
        CommandPalette.Command(title: "Open", shortcut: "", menu: nil, index: 1),
        CommandPalette.Command(title: "Save", shortcut: "", menu: nil, index: 2),
    ]
    let result = CommandPalette.filter(commands, query: "op")
    // "Save" has no o…p subsequence and is dropped; "Open" (prefix) ranks first.
    #expect(result.map(\.title) == ["Open", "Reopen"])
}

@MainActor
@Test func filterEmptyQueryReturnsMenuOrder() {
    let commands = [
        CommandPalette.Command(title: "One", shortcut: "", menu: nil, index: 0),
        CommandPalette.Command(title: "Two", shortcut: "", menu: nil, index: 1),
    ]
    #expect(CommandPalette.filter(commands, query: "  ").map(\.title) == ["One", "Two"])
}

// MARK: - Menu enumeration

@MainActor
@Test func collectCommandsFlattensEnabledLeavesWithParentPath() {
    let root = NSMenu()

    // Top-level "Edit" submenu with two leaves + a separator + a disabled leaf.
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Edit")
    edit.autoenablesItems = false
    editItem.submenu = edit
    root.addItem(editItem)

    let copy = edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    copy.isEnabled = true
    edit.addItem(.separator())
    let disabled = edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    disabled.isEnabled = false
    let noAction = edit.addItem(withTitle: "Inert", action: nil, keyEquivalent: "")
    noAction.isEnabled = true

    let commands = CommandPalette.collectCommands(from: root, parentTitle: nil)

    // Only the enabled, actionable leaf survives, labelled with its parent path.
    #expect(commands.map(\.title) == ["Edit ▸ Copy"])
    // Separator, disabled item, and no-action item are all excluded.
    #expect(!commands.contains { $0.title.contains("Paste") })
    #expect(!commands.contains { $0.title.contains("Inert") })
    _ = copy // keep reference alive
}

@MainActor
@Test func shortcutStringRendersModifierSymbols() {
    let item = NSMenuItem(title: "Palette", action: nil, keyEquivalent: "p")
    item.keyEquivalentModifierMask = [.command, .shift]
    #expect(CommandPalette.shortcutString(for: item) == "⇧⌘P")

    let plain = NSMenuItem(title: "None", action: nil, keyEquivalent: "")
    #expect(CommandPalette.shortcutString(for: plain) == "")
}

// MARK: - Releases all runtime state on close

@MainActor
@Test func paletteReleasesStateWhenClosed() {
    let textView = NSTextView()
    let palette = CommandPalette(textView: textView)

    var closed = false
    palette.present { closed = true }
    #expect(palette.isVisible)

    textView.window?.orderOut(nil)
    palette.perform(NSSelectorFromString("panelResignedKey"))
    #expect(palette.isVisible == false)
    #expect(closed)
}
