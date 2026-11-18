import AppKit
import Darwin

/// Machine-readable evidence for the two acceptance scripts (R11, R12).
///
/// * `KARU_BENCH_REPORT=<path>` (scripts/mem-benchmark.sh): once the first
///   window is up and its document loaded, write a small `key=value` report
///   saying which document is actually open, how long it is, and whether its
///   window is on screen — so a memory reading can be tied to what was
///   measured instead of trusted blindly.
/// * `KARU_SNAPSHOT=<png>` (scripts/visual-smoke.sh): next to the PNG, write
///   `<png>.json` with the shown document and the rects of the text area, the
///   line-number gutter and the first line of text in snapshot pixels, so the
///   smoke test can look for ink where text must be rather than judging the
///   whole image's brightness.
///
/// Both are read once at launch by `AppDelegate`; with the variables unset
/// nothing here runs and nothing stays resident (no observer, timer or
/// allocation). The encoders are pure so tests can pin the formats.
enum DiagnosticHost {

    // MARK: - Bench report (KARU_BENCH_REPORT)

    /// What the benchmark needs to know about the window it measured.
    struct BenchReport: Equatable {
        static let format = "karu-bench-report/1"

        /// Canonical (`realpath`) path of the document in the key/front
        /// editor window; empty for an untitled document.
        var documentPath: String
        /// Document length in UTF-16 units.
        var documentLength: Int
        /// Window frame size in points.
        var windowWidth: Double
        var windowHeight: Double
        /// `NSWindow.isVisible`.
        var windowVisible: Bool
        /// `occlusionState.contains(.visible)`: at least part of the window
        /// is on screen (false when covered, on another space, screen locked).
        var occlusionVisible: Bool
        /// `NSWindow.isOnActiveSpace`.
        var onActiveSpace: Bool
        var backingScaleFactor: Double
        /// Number of editor windows the app delegate holds.
        var editorWindows: Int

        /// `key=value` lines, one per field, values escaped so a path can
        /// never break the line structure; the final `complete=1` lets a
        /// reader tell a finished report from one still being written.
        func encoded() -> String {
            let pairs: [(String, String)] = [
                ("format", Self.format),
                ("documentPath", DiagnosticHost.escape(documentPath)),
                ("documentLength", String(documentLength)),
                ("windowWidth", DiagnosticHost.number(windowWidth)),
                ("windowHeight", DiagnosticHost.number(windowHeight)),
                ("windowVisible", windowVisible ? "1" : "0"),
                ("windowOcclusionVisible", occlusionVisible ? "1" : "0"),
                ("windowOnActiveSpace", onActiveSpace ? "1" : "0"),
                ("backingScaleFactor", DiagnosticHost.number(backingScaleFactor)),
                ("editorWindows", String(editorWindows)),
                ("complete", "1"),
            ]
            return pairs.map { "\($0.0)=\($0.1)\n" }.joined()
        }
    }

    // MARK: - Snapshot geometry (KARU_SNAPSHOT sidecar)

    /// A rect in snapshot pixels, origin at the image's top-left corner (the
    /// convention of `NSBitmapImageRep.colorAt(x:y:)`).
    struct PixelRect: Codable, Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int

