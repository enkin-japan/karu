import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [EditorWindowController] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        newDocument(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func makeController() -> EditorWindowController {
        let controller = EditorWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        return controller
    }
}
