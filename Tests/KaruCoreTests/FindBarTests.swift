import AppKit
import Testing
@testable import KaruCore

// Find bar progressive disclosure: one search row that is always shown, plus
// a replace row behind the disclosure triangle / Find and Replace… (⌥⌘F).
// Both hosts (editor window, scratchpad) share the structure; `compact` only
// lowers the minimum widths.

@MainActor
private func makeBar(compact: Bool = false,
                     text: String = "alpha\nbeta alpha\ngamma alpha\n") -> (FindBarController, NSTextView) {
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    textView.isRichText = false
    textView.allowsUndo = true
    textView.string = text
    let bar = FindBarController(textView: textView, lineIndex: LineIndex(text: textView.string),
                                compact: compact)
    return (bar, textView)
}

/// A real (never ordered-in) window, for anything that needs first responders.
@MainActor
private func makeWindowedBar(text: String = "alpha\nbeta alpha\n") -> (FindBarController, NSTextView, NSWindow) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 200))
    textView.string = text
    let bar = FindBarController(textView: textView, lineIndex: LineIndex(text: textView.string))
    let stack = NSStackView(views: [bar.barView, textView])
    stack.orientation = .vertical
    stack.spacing = 0
    window.contentView = stack
    bar.barView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    return (bar, textView, window)
}

@MainActor
private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(allViews)
}

@Suite("Find bar progressive disclosure")
@MainActor
struct FindBarDisclosureTests {
    @Test func newBarIsCollapsedAndShorterThanExpanded() {
        let (bar, _) = makeBar()
        bar.show()
        #expect(!bar.isReplaceShown)
        #expect(bar.replaceRow.isHidden)
        #expect(bar.replaceField.isHiddenOrHasHiddenAncestor)
        #expect(bar.replaceButton.isHiddenOrHasHiddenAncestor)
        #expect(bar.replaceAllButton.isHiddenOrHasHiddenAncestor)
        #expect(bar.disclosureButton.state == .off)
        let collapsed = bar.barView.fittingSize.height
        bar.setReplaceShown(true)
        let expanded = bar.barView.fittingSize.height
        #expect(collapsed < expanded)
        #expect(expanded - collapsed > 20)
        bar.setReplaceShown(false)
        #expect(bar.barView.fittingSize.height == collapsed)
    }

