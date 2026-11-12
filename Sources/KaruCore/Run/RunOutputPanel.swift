import AppKit

/// The draggable top edge of the output panel: a 1 pt separator line with a
/// 5 pt hit area. Reports the total vertical drag since mouse-down (positive =
/// upwards = the panel grows); the session clamps and applies it.
final class RunPanelDivider: NSView {
    static let thickness: CGFloat = 5

    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    private var dragOriginY: CGFloat?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: isFlipped ? 0 : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginY = event.locationInWindow.y
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOriginY else { return }
        onDrag?(event.locationInWindow.y - origin)
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginY = nil
    }
}

/// Per-window run output panel (T16.3b): header (title, language · tool,
/// Clear / Copy / Stop-Rerun / Close), a read-only output text view and — only
/// while a run is active — a stdin row.
///
/// The panel holds no output model of its own: its text storage mirrors the
/// runner's bounded `RunOutputBuffer` (plus a leading note once that buffer
/// has dropped old text), so the storage can never outgrow the buffer. It is
/// created on first use and released when hidden or closed; showing it again
/// re-renders from the buffer.
@MainActor
final class RunOutputPanel: NSView {
    var onClear: (() -> Void)?
    var onStopOrRerun: (() -> Void)?
    var onClose: (() -> Void)?
    var onSendLine: ((String) -> Void)?
    var onEOF: (() -> Void)?
    /// Called after the panel re-pulled its own strings on a UI-language
    /// switch, so the owner can re-render (the truncation note is localized).
    var onLanguageChange: (() -> Void)?

    let divider = RunPanelDivider()
    let outputTextView: NSTextView
    let outputScrollView = NSScrollView()
    let inputField = NSTextField()

    private let titleLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    let clearButton = NSButton()
    let copyButton = NSButton()
    let stopRerunButton = NSButton()
    let closeButton = NSButton()
    let eofButton = NSButton()
    private let inputRow: NSStackView

    /// Whether the storage starts with the "(earlier output truncated)" note,
    /// and its UTF-16 length.
    private(set) var showsTruncationNote = false
    private var noteLength = 0
    /// A run is active (preparing or running): the button reads Stop.
    private(set) var isActive = false

    var isInputRowVisible: Bool { !inputRow.isHidden }

