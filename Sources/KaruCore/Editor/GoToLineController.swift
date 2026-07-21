import AppKit

/// Ctrl+G "Go to Line" panel (T11.5).
///
/// A transient floating input panel — built on the same "open it, use it, drop
/// it" pattern as `SymbolNavigator` (ARCHITECTURE.md §3.4): created on demand,
/// fully released on close, holding **no** observers and **no** resident state.
/// It reuses the window's shared `LineIndex` to map a 1-based line number to its
/// character offset, then selects the whole line and scrolls it into view.
@MainActor
public final class GoToLineController: NSObject {
    private weak var textView: NSTextView?
    private weak var lineIndex: LineIndex?

    // MARK: Transient runtime state (all released on close)
    private var panel: NSPanel?
    private var field: NSTextField?
    private var onClose: (() -> Void)?

    public init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// True while the panel is on screen.
    public var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Parsing (pure, unit-testable)

    /// Parses a line-number entry: trims surrounding whitespace and returns the
    /// value only when it is a positive integer. Non-numeric, zero, and negative
    /// input yield `nil` (the caller ignores it); over-range positive input is
    /// returned as-is for the caller to clamp against the document's line count.
    public nonisolated static func parseLineInput(_ input: String) -> Int? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    // MARK: - Presentation

    public func present(onClose: (() -> Void)? = nil) {
        guard textView != nil else { return }
        self.onClose = onClose

        let panel = makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        if let field { panel.makeFirstResponder(field) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelResignedKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
    }

    // MARK: - Commit

    private func commit() {
        guard let field, let textView, let lineIndex else { close(); return }
        guard let requested = Self.parseLineInput(field.stringValue) else {
            // Non-numeric input is ignored — just dismiss.
            close()
            return
        }
        let clamped = min(max(requested, 1), lineIndex.lineCount)
        let range = lineIndex.offsetRange(ofLine: clamped)
        let selection = NSRange(location: range.lowerBound,
                                length: max(0, range.upperBound - range.lowerBound))
        let window = textView.window
        close()
        textView.setSelectedRange(selection)
        textView.scrollRangeToVisible(selection)
        window?.makeFirstResponder(textView)
    }

    // MARK: - Panel lifecycle

    private func makePanel() -> NSPanel {
        let panel = GoToLinePanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered,
                                  defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isMovable = false

        let container = NSView(frame: panel.contentView?.bounds ?? .zero)

        let input = NSTextField()
        input.translatesAutoresizingMaskIntoConstraints = false
        input.placeholderString = L10n.t(.goToLinePlaceholder)
        input.font = .systemFont(ofSize: 13)
        input.focusRingType = .none
        input.delegate = self
        self.field = input

        container.addSubview(input)
        panel.contentView = container
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            input.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            input.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let window = textView?.window else { return }
        let frame = window.frame
        let size = panel.frame.size
        let x = frame.minX + (frame.width - size.width) / 2
        let y = frame.minY + frame.height * 0.62
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func panelResignedKey() { close() }

    /// Tears down the panel and releases every piece of runtime state.
    private func close() {
        guard let panel else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: panel)
        panel.orderOut(nil)
        self.panel = nil
        field = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

// MARK: - Input field key handling

extension GoToLineController: NSTextFieldDelegate {
    public func control(_ control: NSControl,
                        textView: NSTextView,
                        doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(); return true
        default:
            return false
        }
    }
}

// MARK: - Panel that can take key focus for the input field

/// A borderless panel that still becomes key so its input field receives
/// keystrokes (a plain borderless `NSPanel` cannot).
private final class GoToLinePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