    @Test func expansionIsRememberedPerBarAndNeverPersisted() {
        let before = UserDefaults.standard.dictionaryRepresentation()
        let (bar, _) = makeBar()
        bar.showReplace()
        #expect(bar.isShown && bar.isReplaceShown)
        #expect(!bar.replaceRow.isHidden)
        bar.hide()
        bar.show()
        #expect(bar.isReplaceShown, "show() keeps the last expansion state")
        #expect(!bar.replaceRow.isHidden)

        bar.disclosureButton.performClick(nil)
        #expect(!bar.isReplaceShown)
        #expect(bar.replaceRow.isHidden)
        bar.disclosureButton.performClick(nil)
        #expect(bar.isReplaceShown)

        let (fresh, _) = makeBar()
        fresh.show()
        #expect(!fresh.isReplaceShown, "a new window starts collapsed")

        // Other suites may write their own defaults in parallel, so only keys
        // that could plausibly be ours are checked.
        let after = UserDefaults.standard.dictionaryRepresentation()
        let changed = after.keys.filter { key in
            guard let value = after[key] as? NSObject else { return false }
            return (before[key] as? NSObject) != value
        }
        #expect(changed.filter { $0.localizedCaseInsensitiveContains("find")
            || $0.localizedCaseInsensitiveContains("replace") }.isEmpty)
    }

    @Test func showReplaceOnAVisibleBarFocusesTheReplaceField() throws {
        let (bar, textView, window) = makeWindowedBar()
        defer { window.close() }
        bar.showReplace()
        // From hidden: focus goes to the search field, like show().
        func editingField() -> NSView? {
            ((window.firstResponder as? NSText)?.delegate as? NSView) ?? (window.firstResponder as? NSView)
        }
        #expect(editingField() === bar.searchField)

        bar.hide()
        #expect(window.firstResponder === textView)
        bar.setReplaceShown(false)
        bar.show()
        #expect(editingField() === bar.searchField)
        bar.showReplace()
        #expect(bar.isReplaceShown)
        #expect(editingField() === bar.replaceField)

        // Collapsing while the replace field has focus hands focus back.
        bar.disclosureButton.performClick(nil)
        #expect(editingField() === bar.searchField)
    }

    /// Esc closes the bar from either field; Return acts in the search field only.
    @Test func escapeClosesTheBarFromEitherFieldAndReturnOnlySearches() {
        let (bar, textView, window) = makeWindowedBar()
        defer { window.close() }
        let editor = NSTextView()
        let cancel = #selector(NSResponder.cancelOperation(_:))
        let newline = #selector(NSResponder.insertNewline(_:))
        bar.showReplace()
        #expect(!bar.control(bar.replaceField, textView: editor, doCommandBy: newline))
        #expect(bar.isShown)
        #expect(bar.control(bar.replaceField, textView: editor, doCommandBy: cancel))
        #expect(!bar.isShown && window.firstResponder === textView)
        // The expansion state survives closing with Esc.
        bar.show()
        #expect(bar.isReplaceShown)
        #expect(bar.control(bar.searchField, textView: editor, doCommandBy: newline))
        #expect(bar.control(bar.searchField, textView: editor, doCommandBy: cancel))
        #expect(!bar.isShown)
    }

    @Test func tabFromSearchReachesReplaceOnlyWhenExpanded() {
        let (bar, _, window) = makeWindowedBar()
        defer { window.close() }
        bar.show()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.searchField.nextKeyView === bar.replaceField)
        #expect(bar.searchField.nextValidKeyView !== bar.replaceField)
        bar.setReplaceShown(true)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.searchField.nextValidKeyView === bar.replaceField)
    }

    @Test func statusSlotShowsPositionNoResultsReplacedAndErrors() {
        let (bar, textView) = makeBar()
        bar.show()
        bar.searchField.stringValue = "alpha"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPosition, 1, 3))
        #expect(bar.countLabel.stringValue.contains(" / "))
        #expect(bar.countLabel.toolTip == L10n.t(.findMatchLineTooltip, 1))
        bar.findNext()
        #expect(bar.countLabel.stringValue == L10n.t(.findMatchPosition, 2, 3))
        #expect(bar.countLabel.toolTip == L10n.t(.findMatchLineTooltip, 2))

        bar.searchField.stringValue = "zzz"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        #expect(bar.countLabel.stringValue == L10n.t(.findNoResults))
        #expect(bar.countLabel.toolTip == L10n.t(.findNoResults))

        bar.searchField.stringValue = "alpha"
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        bar.showReplace()
        bar.replaceField.stringValue = "x"
        bar.replaceAllButton.performClick(nil)
        #expect(textView.string == "x\nbeta x\ngamma x\n")
        #expect(bar.countLabel.stringValue == L10n.t(.findReplacedCount, 3))
        #expect(bar.countLabel.toolTip == L10n.t(.findReplacedCount, 3))
        #expect(bar.countLabel.textColor == .secondaryLabelColor)

        bar.regexToggle.performClick(nil)
        bar.searchField.stringValue = "("
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.searchField))
        #expect(bar.countLabel.textColor == .systemRed)
        #expect(!bar.countLabel.stringValue.isEmpty)
        #expect(bar.countLabel.toolTip == bar.countLabel.stringValue)
    }

    @Test func iconButtonsAndDisclosureAreLabelled() {
        let (bar, _) = makeBar()
        for (button, key) in [(bar.prevButton, L10nKey.findPrevTooltip),
                              (bar.nextButton, .findNextTooltip),
                              (bar.closeButton, .findDoneTooltip)] {
            #expect(button.image != nil)
            #expect(button.title.isEmpty)
            #expect(button.accessibilityLabel() == L10n.t(key))
            #expect(button.toolTip == L10n.t(key))
        }
        #expect(bar.disclosureButton.bezelStyle == .disclosure)
        #expect(bar.disclosureButton.accessibilityLabel() == L10n.t(.findShowReplace))
        #expect(bar.disclosureButton.toolTip == L10n.t(.findShowReplace))
        bar.setReplaceShown(true)
        #expect(bar.disclosureButton.state == .on)
        #expect(bar.disclosureButton.accessibilityLabel() == L10n.t(.findHideReplace))
        #expect(bar.disclosureButton.toolTip == L10n.t(.findHideReplace))
        #expect(bar.replaceAllButton.title == L10n.t(.findReplaceAll))
    }
}