    init() {
        let textView = NSTextView()
        outputTextView = textView
        inputRow = NSStackView()
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 180))

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.allowsUndo = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        // Up to ~1 MB of output: never lay all of it out eagerly.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.font = Self.font
        outputScrollView.documentView = textView
        outputScrollView.hasVerticalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.borderType = .noBorder
        outputScrollView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        infoLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        for (button, symbol, action) in [
            (clearButton, "trash", #selector(clearTapped)),
            (copyButton, "doc.on.doc", #selector(copyTapped)),
            (stopRerunButton, "arrow.clockwise", #selector(stopRerunTapped)),
            (closeButton, "xmark", #selector(closeTapped)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = action
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        closeButton.imagePosition = .imageOnly
        closeButton.title = ""

        let header = NSStackView(views: [titleLabel, infoLabel, clearButton, copyButton, stopRerunButton, closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.setCustomSpacing(10, after: infoLabel)
        header.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 3, right: 6)

        inputField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        inputField.controlSize = .small
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        inputField.lineBreakMode = .byClipping
        inputField.usesSingleLineMode = true
        inputField.cell?.isScrollable = true
        inputField.cell?.wraps = false
        inputField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        eofButton.bezelStyle = .accessoryBarAction
        eofButton.controlSize = .small
        eofButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        eofButton.target = self
        eofButton.action = #selector(eofTapped)
        eofButton.setContentHuggingPriority(.required, for: .horizontal)
        inputRow.setViews([inputField, eofButton], in: .leading)
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 6
        inputRow.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 4, right: 6)
        inputRow.isHidden = true

        let stack = NSStackView(views: [divider, header, outputScrollView, inputRow])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outputScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
        outputScrollView.setContentHuggingPriority(.defaultLow - 10, for: .vertical)

        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange),
                                               name: L10n.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fontSizeDidChange),
                                               name: EditorFontSettings.didChangeNotification, object: nil)
        reloadStrings()
        update(isActive: false, acceptsInput: false, info: "")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: State

    /// Header info (language · tool) and state-dependent controls: Stop while
    /// a run is active (preparing or running), the stdin row only while a
    /// process is running.
    func update(isActive: Bool, acceptsInput: Bool, info: String) {
        let wasAccepting = !inputRow.isHidden
        self.isActive = isActive
        infoLabel.stringValue = info
        infoLabel.toolTip = info.isEmpty ? nil : info
        stopRerunButton.title = isActive ? L10n.t(.menuRunStop) : L10n.t(.runRerun)
        stopRerunButton.image = NSImage(systemSymbolName: isActive ? "stop.fill" : "arrow.clockwise",
                                        accessibilityDescription: nil)
        inputRow.isHidden = !acceptsInput
        if acceptsInput, !wasAccepting { setInputEnabled(true) }
    }

    /// Disabled after EOF until the next run starts.
    func setInputEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        eofButton.isEnabled = enabled
    }

    private func reloadStrings() {
        titleLabel.stringValue = L10n.t(.runOutputTitle)
        clearButton.title = L10n.t(.runClear)
        copyButton.title = L10n.t(.runCopy)
        stopRerunButton.title = isActive ? L10n.t(.menuRunStop) : L10n.t(.runRerun)
        closeButton.toolTip = L10n.t(.runCloseOutput)
        closeButton.setAccessibilityLabel(L10n.t(.runCloseOutput))
        eofButton.title = L10n.t(.runEOF)
        eofButton.toolTip = L10n.t(.runEOFTooltip)
        inputField.placeholderString = L10n.t(.runInputPlaceholder)
    }

    @objc private func languageDidChange() {
        reloadStrings()
        onLanguageChange?()
    }

    // MARK: Rendering

    static var font: NSFont {
        .monospacedSystemFont(ofSize: EditorFontSettings().fontSize, weight: .regular)
    }

    static func color(for stream: RunOutputStream) -> NSColor {
        switch stream {
        case .stdout: return .labelColor
        case .stderr: return .systemRed
        case .system: return .secondaryLabelColor
        }
    }

    private func attributed(_ text: String, _ stream: RunOutputStream, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Self.color(for: stream)])
    }

    private var storage: NSTextStorage { outputTextView.textStorage! }

    /// Replaces the whole storage with `buffer` (plus the truncation note when
    /// the buffer has dropped text).
    func render(_ buffer: RunOutputBuffer) {
        let atBottom = isScrolledToBottom
        let font = Self.font
        let text = NSMutableAttributedString()
        showsTruncationNote = buffer.isTruncated
        if buffer.isTruncated {
            let note = L10n.t(.runOutputTruncated) + "\n"
            text.append(attributed(note, .system, font: font))
            noteLength = (note as NSString).length
        } else {
            noteLength = 0
        }
        for segment in buffer.segments { text.append(attributed(segment.text, segment.stream, font: font)) }
        storage.setAttributedString(text)
        if atBottom { scrollToEnd() }
    }

    /// Appends chunks that `buffer` has just absorbed. Once the buffer starts
    /// dropping old text the storage is re-rendered with the note, then
    /// trimmed from the front after every append so it never holds more than
    /// the buffer does.
    func append(_ chunks: [RunOutputChunk], buffer: RunOutputBuffer) {
        if buffer.isTruncated != showsTruncationNote {
            render(buffer)
            return
        }
        let atBottom = isScrolledToBottom
        let font = Self.font
        storage.beginEditing()
        for chunk in chunks where !chunk.text.isEmpty {
            storage.append(attributed(chunk.text, chunk.stream, font: font))
        }
        if buffer.isTruncated {
            let retained = buffer.segments.reduce(0) { $0 + $1.text.utf16.count }
            let excess = storage.length - noteLength - retained
            if excess > 0 { storage.deleteCharacters(in: NSRange(location: noteLength, length: excess)) }
        }
        storage.endEditing()
        if atBottom { scrollToEnd() }
    }

    /// The panel's text without the truncation note (what Copy copies).
    var outputText: String {
        let string = storage.string as NSString
        return string.substring(from: min(noteLength, string.length))
    }

    var isScrolledToBottom: Bool {
        guard let document = outputScrollView.documentView else { return true }
        let visible = outputScrollView.contentView.bounds
        return visible.maxY >= document.bounds.height - 4
    }

    private func scrollToEnd() {
        outputTextView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    @objc private func fontSizeDidChange() {
        let font = Self.font
        outputTextView.font = font
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
    }

    // MARK: Actions

    @objc private func clearTapped() { onClear?() }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(outputText, forType: .string)
    }

    @objc private func stopRerunTapped() { onStopOrRerun?() }
    @objc private func closeTapped() { onClose?() }

    @objc func inputSubmitted() {
        guard isInputRowVisible, inputField.isEnabled else { return }
        let line = inputField.stringValue
        inputField.stringValue = ""
        onSendLine?(line)
    }

    @objc private func eofTapped() {
        guard isInputRowVisible else { return }
        onEOF?()
    }
}
