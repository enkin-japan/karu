import AppKit

/// Maps `TokenKind`s to colours. System semantic colours are used throughout so
/// highlighting adapts to light / dark appearance for free. `.plain` returns
/// `nil` (no attribute → the view's default text colour).
public struct HighlightTheme {
    public init() {}

    public func color(for kind: TokenKind) -> NSColor? {
        switch kind {
        case .keyword:     return .systemPurple
        case .string:      return .systemRed
        case .number:      return .systemBlue
        case .comment:     return .systemGreen
        case .type:        return .systemOrange
        case .property:    return .systemTeal
        case .punctuation: return .secondaryLabelColor
        case .plain:       return nil
        }
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

    /// Releasable runtime state: the compiled language definition. `nil` when
    /// the module is disabled or no language applies to the current file.
    private var language: LanguageDefinition?

    /// Whether the `highlight` module is currently on.
    private var moduleEnabled: Bool

    /// Pending debounced highlight pass, if any.
    private var pendingHighlight: DispatchWorkItem?

    /// Edit debounce interval (ARCHITECTURE: 0.05–0.1s).
    private let debounceInterval: TimeInterval = 0.07

    // MARK: - Queryable state (for tests / diagnostics)

    /// True when no runtime highlight state is held — either the module is off
    /// or no language is active. When the module is disabled this is guaranteed
    /// true (the acceptance-criteria "released" state).
    public var isRuntimeStateReleased: Bool { language == nil }

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingHighlight?.cancel()
    }

    // MARK: - Language wiring

    /// Points the engine at the language owning `ext` (the file's extension).
    /// Passing `nil` or an unknown extension leaves the engine idle. Remembers
    /// the extension so the language can be rebuilt after a module toggle.
    public func setLanguage(fileExtension ext: String?) {
        languageExtension = ext?.isEmpty == true ? nil : ext
        rebuildLanguage()
        scheduleHighlight(debounced: false)
    }

    /// Resolves `languageExtension` into a compiled definition, but only while
    /// the module is enabled. Clears the definition otherwise.
    private func rebuildLanguage() {
        guard moduleEnabled, let ext = languageExtension else {
            language = nil
            return
        }
        language = LanguageRegistry.definition(forExtension: ext)
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
        removeAllForegroundColour()
    }

    // MARK: - TextStorageObserving

    public func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                             editedRange: NSRange,
                                             changeInLength delta: Int,
                                             textStorage: NSTextStorage) {
        guard editedMask.contains(.editedCharacters) else { return }
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
        let item = DispatchWorkItem { [weak self] in self?.highlightVisibleRange() }
        pendingHighlight = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    // MARK: - Colouring

    /// Removes every foreground temporary attribute across the whole document.
    /// Only the highlighter writes foreground temporary attributes, so this is
    /// safe and leaves the find bar's background highlights untouched.
    private func removeAllForegroundColour() {
        guard let layoutManager = textView?.layoutManager,
              let length = (textView?.string as NSString?)?.length else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor,
                                               forCharacterRange: NSRange(location: 0, length: length))
    }

    /// Tokenizes and colours the currently visible lines. Clears the previous
    /// foreground colour in the visible span first, then repaints.
    private func highlightVisibleRange() {
        guard moduleEnabled,
              let language,
              let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView else { return }

        let ns = textView.string as NSString
        guard ns.length > 0 else { return }

        // Visible character range, expanded to whole lines.
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let clampedStart = min(charRange.location, ns.length - 1)
        let start = ns.lineRange(for: NSRange(location: clampedStart, length: 0)).location
        let rawEnd = min(charRange.location + charRange.length, ns.length)
        let endLineRange = ns.lineRange(for: NSRange(location: min(rawEnd, ns.length - 1), length: 0))
        let end = endLineRange.location + endLineRange.length
        guard end > start else { return }

        let visibleChars = NSRange(location: start, length: end - start)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: visibleChars)

        var loc = start
        while loc < end {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let lineString = ns.substring(with: lineRange)
            for token in language.tokenize(line: lineString) {
                guard let color = theme.color(for: token.kind) else { continue }
                let absolute = NSRange(location: lineRange.location + token.range.location,
                                       length: token.range.length)
                layoutManager.addTemporaryAttribute(.foregroundColor,
                                                    value: color,
                                                    forCharacterRange: absolute)
            }
            let next = lineRange.location + lineRange.length
            if next <= loc { break }
            loc = next
        }
    }
}
