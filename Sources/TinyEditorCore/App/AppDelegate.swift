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

    @objc public func newDocument(_ sender: Any?) {
        let controller = EditorWindowController()
        controller.onClose = { [weak self, weak controller] in
            self?.windowControllers.removeAll { $0 === controller }
        }
        windowControllers.append(controller)
        controller.showWindow(nil)
    }
}
