import Testing
@testable import TinyEditorCore

@MainActor
@Test func coreModuleLinks() {
    #expect(MainMenu.build().items.count == 3)
}
