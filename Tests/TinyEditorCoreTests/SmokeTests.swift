import Testing
@testable import TinyEditorCore

@MainActor
@Test func coreModuleLinks() {
    // App, File, Edit, Format, Language.
    #expect(MainMenu.build().items.count == 5)
}
