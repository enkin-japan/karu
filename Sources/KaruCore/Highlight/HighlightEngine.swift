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
///   cost returns to ≈ 0. It rebuilds from the remembered file extension when
///   re-enabled.
@MainActor
public final class HighlightEngine: NSObject, TextStorageObserving {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private let moduleSettings: ModuleSettings
    private let theme = HighlightTheme()

    /// Lightweight, always-retained config: the file extension used to resolve
    /// a language. Survives module toggles so the language can be rebuilt.
    private var languageExtension: String?

    /// Lightweight, always-retained config: a language identifier pinned
    /// explicitly (from the Language menu or the content sniffer). Takes
    /// precedence over `languageExtension`; survives module toggles.
    private var pinnedIdentifier: String?

    /// Releasable runtime state: the compiled language definition. `nil` when
    /// the module is disabled or no language applies to the current file.
    private var language: LanguageDefinition?

    /// Releasable runtime state: in-document declared symbols (functions /
    /// types / variables), coloured in the gaps the language rules leave
    /// uncoloured. Rebuilt on the edit-debounce tick and on language change;
    /// dropped together with `language` when the module is switched off, so it
    /// is part of the `isRuntimeStateReleased` guarantee.
    private var symbolTable: WordIndex.SymbolTable?

    /// A single compiled identifier matcher, reused across every symbol pass.
    // swiftlint:disable:next force_try
    private static let identifierRegex = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)

    /// Whether the `highlight` module is currently on.
    private var moduleEnabled: Bool

    /// The character range actually painted by the last `highlightVisibleRange`
    /// pass (the overscanned, whole-line span — not just the viewport). A pure
    /// scroll whose new viewport still falls inside this band does zero work.
    /// Set back to `nil` whenever the painted colours may be stale: on edit, on
    /// language change, on a module toggle, and when all colour is cleared.
    /// Internal (not private) so unit tests can assert the invalidation.
    var paintedRange: NSRange?

    /// Pending debounced highlight pass, if any.
    private var pendingHighlight: DispatchWorkItem?

    /// KVO token for the application's effective appearance. A light/dark switch
    /// invalidates the painted band and repaints the viewport so the temporary
    /// attribute colours re-resolve to the new appearance.
    private var appearanceObservation: NSKeyValueObservation?

    /// Edit debounce interval (ARCHITECTURE: 0.05–0.1s).
    private let debounceInterval: TimeInterval = 0.07

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

    public init(textView: NSTextView,
                scrollView: NSScrollView,
                moduleSettings: ModuleSettings = ModuleSettings(),
                moduleCenter: NotificationCenter = .default) {
        self.textView = textView
        self.scrollView = scrollView
        self.moduleSettings = moduleSettings
        self.moduleCenter = moduleCenter
        self.moduleEnabled = moduleSettings.isEnabled(.highlight)
        super.init()

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
        pendingHighlight?.cancel()
    }

    // MARK: - Language wiring

    /// Points the engine at the language owning `ext` (the file's extension).
    /// Passing `nil` or an unknown extension leaves the engine idle. Remembers
    /// the extension so the language can be rebuilt after a module toggle.
    ///
    /// Returns the resolved language identifier (e.g. `"python"`) so the caller
    /// can drive indent width from it without building the definition a second
    /// time — or `nil` if the extension maps to no registered language.
    @discardableResult
    public func setLanguage(fileExtension ext: String?) -> String? {
        languageExtension = ext?.isEmpty == true ? nil : ext
        pinnedIdentifier = nil
        rebuildLanguage()
        scheduleHighlight(debounced: false)
        return currentLanguageIdentifier
    }

    /// Points the engine at the language whose `identifier` is `id` (e.g. from
    /// the Language menu or the content sniffer). Passing `nil` or an empty /
    /// unknown identifier leaves the engine idle (plain text). Takes precedence
    /// over any previously set file extension and is remembered so the language
    /// survives a module toggle.
    ///
    /// Returns the resolved identifier, or `nil` if it maps to no registered
    /// language.
    @discardableResult
    public func setLanguage(identifier id: String?) -> String? {
        pinnedIdentifier = (id?.isEmpty == true) ? nil : id
        languageExtension = nil
        rebuildLanguage()
        scheduleHighlight(debounced: false)
        return currentLanguageIdentifier
    }

    /// The identifier of the language resolved for the current file (e.g.
    /// `"markdown"`), independent of module state — used to drive indent width.
    ///
    /// When the module is enabled the identifier is read from the already-built
    /// definition (no extra work). When the module is disabled the definition is
    /// not retained, so this resolves it once on demand to read the identifier;
    /// that stays lazy (nothing is built until a file actually asks for it).
    public var currentLanguageIdentifier: String? {
        if let language { return language.identifier }
        if let id = pinnedIdentifier { return LanguageRegistry.definition(forIdentifier: id)?.identifier }
        guard let ext = languageExtension else { return nil }
        return LanguageRegistry.definition(forExtension: ext)?.identifier
    }

    /// Resolves the pinned identifier (preferred) or the file extension into a
    /// compiled definition, but only while the module is enabled. Clears the
    /// definition otherwise.
    private func rebuildLanguage() {
        // Language change (either `setLanguage` entry, and module re-enable which
        // also routes through here) invalidates the painted band.
        paintedRange = nil
        guard moduleEnabled else {
            language = nil
            symbolTable = nil
            return
        }
        if let id = pinnedIdentifier {
            language = LanguageRegistry.definition(forIdentifier: id)
        } else if let ext = languageExtension {
            language = LanguageRegistry.definition(forExtension: ext)
        } else {
            language = nil
        }
        rebuildSymbolTable()
    }

    /// Rescans the whole document for declared symbols for the active language.
    ///
    /// This is a single regex pass over `textView.string`; even for a 10 MB
    /// document that is the same order of work the completion module already
    /// performs on every edit (a debounced full scan), so it is acceptable
    /// here. It runs only on the 0.07 s edit-debounce tick and on language
    /// change — never per scroll frame — so viewport panning stays cheap.
    private func rebuildSymbolTable() {
        guard moduleEnabled, let language, let textView else {
            symbolTable = nil
            return
        }
        symbolTable = WordIndex.symbolTable(text: textView.string,
                                            languageIdentifier: language.identifier)
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
        scheduleHighlight(debounced: false)
    }

    // MARK: - Notifications

    @objc private func viewportChanged() {
        scheduleHighlight(debounced: false)
    }

    @objc private func moduleSettingsChanged(_ note: Notification) {
        guard (note.object as? String) == FeatureModule.highlight.rawValue else { return }
        let nowEnabled = moduleSettings.isEnabled(.highlight)
        guard nowEnabled != moduleEnabled else { return }
        moduleEnabled = nowEnabled
        if nowEnabled {
            rebuildLanguage()
            scheduleHighlight(debounced: false)
        } else {
            tearDown()
        }
    }

    /// Releases all runtime state and clears painted colour.
    private func tearDown() {
        pendingHighlight?.cancel()
        pendingHighlight = nil
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
        // Editing may have changed content anywhere in (or shifted) the painted
        // band, so it can no longer be trusted to short-circuit a scroll.
        paintedRange = nil
        scheduleHighlight(debounced: true)
    }

    // MARK: - Scheduling

    private func scheduleHighlight(debounced: Bool) {
        guard moduleEnabled, language != nil else { return }
        pendingHighlight?.cancel()
        guard debounced else {
            pendingHighlight = nil
            highlightVisibleRange()
            return
        }
        // The debounced tick is an edit; refresh the symbol table (once per
        // debounce, not per scroll) before repainting the viewport.
        let item = DispatchWorkItem { [weak self] in
            self?.rebuildSymbolTable()
            self?.highlightVisibleRange()
        }
        pendingHighlight = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    // MARK: - Colouring

    /// Removes every foreground temporary attribute across the whole document.
    /// Only the highlighter writes foreground temporary attributes, so this is
    /// safe and leaves the find bar's background highlights untouched.
    private func removeAllForegroundColour() {
        paintedRange = nil
        guard let layoutManager = textView?.layoutManager,
              let length = (textView?.string as NSString?)?.length else { return }
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

    /// Maps `rect` to a whole-line, document-clamped character range via the
    /// layout manager's glyph geometry.
    private func lineClampedCharRange(for rect: NSRect,
                                      ns: NSString,
                                      layoutManager: NSLayoutManager,
                                      container: NSTextContainer) -> NSRange {
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return Self.wholeLineRange(clamping: charRange, in: ns)
    }

    /// Tokenizes and colours the visible lines *plus an overscan margin*. Skips
    /// entirely when the viewport still sits inside the already-painted band
    /// (a pure scroll tick then does zero work). Clears the previous foreground
    /// colour in the painted span first, then repaints.
    private func highlightVisibleRange() {
        guard moduleEnabled,
              let language,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        let ns = textView.string as NSString
        guard ns.length > 0 else { return }

        let visibleRect = scrollView.contentView.bounds

        // The bare viewport (whole lines, no overscan): used only to decide
        // whether the painted band already covers what's on screen.
        let viewportChars = lineClampedCharRange(for: visibleRect, ns: ns,
                                                 layoutManager: layoutManager, container: container)
        guard viewportChars.length > 0 else { return }

        // Zero-work fast path: the viewport is still inside the pre-painted band.
        if let painted = paintedRange, Self.range(painted, contains: viewportChars) {
            return
        }

        // Overscan: expand the paint rect ~1.5 screens above and below so a
        // region scrolling into view is already coloured. Document-boundary
        // clamping happens in `wholeLineRange`, so this only ever paints a few
        // screens — never the whole document (ARCHITECTURE.md §3.1).
        let overscanRect = visibleRect.insetBy(dx: 0, dy: -1.5 * visibleRect.height)
        let paintChars = lineClampedCharRange(for: overscanRect, ns: ns,
                                              layoutManager: layoutManager, container: container)
        guard paintChars.length > 0 else { return }

        let start = paintChars.location
        let end = paintChars.location + paintChars.length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: paintChars)

        var loc = start
        while loc < end {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let lineString = ns.substring(with: lineRange)
            let tokens = language.tokenize(line: lineString)
            for token in tokens {
                guard let color = theme.color(for: token.kind) else { continue }
                let absolute = NSRange(location: lineRange.location + token.range.location,
                                       length: token.range.length)
                layoutManager.addTemporaryAttribute(.foregroundColor,
                                                    value: color,
                                                    forCharacterRange: absolute)
            }
            // In-document symbol colouring runs *after* the language rules and
            // only in the spans they left uncovered, so string / comment /
            // keyword colours always win over symbol colours.
            if let symbolTable, !symbolTable.isEmpty {
                colourSymbols(inLine: lineString,
                              lineLocation: lineRange.location,
                              ruleTokens: tokens,
                              table: symbolTable,
                              layoutManager: layoutManager)
            }
            let next = lineRange.location + lineRange.length
            if next <= loc { break }
            loc = next
        }

        // Record the band we actually painted so subsequent scroll ticks that
        // stay within it can short-circuit.
        paintedRange = paintChars
    }

    /// Colours the declared-symbol identifiers on one line, but only in the
    /// character gaps left uncovered by the language's own rule tokens — so a
    /// name inside a string / comment / keyword keeps that colour. Each gap is
    /// scanned for `[A-Za-z_]\w*` identifiers, coloured by their category:
    /// functions → `.symbolFunction`, types → `.type` (reused), variables →
    /// `.symbolVariable`.
    private func colourSymbols(inLine line: String,
                               lineLocation: Int,
                               ruleTokens: [(range: NSRange, kind: TokenKind)],
                               table: WordIndex.SymbolTable,
                               layoutManager: NSLayoutManager) {
        let ns = line as NSString
        let length = ns.length
        guard length > 0 else { return }

        // Rule tokens are non-overlapping and produced in ascending order by
        // `tokenize(line:)`; scan the complement (the gaps between them).
        var pos = 0
        func scanGap(_ gap: NSRange) {
            guard gap.length > 0 else { return }
            Self.identifierRegex.enumerateMatches(in: line, range: gap) { match, _, _ in
                guard let r = match?.range else { return }
                let word = ns.substring(with: r)
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
                    forCharacterRange: NSRange(location: lineLocation + r.location,
                                               length: r.length))
            }
        }

        for token in ruleTokens {
            if token.range.location > pos {
                scanGap(NSRange(location: pos, length: token.range.location - pos))
            }
            pos = max(pos, token.range.location + token.range.length)
        }
        if pos < length {
            scanGap(NSRange(location: pos, length: length - pos))
        }
    }
}
