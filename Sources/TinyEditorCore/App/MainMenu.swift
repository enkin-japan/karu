import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About TinyEditor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TinyEditor",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TinyEditor",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAsItem = fileMenu.addItem(withTitle: "Save As…",
                                          action: #selector(EditorWindowController.saveDocumentAs(_:)),
                                          keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Find submenu, nested under Edit, targeting the first responder
        // (EditorWindowController) via the responder chain.
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        editMenu.addItem(findMenuItem)
        let findMenu = NSMenu(title: "Find")
        findMenuItem.submenu = findMenu
        findMenu.addItem(withTitle: "Find…",
                         action: #selector(EditorWindowController.showFindBar(_:)), keyEquivalent: "f")
        findMenu.addItem(withTitle: "Find Next",
                         action: #selector(EditorWindowController.findNext(_:)), keyEquivalent: "g")
        let findPrev = findMenu.addItem(withTitle: "Find Previous",
                                        action: #selector(EditorWindowController.findPrevious(_:)),
                                        keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(withTitle: "Use Selection for Find",
                         action: #selector(EditorWindowController.useSelectionForFind(_:)), keyEquivalent: "e")

        // Format menu: targets the first responder (EditorWindowController),
        // which gates the item on the `format` module + supported language via
        // validateMenuItem.
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: "Format")
        formatMenuItem.submenu = formatMenu
        let formatDoc = formatMenu.addItem(withTitle: "Format Document",
                                           action: #selector(EditorWindowController.formatDocument(_:)),
                                           keyEquivalent: "f")
        formatDoc.keyEquivalentModifierMask = [.control, .shift]

        // Language menu: Auto (content/extension detection) plus a manual
        // override for each supported language. Targets the first responder
        // (EditorWindowController); check state is driven by validateMenuItem.
        let languageMenuItem = NSMenuItem()
        mainMenu.addItem(languageMenuItem)
        let languageMenu = NSMenu(title: "Language")
        languageMenuItem.submenu = languageMenu
        let autoItem = languageMenu.addItem(withTitle: "Auto",
                                            action: #selector(EditorWindowController.selectAutoLanguage(_:)),
                                            keyEquivalent: "")
        autoItem.state = .on
        languageMenu.addItem(.separator())
        // (title, identifier). The empty identifier is Plain Text (no highlight).
        let languages: [(String, String)] = [
            ("Plain Text", ""),
            ("JSON", "json"),
            ("JSONL", "jsonl"),
            ("Markdown", "markdown"),
            ("Python", "python"),
            ("JavaScript", "javascript"),
            ("TypeScript", "typescript"),
            ("HTML", "html"),
            ("CSS", "css"),
            ("C", "c"),
            ("C++", "cpp"),
            ("C#", "csharp"),
            ("Java", "java"),
            ("Bash", "bash"),
            ("SQL", "sql"),
            ("XML", "xml"),
        ]
        for (title, identifier) in languages {
            let item = languageMenu.addItem(withTitle: title,
                                            action: #selector(EditorWindowController.selectLanguage(_:)),
                                            keyEquivalent: "")
            item.representedObject = identifier
        }

        return mainMenu
    }
}