        static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
    }

    struct SnapshotGeometry: Codable, Equatable {
        static let currentFormat = "karu-snapshot-geometry/1"

        var format: String = Self.currentFormat
        /// Canonical path of the document shown; empty for untitled.
        var documentPath: String
        /// Logical lines in the document (newline count + 1).
        var lineCount: Int
        var backingScaleFactor: Double
        var imageWidth: Int
        var imageHeight: Int
        /// Visible part of the text view (the scroll view's clip view).
        var textArea: PixelRect
        /// The line-number ruler.
        var gutter: PixelRect
        /// Bounding box of line 1's glyphs, clipped to the text area; zero for
        /// an empty first line.
        var firstLine: PixelRect

        func jsonData() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)
        }
    }

    /// Converts `rect` (in the coordinates of the captured view, whose bounds
    /// are `bounds`) to snapshot pixels with a top-left origin, rounding
    /// outward and clamping to the image.
    static func pixelRect(_ rect: NSRect, bounds: NSRect, isFlipped: Bool,
                          pixelsWide: Int, pixelsHigh: Int) -> PixelRect {
        guard bounds.width > 0, bounds.height > 0, !rect.isNull, !rect.isEmpty else { return .zero }
        let sx = CGFloat(pixelsWide) / bounds.width
        let sy = CGFloat(pixelsHigh) / bounds.height
        let top = isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
        let x0 = max(0, Int(((rect.minX - bounds.minX) * sx).rounded(.down)))
        let y0 = max(0, Int((top * sy).rounded(.down)))
        let x1 = min(pixelsWide, Int(((rect.maxX - bounds.minX) * sx).rounded(.up)))
        let y1 = min(pixelsHigh, Int(((top + rect.height) * sy).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return .zero }
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: - Helpers

    /// `realpath(3)` of the URL's path, the path itself when it cannot be
    /// resolved, and "" for no URL (untitled). Scripts compare against their
    /// own `pwd -P` paths, so `/var` vs `/private/var` must not matter.
    static func canonicalPath(_ url: URL?) -> String {
        guard let path = url?.path, !path.isEmpty else { return "" }
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Backslash-escapes `\`, newline and carriage return.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Integral values without a fraction ("800"), others with one decimal.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// Logical line count of `text`: newlines + 1.
    static func lineCount(of text: NSString) -> Int {
        var count = 1
        var index = 0
        while index < text.length {
            let found = text.range(of: "\n", range: NSRange(location: index, length: text.length - index))
            if found.location == NSNotFound { break }
            count += 1
            index = found.location + 1
        }
        return count
    }

    // MARK: - Live capture (diagnostic runs only)

    /// The editor window a report describes: the key window if it is an
    /// editor, else the frontmost editor window, else the first controller.
    @MainActor
    private static func frontController(among controllers: [EditorWindowController]) -> EditorWindowController? {
        if let key = NSApp.keyWindow?.windowController as? EditorWindowController { return key }
        for window in NSApp.orderedWindows {
            if let controller = window.windowController as? EditorWindowController,
               controllers.contains(where: { $0 === controller }) {
                return controller
            }
        }
        return controllers.first
    }

    @MainActor
    static func makeBenchReport(controllers: [EditorWindowController]) -> BenchReport {
        let controller = frontController(among: controllers)
        let window = controller?.window
        return BenchReport(
            documentPath: canonicalPath(controller?.currentFileURL),
            documentLength: controller.map { ($0.textViewForTesting.string as NSString).length } ?? 0,
            windowWidth: Double(window?.frame.width ?? 0),
            windowHeight: Double(window?.frame.height ?? 0),
            windowVisible: window?.isVisible ?? false,
            occlusionVisible: window?.occlusionState.contains(.visible) ?? false,
            onActiveSpace: window?.isOnActiveSpace ?? false,
            backingScaleFactor: Double(window?.backingScaleFactor ?? 0),
            editorWindows: controllers.count)
    }

    /// Writes the bench report to `path` once the first window is ready.
    /// Startup documents load synchronously before this is called, so the
    /// only thing worth waiting for is the window server reporting the window
    /// as on screen: polled every 0.25 s from 0.5 s, written at the first
    /// on-screen check or at 3 s regardless (the report then says it was not
    /// visible). Nothing outlives the write. Writes only `path`, in place
    /// (no temporary sibling); readers wait for the final `complete=1` line.
    @MainActor
    static func scheduleBenchReport(to path: String,
                                    controllers: @escaping @MainActor () -> [EditorWindowController]) {
        func attempt(_ remaining: Int) {
            let report = makeBenchReport(controllers: controllers())
            if (report.windowVisible && report.occlusionVisible) || remaining <= 0 {
                FileManager.default.createFile(atPath: path, contents: Data(report.encoded().utf8))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { attempt(remaining - 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { attempt(10) }
        }
    }

    /// Geometry of what the snapshot captured: `view` is the rendered view
    /// (the window's theme frame), `rep` the bitmap it was cached into.
    @MainActor
    static func snapshotGeometry(window: NSWindow, view: NSView, rep: NSBitmapImageRep) -> SnapshotGeometry {
        let controller = window.windowController as? EditorWindowController
        let toPixels: (NSRect) -> PixelRect = { rect in
            pixelRect(rect, bounds: view.bounds, isFlipped: view.isFlipped,
                      pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh)
        }
        var textArea = PixelRect.zero, gutter = PixelRect.zero, firstLine = PixelRect.zero
        var lineCount = 0
        if let textView = controller?.textViewForTesting {
            let text = textView.string as NSString
            lineCount = Self.lineCount(of: text)
            var visible = NSRect.null
            if let scrollView = textView.enclosingScrollView {
                let clip = scrollView.contentView
                visible = clip.convert(clip.bounds, to: view)
                if let ruler = scrollView.verticalRulerView, !ruler.isHidden {
                    let rulerRect = ruler.convert(ruler.bounds, to: view)
                    gutter = toPixels(rulerRect)
                    // The clip view can extend under the ruler; the text area
                    // proper starts where the gutter ends, so line numbers
                    // never count as text.
                    if rulerRect.maxX > visible.minX, rulerRect.minX <= visible.minX {
                        visible = NSRect(x: rulerRect.maxX, y: visible.minY,
                                         width: max(0, visible.maxX - rulerRect.maxX), height: visible.height)
                    }
                }
                textArea = toPixels(visible)
            }
            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                var lineEnd = 0
                text.getLineStart(nil, end: nil, contentsEnd: &lineEnd,
                                  for: NSRange(location: 0, length: 0))
                if lineEnd > 0 {
                    let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: 0, length: lineEnd),
                                                          actualCharacterRange: nil)
                    layoutManager.ensureLayout(forGlyphRange: glyphs)
                    var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                    rect = rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
                    let inView = textView.convert(rect, to: view)
                    firstLine = toPixels(visible.isNull ? inView : inView.intersection(visible))
                }
            }
        }
        return SnapshotGeometry(
            documentPath: canonicalPath(controller?.currentFileURL),
            lineCount: lineCount,
            backingScaleFactor: Double(window.backingScaleFactor),
            imageWidth: rep.pixelsWide,
            imageHeight: rep.pixelsHigh,
            textArea: textArea,
            gutter: gutter,
            firstLine: firstLine)
    }

    /// Writes the snapshot sidecar; best-effort like the PNG itself.
    @MainActor
    static func writeSnapshotGeometry(window: NSWindow, view: NSView, rep: NSBitmapImageRep, to path: String) {
        guard let data = try? snapshotGeometry(window: window, view: view, rep: rep).jsonData() else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
