import AppKit

/// Maps `TokenKind`s to colours, following VS Code's **Dark Modern** palette in
/// dark appearance and **Light Modern** in light appearance. Each colour is a
/// dynamic `NSColor` built with `NSColor(name:dynamicProvider:)`, so it resolves
/// against whichever appearance the text view is drawing in and flips live on a
/// light/dark switch without the theme storing two concrete values. `.plain`
/// returns `nil` (no attribute → the view's default text colour).
public struct HighlightTheme {
    public init() {}

    public func color(for kind: TokenKind) -> NSColor? {
        switch kind {
        case .keyword:        return Self.keyword
        // Built-ins share the function colour (VS Code renders both in yellow /
        // brown), while staying a distinct token so the rule wins over symbols.
        case .builtin:        return Self.function
        case .string:         return Self.string
        case .number:         return Self.number
        case .comment:        return Self.comment
        case .type:           return Self.type
        // Keys / member-style names (JSON keys, shell `$VAR`, `self` / `cls`)
        // read as the variable blue, matching VS Code's property colour.
        case .property:       return Self.variable
        case .punctuation:    return Self.punctuation
        // In-document declared symbols reuse the function / variable colours.
        case .symbolFunction: return Self.function
        case .symbolVariable: return Self.variable
        case .plain:          return nil
        }
    }

    // MARK: - Palette (Dark Modern / Light Modern approximations)

    private static let keyword     = dynamic(dark: 0x569CD6, light: 0x0000FF)
    private static let string      = dynamic(dark: 0xCE9178, light: 0xA31515)
    private static let number      = dynamic(dark: 0xB5CEA8, light: 0x098658)
    private static let comment     = dynamic(dark: 0x6A9955, light: 0x008000)
    private static let type        = dynamic(dark: 0x4EC9B2, light: 0x267F99)
    private static let function    = dynamic(dark: 0xDCDCAA, light: 0x795E26)
    private static let variable    = dynamic(dark: 0x9CDCFE, light: 0x001080)
    private static let punctuation = dynamic(dark: 0xD4D4D4, light: 0x000000)

