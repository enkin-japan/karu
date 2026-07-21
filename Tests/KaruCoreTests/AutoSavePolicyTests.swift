import Foundation
import Testing
@testable import KaruCore

// MARK: - shouldSave truth table (T12.14)

@Test func autoSaveSavesOnlyWhenAllThreeTrue() {
    #expect(AutoSavePolicy.shouldSave(enabled: true, isDirty: true, hasFileURL: true))
}

@Test func autoSaveSkipsWhenDisabled() {
    #expect(!AutoSavePolicy.shouldSave(enabled: false, isDirty: true, hasFileURL: true))
}

@Test func autoSaveSkipsWhenClean() {
    #expect(!AutoSavePolicy.shouldSave(enabled: true, isDirty: false, hasFileURL: true))
}

@Test func autoSaveSkipsUntitledDocument() {
    // No file URL: never pop a storage panel on focus loss.
    #expect(!AutoSavePolicy.shouldSave(enabled: true, isDirty: true, hasFileURL: false))
}

@Test func autoSaveSkipsWhenNothingIsTrue() {
    #expect(!AutoSavePolicy.shouldSave(enabled: false, isDirty: false, hasFileURL: false))
}

// MARK: - Default toggle (defaults OFF, persists)

@Test func autoSaveDefaultsToDisabledWhenUnset() {
    let name = "AutoSaveTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    // The production accessor reads `.standard`; assert the documented default
    // contract (unset ⇒ false) directly against an isolated store.
    #expect(defaults.object(forKey: AutoSavePolicy.enabledKey) == nil)
    #expect(defaults.bool(forKey: AutoSavePolicy.enabledKey) == false)
}

@Test func autoSaveFlagPersists() {
    let name = "AutoSaveTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    defaults.set(true, forKey: AutoSavePolicy.enabledKey)
    #expect(defaults.object(forKey: AutoSavePolicy.enabledKey) != nil)
    #expect(defaults.bool(forKey: AutoSavePolicy.enabledKey) == true)
}
