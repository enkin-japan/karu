import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [EditorWindowController] = []

    /// Single shared preferences window; created on first use, then just
    /// brought forward on subsequent opens.
    private lazy var preferencesController = PreferencesWindowController()

    public func applicationDidFinishLaunching(_ notification: Notification) {
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
        // scripts/mem-benchmark.sh and handy for `open -a TinyEditor file`);
        // arguments that are not existing files (e.g. -NSDebug flags) are
        // ignored. With no file arguments, start with one untitled window.
        let fileArgs = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
        }
        if fileArgs.isEmpty {
            newDocument(nil)
        } else {
            for path in fileArgs {
                let controller = makeController()
                controller.load(url: URL(fileURLWithPath: path))
                controller.showWindow(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        // Headless visual-diagnostics hook: TINYEDITOR_SNAPSHOT=<png-path>
        // renders the first window's content view to a PNG after layout settles
        // and exits. Lets scripts verify real rendering without the screen-
        // recording permission that `screencapture` needs.
        if let snapshotPath = ProcessInfo.processInfo.environment["TINYEDITOR_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: snapshotPath))
                    // Companion hierarchy dump for frame-level diagnostics.
                    var dump = ""
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

    // Quit must honor the same unsaved-changes confirmation as closing a window;
    // NSApp.terminate does not consult windowShouldClose on its own.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in windowControllers {
            if let window = controller.window, !controller.windowShouldClose(window) {
                return .terminateCancel
            }
        }
        return .terminateNow
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

    @objc public func showPreferences(_ sender: Any?) {
        preferencesController.showWindow(nil)
        preferencesController.window?.makeKeyAndOrderFront(nil)
    }

    private func makeController() -> EditorWindowController {
        let controller = EditorWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        return controller
    }
}
