import AppKit
import Foundation
import Testing
@testable import KaruCore

// Exercises the pure line-number parser behind the Ctrl+G "Go to Line" panel
// (T11.5). The panel UI itself is a thin transient AppKit shell over this.

@Test func parseAcceptsPlainPositiveIntegers() {
    #expect(GoToLineController.parseLineInput("1") == 1)
    #expect(GoToLineController.parseLineInput("42") == 42)
    #expect(GoToLineController.parseLineInput("100000") == 100000)
}

@Test func parseTrimsSurroundingWhitespace() {
    #expect(GoToLineController.parseLineInput("  7  ") == 7)
    #expect(GoToLineController.parseLineInput("\t12\n") == 12)
}

@Test func parseRejectsNonNumericInput() {
    #expect(GoToLineController.parseLineInput("") == nil)
    #expect(GoToLineController.parseLineInput("   ") == nil)
    #expect(GoToLineController.parseLineInput("abc") == nil)
    #expect(GoToLineController.parseLineInput("12x") == nil)
    #expect(GoToLineController.parseLineInput("3.5") == nil)
    #expect(GoToLineController.parseLineInput("1 2") == nil)
}

@Test func parseRejectsZeroAndNegative() {
    #expect(GoToLineController.parseLineInput("0") == nil)
    #expect(GoToLineController.parseLineInput("-5") == nil)
}

@Test func parseReturnsOverRangeValueForCallerToClamp() {
    // Over-range positive input comes back unchanged; clamping to the document's
    // line count is the controller's job, not the parser's.
    #expect(GoToLineController.parseLineInput("999999") == 999999)
}
