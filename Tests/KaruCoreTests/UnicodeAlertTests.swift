import Foundation
import Testing
@testable import KaruCore

// Coverage for the invisible / dangerous-character scanner (T12.10). The scanner
// is pure; the editor draws boxes around each hit live in `drawBackground`.

private func fullRange(_ s: String) -> NSRange {
    NSRange(location: 0, length: (s as NSString).length)
}

private func scanScalars(_ s: String) -> [UInt32] {
    UnicodeAlert.scan(text: s, range: fullRange(s)).map(\.scalar)
}

// MARK: - Clean text: zero hits

@Test func cleanAsciiTextHasNoHits() {
    #expect(UnicodeAlert.scan(text: "let x = 1\nprint(x)\n", range: fullRange("let x = 1\nprint(x)\n")).isEmpty)
}

@Test func normalUnicodeTextHasNoHits() {
    // CJK, accents, emoji — all legitimate, none flagged.
    let text = "héllo 世界 café 🎉 naïve"
    #expect(UnicodeAlert.scan(text: text, range: fullRange(text)).isEmpty)
}

// MARK: - Zero-width family

@Test func detectsZeroWidthCharacters() {
    #expect(scanScalars("a\u{200B}b") == [0x200B])   // ZWSP
    #expect(scanScalars("a\u{200C}b") == [0x200C])   // ZWNJ
    #expect(scanScalars("a\u{200D}b") == [0x200D])   // ZWJ
    #expect(scanScalars("a\u{2060}b") == [0x2060])   // word joiner
}

// MARK: - Bidirectional controls

@Test func detectsBidiControls() {
    #expect(scanScalars("a\u{202A}b") == [0x202A])   // LRE
    #expect(scanScalars("a\u{202E}b") == [0x202E])   // RLO
    #expect(scanScalars("a\u{2066}b") == [0x2066])   // LRI
    #expect(scanScalars("a\u{2069}b") == [0x2069])   // PDI
}

// MARK: - Abnormal line terminators

@Test func detectsAbnormalLineTerminators() {
    #expect(scanScalars("a\u{2028}b") == [0x2028])   // line separator
    #expect(scanScalars("a\u{2029}b") == [0x2029])   // paragraph separator
    #expect(scanScalars("a\u{0085}b") == [0x0085])   // NEL
}

// MARK: - Soft hyphen

@Test func detectsSoftHyphen() {
    #expect(scanScalars("soft\u{00AD}hyphen") == [0x00AD])
}

// MARK: - FEFF (BOM) leading-position exemption

@Test func feffAtDocumentStartIsExempt() {
    // A leading BOM is a legitimate byte-order mark → not flagged.
    #expect(UnicodeAlert.scan(text: "\u{FEFF}hello", range: fullRange("\u{FEFF}hello")).isEmpty)
}

@Test func feffElsewhereIsFlagged() {
    let text = "hello\u{FEFF}world"
    let hits = UnicodeAlert.scan(text: text, range: fullRange(text))
    #expect(hits.map(\.scalar) == [0xFEFF])
    #expect(hits.first?.range == NSRange(location: 5, length: 1))
}

// MARK: - Ranges + sub-range scanning

@Test func hitRangesAreSingleUnitAndInOrder() {
    let text = "\u{200B}x\u{202E}y"
    let hits = UnicodeAlert.scan(text: text, range: fullRange(text))
    #expect(hits.map(\.scalar) == [0x200B, 0x202E])
    #expect(hits.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
}

@Test func scanHonoursTheGivenRange() {
    // Two zero-width chars; scanning only the tail sees just the second.
    let text = "a\u{200B}b\u{200C}c"          // indices: a0 ZWSP1 b2 ZWNJ3 c4
    let hits = UnicodeAlert.scan(text: text, range: NSRange(location: 2, length: 3))
    #expect(hits.map(\.scalar) == [0x200C])
    #expect(hits.first?.range == NSRange(location: 3, length: 1))
}