    /// Builds a dynamic colour that returns `dark` under a dark appearance and
    /// `light` otherwise, resolved at draw time so temporary-attribute colours
    /// track the current appearance.
    private static func dynamic(dark: UInt32, light: UInt32) -> NSColor {
        let darkColor = NSColor(rgb: dark)
        let lightColor = NSColor(rgb: light)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

private extension NSColor {
    /// Builds an sRGB colour from a packed `0xRRGGBB` integer.
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(rgb & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}

/// Viewport-only syntax highlight scheduler.
///
/// Design (ARCHITECTURE.md §3.1, §2.5):
/// - **Viewport-only**: only the visible character range is tokenized and
///   coloured, and colour is written with `NSLayoutManager` *temporary*
///   attributes — never stored into the text storage, never precomputed for the
///   whole document.
/// - **Foreground only**: the highlighter owns `.foregroundColor` temporary
///   attributes exclusively; `.backgroundColor` belongs to the find bar, so the
///   two never collide.
/// - **Module-gated**: gated on `module.highlight`. When the module is switched
///   off it removes every foreground attribute and drops all runtime state
///   (the compiled `LanguageDefinition`), so a disabled highlighter's resident
///   cost returns to ≈ 0. It rebuilds from the analysis's language when
///   re-enabled.
/// - **Shared analysis** (M17 T17.1): the language, the declared-symbol table
///   and the lexical checkpoints come from the window's `DocumentAnalysis`; the
///   engine no longer scans declarations itself. Constructed without one (unit
///   tests, probes) it owns a private analysis and forwards its edits to it.
/// - **Cross-line state** (M17 T17.2): profiled languages resume the generic
///   scanner and Python its `PythonTokenizer` from the nearest checkpoint at or
///   before the band (`bandTokens`); nothing is scanned from offset 0 per pass.
/// - **Off-screen cleanup** (T17.2): colour is held only in the last painted
///   band (`colouredRange`); each pass clears what lies outside its new band.
/// - **Long lines** (plan §6 item 2): the band snaps to whole lines only when
///   the line edge is within `LanguageDefinition.longLineThreshold` of the
///   viewport (`bandBounds`); otherwise it starts / ends mid-line. Profiled
///   languages resume the scanner to a safe point there (checkpoints inside a
///   long line too) and paint only that slice; Python and unprofiled
///   languages colour the slice with stateless rules.
@MainActor
public final class HighlightEngine: NSObject, TextStorageObserving, DocumentAnalysisConsumer {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let moduleSettings: ModuleSettings
    private let theme = HighlightTheme()

    /// The document analysis that owns the language, the declaration snapshot
    /// and the lexical checkpoints. Shared with completion in an editor window;
    /// private to this engine when none was injected (`ownsAnalysis`).
    let analysis: DocumentAnalysis
    /// True when the engine created `analysis` itself and must therefore feed
    /// it the edits it observes (nobody else registered it on a hub).
    private let ownsAnalysis: Bool

    /// Releasable runtime state: the compiled language definition. `nil` when
    /// the module is disabled or no language applies to the current file.
    private var language: LanguageDefinition?

    /// Releasable runtime state: in-document declared symbols (functions /
    /// types / variables), coloured in the gaps the language rules leave
    /// uncoloured. Taken from the analysis's declaration snapshot on language
    /// change and whenever a new snapshot is published (after the edit
    /// debounce); dropped together with `language` when the module is switched
    /// off, so it is part of the `isRuntimeStateReleased` guarantee.
    private var symbolTable: WordIndex.SymbolTable?

    /// A single compiled identifier matcher, reused across every symbol pass.
    // swiftlint:disable:next force_try
    private static let identifierRegex = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)

    /// Whether the `highlight` module is currently on.
    private var moduleEnabled: Bool

    /// The character range actually painted by the last `highlightVisibleRange`
    /// pass (the overscanned span, whole lines except inside a long line — not
    /// just the viewport). A pure
    /// scroll whose new viewport still falls inside this band does zero work.
    /// Set back to `nil` whenever the painted colours may be stale: on edit, on
    /// language change, on a module toggle, and when all colour is cleared.
    /// Internal (not private) so unit tests can assert the invalidation.
    var paintedRange: NSRange?

    /// The span in which this engine may currently hold foreground colour
    /// (plan §6 item 1). Each pass clears what lies outside its new band, so
    /// scrolling a large file never accumulates colour runs off screen. Kept
    /// across edits by mapping it through them (`heldRange`), so it may be
    /// larger than the band actually painted, never smaller. `nil` when no
    /// colour is held. Internal so tests can read it.
    var colouredRange: NSRange?

    /// KVO token for the application's effective appearance. A light/dark switch
    /// invalidates the painted band and repaints the viewport so the temporary
    /// attribute colours re-resolve to the new appearance.
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Queryable state (for tests / diagnostics)

    /// True when no runtime highlight state is held — neither a compiled
    /// language nor a scanned symbol table. When the module is disabled this is
    /// guaranteed true (the acceptance-criteria "released" state).
    public var isRuntimeStateReleased: Bool { language == nil && symbolTable == nil }

    /// Whether the `highlight` module is enabled.
    public var isModuleEnabled: Bool { moduleEnabled }

    // MARK: - Init

    /// Center on which `ModuleSettings.didChangeNotification` is observed. Must
    /// match the one the injected `moduleSettings` posts to (both default to
    /// `.default` in production; tests inject a private center for isolation).
    private let moduleCenter: NotificationCenter

    /// `analysis`: the window's shared document analysis. When `nil` the
    /// engine creates a private one on the same text view and settings (and
    /// forwards its edits to it), so a standalone engine behaves as before.
    public init(textView: NSTextView,
                scrollView: NSScrollView,
                moduleSettings: ModuleSettings = ModuleSettings(),
                moduleCenter: NotificationCenter = .default,
                analysis: DocumentAnalysis? = nil) {
        self.textView = textView
        self.scrollView = scrollView
        self.moduleSettings = moduleSettings
        self.moduleCenter = moduleCenter
        self.moduleEnabled = moduleSettings.isEnabled(.highlight)
        // Created before this engine observes module changes, so the analysis
        // sees each toggle first (same order as in an editor window).
        self.analysis = analysis ?? DocumentAnalysis(textView: textView,
                                                     moduleSettings: moduleSettings,
                                                     moduleCenter: moduleCenter)
        self.ownsAnalysis = analysis == nil
        super.init()
        self.analysis.addConsumer(self)

        // Recolour on scroll (AppKit view notifications: always `.default`).
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: clip
        )
        // Recolour when the text view is resized / relaid out.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: textView
        )
        // React to the module switch on the module settings' center.
        moduleCenter.addObserver(
            self, selector: #selector(moduleSettingsChanged(_:)),
            name: ModuleSettings.didChangeNotification, object: nil
        )
        // React to a light/dark appearance switch. Highlight colours are stored
        // as *temporary attributes*: they re-resolve on redraw, but the
        // `paintedRange` short-circuit means a subsequent scroll would skip
        // repainting, so invalidate the band and repaint the viewport now.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.appearanceDidChange() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        appearanceObservation?.invalidate()
        pendingViewport?.cancel()
    }

    // MARK: - Language wiring

    /// Points the document at the language owning `ext` (the file's
    /// extension) via the analysis — the language is the analysis's, so in an
    /// editor window this also re-points completion. Passing `nil` or an
    /// unknown extension leaves the engine idle.
    ///
    /// Returns the resolved language identifier (e.g. `"python"`), or `nil` if
    /// the extension maps to no registered language.
    @discardableResult
    public func setLanguage(fileExtension ext: String?) -> String? {
        analysis.setLanguage(identifier: ext.flatMap { LanguageRegistry.identifier(forExtension: $0) })
        return currentLanguageIdentifier
    }

    /// Points the document at the language whose `identifier` is `id` (e.g.
    /// from the Language menu or the content sniffer) via the analysis. Passing
    /// `nil` or an empty / unknown identifier leaves the engine idle (plain
    /// text). The language lives in the analysis, so it survives a module
    /// toggle.
    ///
    /// Returns the resolved identifier, or `nil` if it maps to no registered
    /// language.
    @discardableResult
    public func setLanguage(identifier id: String?) -> String? {
        analysis.setLanguage(identifier: id)
        return currentLanguageIdentifier
    }

    /// The identifier of the language resolved for the current file (e.g.
    /// `"markdown"`), independent of module state — read from the analysis,
    /// which keeps it whether or not the definition is built.
    public var currentLanguageIdentifier: String? {
        analysis.languageIdentifier.isEmpty ? nil : analysis.languageIdentifier
    }

