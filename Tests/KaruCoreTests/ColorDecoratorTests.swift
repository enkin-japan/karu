import Foundation
import CoreGraphics
import Testing
@testable import KaruCore

// Approximate equality for channel comparisons (parsing divides by 255 etc.).
private func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.01) -> Bool {
    abs(a - b) <= tol
}

private func fullRange(_ text: String) -> NSRange {
    NSRange(location: 0, length: (text as NSString).length)
}

// MARK: - Hex forms

@Test func hexShortFormExpandsNibbles() {
    let c = ColorDecorator.hexColor("#f00")
    #expect(c != nil)
    #expect(approx(c!.r, 1) && approx(c!.g, 0) && approx(c!.b, 0) && approx(c!.a, 1))
}

@Test func hexSixDigitForm() {
    let c = ColorDecorator.hexColor("#00ff80")
    #expect(c != nil)
    #expect(approx(c!.r, 0) && approx(c!.g, 1) && approx(c!.b, 0.502))
    #expect(approx(c!.a, 1))
}

@Test func hexEightDigitFormCarriesAlpha() {
    let c = ColorDecorator.hexColor("#ff000080")
    #expect(c != nil)
    #expect(approx(c!.r, 1) && approx(c!.g, 0) && approx(c!.b, 0))
    #expect(approx(c!.a, 0.502))
}

@Test func hexMatchesInText() {
    let text = "color: #abc; background: #112233;"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    let hexes = matches.map { (text as NSString).substring(with: $0.range) }
    #expect(hexes.contains("#abc"))
    #expect(hexes.contains("#112233"))
}

@Test func hexDoesNotEatSevenDigitRun() {
    // A 7-hex-digit run is not a valid colour: no #123456 partial match.
    let text = "#1234567"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.isEmpty)
}

// MARK: - rgb / rgba

@Test func rgbIntegerForm() {
    let text = "rgb(255, 128, 0)"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    let c = matches[0].color
    #expect(approx(c.r, 1) && approx(c.g, 0.502) && approx(c.b, 0) && approx(c.a, 1))
}

@Test func rgbaCarriesAlpha() {
    let text = "rgba(0, 0, 255, 0.5)"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    let c = matches[0].color
    #expect(approx(c.r, 0) && approx(c.g, 0) && approx(c.b, 1) && approx(c.a, 0.5))
}

// MARK: - hsl conversion

@Test func hslPureRedConvertsToRGB() {
    let c = ColorDecorator.hslToRGB(h: 0, s: 1, l: 0.5)
    #expect(approx(c.r, 1) && approx(c.g, 0) && approx(c.b, 0) && approx(c.a, 1))
}

@Test func hslPureGreenAndBlue() {
    let g = ColorDecorator.hslToRGB(h: 120, s: 1, l: 0.5)
    #expect(approx(g.r, 0) && approx(g.g, 1) && approx(g.b, 0))
    let b = ColorDecorator.hslToRGB(h: 240, s: 1, l: 0.5)
    #expect(approx(b.r, 0) && approx(b.g, 0) && approx(b.b, 1))
}

@Test func hslMatchesInText() {
    let text = "color: hsl(0, 100%, 50%);"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    let c = matches[0].color
    #expect(approx(c.r, 1) && approx(c.g, 0) && approx(c.b, 0))
}

@Test func hslaMatchesWithAlpha() {
    let text = "hsla(240, 100%, 50%, 0.25)"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    #expect(approx(matches[0].color.b, 1))
    #expect(approx(matches[0].color.a, 0.25))
}

// MARK: - Named colours (whole word only)

@Test func namedColorMatchesWholeWord() {
    let text = "color: red;"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    let c = matches[0].color
    #expect(approx(c.r, 1) && approx(c.g, 0) && approx(c.b, 0))
}

@Test func namedColorDoesNotMatchSubstring() {
    // "green" is a colour but "greenish" / "background" must not light up.
    let text = "background: evergreen;"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.isEmpty)
}

@Test func namedColorIsCaseInsensitive() {
    let text = "border: BLUE"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.count == 1)
    #expect(approx(matches[0].color.b, 1))
}

// MARK: - Range semantics / non-CSS agnostic

@Test func nonColorTextYieldsNoMatches() {
    let text = "let x = 42; // just code, no colors"
    let matches = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    #expect(matches.isEmpty)
}

@Test func matchesAreSortedAndScopedToRange() {
    let text = "a #fff b rgb(0,0,0) c red"
    // Restrict to the first half — only the hex should be seen.
    let head = NSRange(location: 0, length: 6) // "a #fff"
    let matches = ColorDecorator.colorMatches(in: text, range: head)
    #expect(matches.count == 1)
    #expect((text as NSString).substring(with: matches[0].range) == "#fff")

    // Full range: all three, in document order.
    let all = ColorDecorator.colorMatches(in: text, range: fullRange(text))
    let ordered = all.map { $0.range.location }
    #expect(ordered == ordered.sorted())
    #expect(all.count == 3)
}
