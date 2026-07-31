import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [EditorWindowController] = []

    /// Single shared preferences window; created on first use, then just
    /// brought forward on subsequent opens.
    private lazy var preferencesController = PreferencesWindowController()

    /// Sparkle updater (M11). Created in `applicationDidFinishLaunching` only
    /// when running from a bundled .app — the bare test/benchmark binary has no
    /// feed URL or signing key and must not start an updater.
    private var updateController: UpdateController?

    /// "What was open last time" list backing session restore (T14.8). Shared
    /// with every window this delegate creates; injectable so tests can isolate
    /// it in their own UserDefaults suite.
    var sessionStore = SessionStore()

    /// Unsaved-content backup shared by every window (T14.11): what a crash
    /// leaves behind and this delegate hands back at the next launch.
    /// Injectable so tests never touch the user's real drafts.
    var draftStore = DraftStore()

    /// True from the moment termination is approved. Windows consult it while
    /// closing: a close during quit keeps its session entry (so the file
    /// reopens next launch), a close by the user removes it.
    private(set) var isTerminating = false

    /// The always-available scratchpad (T15.1). While hidden this is an empty
    /// shell — a store plus two closures; the panel and its text view only exist
    /// between `show()` and `hide()`. Created lazily so a delegate built by a
    /// test that never launches the app pays nothing for it.
    lazy var scratchpadController = ScratchpadController()

    /// The global hot key that summons the scratchpad. Together with the status
    /// item below it is the only part of the feature that stays resident.
    private let hotKeyCenter = HotKeyCenter()

    /// Menu-bar item: reaches the scratchpad (and a new window / settings) while
    /// Karu has no window on screen — the counterpart of the "keep running after
    /// the last window closes" policy below.
    private var statusItem: NSStatusItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if UpdateController.isSupported {
            updateController = UpdateController()
            // An update relaunch must restore the session even though the quit
            // it rides on is otherwise clean (T14.9).
            updateController?.willRelaunchForUpdate = { [sessionStore] in
                sessionStore.markUpdateRelaunch()
            }
        }
        NSApp.mainMenu = MainMenu.build()

        // Restore policy (T14.9, user decision): only an update relaunch or an
        // exit that never marked itself clean (crash / force quit) restores the
        // previous session; a normal quit-and-reopen starts fresh. Decided once
        // here, before any window opens; when not restoring, the leftover list
        // is dropped so stale entries can't resurface after a later crash.
        let shouldRestoreSession = sessionStore.beginSession()
        if !shouldRestoreSession {
            sessionStore.clear()
            // Belt and braces: a clean quit already wiped the drafts, so
            // anything still here is residue that must not resurface (T14.11).
            draftStore.clear()
        }

        // Rebuild the main menu in the new language on a live switch; open
        // windows and the preferences window re-pull their own strings via their
        // own observers.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.didChangeNotification,
            object: nil
        )

        // Open any existing file paths passed on the command line (used by
        // scripts/mem-benchmark.sh and handy for `open -a Karu file`);
        // arguments that are not existing files (e.g. -NSDebug flags) are
        // ignored. With no file arguments, start with one untitled window.
        let fileArgs = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
        }
        if fileArgs.isEmpty {
            // application(_:open:) may already have opened documents before
            // didFinishLaunching runs (Finder double-click launch) — only
            // create the untitled window when nothing else is open, otherwise
            // every Finder open spawned a stray empty window.
            if windowControllers.isEmpty {
                // Plain launch (no file arguments, nothing opened from Finder):
                // bring back the previous session's documents when the restore
                // policy above says so (update relaunch / crash), then pour any
                // unsaved content a crash left behind into them (T14.11 — it
                // can also open windows of its own, for untitled drafts).
                if shouldRestoreSession {
                    restoreSession()
                    restoreDrafts()
                }
                // Nothing came back (or nothing to come back to): start fresh.
                if windowControllers.isEmpty {
                    newDocument(nil)
                }
            }
        } else {
            for path in fileArgs {
                let controller = makeController()
                controller.load(url: URL(fileURLWithPath: path))
                controller.showWindow(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        // Scratchpad (T15.1). Installed after the windows exist so the status
        // item's own window can never be mistaken for the editor by the snapshot
        // hook below (it walks `NSApp.windows` in creation order).
        hotKeyCenter.start { [weak self] in
            MainActor.assumeIsolated { self?.scratchpadController.toggle() }
        }
        MainActor.assumeIsolated {
            // Graduating a note hands the new file back here, where it opens in a
            // normal editor window through the same path Finder uses.
            scratchpadController.openInEditor = { [weak self] url in self?.openFromFinder(url) }
        }
        installStatusItem()
        // A rebound hot key must take effect at once (and relabel the status-bar
        // menu, which spells the binding out).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotKeyDidChange),
            name: HotKeyCenter.didChangeNotification,
            object: nil
        )

        // Fold-rendering diagnostics hook (T13.9, used by visual-smoke.sh):
        // KARU_FOLDTEST=all|current[:<line>] performs the fold shortly after
        // launch so KARU_SNAPSHOT captures the folded rendering, and
        // KARU_FOLDTEST_GEO dumps per-line fragment geometry. Fold rendering
        // proved environment-sensitive (the unit rig's typesetter breaks lines
        // at .null glyphs, the app's fuses them), so the regression guard must
        // run the real app. Zero cost when the variables are unset.
        if let foldTest = ProcessInfo.processInfo.environment["KARU_FOLDTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let controller = self?.windowControllers.first else { return }
                if foldTest == "all" {
                    controller.foldAll(nil)
                } else if foldTest.hasPrefix("current") {
                    if let lineStr = foldTest.split(separator: ":").last, let line = Int(lineStr),
                       let tv = controller.window?.contentView?.firstSubview(ofType: NSTextView.self) {
                        let ns = tv.string as NSString
                        var offset = 0
                        for _ in 1..<line { offset = ns.range(of: "\n", range: NSRange(location: offset, length: ns.length - offset)).location + 1 }
                        tv.setSelectedRange(NSRange(location: offset, length: 0))
                    }
                    controller.foldCurrentBlock(nil)
                }
                // Geometry dump shortly after the fold, before the snapshot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard let tv = controller.window?.contentView?.firstSubview(ofType: NSTextView.self),
                          let lm = tv.layoutManager else { return }
                    let ns = tv.string as NSString
                    var out = ""
                    var idx = 0
                    var line = 1
                    while idx < ns.length {
                        let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
                        let g = lm.glyphIndexForCharacter(at: lineRange.location)
                        var eff = NSRange()
                        let frag = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: &eff)
                        let used = lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
                        let fragChars = lm.characterRange(forGlyphRange: eff, actualGlyphRange: nil)
                        out += "L\(line) chars=\(NSStringFromRange(lineRange)) glyph=\(g) fragY=\(frag.origin.y) fragH=\(frag.size.height) usedW=\(used.size.width) fragChars=\(NSStringFromRange(fragChars))\n"
                        idx = NSMaxRange(lineRange)
                        line += 1
                    }
                    try? out.write(toFile: ProcessInfo.processInfo.environment["KARU_FOLDTEST_GEO"] ?? "/tmp/foldgeo.txt",
                                   atomically: true, encoding: .utf8)
                }
            }
        }

        // Scratchpad diagnostics hook (T15.1), same spirit as KARU_FOLDTEST: the
        // panel is a non-activating floating window whose whole point is what it
        // leaves behind (nothing) after hiding, and neither headless unit tests
        // nor a pixel snapshot can show that. KARU_SCRATCHTEST=show dumps the
        // built panel's state; =cycle types into it, hides it, and dumps proof
        // that the panel is gone while the text reached disk. Zero cost unset.
        if let scratchTest = ProcessInfo.processInfo.environment["KARU_SCRATCHTEST"] {
            let outPath = ProcessInfo.processInfo.environment["KARU_SCRATCHTEST_OUT"]
                ?? "/tmp/scratchtest.txt"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.scratchpadController.show()
                if scratchTest == "cycle" {
                    if let tv = self.scratchpadController.diagnosticTextView {
                        tv.string = "scratch-cycle-proof"
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                        tv.insertText(" typed", replacementRange: tv.selectedRange())
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.scratchpadController.hide()
                        let visible = NSApp.windows.filter { $0.isVisible }.count
                        var dump = "panelNil=\(self.scratchpadController.diagnosticPanel == nil)\n"
                        dump += "storeContent=\(String(self.scratchpadController.store.read().prefix(80)))\n"
                        dump += "windowsVisible=\(visible)\n"
                        try? dump.write(toFile: outPath, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let panel = self.scratchpadController.diagnosticPanel
                        let text = self.scratchpadController.diagnosticTextView?.string ?? ""
                        // Optional pixel proof: the pin-button regression (user
                        // report: "no pin visible") showed that what the panel
                        // *contains* and what it *shows* can differ — dump the
                        // real rendering when a path is given.
                        if let pngPath = ProcessInfo.processInfo.environment["KARU_SCRATCHTEST_PNG"],
                           let view = panel?.contentView?.superview ?? panel?.contentView,
                           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: pngPath))
                        }
                        var dump = "panelVisible=\(panel?.isVisible == true)\n"
                        dump += "titlebarAccessories=\(panel?.titlebarAccessoryViewControllers.count ?? -1)\n"
                        dump += "panelLevel=\(panel?.level.rawValue ?? -1)\n"
                        dump += "styleMask=\(panel?.styleMask.rawValue ?? 0)\n"
                        dump += "textLen=\((text as NSString).length)\n"
                        dump += "text=\(String(text.prefix(80)))\n"
                        dump += "hotkeyStatus=\(self.hotKeyCenter.lastStatus)\n"
                        dump += "hotkeyDisplay=\(self.hotKeyCenter.displayString)\n"
                        dump += "pinned=\(ScratchpadStore.isPinned())\n"
                        try? dump.write(toFile: outPath, atomically: true, encoding: .utf8)
                        NSApp.terminate(nil)
                    }
                }
            }
        }

        // Headless visual-diagnostics hook: KARU_SNAPSHOT=<png-path>
        // renders the first window's content view to a PNG after layout settles
        // and exits. Lets scripts verify real rendering without the screen-
        // recording permission that `screencapture` needs.
        if let snapshotPath = ProcessInfo.processInfo.environment["KARU_SNAPSHOT"] {
            // Deterministic rendering for the pixel checks in visual-smoke.sh:
            // force light appearance so the bright/dark thresholds hold no matter
            // the system theme (auto dark mode at night broke the smoke test).
            // KARU_SNAPSHOT_APPEARANCE=dark opts a diagnostic run into dark mode.
            let env = ProcessInfo.processInfo.environment
            NSApp.appearance = NSAppearance(
                named: env["KARU_SNAPSHOT_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
            // KARU_SNAPSHOT_SCROLLEND=1 scrolls to the document end before the
            // capture — needed to reproduce scrolled-state bugs (titlebar
            // underlap, scroll-edge effects) that never show at offset zero.
            if env["KARU_SNAPSHOT_SCROLLEND"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    if let tv = NSApp.windows.first(where: { $0.isVisible })?
                        .contentView?.firstSubview(ofType: NSTextView.self) {
                        tv.scrollToEndOfDocument(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Render the theme frame (contentView's superview) when available
                // so the capture includes the titlebar/toolbar — needed to catch
                // titlebar-transparency / content-underlap bugs.
                if let contentView = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let view = contentView.superview ?? contentView as NSView?,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: snapshotPath))
                    // Companion hierarchy dump for frame-level diagnostics.
                    var dump = "windows=\(NSApp.windows.filter { $0.isVisible && $0.contentView != nil }.count)\n"
                    func walk(_ v: NSView, _ depth: Int) {
                        dump += String(repeating: "  ", count: depth)
                        dump += "\(type(of: v)) frame=\(v.frame) hidden=\(v.isHidden)"
                        if let tv = v as? NSTextView {
                            dump += " textLen=\((tv.string as NSString).length)"
                            dump += " container=\(tv.textContainer?.size ?? .zero)"
                            dump += " usedRect=\(tv.layoutManager?.usedRect(for: tv.textContainer!) ?? .zero)"
                        }
                        dump += "\n"
                        for sub in v.subviews { walk(sub, depth + 1) }
                    }
                    walk(view, 0)
                    try? dump.write(toFile: snapshotPath + ".txt", atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Karu keeps running with no window open (user decision, T15.1): the whole
    /// point of a global scratchpad hot key is that it works when the editor is
    /// out of sight, and quitting on the last close would kill the hot key with
    /// it. The status-bar item is what makes that state navigable.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon of a running-but-windowless Karu must give the user
    /// something to type in; with a window already open, AppKit's own unminimize /
    /// front behaviour is the right one, so it is left alone.
    public func applicationShouldHandleReopen(_ sender: NSApplication,
                                              hasVisibleWindows: Bool) -> Bool {
        guard windowControllers.isEmpty else { return true }
        newDocument(nil)
        return false
    }

    // MARK: - Status-bar item (T15.1)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "square.and.pencil",
                            accessibilityDescription: L10n.t(.scratchpadTitle))
        image?.isTemplate = true   // tints itself for light / dark menu bars
        item.button?.image = image
        statusItem = item
        rebuildStatusItemMenu()
    }

    /// Built fresh whenever the UI language or the hot key changes — the menu
    /// spells the current binding out next to the scratchpad entry.
    private func rebuildStatusItemMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let scratchpad = menu.addItem(
            withTitle: "\(L10n.t(.statusScratchpad))  \(hotKeyCenter.displayString)",
            action: #selector(toggleScratchpad(_:)), keyEquivalent: "")
        scratchpad.target = self
        let newWindow = menu.addItem(withTitle: L10n.t(.dockNewWindow),
                                     action: #selector(newWindowFromStatusItem(_:)),
                                     keyEquivalent: "")
        newWindow.target = self
        let settings = menu.addItem(withTitle: L10n.t(.appSettings),
                                    action: #selector(showPreferences(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.t(.appQuit, L10n.appName),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        statusItem.menu = menu
    }

    /// Scratchpad toggle: the View-menu item, the status-bar entry and the global
    /// hot key all land here.
    @objc public func toggleScratchpad(_ sender: Any?) {
        MainActor.assumeIsolated { scratchpadController.toggle() }
    }

    /// Status-bar "New Window": unlike the menu-bar item this can be picked while
    /// Karu is in the background, so it has to activate before opening.
    @objc private func newWindowFromStatusItem(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        newDocument(sender)
    }

    @objc private func hotKeyDidChange() {
        hotKeyCenter.reregister()
        rebuildStatusItemMenu()
    }

    /// Dock icon context menu: a "New Window" entry (a new document *is* a new
    /// window in Karu). Built fresh on every right-click, so it always speaks
    /// the current UI language.
    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t(.dockNewWindow),
                     action: #selector(newDocument(_:)),
                     keyEquivalent: "")
        return menu
    }

    // Quit must honor the same unsaved-changes confirmation as closing a window;
    // NSApp.terminate does not consult windowShouldClose on its own.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windowControllers {
            if let window = controller.window, !controller.windowShouldClose(window) {
                return .terminateCancel
            }
        }
        // Quitting for real (⌘Q, or a Sparkle update relaunch). Mark it *before*
        // any window closes, so the closes that follow keep their session
        // entries instead of clearing the list, and take one last caret/scroll
        // snapshot here — AppKit does not reliably send windowWillClose during
        // termination, so this is the only dependable moment (T14.8).
        isTerminating = true
        for controller in windowControllers {
            controller.recordSessionState()
        }
        // The scratchpad's debounced write would never fire once we return
        // `.terminateNow`, so force it out here — the pad is a notebook, and
        // losing the last sentence typed before ⌘Q is not acceptable.
        MainActor.assumeIsolated { scratchpadController.flushIfVisible() }
        // A quit that reaches this line is deliberate: mark it clean so the
        // next launch starts fresh. If Sparkle set the update-relaunch flag
        // before terminating us, that flag overrides cleanliness and the next
        // launch restores anyway (T14.9).
        sessionStore.markCleanExit()
        // Every window has just passed its unsaved-changes confirmation above —
        // saved, or discarded on purpose — so the crash drafts have done their
        // job and must not resurface next launch (T14.11). A crash never
        // reaches this line, which is exactly what keeps its drafts alive.
        draftStore.clear()
        return .terminateNow
    }

    // MARK: - Session restore (T14.8)

    /// Reopens the files recorded by the previous session, in the order they
    /// were opened, and returns how many windows were restored.
    ///
    /// Entries whose file has since disappeared (moved, deleted, an unmounted
    /// volume) are dropped from the list silently — a restore must never nag on
    /// launch. Only saved documents are involved; untitled drafts are out of
    /// scope for plan A.
    @discardableResult
    func restoreSession() -> Int {
        var restored = 0
        for entry in sessionStore.entries() {
            let url = UbiquitousFile.resolvedURL(for: URL(fileURLWithPath: entry.path))
            guard FileManager.default.fileExists(atPath: url.path) else {
                sessionStore.remove(path: entry.path)
                continue
            }
            let controller = makeController()
            controller.load(url: url)
            controller.restoreSession(caret: entry.caret, scrollY: entry.scrollY)
            controller.showWindow(nil)
            restored += 1
        }
        return restored
    }

    // MARK: - Crash-draft restore (T14.11)

    /// Hands back the unsaved content a crash (or force quit) left behind, and
    /// returns how many drafts were recovered.
    ///
    /// Runs right after `restoreSession()` on a restoring launch, so the windows
    /// for saved files already exist and most drafts only have to be poured into
    /// one. Three shapes are handled:
    ///   * untitled draft → a new window carrying the content;
    ///   * draft for a file that is open (or can be opened) → the buffer is
    ///     replaced with the draft, unless the file itself changed on disk after
    ///     the draft was taken, in which case disk wins and the draft is dropped;
    ///   * draft for a file that no longer exists → recovered as untitled, since
    ///     the draft is then the only copy of that text left.
    @discardableResult
    func restoreDrafts() -> Int {
        var restored = 0
        for draft in draftStore.drafts() {
            guard let path = draft.originalPath else {
                openRecoveredUntitled(draft, message: L10n.t(.draftRestored))
                restored += 1
                continue
            }
            let url = UbiquitousFile.resolvedURL(for: URL(fileURLWithPath: path))
            guard FileManager.default.fileExists(atPath: url.path) else {
                openRecoveredUntitled(draft, message: L10n.t(.draftRestoredAsUntitled))
                restored += 1
                continue
            }
            let controller = windowController(for: url) ?? openRestoredFile(url)

            // Conflict rule (user decision): a file that changed on disk *after*
            // the draft was written wins — another app or a sync edited it in
            // the meantime, and silently pasting stale text over that would be
            // the worse loss. Reported in the status bar rather than a modal:
            // a launch must never open with an alert.
            if let modified = Self.modificationDate(of: url), modified > draft.savedAt {
                draftStore.remove(id: draft.id)
                controller.flashStatus(L10n.t(.draftDiscardedDiskNewer))
                continue
            }
            controller.applyRecoveredDraft(id: draft.id, content: draft.content)
            controller.flashStatus(L10n.t(.draftRestored))
            restored += 1
        }
        return restored
    }

    /// Opens a fresh untitled window holding a recovered draft.
    private func openRecoveredUntitled(_ draft: DraftStore.Draft, message: String) {
        let controller = makeController()
        controller.applyRecoveredDraft(id: draft.id, content: draft.content)
        controller.showWindow(nil)
        controller.flashStatus(message)
    }

    /// The already-open window showing `url`, if any.
    private func windowController(for url: URL) -> EditorWindowController? {
        windowControllers.first {
            $0.currentFileURL.map { UbiquitousFile.sameFile($0, url) } ?? false
        }
    }

    /// Opens a window for a draft whose file the session list did not restore
    /// (the window had been closed, or the file arrived some other way), so the
    /// recovered text lands next to its document rather than as an orphan.
    private func openRestoredFile(_ url: URL) -> EditorWindowController {
        let controller = makeController()
        controller.load(url: url)
        controller.showWindow(nil)
        return controller
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    @objc private func languageDidChange() {
        NSApp.mainMenu = MainMenu.build()
        rebuildStatusItemMenu()
    }

    @objc public func newDocument(_ sender: Any?) {
        let controller = makeController()
        controller.showWindow(nil)
    }

    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let controller = makeController()
            controller.load(url: url)
            controller.showWindow(nil)
        }
    }

    /// Finder / LaunchServices entry point (double-click, Open With, drag onto
    /// Dock icon). Without this — and CFBundleDocumentTypes in Info.plist —
    /// files could only be opened from inside the app, which shipped as the
    /// "saved a file but can't reopen it" bug.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openFromFinder(url)
        }
    }

    /// Opens (or re-fronts) a single URL arriving from Finder/LaunchServices.
    /// Handles three things beyond a plain load (T10.4):
    ///   1. `.name.icloud` placeholder → real file URL.
    ///   2. De-duplication: if a window is already open (or mid-download) for
    ///      the same file, bring it forward instead of opening a duplicate —
    ///      this kills the "two identical windows" report, including the extra
    ///      `open` event LaunchServices re-sends after a download finishes.
    ///   3. A not-yet-synced iCloud item opens a window immediately in a
    ///      "(Downloading…)" state and loads once the download lands, rather
    ///      than opening a blank/failed window that needs a second double-click.
    /// Internal rather than private: the scratchpad hands graduated files back
    /// through this same path, so a note that just became a document opens
    /// exactly like one double-clicked in Finder.
    func openFromFinder(_ rawURL: URL) {
        let url = UbiquitousFile.resolvedURL(for: rawURL)

        // De-duplicate against an already-open (or downloading) window.
        if let existing = windowControllers.first(where: {
            guard let open = $0.currentFileURL else { return false }
            return UbiquitousFile.sameFile(open, url)
        }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Reuse a single pristine untitled window (fresh launch case) instead of
        // leaving it orphaned next to the opened document; otherwise open a new
        // one. A window mid-download is not pristine, so it is never reused here.
        let controller: EditorWindowController
        if windowControllers.count == 1,
           let only = windowControllers.first, only.isPristineUntitled {
            controller = only
        } else {
            controller = makeController()
        }

        if shouldDownloadBeforeOpening(rawURL: rawURL, resolved: url) {
            controller.beginDownloading(url: url)
        } else {
            controller.load(url: url)
        }
        controller.showWindow(nil)
    }

    /// Whether `url` must be pulled down from iCloud before it can be read.
    /// A `.icloud` placeholder means the real file is not on disk yet, so it
    /// always needs downloading; otherwise consult the item's resource values.
    private func shouldDownloadBeforeOpening(rawURL: URL, resolved: URL) -> Bool {
        if UbiquitousFile.isPlaceholder(rawURL) { return true }
        guard let values = try? resolved.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        else { return false }
        return UbiquitousFile.needsDownload(
            isUbiquitous: values.isUbiquitousItem ?? false,
            status: values.ubiquitousItemDownloadingStatus)
    }

    /// Menu target for "Check for Updates…". No-ops (beep) in unbundled runs
    /// where the updater cannot exist.
    @objc public func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let updateController else { NSSound.beep(); return }
            updateController.checkForUpdates(sender)
        }
    }

    // MARK: - View ▸ Zoom (global editor font size)

    /// The editor font size is a global setting, so zoom lives here: each command
    /// updates the shared `EditorFontSettings` key, which broadcasts the change to
    /// every open window and the preferences panel.
    @objc public func zoomIn(_ sender: Any?) { applyZoom(.increase) }

    @objc public func zoomOut(_ sender: Any?) { applyZoom(.decrease) }

    /// Restores the default editor font size (⌘0).
    @objc public func actualSize(_ sender: Any?) {
        EditorFontSettings().setFontSize(FontZoom.defaultSize)
    }

    private func applyZoom(_ direction: FontZoom.Direction) {
        let current = EditorFontSettings().fontSize
        EditorFontSettings().setFontSize(FontZoom.step(current: current, direction: direction))
    }

    @objc public func showPreferences(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        preferencesController.showWindow(nil)
        if let window = preferencesController.window {
            // The panel must land in front of the editor no matter what: follow
            // the user to the active Space (it may have been left open on
            // another one) and force it above the key editor window — plain
            // makeKeyAndOrderFront alone left it stacked behind (user bug).
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func makeController() -> EditorWindowController {
        let controller = EditorWindowController()
        // Session restore (T14.8): every window shares this delegate's store and
        // asks it whether a close is "the user closed it" or "the app is
        // quitting" — the two mean opposite things for the restore list.
        controller.sessionStore = sessionStore
        controller.isAppTerminating = { [weak self] in self?.isTerminating ?? false }
        // Crash drafts (T14.11): one shared store, so a window's unsaved content
        // ends up where this delegate looks for it at the next launch.
        controller.draftStore = draftStore
        // Every window shares one frame-autosave slot, so a second window would
        // restore to exactly the first one's frame and hide it completely.
        // Cascade it down-right from the most recent window instead, wrapping
        // back to the screen's top-left when it would fall off the visible area.
        if let previous = windowControllers.last?.window, let window = controller.window {
            var topLeft = NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)
            if let screen = previous.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if topLeft.x + window.frame.width > visible.maxX
                    || topLeft.y - window.frame.height < visible.minY {
                    topLeft = NSPoint(x: visible.minX + 24, y: visible.maxY - 24)
                }
            }
            window.setFrameTopLeftPoint(topLeft)
        }
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        return controller
    }
}

private extension NSView {
    /// Depth-first search for the first descendant of the given type — used by
    /// the snapshot diagnostics hook to find the editor text view.
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        for sub in subviews {
            if let hit = sub as? T { return hit }
            if let hit = sub.firstSubview(ofType: type) { return hit }
        }
        return nil
    }
}
