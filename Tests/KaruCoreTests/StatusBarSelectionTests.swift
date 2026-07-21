import Foundation
import Testing
@testable import KaruCore

// MARK: - StatusBarMetrics.selectionDescription (pure formatting)

@Test func selectionDescriptionIncludesLineCountWhenMultiLine() {
    let text = StatusBarMetrics.selectionDescription(length: 12, lines: 3, language: .en)
    #expect(text.contains("12"))
    #expect(text.contains("3"))
}

@Test func selectionDescriptionOmitsLineCountOnSingleLine() {
    let text = StatusBarMetrics.selectionDescription(length: 5, lines: 1, language: .en)
    #expect(text.contains("5"))
    #expect(!text.lowercased().contains("line"))
}

// MARK: - StatusBarView (rendered label text)

@MainActor
@Test func updateSelectionShowsSelectedCharacterCountAndLineSpan() {
    let statusBar = StatusBarView()
    statusBar.updateSelection(length: 12, lines: 3)
    #expect(statusBar.characterCountText.contains("12"))
}

@MainActor
@Test func updateSelectionOnSingleLineOmitsLineWording() {
    let statusBar = StatusBarView()
    statusBar.updateSelection(length: 12, lines: 1)
    let text = statusBar.characterCountText
    #expect(text.contains("12"))
    #expect(!text.lowercased().contains("line"))
    #expect(!text.contains("行"))
}

@MainActor
@Test func clearSelectionRestoresFullDocumentCharacterCount() {
    let statusBar = StatusBarView()
    statusBar.updateCharacterCount(2048)
    statusBar.updateSelection(length: 12, lines: 3)
    #expect(statusBar.characterCountText.contains("12"))

    statusBar.clearSelection()
    #expect(statusBar.characterCountText.contains("2048"))
    #expect(!statusBar.characterCountText.contains("12"))
}
