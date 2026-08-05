import AppKit
import Carbon.HIToolbox
import Testing
@testable import KaruCore

// T15.1 — the always-available scratchpad, in its two unit-testable halves:
//
//   1. `ScratchpadStore` as pure filesystem logic (round-trip, overwrite, the
//      empty-pad cases), each case against its own temporary directory so the
//      developer's real notes are never touched;
//   2. `HotKeyCenter`'s conversions and defaults plumbing, against isolated
//      UserDefaults suites so no test can rebind the real hot key.
//
// The panel itself is deliberately not exercised here: an NSPanel's visibility,
// key status and non-activating behaviour are unreliable in a headless test
// process. The `KARU_SCRATCHTEST=show|cycle` hook in `AppDelegate` covers the
// panel lifecycle in the real app instead, for the same reason KARU_FOLDTEST
// exists (see AppDelegate).

// MARK: - ScratchpadStore

private func makeScratchpadStore() -> (ScratchpadStore, () -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("KaruScratchpad-\(UUID().uuidString)")
    return (ScratchpadStore(directory: dir), {
        try? FileManager.default.removeItem(at: dir)
    })
}

@Test func scratchpadRoundTripsItsContent() {
    let (store, cleanup) = makeScratchpadStore()
    defer { cleanup() }

    store.write("first note\nsecond line\n")
    #expect(store.read() == "first note\nsecond line\n")
}

@Test func scratchpadWriteReplacesPreviousContent() {
    let (store, cleanup) = makeScratchpadStore()
    defer { cleanup() }

    store.write("old and rather long")
    store.write("new")
    #expect(store.read() == "new")
}

@Test func scratchpadReadsEmptyWhenNothingWasEverWritten() {
    let (store, cleanup) = makeScratchpadStore()
    defer { cleanup() }

    #expect(store.read() == "")
}

@Test func scratchpadClearEmptiesThePad() {
    let (store, cleanup) = makeScratchpadStore()
    defer { cleanup() }

    store.write("graduated into a file")
    store.clear()
    #expect(store.read() == "")
    // Clearing twice is a no-op, not a failure.
    store.clear()
    #expect(store.read() == "")
}

@Test func scratchpadIsPinnedByDefaultAndFollowsTheStoredFlag() {
    let name = "ScratchpadPinTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults().removePersistentDomain(forName: name) }

    // Unset = pinned: the panel must never vanish under a user who never asked.
    #expect(ScratchpadStore.isPinned(defaults: defaults))
    defaults.set(false, forKey: ScratchpadStore.pinnedKey)
    #expect(!ScratchpadStore.isPinned(defaults: defaults))
    defaults.set(true, forKey: ScratchpadStore.pinnedKey)
    #expect(ScratchpadStore.isPinned(defaults: defaults))
}

// MARK: - Scratchpad font size (T15.3)

private func makeFontDefaults() -> (UserDefaults, () -> Void) {
    let name = "ScratchpadFontTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { UserDefaults().removePersistentDomain(forName: name) })
}

@Test func scratchpadFontSizeInheritsTheEditorUntilItIsSetOnce() {
    let (defaults, cleanup) = makeFontDefaults()
    defer { cleanup() }

    // Nothing stored anywhere: both fall back to the editor's default.
    #expect(ScratchpadStore.fontSize(defaults: defaults) == EditorFontSettings.defaultFontSize)

    // The user only ever set the editor size — the pad follows it, so a single
    // font preference still means one font everywhere.
    EditorFontSettings(defaults: defaults).setFontSize(20)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == 20)
}

@Test func scratchpadFontSizeBecomesIndependentOnceSet() {
    let (defaults, cleanup) = makeFontDefaults()
    defer { cleanup() }

    EditorFontSettings(defaults: defaults).setFontSize(20)
    ScratchpadStore.setFontSize(30, defaults: defaults)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == 30)

    // Zooming the editor from here on must not move the pad (the whole point:
    // ⌘+ in the pad used to resize every editor window and vice versa).
    EditorFontSettings(defaults: defaults).setFontSize(11)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == 30)
    #expect(EditorFontSettings(defaults: defaults).fontSize == 11)
}

@Test func scratchpadFontSizeRoundTripsAndClampsToTheEditorRange() {
    let (defaults, cleanup) = makeFontDefaults()
    defer { cleanup() }

    ScratchpadStore.setFontSize(24, defaults: defaults)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == 24)

    ScratchpadStore.setFontSize(2, defaults: defaults)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == EditorFontSettings.minFontSize)

    ScratchpadStore.setFontSize(500, defaults: defaults)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == EditorFontSettings.maxFontSize)

    // A hand-edited defaults value outside the range is clamped on read, too.
    defaults.set(999.0, forKey: ScratchpadStore.fontSizeKey)
    #expect(ScratchpadStore.fontSize(defaults: defaults) == EditorFontSettings.maxFontSize)
}

@Test func scratchpadFontChangeHasItsOwnBroadcast() {
    // Sharing the editor's notification would drag every editor window into a
    // pad-only change; they must stay distinct.
    #expect(ScratchpadStore.fontDidChangeNotification != EditorFontSettings.didChangeNotification)
}