/// Language-dependent widths. Switches the UI language the quiet way (no
/// change notification), restoring it afterwards; serialized so the other
/// language suites never interleave.
@Suite("Find bar widths per language", .serialized)
@MainActor
struct FindBarLanguageTests {
    private func setQuietly(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: L10n.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.defaultsKey)
        }
    }

    /// Lays the bar out at its own fitting width and checks nothing is clipped.
    private func checkNothingClipped(_ bar: FindBarController, _ context: String) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 200))
        host.addSubview(bar.barView)
        let width = bar.barView.fittingSize.width
        NSLayoutConstraint.activate([
            bar.barView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.barView.topAnchor.constraint(equalTo: host.topAnchor),
            bar.barView.widthAnchor.constraint(equalToConstant: width),
        ])
        host.layoutSubtreeIfNeeded()
        for view in allViews(bar.barView) where !view.isHiddenOrHasHiddenAncestor {
            if view === bar.countLabel { continue } // truncates by design
            let isLabel = (view as? NSTextField).map { !$0.isEditable && !$0.isBezeled } ?? false
            guard view is NSButton || isLabel else { continue }
            #expect(view.frame.width + 0.5 >= view.fittingSize.width,
                    "\(context): \((view as? NSButton)?.title ?? "") \(view.frame.width) < \(view.fittingSize.width)")
        }
        bar.barView.removeFromSuperview()
    }

    @Test func compactBarFitsThePadInEveryLanguage() {
        let previous = UserDefaults.standard.string(forKey: L10n.defaultsKey)
        defer { setQuietly(previous) }
        for language in AppLanguage.allCases {
            setQuietly(language.rawValue)
            #expect(L10n.current == language)
            for compact in [true, false] {
                let (bar, _) = makeBar(compact: compact)
                bar.show()
                let collapsed = bar.barView.fittingSize.width
                checkNothingClipped(bar, "\(language) compact=\(compact) collapsed")
                bar.setReplaceShown(true)
                let expanded = bar.barView.fittingSize.width
                checkNothingClipped(bar, "\(language) compact=\(compact) expanded")
                #expect(bar.minimumWidth == ceil(max(collapsed, expanded)))
                if compact {
                    #expect(collapsed <= 340, "\(language) collapsed: \(collapsed)")
                    #expect(expanded <= 340, "\(language) expanded: \(expanded)")
                }
            }
        }
    }
}

@Suite("Find and Replace command")
@MainActor
struct FindAndReplaceCommandTests {
    @Test func findSubmenuOffersFindAndReplaceRightAfterFind() throws {
        let menu = MainMenu.build(applyShortcuts: false)
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == L10n.t(.menuEdit) })
        let find = try #require(edit.items.compactMap(\.submenu).first { $0.title == L10n.t(.menuFind) })
        let index = try #require(find.items.firstIndex { $0.action == #selector(EditorWindowController.showFindBar(_:)) })
        let item = find.items[index + 1]
        #expect(item.action == #selector(EditorWindowController.showFindAndReplace(_:)))
        #expect(item.title == L10n.t(.menuFindAndReplace))
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.command, .option])

        // No other default binding claims ⌥⌘F.
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { $0.submenu.map(items) ?? [$0] }
        }
        let clashes = items(menu).filter {
            $0.keyEquivalent.lowercased() == "f" && $0.keyEquivalentModifierMask == [.command, .option]
        }
        #expect(clashes.count == 1)

        let suite = "FindAndReplaceShortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ShortcutSettings(defaults: defaults)
        let command = try #require(settings.commands.first { $0.action == "showFindAndReplace:" })
        #expect(command.scope == .all)
        #expect(command.defaultBinding == [ShortcutStroke("f", [.command, .option])])
        #expect(settings.conflicts(command.defaultBinding, for: command).isEmpty)
    }

    @Test func editorCommandShowsTheExpandedBar() throws {
        let defaults = try #require(UserDefaults(suiteName: "FindAndReplaceCommand-\(UUID().uuidString)"))
        let controller = EditorWindowController()
        controller.sessionStore = SessionStore(defaults: defaults)
        controller.draftStore = DraftStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KaruFindDrafts-\(UUID().uuidString)", isDirectory: true))
        defer { controller.close() }
        let bar = controller.findBarForTesting
        #expect(!bar.isShown && !bar.isReplaceShown)
        controller.showFindAndReplace(nil)
        #expect(bar.isShown)
        #expect(bar.isReplaceShown)
        #expect(!bar.barView.isHidden && !bar.replaceRow.isHidden)
        // ⌘F afterwards keeps the expansion.
        controller.showFindBar(nil)
        #expect(bar.isReplaceShown)
    }

    @Test func scratchpadCommandShowsTheExpandedBar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KaruFindPad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = ScratchpadController(store: ScratchpadStore(directory: dir))
        controller.show()
        defer { controller.hide() }
        let bar = try #require(controller.diagnosticFindBar)
        controller.showFindAndReplace()
        #expect(bar.isShown && bar.isReplaceShown)
        // The pad stays at least as wide as either state of its compact bar.
        let panel = try #require(controller.diagnosticPanel)
        #expect(panel.contentMinSize.width >= bar.minimumWidth)
        // The text sits below the two-row bar.
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        let textView = try #require(controller.diagnosticTextView)
        let scroll = try #require(textView.enclosingScrollView)
        let barFrame = bar.barView.convert(bar.barView.bounds, to: content)
        let scrollFrame = scroll.convert(scroll.bounds, to: content)
        #expect(barFrame.height > 50)
        if content.isFlipped {
            #expect(scrollFrame.minY >= barFrame.maxY - 0.5)
        } else {
            #expect(scrollFrame.maxY <= barFrame.minY + 0.5)
        }
    }
}
