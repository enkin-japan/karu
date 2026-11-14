import Foundation

/// The character edits applied to a document since some base text version
/// (M17 T17.5, plan §3 "版本"): maps offsets between that base text and the
/// live text.
///
/// `DocumentAnalysis` keeps one relative to the last *published* declaration
/// snapshot, so completion can query the snapshot's scopes while a rescan is
/// pending; the completion controller keeps one relative to its document
/// word index. Each entry is one `NSTextStorage` edit in application order:
/// the location and the replaced / inserted lengths, in UTF-16 units of the
/// text the edit applied to.
///
/// Bounded: past `capacity` entries the journal turns **unmappable** (both
/// mappings return nil) and stops recording until it is reset — the caller
/// falls back to offset-free data (module-level names) until the next base
/// version arrives. Pure value type: no AppKit, `Sendable`.
public struct EditJournal: Sendable, Equatable {
    public struct Edit: Sendable, Equatable {
        public let location: Int
        public let oldLength: Int
        public let newLength: Int
    }

    /// Entries kept before the journal gives up (an edit burst this long
    /// means the base is far behind anyway).
    public static let capacity = 256

    public private(set) var edits: [Edit] = []
    public private(set) var isUnmappable = false

    public init() {}

    /// True when no edit happened since the base.
    public var isEmpty: Bool { edits.isEmpty && !isUnmappable }

    /// Sum of the length changes (live length − base length), when mappable.
    public var netDelta: Int? {
        isUnmappable ? nil : edits.reduce(0) { $0 + $1.newLength - $1.oldLength }
    }

    /// Records one edit, given as `NSTextStorage` reports it: `editedRange`
    /// in the post-edit text and `changeInLength`.
    public mutating func record(editedRange: NSRange, changeInLength delta: Int) {
        guard !isUnmappable else { return }
        guard edits.count < Self.capacity else {
            isUnmappable = true
            edits.removeAll()
            return
        }
        let oldLength = max(0, editedRange.length - delta)
        edits.append(Edit(location: editedRange.location, oldLength: oldLength, newLength: editedRange.length))
    }

    /// Forgets every edit (a new base version was published).
    public mutating func reset() {
        edits.removeAll()
        isUnmappable = false
    }

    /// The base-text offset of live offset `offset`. An offset inside text
    /// inserted since the base maps to the insertion point; nil when
    /// unmappable.
    public func mapToBase(_ offset: Int) -> Int? {
        guard !isUnmappable else { return nil }
        var p = offset
        for edit in edits.reversed() {
            if p >= edit.location + edit.newLength {
                p += edit.oldLength - edit.newLength
            } else if p > edit.location {
                p = edit.location
            }
        }
        return max(0, p)
    }

    /// The live offset of base offset `offset`. An offset inside text
    /// replaced since the base maps into the replacement, clamped to its end;
    /// nil when unmappable.
    public func mapFromBase(_ offset: Int) -> Int? {
        guard !isUnmappable else { return nil }
        var p = offset
        for edit in edits {
            if p >= edit.location + edit.oldLength {
                p += edit.newLength - edit.oldLength
            } else if p > edit.location {
                p = edit.location + min(p - edit.location, edit.newLength)
            }
        }
        return max(0, p)
    }
}
