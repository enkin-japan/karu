import AppKit
import Testing
@testable import KaruCore

// R11 / R12: the bench report and the snapshot sidecar are what
// scripts/mem-benchmark.sh and scripts/visual-smoke.sh parse to decide whether
// a run has evidence. These pin the formats and the pixel conversion; the live
// capture itself is exercised by running the two scripts.
struct DiagnosticHostTests {

    @Test func benchReportIsKeyValueLinesEndingWithComplete() {
        let report = DiagnosticHost.BenchReport(
            documentPath: "/private/var/folders/x/medium.json", documentLength: 1_048_576,
            windowWidth: 800, windowHeight: 622.5, windowVisible: true, occlusionVisible: false,
            onActiveSpace: true, backingScaleFactor: 2, editorWindows: 1)
        #expect(report.encoded() == """
            format=karu-bench-report/1
            documentPath=/private/var/folders/x/medium.json
            documentLength=1048576
            windowWidth=800
            windowHeight=622.5
            windowVisible=1
            windowOcclusionVisible=0
            windowOnActiveSpace=1
            backingScaleFactor=2
            editorWindows=1
            complete=1

            """)
    }

    @Test func benchReportEscapesPathsThatWouldBreakLines() {
        let report = DiagnosticHost.BenchReport(
            documentPath: "/tmp/a\nb\\c", documentLength: 0, windowWidth: 0, windowHeight: 0,
            windowVisible: false, occlusionVisible: false, onActiveSpace: false,
            backingScaleFactor: 1, editorWindows: 0)
        let lines = report.encoded().split(separator: "\n")
        #expect(lines.contains("documentPath=/tmp/a\\nb\\\\c"))
        #expect(lines.count == 11)
    }

    @Test func untitledReportHasEmptyPath() {
        #expect(DiagnosticHost.canonicalPath(nil) == "")
    }

    @Test func canonicalPathResolvesSymlinkedTempDirectory() throws {
        // /var is a symlink to /private/var on macOS; scripts compare against
        // `pwd -P`, so the report must carry the resolved form.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruDiag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try Data().write(to: file)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let resolved = DiagnosticHost.canonicalPath(link)
        #expect(resolved.hasSuffix("/f.txt"))
        #expect(resolved == DiagnosticHost.canonicalPath(file))
        // A path that does not exist comes back unchanged.
        #expect(DiagnosticHost.canonicalPath(URL(fileURLWithPath: "/no/such/file")) == "/no/such/file")
    }

    @Test func pixelRectFlipsUnflippedViewsAndScales() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        // Unflipped: a rect at the bottom-left in points sits at the bottom of
        // the image in top-left pixel coordinates.
        let rect = DiagnosticHost.pixelRect(NSRect(x: 10, y: 20, width: 100, height: 50), bounds: bounds,
                                            isFlipped: false, pixelsWide: 1600, pixelsHigh: 1200)
        #expect(rect == DiagnosticHost.PixelRect(x: 20, y: 1060, width: 200, height: 100))
        let flipped = DiagnosticHost.pixelRect(NSRect(x: 10, y: 20, width: 100, height: 50), bounds: bounds,
                                               isFlipped: true, pixelsWide: 1600, pixelsHigh: 1200)
        #expect(flipped == DiagnosticHost.PixelRect(x: 20, y: 40, width: 200, height: 100))
    }

    @Test func pixelRectRoundsOutwardAndClamps() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 100)
        let rect = DiagnosticHost.pixelRect(NSRect(x: 0.4, y: -10, width: 120, height: 30.2), bounds: bounds,
                                            isFlipped: true, pixelsWide: 100, pixelsHigh: 100)
        #expect(rect == DiagnosticHost.PixelRect(x: 0, y: 0, width: 100, height: 21))
        #expect(DiagnosticHost.pixelRect(.zero, bounds: bounds, isFlipped: true,
                                         pixelsWide: 100, pixelsHigh: 100) == .zero)
        #expect(DiagnosticHost.pixelRect(.null, bounds: bounds, isFlipped: true,
                                         pixelsWide: 100, pixelsHigh: 100) == .zero)
    }

    @Test func snapshotGeometryRoundTripsThroughJSON() throws {
        let geometry = DiagnosticHost.SnapshotGeometry(
            documentPath: "/private/tmp/sample.md", lineCount: 5, backingScaleFactor: 2,
            imageWidth: 1600, imageHeight: 1256,
            textArea: .init(x: 100, y: 120, width: 1500, height: 1080),
            gutter: .init(x: 0, y: 120, width: 100, height: 1080),
            firstLine: .init(x: 110, y: 130, width: 180, height: 34))
        let data = try geometry.jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "karu-snapshot-geometry/1")
        #expect(object["documentPath"] as? String == "/private/tmp/sample.md")
        #expect((object["gutter"] as? [String: Int])?["width"] == 100)
        let decoded = try JSONDecoder().decode(DiagnosticHost.SnapshotGeometry.self, from: data)
        #expect(decoded == geometry)
    }

    @Test func lineCountIsNewlinesPlusOne() {
        #expect(DiagnosticHost.lineCount(of: "") == 1)
        #expect(DiagnosticHost.lineCount(of: "a") == 1)
        #expect(DiagnosticHost.lineCount(of: "a\n") == 2)
        #expect(DiagnosticHost.lineCount(of: "# H\n\ndef f():\n    return 42\n") == 5)
    }
}
