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
