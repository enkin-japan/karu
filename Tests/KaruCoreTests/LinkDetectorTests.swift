import AppKit
import Testing
@testable import KaruCore

// T15.6 — URL recognition, in its unit-testable half: which spans of a document
// count as links and which URLs a ⌘-click is allowed to hand to the workspace.
//
// The painting side (temporary attributes) and the click hit test need a live
// layout manager with real glyph geometry, which is exactly the kind of thing
// that is unreliable in a headless test process — so the rules that decide
// *what* is a link, and the scheme filter that keeps a stray `file:` out of
// NSWorkspace, are pinned here instead.

private func substrings(_ text: String, _ ranges: [NSRange]) -> [String] {
    let ns = text as NSString
    return ranges.map { ns.substring(with: $0) }
}

// MARK: - Range extraction

@Test func detectorFindsPlainWebAddresses() {
    let text = "see https://example.com/a?b=1 and http://x.test/ for details"
    #expect(substrings(text, LinkDetector.detect(in: text))
            == ["https://example.com/a?b=1", "http://x.test/"])
}

@Test func detectorRangesLineUpWithTheDocument() {
    let text = "go to https://example.com now"
    let ranges = LinkDetector.detect(in: text)
    #expect(ranges.count == 1)
    #expect(ranges.first == NSRange(location: 6, length: 19))
}

@Test func detectorFindsBareEmailAddresses() {
    let text = "write to hi@example.com please"
    #expect(substrings(text, LinkDetector.detect(in: text)) == ["hi@example.com"])
    // The text carries no scheme, but the URL does — that is what gets opened.
    #expect(LinkDetector.url(forLinkText: "hi@example.com")?.absoluteString
            == "mailto:hi@example.com")
}

@Test func detectorFindsNothingInOrdinaryProse() {
    #expect(LinkDetector.detect(in: "just some notes, nothing to click").isEmpty)
    #expect(LinkDetector.detect(in: "").isEmpty)
}

@Test func detectorSkipsDocumentsOverTheSizeCap() {
    let text = "https://example.com " + String(repeating: "x", count: 200)
    #expect(!LinkDetector.detect(in: text).isEmpty)
    // Same text, a cap it cannot fit under: no scan at all, not a partial one.
    #expect(LinkDetector.detect(in: text, limit: 10).isEmpty)
}

// MARK: - Scheme filter

@Test func onlyWebAndMailSchemesSurvive() {
    #expect(LinkDetector.allowedSchemes == ["http", "https", "mailto"])
    #expect(LinkDetector.url(forLinkText: "https://example.com") != nil)
    #expect(LinkDetector.url(forLinkText: "http://example.com") != nil)
    #expect(LinkDetector.url(forLinkText: "mailto:hi@example.com") != nil)
}

@Test func otherSchemesAreNeverOpened() {
    // A ⌘-click must not be able to reach the file system or an app scheme
    // just because the text happened to spell one out.
    #expect(LinkDetector.url(forLinkText: "file:///etc/passwd") == nil)
    #expect(LinkDetector.url(forLinkText: "ftp://example.com/x") == nil)
    #expect(LinkDetector.url(forLinkText: "notes:///open") == nil)
    // ... and none of them are underlined either.
    #expect(LinkDetector.detect(in: "file:///etc/passwd").isEmpty)
    #expect(LinkDetector.detect(in: "ftp://ftp.example.com/pub").isEmpty)
}

@Test func aFragmentThatIsOnlyPartlyALinkIsNotOne() {
    // `url(forLinkText:)` is fed a cached range's substring; it must refuse
    // anything that is not a link end to end, so a stale range can never open
    // something the user did not click.
    #expect(LinkDetector.url(forLinkText: "see https://example.com") == nil)
    #expect(LinkDetector.url(forLinkText: "https://example.com now") == nil)
    #expect(LinkDetector.url(forLinkText: "") == nil)
    #expect(LinkDetector.url(forLinkText: "not a link at all") == nil)
}

// MARK: - Wiring

@MainActor
@Test func aDetectorWithNoScanYetOpensNothing() {
    // Freshly built, nothing scanned: every click is just a click.
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.string = "https://example.com"
    let detector = LinkDetector(textView: textView)
    #expect(detector.url(atPoint: NSPoint(x: 10, y: 10)) == nil)
}