// MARK: - Scratchpad zoom key routing (T15.3)

@Test func scratchpadClaimsTheZoomKeys() {
    #expect(ScratchpadController.zoomCommand(modifiers: .command,
                                             charactersIgnoringModifiers: "=") == .zoomIn)
    // ⌘+ is ⇧⌘= on a US keyboard; both spellings mean zoom in.
    #expect(ScratchpadController.zoomCommand(modifiers: [.command, .shift],
                                             charactersIgnoringModifiers: "+") == .zoomIn)
    #expect(ScratchpadController.zoomCommand(modifiers: .command,
                                             charactersIgnoringModifiers: "-") == .zoomOut)
    #expect(ScratchpadController.zoomCommand(modifiers: .command,
                                             charactersIgnoringModifiers: "0") == .actualSize)
}

@Test func scratchpadLeavesOtherChordsToTheResponderChain() {
    #expect(ScratchpadController.zoomCommand(modifiers: [], charactersIgnoringModifiers: "0") == nil)
    #expect(ScratchpadController.zoomCommand(modifiers: .command,
                                             charactersIgnoringModifiers: "s") == nil)
    // ⌘K ⌘0 (the editor's fold chord) and ⌥⌘0 must not be swallowed here.
    #expect(ScratchpadController.zoomCommand(modifiers: [.command, .option],
                                             charactersIgnoringModifiers: "0") == nil)
    #expect(ScratchpadController.zoomCommand(modifiers: [.command, .control],
                                             charactersIgnoringModifiers: "-") == nil)
}

// MARK: - Graduation file name

@Test func graduatedFileNameComesFromTheFirstNonEmptyLine() {
    #expect(ScratchpadController.suggestedFileName(for: "\n\n  Shopping list \nmilk\n")
            == "Shopping list.txt")
}

@Test func graduatedFileNameFallsBackForAnEmptyPad() {
    #expect(ScratchpadController.suggestedFileName(for: "") == "Draft.txt")
    #expect(ScratchpadController.suggestedFileName(for: "   \n\n") == "Draft.txt")
}

@Test func graduatedFileNameIsCappedAndPathSafe() {
    let long = String(repeating: "a", count: 100)
    #expect(ScratchpadController.suggestedFileName(for: long) == String(repeating: "a", count: 40) + ".txt")
    #expect(ScratchpadController.suggestedFileName(for: "notes/2026: draft") == "notes-2026- draft.txt")
}

// MARK: - HotKeyCenter conversions

@Test func hotKeyDefaultsToOptionD() {
    #expect(HotKeyCenter.defaultKeyCode == UInt32(kVK_ANSI_D))
    #expect(HotKeyCenter.defaultModifiers == UInt32(optionKey))
    #expect(HotKeyCenter.displayString(keyCode: HotKeyCenter.defaultKeyCode,
                                       carbonModifiers: HotKeyCenter.defaultModifiers) == "⌥D")
}

@Test func hotKeyDisplayUsesThePlatformModifierOrder() {
    // macOS always prints ⌃⌥⇧⌘, whatever order the keys were pressed in.
    let all = HotKeyCenter.carbonModifiers(from: [.command, .shift, .option, .control])
    #expect(HotKeyCenter.displayString(keyCode: UInt32(kVK_ANSI_K), carbonModifiers: all) == "⌃⌥⇧⌘K")
    let cmdShift = HotKeyCenter.carbonModifiers(from: [.command, .shift])
    #expect(HotKeyCenter.displayString(keyCode: UInt32(kVK_ANSI_7), carbonModifiers: cmdShift) == "⇧⌘7")
}

@Test func hotKeyDisplayHandlesAnUnmodifiedAndUnknownKey() {
    #expect(HotKeyCenter.displayString(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: 0) == "A")
    // Keys outside the letter/digit table still render, just without a label.
    #expect(HotKeyCenter.displayString(keyCode: UInt32(kVK_Space),
                                       carbonModifiers: UInt32(cmdKey)) == "⌘?")
}

@Test func carbonModifiersMapEachCocoaFlagAndDropTheRest() {
    #expect(HotKeyCenter.carbonModifiers(from: []) == 0)
    #expect(HotKeyCenter.carbonModifiers(from: .command) == UInt32(cmdKey))
    #expect(HotKeyCenter.carbonModifiers(from: .option) == UInt32(optionKey))
    #expect(HotKeyCenter.carbonModifiers(from: .control) == UInt32(controlKey))
    #expect(HotKeyCenter.carbonModifiers(from: .shift) == UInt32(shiftKey))
    #expect(HotKeyCenter.carbonModifiers(from: [.command, .shift])
            == UInt32(cmdKey) | UInt32(shiftKey))
    // Flags Carbon has no equivalent for contribute nothing.
    #expect(HotKeyCenter.carbonModifiers(from: [.command, .capsLock, .function]) == UInt32(cmdKey))
}

// MARK: - HotKeyCenter defaults plumbing

