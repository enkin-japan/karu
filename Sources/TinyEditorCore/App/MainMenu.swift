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
        formatDoc.keyEquivalentModifierMask = [.control, .shift]

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
