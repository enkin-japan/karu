import AppKit
import Sparkle

/// One-click in-app updates via Sparkle (M11, user decision 2026-07-21:
/// download size is irrelevant on modern networks — the budget red line is
/// *resident memory*, which Sparkle barely touches; see ARCHITECTURE.md §1).
///
/// The updater consumes an appcast.xml attached to every GitHub release
/// (SUFeedURL points at `releases/latest/download/appcast.xml`, which always
/// resolves to the newest release's asset) and verifies each download against
/// the EdDSA public key baked into Info.plist. Only instantiated when running
/// from a real .app bundle — the bare `.build` binary used by tests and the
/// benchmark scripts has no feed/key and must not start an updater.
@MainActor
public final class UpdateController {
    private let controller: SPUStandardUpdaterController

    /// True when this process can meaningfully update itself (bundled app).
    public static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    @objc public func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
