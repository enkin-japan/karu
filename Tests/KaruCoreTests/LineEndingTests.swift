import Foundation
import Testing
@testable import KaruCore

// MARK: - LineEnding.detect

@Test func detectPureLF() {
    #expect(LineEnding.detect(in: "a\nb\nc\n") == .lf)
}

@Test func detectPureCRLF() {
    #expect(LineEnding.detect(in: "a\r\nb\r\nc\r\n") == .crlf)
}

@Test func detectPureCR() {
    #expect(LineEnding.detect(in: "a\rb\rc\r") == .cr)
}

@Test func detectMixedTakesMajority() {
    // Two CRLF vs one lone LF → CRLF wins. The lone LF here belongs to no CR.
    #expect(LineEnding.detect(in: "a\r\nb\r\nc\nd") == .crlf)
    // Three lone CR vs one LF → CR wins.
    #expect(LineEnding.detect(in: "a\rb\rc\rd\ne") == .cr)
}

@Test func detectNoNewlineDefaultsToLF() {
    #expect(LineEnding.detect(in: "single line, no break") == .lf)
    #expect(LineEnding.detect(in: "") == .lf)
}

@Test func detectDoesNotCountCRLFAsLoneCROrLF() {
    // A file that is purely CRLF must not resolve to CR or LF via double-counting.
    let text = String(repeating: "x\r\n", count: 10)
    #expect(LineEnding.detect(in: text) == .crlf)
}

// MARK: - LineEnding.convert

@Test func convertLFToCRLF() {
    #expect(LineEnding.convert("a\nb\nc", to: .crlf) == "a\r\nb\r\nc")
}

@Test func convertLFToCR() {
    #expect(LineEnding.convert("a\nb\nc", to: .cr) == "a\rb\rc")
}

@Test func convertCRLFToLF() {
    #expect(LineEnding.convert("a\r\nb\r\nc", to: .lf) == "a\nb\nc")
}

@Test func convertCRToLF() {
    #expect(LineEnding.convert("a\rb\rc", to: .lf) == "a\nb\nc")
}

@Test func convertMixedNormalizesUniformly() {
    // Mixed input → uniform CRLF output regardless of the styles it started with.
    #expect(LineEnding.convert("a\r\nb\nc\rd", to: .crlf) == "a\r\nb\r\nc\r\nd")
}

@Test func convertIsIdempotent() {
    let lf = "a\nb\nc\n"
    #expect(LineEnding.convert(lf, to: .lf) == lf)
    let crlf = "a\r\nb\r\nc\r\n"
    #expect(LineEnding.convert(crlf, to: .crlf) == crlf)
    let cr = "a\rb\rc\r"
    #expect(LineEnding.convert(cr, to: .cr) == cr)
    // Converting twice equals converting once.
    #expect(LineEnding.convert(LineEnding.convert(lf, to: .crlf), to: .crlf)
            == LineEnding.convert(lf, to: .crlf))
}

@Test func lineEndingDisplayNames() {
    #expect(LineEnding.lf.displayName == "LF")
    #expect(LineEnding.crlf.displayName == "CRLF")
    #expect(LineEnding.cr.displayName == "CR")
}
