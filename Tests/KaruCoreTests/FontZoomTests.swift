import CoreGraphics
import Testing
@testable import KaruCore

@Test func zoomInAddsOneStep() {
    #expect(FontZoom.step(current: 13, direction: .increase) == 14)
}

@Test func zoomOutSubtractsOneStep() {
    #expect(FontZoom.step(current: 13, direction: .decrease) == 12)
}

@Test func zoomInClampsAtMaximum() {
    #expect(FontZoom.step(current: 72, direction: .increase) == 72)
    #expect(FontZoom.step(current: 71.5, direction: .increase) == 72)
}

@Test func zoomOutClampsAtMinimum() {
    #expect(FontZoom.step(current: 8, direction: .decrease) == 8)
    #expect(FontZoom.step(current: 8.5, direction: .decrease) == 8)
}

@Test func actualSizeIsEditorDefault() {
    #expect(FontZoom.defaultSize == EditorFontSettings.defaultFontSize)
    #expect(FontZoom.defaultSize == 13)
}

@Test func zoomRangeMatchesFontSettingsClamp() {
    #expect(FontZoom.minSize == EditorFontSettings.minFontSize)
    #expect(FontZoom.maxSize == EditorFontSettings.maxFontSize)
    #expect(FontZoom.maxSize == 72)
}
