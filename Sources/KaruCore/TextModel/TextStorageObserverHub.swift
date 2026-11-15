import AppKit

/// An object that wants to observe `NSTextStorage` edit processing without
/// owning the single `textStorage.delegate` slot.
///
/// `NSTextStorage` exposes exactly one delegate. Both the gutter (which drives
/// incremental `LineIndex` updates) and the highlight engine (which reschedules
/// viewport colouring) need the same `didProcessEditing` signal, so the slot is
/// occupied by a `TextStorageObserverHub` that fans the callback out to any
/// number of these observers.
@MainActor
public protocol TextStorageObserving: AnyObject {
    /// Mirror of `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)`,
    /// forwarded from the hub. Runs on the main thread as part of edit
    /// processing.
    func textStorageDidProcessEditing(editedMask: NSTextStorageEditActions,
                                      editedRange: NSRange,
                                      changeInLength delta: Int,
                                      textStorage: NSTextStorage)

    /// Mirror of `textStorage(_:willProcessEditing:range:changeInLength:)`.
    /// Its range is the edited characters themselves; by `didProcessEditing`
    /// attribute fixing has widened it to whole paragraphs (a one-unit insert
    /// into a 1 MB line reports the whole line), so an observer that needs
    /// the exact extent reads it here (T17.15d-A). Optional.
    func textStorageWillProcessEditing(editedMask: NSTextStorageEditActions,
                                       editedRange: NSRange,
                                       changeInLength delta: Int,
                                       textStorage: NSTextStorage)
}

public extension TextStorageObserving {
    func textStorageWillProcessEditing(editedMask: NSTextStorageEditActions,
                                       editedRange: NSRange,
                                       changeInLength delta: Int,
                                       textStorage: NSTextStorage) {}
}

/// Delegate multiplexer for `NSTextStorage`.
///
/// Set one instance as `textStorage.delegate` and register observers with
/// `add(_:)`. Observers are held weakly, so they do not need to unregister on
/// teardown — dead references are pruned lazily on the next mutation.
public final class TextStorageObserverHub: NSObject, NSTextStorageDelegate {
    private struct WeakObserver {
        weak var observer: TextStorageObserving?
    }

    private var observers: [WeakObserver] = []

    /// Registers `observer` (idempotent). Also drops any observers that have
    /// since been deallocated.
    public func add(_ observer: TextStorageObserving) {
        observers.removeAll { $0.observer == nil }
        guard !observers.contains(where: { $0.observer === observer }) else { return }
        observers.append(WeakObserver(observer: observer))
    }

    /// Removes `observer` if present.
    public func remove(_ observer: TextStorageObserving) {
        observers.removeAll { $0.observer == nil || $0.observer === observer }
    }

    // MARK: - NSTextStorageDelegate

    public func textStorage(_ textStorage: NSTextStorage,
                            willProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange,
                            changeInLength delta: Int) {
        MainActor.assumeIsolated {
            for box in observers {
                box.observer?.textStorageWillProcessEditing(
                    editedMask: editedMask,
                    editedRange: editedRange,
                    changeInLength: delta,
                    textStorage: textStorage
                )
            }
        }
    }

    public func textStorage(_ textStorage: NSTextStorage,
                            didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange,
                            changeInLength delta: Int) {
        // Text storage edit processing is delivered on the main thread, so it is
        // safe to hop into the main actor to reach the (main-actor) observers.
        MainActor.assumeIsolated {
            for box in observers {
                box.observer?.textStorageDidProcessEditing(
                    editedMask: editedMask,
                    editedRange: editedRange,
                    changeInLength: delta,
                    textStorage: textStorage
                )
            }
        }
    }
}
