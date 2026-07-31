import AppKit
import Carbon.HIToolbox

/// The one system-wide hot key Karu owns: summon / dismiss the scratchpad
/// (T15.1). Carbon's `RegisterEventHotKey` is used rather than an
/// `NSEvent` global monitor because a monitor needs the Accessibility
/// permission and still cannot swallow the keystroke, while a Carbon hot key
/// works out of the box in a sandboxed, unprivileged app.
///
/// This is one of the two things allowed to stay resident while the scratchpad
/// panel is torn down (ARCHITECTURE.md §3.4): a registration in the window
/// server plus one closure. It holds no timer and no observer.
///
/// The keystroke itself is stored as a Carbon key code + Carbon modifier mask in
/// `UserDefaults`; the conversions between that representation, `NSEvent`'s
/// modifier flags and the string shown in menus are pure static functions so the
/// preferences recorder can be unit tested without registering anything.
public final class HotKeyCenter {

    /// Posted (object: nil) after the stored hot key changes, so the app delegate
    /// can re-register it and relabel the status-bar menu.
    public static let didChangeNotification = Notification.Name("KaruHotKeyDidChange")

    /// UserDefaults keys holding the override. Absent = the ⌥D default.
    public static let keyCodeDefaultsKey = "scratchpad.hotkey.keyCode"
    public static let modifiersDefaultsKey = "scratchpad.hotkey.modifiers"

    /// ⌥D out of the box: `D` for "draft", and ⌥ + a letter is the one modifier
    /// combination macOS itself barely uses, so the odds of a clash are low.
    public static let defaultKeyCode = UInt32(kVK_ANSI_D)
    public static let defaultModifiers = UInt32(optionKey)

    /// Owner signature of our hot-key ID ('Karu'), so the registration is ours
    /// alone even though the Carbon table is process-wide.
    private static let signature: OSType = 0x4B61_7275

    /// Result of the last `RegisterEventHotKey` call. Surfaced (rather than
    /// swallowed) because a hot key that silently failed to register — taken by
    /// another app, say — is otherwise invisible; the diagnostics hook dumps it.
    public private(set) var lastStatus: OSStatus = noErr

    private let defaults: UserDefaults
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// What a press runs. Retained for the app's lifetime — that closure and the
    /// registration are the whole resident footprint of this type.
    fileprivate var handler: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - Registration

    /// Installs the Carbon event handler and registers the stored hot key.
    /// Calling it twice is harmless: the handler is installed once and the
    /// registration is replaced.
    public func start(handler: @escaping () -> Void) {
        self.handler = handler
        installEventHandlerIfNeeded()
        register()
    }

    /// Re-reads the stored hot key after the user changed it: the old
    /// registration must go first, or the new one lands next to a stale binding
    /// that still fires.
    public func reregister() {
        installEventHandlerIfNeeded()
        register()
    }

    private func register() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        lastStatus = RegisterEventHotKey(storedKeyCode, storedModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The callback is a C function pointer and cannot capture, so `self` is
        // handed over as user data. Unretained on purpose: the app delegate owns
        // this object for the whole process lifetime, and the handler is removed
        // in `deinit` before the pointer could ever dangle.
        InstallEventHandler(GetApplicationEventTarget(),
                            hotKeyEventHandler,
                            1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    fileprivate func fire() {
        handler?()
    }

    // MARK: - Stored key (injectable defaults, so tests stay isolated)

    public var storedKeyCode: UInt32 { Self.storedKeyCode(in: defaults) }
    public var storedModifiers: UInt32 { Self.storedModifiers(in: defaults) }

    /// The current binding rendered for a menu title, e.g. "⌥D".
    public var displayString: String {
        Self.displayString(keyCode: storedKeyCode, carbonModifiers: storedModifiers)
    }

    public static func storedKeyCode(in defaults: UserDefaults = .standard) -> UInt32 {
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil else { return defaultKeyCode }
        return UInt32(max(0, defaults.integer(forKey: keyCodeDefaultsKey)))
    }

    public static func storedModifiers(in defaults: UserDefaults = .standard) -> UInt32 {
        guard defaults.object(forKey: modifiersDefaultsKey) != nil else { return defaultModifiers }
        return UInt32(max(0, defaults.integer(forKey: modifiersDefaultsKey)))
    }

    /// Persists a new binding. Broadcasting is left to the caller so a recorder
    /// can post once after writing both halves.
    public static func store(keyCode: UInt32, carbonModifiers: UInt32,
                             in defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: keyCodeDefaultsKey)
        defaults.set(Int(carbonModifiers), forKey: modifiersDefaultsKey)
    }

    /// Drops the override so the ⌥D default applies again.
    public static func resetToDefault(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyCodeDefaultsKey)
        defaults.removeObject(forKey: modifiersDefaultsKey)
    }

    // MARK: - Pure conversions

    /// Carbon modifier mask for a set of `NSEvent` flags — the direction the
    /// preferences recorder needs (it sees Cocoa events, Carbon does the
    /// registering). Flags Carbon has no equivalent for (caps lock, fn) are
    /// dropped rather than approximated.
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// A binding as macOS writes it in menus: modifiers in the platform's fixed
    /// ⌃⌥⇧⌘ order, then the key. Key codes outside the letter/digit tables show
    /// as "?" — the recorder accepts any key, and an unlabelled one is still
    /// better than refusing the binding the user just pressed.
    public static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + (keyNames[keyCode] ?? "?")
    }

    /// Key code → printed character, for the A–Z / 0–9 keys a shortcut realistically
    /// uses. Built from the `kVK_ANSI_*` constants so the mapping is checkable by
    /// eye against the headers.
    private static let keyNames: [UInt32: String] = {
        let table: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { (UInt32($0.0), $0.1) })
    }()
}

/// Carbon hot-key callback. A file-level function because `InstallEventHandler`
/// takes a bare C function pointer; the owning `HotKeyCenter` arrives as user
/// data. Carbon delivers this on the main thread, hence `assumeIsolated`.
private func hotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { center.fire() }
    return noErr
}