    /// Builds the compiled definition for the analysis's language and takes
    /// the symbol table from its declaration snapshot, but only while the
    /// module is enabled. Clears both otherwise.
    private func rebuildLanguage() {
        // Language change (via the analysis, and module re-enable which also
        // routes through here) invalidates the painted band.
        removeAllForegroundColour()
        guard moduleEnabled else {
            language = nil
            symbolTable = nil
            return
        }
        let id = analysis.languageIdentifier
        language = id.isEmpty ? nil : LanguageRegistry.definition(forIdentifier: id)
        symbolTable = language == nil ? nil : analysis.ensureDeclarations().scan.table
    }

    // MARK: - DocumentAnalysisConsumer

    public func documentAnalysisDidChange(_ analysis: DocumentAnalysis,
                                          reason: DocumentAnalysis.ChangeReason) {
        switch reason {
        case .language:
            rebuildLanguage()
            scheduleHighlight()
        case .declarations:
            // The post-edit rescan landed: refresh the table and repaint the
            // viewport (what the engine's own debounce tick did before T17.1).
            guard moduleEnabled, language != nil, let snapshot = analysis.declarations else { return }
            symbolTable = snapshot.scan.table
            highlightVisibleRange()
        case .released:
            break
        }
    }

    // MARK: - Appearance

    /// Invalidates the painted band and repaints the visible range. Public entry
    /// for anything that changes how the stored temporary-attribute colours
    /// should render without changing the text — chiefly a light/dark appearance
    /// switch (the KVO observer calls this; callers may too). Cheap: it repaints
    /// only the viewport plus overscan, never the whole document, and no-ops when
    /// the module is off or no language applies.
    public func appearanceDidChange() {
        paintedRange = nil
        scheduleHighlight()
    }

    // MARK: - Notifications

    private var pendingViewport: DispatchWorkItem?

