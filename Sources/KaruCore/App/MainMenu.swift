import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t(.appAbout, L10n.appName),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // Sparkle one-click update (M11); no-ops with a beep in unbundled runs.
        appMenu.addItem(withTitle: L10n.t(.appCheckForUpdates),
                        action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t(.appSettings),
                        action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t(.appHide, L10n.appName),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t(.appQuit, L10n.appName),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L10n.t(.menuFile))
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: L10n.t(.menuNew), action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: L10n.t(.menuOpen), action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L10n.t(.menuClose), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: L10n.t(.menuSave), action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAsItem = fileMenu.addItem(withTitle: L10n.t(.menuSaveAs),
                                          action: #selector(EditorWindowController.saveDocumentAs(_:)),
                                          keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]

        // Reopen with Encoding: manual override when auto-detection guessed wrong.
        // Each item carries its `TextEncoding.rawValue` on `representedObject`;
        // EditorWindowController gates the whole submenu on there being a file URL.
        fileMenu.addItem(.separator())
        let reopenItem = NSMenuItem(title: L10n.t(.menuReopenWithEncoding), action: nil, keyEquivalent: "")
        fileMenu.addItem(reopenItem)
        let reopenMenu = NSMenu(title: L10n.t(.menuReopenWithEncoding))
        reopenItem.submenu = reopenMenu
        for encoding in TextEncoding.allCases {
            let item = reopenMenu.addItem(withTitle: encoding.displayName,
                                          action: #selector(EditorWindowController.reopenWithEncoding(_:)),
                                          keyEquivalent: "")
            item.representedObject = encoding.rawValue
        }

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.t(.menuEdit))
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.t(.menuUndo), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.t(.menuRedo), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Find submenu, nested under Edit, targeting the first responder
        // (EditorWindowController) via the responder chain.
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: L10n.t(.menuFind), action: nil, keyEquivalent: "")
        editMenu.addItem(findMenuItem)
        let findMenu = NSMenu(title: L10n.t(.menuFind))
        findMenuItem.submenu = findMenu
        findMenu.addItem(withTitle: L10n.t(.menuFindEllipsis),
                         action: #selector(EditorWindowController.showFindBar(_:)), keyEquivalent: "f")
        findMenu.addItem(withTitle: L10n.t(.menuFindNext),
                         action: #selector(EditorWindowController.findNext(_:)), keyEquivalent: "g")
        let findPrev = findMenu.addItem(withTitle: L10n.t(.menuFindPrevious),
                                        action: #selector(EditorWindowController.findPrevious(_:)),
                                        keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(withTitle: L10n.t(.menuUseSelectionForFind),
                         action: #selector(EditorWindowController.useSelectionForFind(_:)), keyEquivalent: "e")

        // Jump to Symbol (Cmd+Shift+O): sits at the end of the Edit menu, after
        // the Find submenu. Targets the first responder (EditorWindowController).
        let jumpToSymbol = editMenu.addItem(withTitle: L10n.t(.menuJumpToSymbol),
                                            action: #selector(EditorWindowController.jumpToSymbol(_:)),
                                            keyEquivalent: "o")
        jumpToSymbol.keyEquivalentModifierMask = [.command, .shift]

        // Go to Line (Ctrl+G): aligns with VS Code's macOS key binding. Targets
        // the first responder (EditorWindowController).
        let goToLine = editMenu.addItem(withTitle: L10n.t(.menuGoToLine),
                                        action: #selector(EditorWindowController.goToLine(_:)),
                                        keyEquivalent: "g")
        goToLine.keyEquivalentModifierMask = [.control]

        // Toggle Comment (⌘/, VS Code parity). Contains ⌘, so the menu equivalent
        // is reliable and no keyDown interception is needed.
        editMenu.addItem(.separator())
        let toggleComment = editMenu.addItem(withTitle: L10n.t(.menuToggleComment),
                                             action: #selector(EditorWindowController.toggleComment(_:)),
                                             keyEquivalent: "/")
        toggleComment.keyEquivalentModifierMask = [.command]

        // Line operations. ⌥↑ / ⌥↓ / ⌥⇧↑ / ⌥⇧↓ have no ⌘ so their menu equivalents
        // are unreliable (T12.1) — the items exist for discoverability, but the
        // real trigger is EditorTextView.keyDown → lineOperationChord. Delete Line
        // (⌘⇧K) does carry ⌘, so its menu equivalent works directly.
        editMenu.addItem(.separator())
        let up = UnicodeScalar(NSUpArrowFunctionKey)!
        let down = UnicodeScalar(NSDownArrowFunctionKey)!
        let moveUp = editMenu.addItem(withTitle: L10n.t(.menuMoveLineUp),
                                      action: #selector(EditorWindowController.moveLinesUp(_:)),
                                      keyEquivalent: String(up))
        moveUp.keyEquivalentModifierMask = [.option]
        let moveDown = editMenu.addItem(withTitle: L10n.t(.menuMoveLineDown),
                                        action: #selector(EditorWindowController.moveLinesDown(_:)),
                                        keyEquivalent: String(down))
        moveDown.keyEquivalentModifierMask = [.option]
        let copyUp = editMenu.addItem(withTitle: L10n.t(.menuCopyLineUp),
                                      action: #selector(EditorWindowController.copyLinesUp(_:)),
                                      keyEquivalent: String(up))
        copyUp.keyEquivalentModifierMask = [.option, .shift]
        let copyDown = editMenu.addItem(withTitle: L10n.t(.menuCopyLineDown),
                                        action: #selector(EditorWindowController.copyLinesDown(_:)),
                                        keyEquivalent: String(down))
        copyDown.keyEquivalentModifierMask = [.option, .shift]
        let deleteLine = editMenu.addItem(withTitle: L10n.t(.menuDeleteLine),
                                          action: #selector(EditorWindowController.deleteLines(_:)),
                                          keyEquivalent: "k")
        deleteLine.keyEquivalentModifierMask = [.command, .shift]

        // Jump to Matching Bracket (⌘⇧\). Carries ⌘, so its menu equivalent is
        // reliable. Targets the first responder (EditorWindowController).
        editMenu.addItem(.separator())
        let jumpBracket = editMenu.addItem(withTitle: L10n.t(.menuJumpToMatchingBracket),
                                           action: #selector(EditorWindowController.jumpToMatchingBracket(_:)),
                                           keyEquivalent: "\\")
        jumpBracket.keyEquivalentModifierMask = [.command, .shift]

        // Format menu: targets the first responder (EditorWindowController),
        // which gates the item on the `format` module + supported language via
        // validateMenuItem.
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: L10n.t(.menuFormat))
        formatMenuItem.submenu = formatMenu
        let formatDoc = formatMenu.addItem(withTitle: L10n.t(.menuFormatDocument),
                                           action: #selector(EditorWindowController.formatDocument(_:)),
                                           keyEquivalent: "f")
        // VS Code's Format Document chord (⌥⇧F) — zero adaptation cost for
        // users coming from there (user request, M10).
        formatDoc.keyEquivalentModifierMask = [.option, .shift]

        // Convert Line Endings: LF / CRLF / CR, the current file's style checked.
        // Each item carries its `LineEnding.rawValue` on `representedObject`;
        // EditorWindowController drives the check state via validateMenuItem.
        formatMenu.addItem(.separator())
        let lineEndingItem = NSMenuItem(title: L10n.t(.menuConvertLineEndings), action: nil, keyEquivalent: "")
        formatMenu.addItem(lineEndingItem)
        let lineEndingMenu = NSMenu(title: L10n.t(.menuConvertLineEndings))
        lineEndingItem.submenu = lineEndingMenu
        for ending in LineEnding.allCases {
            let item = lineEndingMenu.addItem(withTitle: ending.displayName,
                                              action: #selector(EditorWindowController.convertLineEndings(_:)),
                                              keyEquivalent: "")
            item.representedObject = ending.rawValue
        }

        // View menu: editor font zoom (global setting; actions on AppDelegate).
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L10n.t(.menuView))
        viewMenuItem.submenu = viewMenu
        // Zoom In (⌘+). A hidden alternate on ⌘= handles the common US-keyboard
        // habit of pressing ⌘= to mean ⌘+ (same action, same mask).
        let zoomIn = viewMenu.addItem(withTitle: L10n.t(.viewZoomIn),
                                      action: #selector(AppDelegate.zoomIn(_:)),
                                      keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = [.command]
        let zoomInAlt = viewMenu.addItem(withTitle: L10n.t(.viewZoomIn),
                                         action: #selector(AppDelegate.zoomIn(_:)),
                                         keyEquivalent: "=")
        zoomInAlt.keyEquivalentModifierMask = [.command]
        zoomInAlt.isAlternate = true
        let zoomOut = viewMenu.addItem(withTitle: L10n.t(.viewZoomOut),
                                       action: #selector(AppDelegate.zoomOut(_:)),
                                       keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = [.command]
        let actualSize = viewMenu.addItem(withTitle: L10n.t(.viewActualSize),
                                          action: #selector(AppDelegate.actualSize(_:)),
                                          keyEquivalent: "0")
        actualSize.keyEquivalentModifierMask = [.command]

        // Language menu: Auto (content/extension detection) plus a manual
        // override for each supported language. Targets the first responder
        // (EditorWindowController); check state is driven by validateMenuItem.
        let languageMenuItem = NSMenuItem()
        mainMenu.addItem(languageMenuItem)
        let languageMenu = NSMenu(title: L10n.t(.menuLanguage))
        languageMenuItem.submenu = languageMenu
        let autoItem = languageMenu.addItem(withTitle: L10n.t(.languageAuto),
                                            action: #selector(EditorWindowController.selectAutoLanguage(_:)),
                                            keyEquivalent: "")
        autoItem.state = .on
        languageMenu.addItem(.separator())
        // Shared with the toolbar's language popup (SupportedLanguage) so the two
        // lists never drift. The empty identifier is Plain Text (no highlight).
        for (title, identifier) in SupportedLanguage.all {
            let item = languageMenu.addItem(withTitle: title,
                                            action: #selector(EditorWindowController.selectLanguage(_:)),
                                            keyEquivalent: "")
            item.representedObject = identifier
        }

        return mainMenu
    }
}