@Test func hotKeyStoreRoundTripsThroughDefaults() {
    let name = "HotKeyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults().removePersistentDomain(forName: name) }

    // Nothing stored → the ⌥D default.
    #expect(HotKeyCenter.storedKeyCode(in: defaults) == HotKeyCenter.defaultKeyCode)
    #expect(HotKeyCenter.storedModifiers(in: defaults) == HotKeyCenter.defaultModifiers)

    let modifiers = HotKeyCenter.carbonModifiers(from: [.command, .control])
    HotKeyCenter.store(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: modifiers, in: defaults)
    #expect(HotKeyCenter.storedKeyCode(in: defaults) == UInt32(kVK_ANSI_N))
    #expect(HotKeyCenter.storedModifiers(in: defaults) == modifiers)
    #expect(HotKeyCenter.displayString(keyCode: HotKeyCenter.storedKeyCode(in: defaults),
                                       carbonModifiers: HotKeyCenter.storedModifiers(in: defaults))
            == "⌃⌘N")

    HotKeyCenter.resetToDefault(in: defaults)
    #expect(HotKeyCenter.storedKeyCode(in: defaults) == HotKeyCenter.defaultKeyCode)
    #expect(HotKeyCenter.storedModifiers(in: defaults) == HotKeyCenter.defaultModifiers)
}

@Test func hotKeyCenterReadsItsInjectedDefaults() {
    let name = "HotKeyTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults().removePersistentDomain(forName: name) }

    HotKeyCenter.store(keyCode: UInt32(kVK_ANSI_9),
                       carbonModifiers: UInt32(optionKey) | UInt32(shiftKey), in: defaults)
    let center = HotKeyCenter(defaults: defaults)
    #expect(center.storedKeyCode == UInt32(kVK_ANSI_9))
    #expect(center.displayString == "⌥⇧9")
    // Nothing has been registered yet, so the status is still the initial noErr.
    #expect(center.lastStatus == noErr)
}

// MARK: - Title spacing (T15.4)

@Test func scratchpadTitleSpacingLoosensShortCJKTitlesOnly() {
    // "草稿本" gains ideographic spaces (user request: too tight in the bar);
    // long titles (EN/JA) and single characters stay untouched.
    #expect(ScratchpadController.spacedTitle("草稿本") == "草\u{3000}稿\u{3000}本")
    #expect(ScratchpadController.spacedTitle("Scratchpad") == "Scratchpad")
    #expect(ScratchpadController.spacedTitle("スクラッチパッド") == "スクラッチパッド")
    #expect(ScratchpadController.spacedTitle("A") == "A")
}

// MARK: - Find bar layout (T15.5)
//
// Layout metrics only — no window, no panel. `fittingSize` is exactly the number
// the scratchpad turns into `contentMinSize`, and it is computable headlessly,
// so the two user-visible failures (buttons clipped in a narrow pad, first text
// line covered) are pinned down by the measurements below plus the visibility
// callback that drives the push-down.

/// A bar built over a throwaway text view, the way both hosts build theirs.
@MainActor
private func makeFindBar(compact: Bool) -> FindBarController {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.string = "alpha\nbeta\n"
    return FindBarController(textView: textView,
                             lineIndex: LineIndex(text: textView.string),
                             compact: compact)
}

@MainActor
@Test func compactFindBarIsFarNarrowerThanTheSingleRowOne() {
    let single = makeFindBar(compact: false).barView.fittingSize
    let compact = makeFindBar(compact: true).barView.fittingSize
    // Two rows: much narrower, and correspondingly taller.
    #expect(compact.width < single.width * 0.75)
    #expect(compact.height > single.height)
}

@MainActor
@Test func compactFindBarFitsThePadsMinimumWidth() {
    // The pad's `contentMinSize` is max(340, this) — the bar must not push that
    // minimum up, or a "narrow pad" is impossible again (the T15.4 accident).
    #expect(makeFindBar(compact: true).barView.fittingSize.width <= 340)
}

@MainActor
@Test func singleRowFindBarKeepsItsEditorWidth() {
    // Guards the editor against this change: one row, ~660 pt of controls.
    let bar = makeFindBar(compact: false).barView
    #expect(bar.fittingSize.width > 500)
    #expect(bar.fittingSize.height < 50)
}

@MainActor
@Test func findBarReportsEveryVisibilityChange() {
    let bar = makeFindBar(compact: true)
    var seen: [Bool] = []
    bar.onVisibilityChanged = { seen.append($0) }
    bar.show()
    bar.hide()
    bar.show()
    #expect(seen == [true, false, true])
    #expect(bar.isShown)
}

@MainActor
@Test func findBarClosingRoutesThroughHideAndNotifies() {
    // Esc in the search field and the Done button both call `hide()`, so the
    // scratchpad's text always gets its top edge back.
    let bar = makeFindBar(compact: true)
    bar.show()
    var seen: [Bool] = []
    bar.onVisibilityChanged = { seen.append($0) }
    bar.hide()
    #expect(seen == [false])
    #expect(!bar.isShown)
}
