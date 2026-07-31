import AppKit
import Testing
@testable import KaruCore

// T15.3 — the gutter's width rule, extracted as a pure function so the geometry
// can be checked without a window (the ruler itself needs a live scroll view).
//
// The bug these guard: line numbers were pinned at 11 pt with 6 pt of padding
// and a 40 pt minimum width, so an 18 pt document got small numbers in a gutter
// wider than they needed.

@MainActor
@Test func gutterDropsTheOldFortyPointFloor() {
    // Two digits of 18 pt text used to be padded out to the 40 pt floor.
    let width = GutterView.thickness(fontSize: 18, digits: 2, hasArrowColumn: false)
    #expect(width < 40)
    // …but still fits the numbers themselves.
    #expect(width > 18)
}

@MainActor
@Test func gutterWidthGrowsWithTheFontSize() {
    var previous: CGFloat = 0
    for size in stride(from: CGFloat(8), through: 72, by: 2) {
        let width = GutterView.thickness(fontSize: size, digits: 3, hasArrowColumn: false)
        #expect(width >= previous)
        previous = width
    }
    // Strictly wider across the whole range, not merely non-decreasing.
    #expect(GutterView.thickness(fontSize: 72, digits: 3, hasArrowColumn: false)
            > GutterView.thickness(fontSize: 8, digits: 3, hasArrowColumn: false))
}

@MainActor
@Test func gutterWidthGrowsWithTheLineCount() {
    let two = GutterView.thickness(fontSize: 13, digits: 2, hasArrowColumn: false)
    let three = GutterView.thickness(fontSize: 13, digits: 3, hasArrowColumn: false)
    let five = GutterView.thickness(fontSize: 13, digits: 5, hasArrowColumn: false)
    #expect(three > two)
    #expect(five > three)
}

@MainActor
@Test func gutterReservesExactlyTheArrowColumn() {
    for size in [CGFloat(8), 13, 18, 40] {
        let bare = GutterView.thickness(fontSize: size, digits: 4, hasArrowColumn: false)
        let withArrows = GutterView.thickness(fontSize: size, digits: 4, hasArrowColumn: true)
        // The fold click target must not shrink with the type size.
        #expect(withArrows - bare == GutterView.arrowColumnWidth)
    }
}
