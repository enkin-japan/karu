import Testing
@testable import KaruCore

@MainActor
@Test func coreModuleLinks() {
    // App, File, Edit, Format, View, Language.
    #expect(MainMenu.build().items.count == 6)
}
