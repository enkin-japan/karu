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

    /// True from the moment termination is approved. Windows consult it while
    /// closing: a close during quit keeps its session entry (so the file
    /// reopens next launch), a close by the user removes it.
    private(set) var isTerminating = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if UpdateController.isSupported {
            updateController = UpdateController()
        }
        NSApp.mainMenu = MainMenu.build()

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
                // bring back the documents the previous session had open — the
                // whole point of T14.8, since an update relaunch or a crash used
                // to leave the user with a single empty window. Falls back to an
                // untitled window when there is nothing to restore.
                if restoreSession() == 0 {
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

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    @objc private func languageDidChange() {
        NSApp.mainMenu = MainMenu.build()
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
    private func openFromFinder(_ rawURL: URL) {
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
