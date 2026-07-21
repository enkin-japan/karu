import Foundation
import Testing
@testable import TinyEditorCore

private func isolatedDefaults() -> UserDefaults {
    let name = "ModuleSettingsTests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func modulesDefaultToEnabled() {
    let settings = ModuleSettings(defaults: isolatedDefaults())
    for module in FeatureModule.allCases {
        #expect(settings.isEnabled(module))
    }
}

@Test func disableAndReenableRoundTrips() {
    let settings = ModuleSettings(defaults: isolatedDefaults())
    settings.setEnabled(false, for: .highlight)
    #expect(settings.isEnabled(.highlight) == false)
    #expect(settings.isEnabled(.completion))
    settings.setEnabled(true, for: .highlight)
    #expect(settings.isEnabled(.highlight))
}

@Test func changeNotificationCarriesModuleName() {
    // Use a private center so concurrently-running tests posting to
    // `NotificationCenter.default` cannot leak into this exact-match assertion.
    let center = NotificationCenter()
    let settings = ModuleSettings(defaults: isolatedDefaults(), center: center)
    var received: [String] = []
    let observer = center.addObserver(
        forName: ModuleSettings.didChangeNotification, object: nil, queue: nil
    ) { note in
        if let name = note.object as? String { received.append(name) }
    }
    defer { center.removeObserver(observer) }

    settings.setEnabled(false, for: .format)
    settings.setEnabled(false, for: .format) // no-op, must not re-post
    #expect(received == ["format"])
}
