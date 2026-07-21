import Testing
@testable import TinyEditorCore

@MainActor
@Test func coreModuleLinks() {
    // App, File, Edit, Format.
    #expect(MainMenu.build().items.count == 4)
}