    @objc private func viewportChanged() {
        pendingViewport?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pendingViewport = nil
            self?.scheduleHighlight()
        }
        pendingViewport = item
        DispatchQueue.main.async(execute: item)
    }

    @objc private func moduleSettingsChanged(_ note: Notification) {
        guard (note.object as? String) == FeatureModule.highlight.rawValue else { return }
        let nowEnabled = moduleSettings.isEnabled(.highlight)
        guard nowEnabled != moduleEnabled else { return }
        moduleEnabled = nowEnabled
        if nowEnabled {
            rebuildLanguage()
            scheduleHighlight()
        } else {
            tearDown()
        }
    }

    /// Releases all runtime state and clears painted colour.
    private func tearDown() {
        analysis.checkpoints.removeAll()
        language = nil
        symbolTable = nil
        removeAllForegroundColour()
    }

    // MARK: - TextStorageObserving

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
        // A private analysis is on no hub: feed it the edit first (version bump,
        // checkpoint invalidation, debounced declaration rescan).
        if ownsAnalysis {
            analysis.textStorageDidProcessEditing(editedMask: editedMask, editedRange: editedRange,
                                                  changeInLength: delta, textStorage: textStorage)
        }
        // Editing may have changed content anywhere in (or shifted) the painted
        // band, so it can no longer be trusted to short-circuit a scroll. The
        // repaint follows the analysis's debounced rescan (`.declarations`).
        paintedRange = nil
        // Track where colour is still held through the shift (cleared by the
        // next pass outside its band).
        if let held = colouredRange {
            colouredRange = Self.heldRange(held, afterEditing: editedRange, delta: delta)
        }
    }

    // MARK: - Scheduling

    private func scheduleHighlight() {
        guard moduleEnabled, language != nil else { return }
        highlightVisibleRange()
    }

    // MARK: - Colouring

    /// Removes every foreground temporary attribute across the whole document.
    /// Only the highlighter writes foreground temporary attributes, so this is
    /// safe and leaves the find bar's background highlights untouched.
    private func removeAllForegroundColour() {
        paintedRange = nil
        colouredRange = nil
        guard let textView, let layoutManager = textView.layoutManager else { return }
        // Length without copying the document (`textView.string` copies).
        let length = textView.textStorage?.length ?? (textView.string as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor,
                                               forCharacterRange: NSRange(location: 0, length: length))
    }

    /// Snaps `raw` (a character range derived from a glyph query) outward to
    /// whole lines and clamps it into `[0, ns.length]`. Pure — it depends only
    /// on the string — so the document-boundary clamping (first / last line) is
    /// unit-testable without a live layout manager. Returns a zero-length range
    /// when the document is empty or the span collapses.
    nonisolated static func wholeLineRange(clamping raw: NSRange, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let clampedStart = min(max(raw.location, 0), ns.length - 1)
        let start = ns.lineRange(for: NSRange(location: clampedStart, length: 0)).location
        let rawEnd = min(max(raw.location + raw.length, 0), ns.length)
        let endLineRange = ns.lineRange(for: NSRange(location: min(rawEnd, ns.length - 1), length: 0))
        let end = endLineRange.location + endLineRange.length
        guard end > start else { return NSRange(location: start, length: 0) }
        return NSRange(location: start, length: end - start)
    }

    /// `true` when `inner` is fully contained in `outer` — the skip predicate
    /// for the painted band. Pure, so the boundary cases are unit-testable.
    nonisolated static func range(_ outer: NSRange, contains inner: NSRange) -> Bool {
        outer.location <= inner.location &&
            (outer.location + outer.length) >= (inner.location + inner.length)
    }

    /// A paint band before the scanner adjusts it (`bandBounds`): each edge
    /// is a line boundary, or a raw position inside a long line (`…MidLine`).
    struct BandBounds: Equatable {
        var start: Int
        var startMidLine: Bool
        var end: Int
        var endMidLine: Bool

        var range: NSRange { NSRange(location: start, length: max(0, end - start)) }
        var isSliced: Bool { startMidLine || endMidLine }
    }

    /// What `NSString.lineRange` ends a line at: CR, LF (CRLF as one), NEL,
    /// LINE SEPARATOR and PARAGRAPH SEPARATOR — so band edges on short lines
    /// stay exactly `wholeLineRange`'s.
    private nonisolated static let lineBreaks = CharacterSet(charactersIn: "\r\n\u{0085}\u{2028}\u{2029}")

    private nonisolated static func isLineBreak(_ u: unichar) -> Bool {
        u == 10 || u == 13 || u == 0x85 || u == 0x2028 || u == 0x2029
    }

    /// The last line-break unit in `[from, to)`, or nil. Unit by unit through a
    /// small buffer: a backward `rangeOfCharacter` reports composed ranges
    /// around CRLF and surrogate pairs, which can skip the last terminator.
    private nonisolated static func lastLineBreak(in ns: NSString, from: Int, to: Int) -> Int? {
        let chunk = 1_024
        var buffer = [unichar](repeating: 0, count: chunk)
        var end = to
        while end > from {
            let start = max(from, end - chunk)
            buffer.withUnsafeMutableBufferPointer { pointer in
                ns.getCharacters(pointer.baseAddress!, range: NSRange(location: start, length: end - start))
            }
            for i in stride(from: end - start - 1, through: 0, by: -1) where isLineBreak(buffer[i]) {
                return start + i
            }
            end = start
        }
        return nil
    }

    /// The first line-break unit in `[from, to)`, or nil. Starts a unit early on
    /// a low surrogate: a forward `rangeOfCharacter` from the middle of a
    /// surrogate pair skips the unit after it.
    private nonisolated static func firstLineBreak(in ns: NSString, from: Int, to: Int) -> Int? {
        guard to > from else { return nil }
        var start = from
        if start > 0, (0xDC00...0xDFFF).contains(ns.character(at: start)),
           (0xD800...0xDBFF).contains(ns.character(at: start - 1)) {
            start -= 1
        }
        let hit = ns.rangeOfCharacter(from: lineBreaks, options: [], range: NSRange(location: start, length: to - start))
        return hit.location == NSNotFound ? nil : hit.location
    }

    /// End of the line whose terminator starts at `t` (CRLF counts as one).
    private nonisolated static func lineEnd(afterTerminatorAt t: Int, in ns: NSString) -> Int {
        ns.character(at: t) == 13 && t + 1 < ns.length && ns.character(at: t + 1) == 10 ? t + 2 : t + 1
    }

    /// `raw` clamped into the document and snapped outward to whole lines like
    /// `wholeLineRange`, except that an edge whose line boundary lies more
    /// than `threshold` units away stays at the raw position (mid-line, moved
    /// off the middle of a surrogate pair). Pure, and it never scans more than
    /// about `threshold` units: a long line is not walked to its ends. Short
    /// lines give exactly `wholeLineRange`.
    nonisolated static func bandBounds(raw: NSRange, in ns: NSString, threshold: Int) -> BandBounds {
        let length = ns.length
        guard length > 0 else { return BandBounds(start: 0, startMidLine: false, end: 0, endMidLine: false) }
        func isHigh(_ u: unichar) -> Bool { (0xD800...0xDBFF).contains(u) }

        // Start: the line start of the clamped raw start, if close enough.
        let s = min(max(raw.location, 0), length - 1)
        // The LF of a CRLF belongs to the line its CR ends.
        let searchEnd = s > 0 && ns.character(at: s) == 10 && ns.character(at: s - 1) == 13 ? s - 1 : s
        let windowStart = max(0, searchEnd - threshold - 1)
        let lineStart: Int? = lastLineBreak(in: ns, from: windowStart, to: searchEnd)
            .map { Self.lineEnd(afterTerminatorAt: $0, in: ns) } ?? (windowStart == 0 ? 0 : nil)
        var start = s
        var startMidLine = true
        if let lineStart, s - lineStart <= threshold {
            start = lineStart
            startMidLine = false
        } else if start > 0, isHigh(ns.character(at: start - 1)) {
            start -= 1
        }

        // End: the line end of the line holding the clamped raw end, if close enough.
        let rawEnd = min(max(raw.location + raw.length, 0), length)
        let p = min(rawEnd, length - 1)
        let windowEnd = min(length, p + threshold + 2)
        let lineEnd: Int? = firstLineBreak(in: ns, from: p, to: windowEnd)
            .map { Self.lineEnd(afterTerminatorAt: $0, in: ns) } ?? (windowEnd == length ? length : nil)
        var end = rawEnd
        var endMidLine = true
        if let lineEnd, lineEnd - rawEnd <= threshold {
            end = lineEnd
            endMidLine = false
        } else if end > 0, end < length, isHigh(ns.character(at: end - 1)) {
            end += 1
        }
        if end < start { end = start }
        return BandBounds(start: start, startMidLine: startMidLine, end: end, endMidLine: endMidLine)
    }

    /// The document-clamped character range `rect` covers, from the layout
    /// manager's glyph geometry (not snapped to lines).
    private func rawCharRange(for rect: NSRect, layoutManager: NSLayoutManager,
                              container: NSTextContainer) -> NSRange {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    /// Tokenizes and colours the visible lines *plus an overscan margin*. Skips
    /// entirely when the viewport still sits inside the already-painted band
    /// (a pure scroll tick then does zero work). Clears the foreground colour
    /// still held outside the new band (off-screen cleanup, plan §6 item 1)
    /// and inside it, then repaints the band. Inside a long line the band is a
    /// slice of it (`bandBounds`, `bandTokens`).
    private func highlightVisibleRange() {
        guard moduleEnabled,
              let language,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        // The storage's own string: `textView.string` would copy the whole
        // document on every pass.
        let ns: NSString = textView.textStorage?.mutableString ?? (textView.string as NSString)
        guard ns.length > 0 else { return }
        let perfStart = PerfLog.isEnabled ? PerfLog.now() : 0
        let threshold = LanguageDefinition.longLineThreshold

        let visibleRect = scrollView.contentView.bounds

        // The bare viewport (whole lines unless inside a long line, no
        // overscan): used only to decide whether the painted band already
        // covers what's on screen.
        let viewportChars = Self.bandBounds(raw: rawCharRange(for: visibleRect, layoutManager: layoutManager,
                                                              container: container),
                                            in: ns, threshold: threshold).range
        guard viewportChars.length > 0 else { return }

        // Zero-work fast path: the viewport is still inside the pre-painted band.
        if let painted = paintedRange, Self.range(painted, contains: viewportChars) {
            if PerfLog.isEnabled {
                PerfLog.record("highlight.pass", since: perfStart,
                               ["lang": language.identifier, "painted": 0, "skipped": 1, "sliced": 0])
            }
            return
        }

        // Overscan: expand the paint rect ~1.5 screens above and below so a
        // region scrolling into view is already coloured. Document-boundary
        // clamping happens in `bandBounds`, so this only ever paints a few
        // screens — never the whole document (ARCHITECTURE.md §3.1), and
        // never a whole long line.
        let overscanRect = visibleRect.insetBy(dx: 0, dy: -1.5 * visibleRect.height)
        let bounds = Self.bandBounds(raw: rawCharRange(for: overscanRect, layoutManager: layoutManager,
                                                       container: container),
                                     in: ns, threshold: threshold)
        guard bounds.range.length > 0 else { return }

        // Lexical state at the band start comes from the analysis's sparse
        // checkpoints (Python and profiled languages); tokens are transient.
        // Computed before clearing, since a sliced band's actual extent is
        // only known once the scanner has found its safe points.
        let band = Self.bandTokens(in: ns, bounds: bounds, language: language,
                                   checkpoints: &analysis.checkpoints)
        let paintChars = band.painted
        guard paintChars.length > 0 else { return }

        // Off-screen cleanup: the colour held outside the new band is cleared
        // right away, in this same pass. The pass never runs inside
        // `didProcessEditing` (edits only invalidate; repaints follow the
        // analysis's rescan or a deferred viewport tick), the cleared span is
        // at least the overscan away from the viewport, and its cost is bounded
        // by the previous band — so deferring would only add a pending state
        // and a window where two bands are held.
        if let held = colouredRange {
            for piece in Self.ranges(held, minus: paintChars, clampedTo: ns.length) {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: piece)
            }
        }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: paintChars)
        colouredRange = paintChars

        let tokens = band.tokens
        for token in tokens {
            guard let color = theme.color(for: token.kind) else { continue }
            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: token.range)
        }
        // In-document symbol colouring runs *after* the language tokens and
        // only in the spans they left uncovered, so string / comment / keyword
        // colours always win over symbol colours.
        if let symbolTable, !symbolTable.isEmpty {
            colourSymbols(in: ns, range: paintChars, tokens: tokens, table: symbolTable,
                          layoutManager: layoutManager)
        }

        // Record the band we actually painted so subsequent scroll ticks that
        // stay within it can short-circuit.
        paintedRange = paintChars
        if PerfLog.isEnabled {
            PerfLog.record("highlight.pass", since: perfStart,
                           ["lang": language.identifier, "painted": paintChars.length, "skipped": 0,
                            "sliced": bounds.isSliced ? 1 : 0])
        }
    }

    // MARK: - Band tokens (pure)

    /// The tokens of `range` (whole lines) with absolute, ascending ranges.
    /// `bandTokens(in:bounds:…)` with both edges on line boundaries.
    nonisolated static func bandTokens(in ns: NSString, range: NSRange, language: LanguageDefinition,
                                       checkpoints: inout CheckpointStore) -> [(range: NSRange, kind: TokenKind)] {
        let bounds = BandBounds(start: range.location, startMidLine: false, end: NSMaxRange(range), endMidLine: false)
        return bandTokens(in: ns, bounds: bounds, language: language, checkpoints: &checkpoints).tokens
    }

    /// The tokens of the band `bounds` (absolute, ascending, inside
    /// `painted`) and the range actually painted.
    ///
    /// - Profiled languages: the generic scanner's state at the band start
    ///   (resumed from `checkpoints`), then `LanguageDefinition.tokens`. A
    ///   mid-line start is moved to the first scanner safe point at or after
    ///   it; the tokens are computed from a safe point `ruleContext` units
    ///   earlier (a rule lead-in, so a rule token crossing the start keeps its
    ///   extent) and clipped. A mid-line end stops at the first safe point at
    ///   or after it.
    /// - Python: `PythonTokenizer` line by line from its resumed state.
    /// - Everything else: `tokenize(line:)` line by line, no state.
    /// - Python and unprofiled languages, in a line longer than
    ///   `longLineThreshold`: stateless rule tokens of the band's slice of
    ///   that line only (`statelessRuleTokens`), never the whole line. For
    ///   Python this ignores string state inside the long line — an accepted
    ///   compromise; the state after it is resumed exactly.
    ///
    /// Pure apart from recording checkpoints into `checkpoints`, so tests can
    /// run the exact pass the engine paints with. With both edges on line
    /// boundaries and no long line this is the whole-line pass of T17.2.
    nonisolated static func bandTokens(in ns: NSString, bounds: BandBounds, language: LanguageDefinition,
                                       checkpoints: inout CheckpointStore)
        -> (tokens: [(range: NSRange, kind: TokenKind)], painted: NSRange) {
        if let scanner = language.lexicalScanner {
            return profiledBandTokens(in: ns, bounds: bounds, language: language, scanner: scanner,
                                      checkpoints: &checkpoints)
        }
        return lineBandTokens(in: ns, bounds: bounds, language: language, checkpoints: &checkpoints)
    }

    private nonisolated static func profiledBandTokens(in ns: NSString, bounds: BandBounds,
                                                       language: LanguageDefinition, scanner: LexicalScanner,
                                                       checkpoints: inout CheckpointStore)
        -> (tokens: [(range: NSRange, kind: TokenKind)], painted: NSRange) {
        var from = bounds.start
        var paintStart = bounds.start
        var state: LexicalScanState
        if bounds.startMidLine {
            let resumed = lexicalScanResume(at: max(0, bounds.start - LanguageDefinition.ruleContext), in: ns,
                                            language: language, checkpoints: &checkpoints)
            from = resumed.position
            state = resumed.state
            var probe = state
            paintStart = max(from, scanner.advance(ns, from: from, to: ns.length,
                                                   stoppingAtSafePointFrom: bounds.start, state: &probe))
        } else {
            state = lexicalScanState(at: bounds.start, in: ns, language: language, checkpoints: &checkpoints)
        }
        var tokens: [(range: NSRange, kind: TokenKind)]
        var end = bounds.end
        if bounds.endMidLine {
            (tokens, end) = language.tokens(in: ns, range: NSRange(location: from, length: ns.length - from),
                                            stoppingAtSafePointFrom: max(bounds.end, paintStart), state: &state)
        } else {
            tokens = end > from
                ? language.tokens(in: ns, range: NSRange(location: from, length: end - from), state: &state)
                : []
        }
        let painted = NSRange(location: paintStart, length: max(0, end - paintStart))
        if from < paintStart { tokens = clipped(tokens, to: painted) }
        return (tokens, painted)
    }

    /// `tokens` (ascending) restricted to `range`.
    nonisolated static func clipped(_ tokens: [(range: NSRange, kind: TokenKind)],
                                    to range: NSRange) -> [(range: NSRange, kind: TokenKind)] {
        tokens.compactMap { token in
            let piece = NSIntersectionRange(token.range, range)
            return piece.length > 0 ? (piece, token.kind) : nil
        }
    }

    // swiftlint:disable:next function_body_length
    private nonisolated static func lineBandTokens(in ns: NSString, bounds: BandBounds,
                                                   language: LanguageDefinition,
                                                   checkpoints: inout CheckpointStore)
        -> (tokens: [(range: NSRange, kind: TokenKind)], painted: NSRange) {
        let start = bounds.start
        let end = bounds.end
        let length = ns.length
        let threshold = LanguageDefinition.longLineThreshold
        let context = LanguageDefinition.ruleContext
        let isPython = language.identifier == "python"
        /// Python's state at `loc`, when known.
        var pythonState: PythonTokenizer.State?
        var tokens: [(range: NSRange, kind: TokenKind)] = []
        var loc = start
        while loc < end {
            // The line holding `loc`: its start when known (`loc` is a line
            // start except at a mid-line band start), its end when found
            // within `threshold` units (or inside the band), and whether it
            // is long.
            let atLineStart = !(loc == start && bounds.startMidLine)
            var lineEnd: Int?
            var isLong = !atLineStart
            if atLineStart {
                let reach = min(length, loc + threshold + 1)
                if let lineBreak = firstLineBreak(in: ns, from: loc, to: reach) {
                    lineEnd = Self.lineEnd(afterTerminatorAt: lineBreak, in: ns)
                } else if reach == length {
                    lineEnd = length
                }
                isLong = lineEnd.map { $0 - loc > threshold } ?? true
            }

            if !isLong, let lineEnd {
                let lineRange = NSRange(location: loc, length: lineEnd - loc)
                let lineString = ns.substring(with: lineRange)
                let lineTokens: [(range: NSRange, kind: TokenKind)]
                if isPython {
                    var state = pythonState
                        ?? pythonLexicalState(at: loc, in: ns, language: language, checkpoints: &checkpoints)
                    lineTokens = PythonTokenizer.scan(lineString, language: language, state: &state)
                    pythonState = state
                } else {
                    lineTokens = language.tokenize(line: lineString)
                }
                for token in lineTokens {
                    tokens.append((NSRange(location: loc + token.range.location, length: token.range.length),
                                   token.kind))
                }
                loc = lineEnd
                continue
            }

            // A long line: only the band's slice of it, stateless.
            if lineEnd == nil {
                lineEnd = firstLineBreak(in: ns, from: loc, to: end).map { Self.lineEnd(afterTerminatorAt: $0, in: ns) }
            }
            let sliceEnd = min(end, lineEnd ?? end)
            // Rule context: within the line, up to `context` units around the slice.
            let contextEnd: Int
            if let lineEnd {
                contextEnd = lineEnd
            } else {
                let reach = min(length, sliceEnd + context)
                contextEnd = firstLineBreak(in: ns, from: sliceEnd, to: reach) ?? reach
            }
            tokens += language.statelessRuleTokens(in: ns, range: NSRange(location: loc, length: sliceEnd - loc),
                                                   lineStart: atLineStart ? loc : max(0, loc - context),
                                                   lineEnd: contextEnd)
            pythonState = nil
            guard sliceEnd > loc else { break }
            loc = sliceEnd
        }
        return (tokens, NSRange(location: start, length: max(0, end - start)))
    }

    /// The generic scanner's state at `start` (a line start) for a profiled
    /// language. See `resumeLexicalState`.
    nonisolated static func lexicalScanState(at start: Int, in ns: NSString, language: LanguageDefinition,
                                             checkpoints: inout CheckpointStore) -> LexicalScanState {
        lexicalScanResume(at: start, in: ns, language: language, checkpoints: &checkpoints).state
    }

    /// The generic scanner's state at `start`, or — when `start` lies inside a
    /// line — at the first scanner safe point at or after it, together with
    /// that position. See `resumeLexicalState`.
    nonisolated static func lexicalScanResume(at start: Int, in ns: NSString, language: LanguageDefinition,
                                              checkpoints: inout CheckpointStore)
        -> (position: Int, state: LexicalScanState) {
        guard let scanner = language.lexicalScanner else { return (start, LexicalScanState()) }
        return resumeLexicalState(at: start, in: ns, languageIdentifier: language.identifier,
                                  initial: LexicalScanState(), checkpoints: &checkpoints,
                                  unwrap: { if case .generic(let s) = $0 { return s } else { return nil } },
                                  wrap: { .generic($0) },
                                  advance: { from, to, state in
                                      scanner.advance(ns, from: from, to: to, state: &state)
                                  },
                                  advanceToSafePoint: { from, to, target, state in
                                      scanner.advance(ns, from: from, to: to, stoppingAtSafePointFrom: target,
                                                      state: &state)
                                  })
    }

    /// The Python lexical state at `start` (a line start).
    nonisolated static func pythonLexicalState(at start: Int, in ns: NSString, language: LanguageDefinition,
                                               checkpoints: inout CheckpointStore) -> PythonTokenizer.State {
        resumeLexicalState(at: start, in: ns, languageIdentifier: language.identifier,
                           initial: PythonTokenizer.State(), checkpoints: &checkpoints,
                           unwrap: { if case .python(let s) = $0 { return s } else { return nil } },
                           wrap: { .python($0) },
                           advance: { from, to, state in
                               state = PythonTokenizer.state(in: ns, before: to, language: language,
                                                             from: from, initial: state)
                           }).state
    }

    /// Resumes from the nearest checkpoint at or before `start` whose state
    /// is of this tokenizer's kind (else from offset 0 with `initial`), walks
    /// forward in line-aligned chunks of about `CheckpointStore.spacing`,
    /// recording a checkpoint at each chunk boundary, then advances to
    /// `start`. Logs `lexical.advance` (units scanned) when PerfLog is on.
    ///
    /// Inside a line longer than the spacing, a tokenizer that can stop at a
    /// safe point (`advanceToSafePoint(from, to, target, &state)` returns the
    /// first safe point ≥ target; the generic scanner) steps to the safe point
    /// at or after `offset + spacing` within the line and records a
    /// checkpoint there; without it (Python) the chunk runs to the line end
    /// as before. A `start` inside a line is reached the same way, so the
    /// returned position may lie after it; at a line start it is `start`.
    // swiftlint:disable:next function_parameter_count function_body_length
    nonisolated static func resumeLexicalState<State>(at start: Int, in ns: NSString, languageIdentifier: String,
                                                      initial: State, checkpoints: inout CheckpointStore,
                                                      unwrap: (LexicalState) -> State?,
                                                      wrap: (State) -> LexicalState,
                                                      advance: (Int, Int, inout State) -> Void,
                                                      advanceToSafePoint: ((Int, Int, Int, inout State) -> Int)? = nil)
        -> (position: Int, state: State) {
        let perfStart = PerfLog.isEnabled ? PerfLog.now() : 0
        let length = ns.length
        var offset = 0
        var state = initial
        if let checkpoint = checkpoints.nearest(atOrBefore: start), let saved = unwrap(checkpoint.state) {
            offset = checkpoint.offset
            state = saved
        }
        let resumedAt = offset
        let spacing = CheckpointStore.spacing
        let midLine: Bool = {
            guard start > 0, start < length else { return false }
            let previous = ns.character(at: start - 1)
            if previous == 13 { return ns.character(at: start) == 10 }
            return !isLineBreak(previous)
        }()
        // A safe-point step never runs past a `start` at a line start (line
        // starts are safe points); towards a mid-line `start` it may.
        let stepEnd = midLine ? length : start
        while start - offset > spacing {
            // The line start at or before `offset + spacing` (found by a
            // bounded backward search, so a long line is not walked).
            var next: Int
            if let lineBreak = lastLineBreak(in: ns, from: offset, to: offset + spacing) {
                next = Self.lineEnd(afterTerminatorAt: lineBreak, in: ns)
            } else if let advanceToSafePoint {
                // Inside a line longer than the spacing: the first safe point
                // after `offset + spacing`.
                next = advanceToSafePoint(offset, stepEnd, offset + spacing, &state)
                guard next > offset else { break }
                if next < start { checkpoints.record(offset: next, state: wrap(state)) }
                offset = next
                continue
            } else {
                // No safe points: the end of that line instead.
                next = NSMaxRange(ns.lineRange(for: NSRange(location: offset, length: 0)))
            }
            guard next > offset, next < start else { break }
            advance(offset, next, &state)
            checkpoints.record(offset: next, state: wrap(state))
            offset = next
        }
        var position = start
        if offset >= start {
            position = offset
        } else if midLine, let advanceToSafePoint {
            position = advanceToSafePoint(offset, length, start, &state)
        } else {
            advance(offset, start, &state)
        }
        if PerfLog.isEnabled {
            PerfLog.record("lexical.advance", since: perfStart,
                           ["lang": languageIdentifier, "units": position - resumedAt,
                            "resumedAt": resumedAt, "checkpoints": checkpoints.entries.count])
        }
        return (position, state)
    }

    /// `outer` minus `inner`, as up to two ranges clamped to `[0, length)`.
    /// Pure, so the cleanup arithmetic is unit-testable.
    nonisolated static func ranges(_ outer: NSRange, minus inner: NSRange, clampedTo length: Int) -> [NSRange] {
        let outerStart = min(max(outer.location, 0), length)
        let outerEnd = min(max(NSMaxRange(outer), outerStart), length)
        let innerStart = min(max(inner.location, outerStart), outerEnd)
        let innerEnd = min(max(NSMaxRange(inner), innerStart), outerEnd)
        var out: [NSRange] = []
        if innerStart > outerStart { out.append(NSRange(location: outerStart, length: innerStart - outerStart)) }
        if outerEnd > innerEnd { out.append(NSRange(location: innerEnd, length: outerEnd - innerEnd)) }
        return out
    }

    /// Where foreground colour may still be held after an edit that replaced
    /// `editedRange.length - delta` units at `editedRange.location` with
    /// `editedRange.length` units: `held` mapped through the edit, widened to
    /// the edited text when the two touch (inserted text can inherit an
    /// adjacent run). Errs on the side of a larger span.
    nonisolated static func heldRange(_ held: NSRange, afterEditing editedRange: NSRange, delta: Int) -> NSRange {
        let editStart = editedRange.location
        let oldEditEnd = editStart + editedRange.length - delta
        func map(_ position: Int, low: Bool) -> Int {
            if position < editStart || (low && position == editStart) { return position }
            if position >= oldEditEnd { return position + delta }
            // Inside the replaced text: widen to the edited span.
            return low ? editStart : NSMaxRange(editedRange)
        }
        var start = map(held.location, low: true)
        var end = max(start, map(NSMaxRange(held), low: false))
        if editStart <= end && NSMaxRange(editedRange) >= start {
            start = min(start, editStart)
            end = max(end, NSMaxRange(editedRange))
        }
        return NSRange(location: start, length: end - start)
    }

    /// Colours the declared-symbol identifiers of `range`, but only in the
    /// character gaps left uncovered by `tokens` (absolute, ascending) — so a
    /// name inside a string / comment / keyword keeps that colour. Each gap is
    /// scanned for `[A-Za-z_]\w*` identifiers, coloured by their category:
    /// functions → `.symbolFunction`, types → `.type` (reused), variables →
    /// `.symbolVariable`.
    private func colourSymbols(in ns: NSString, range: NSRange,
                               tokens: [(range: NSRange, kind: TokenKind)],
                               table: WordIndex.SymbolTable,
                               layoutManager: NSLayoutManager) {
        guard range.length > 0 else { return }
        let band = ns.substring(with: range)
        let bandNS = band as NSString
        let base = range.location

        func scanGap(_ gap: NSRange) {
            guard gap.length > 0 else { return }
            Self.identifierRegex.enumerateMatches(in: band, range: gap) { match, _, _ in
                guard let r = match?.range else { return }
                let word = bandNS.substring(with: r)
                let color: NSColor?
                if table.functions.contains(word) {
                    color = theme.color(for: .symbolFunction)
                } else if table.types.contains(word) {
                    color = theme.color(for: .type)
                } else if table.variables.contains(word) {
                    color = theme.color(for: .symbolVariable)
                } else {
                    color = nil
                }
                guard let color else { return }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: color,
                    forCharacterRange: NSRange(location: base + r.location, length: r.length))
            }
        }

        var pos = 0
        for token in tokens {
            let tokenStart = token.range.location - base
            if tokenStart > pos {
                scanGap(NSRange(location: pos, length: min(tokenStart, range.length) - pos))
            }
            pos = max(pos, NSMaxRange(token.range) - base)
            if pos >= range.length { break }
        }
        if pos < range.length {
            scanGap(NSRange(location: pos, length: range.length - pos))
        }
    }
}
