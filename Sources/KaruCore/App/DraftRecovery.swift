import Foundation

/// What to do with one crash draft at launch (R07, user decision D4).
///
/// Pure: no AppKit and no file access. `AppDelegate.restoreDrafts()` gathers the
/// facts about the draft's file (does it exist, the digest of its bytes, its
/// modification date), asks `decide`, and only executes the answer.
///
/// The invariant every rule keeps: a draft's text is only ever dropped when the
/// file on disk provably holds exactly the same bytes. A conflict never loses
/// either side — the disk version opens as usual and the draft comes back next
/// to it as an untitled copy.
enum DraftRecovery {

    /// Facts about the draft's file, gathered by the caller.
    enum Disk: Equatable {
        /// Nothing exists at the draft's path any more.
        case missing
        /// The file exists. `digest` is the SHA-256 of its raw bytes, or `nil`
        /// when it could not be read; `modified` is its modification date, or
        /// `nil` when unknown.
        case present(digest: Data?, modified: Date?)
    }

    enum Decision: Equatable {
        /// Untitled draft, or its file is gone: the draft is the only copy, so
        /// it comes back in a new untitled window.
        case recoverAsUntitled
        /// The disk still holds what the draft was based on: pour the draft
        /// into the file's window.
        case applyToFile
        /// The disk already holds exactly the draft's text: nothing to recover.
        case discard
        /// Conflict (or not provably safe to apply): open the disk version
        /// untouched AND the draft as an untitled recovered copy.
        case keepBothAsCopy
    }

    static func decide(draft: DraftStore.Draft, disk: Disk) -> Decision {
        guard draft.originalPath != nil else { return .recoverAsUntitled }

        switch disk {
        case .missing:
            return .recoverAsUntitled

        case .present(let digest, let modified):
            // Unreadable file: nothing proves the draft still fits it.
            guard let digest else { return .keepBothAsCopy }

            // The disk already holds these exact bytes — the only case in which
            // the draft may go.
            if digest == DiskState.digest(of: Data(draft.content.utf8)) {
                return .discard
            }

            // Digests only, never stamps: a `touch`, a byte-identical rewrite
            // or a new inode with the same bytes is not a conflict.
            if let base = draft.base {
                return digest == base.digest ? .applyToFile : .keepBothAsCopy
            }

            // No base (legacy pair, or a writer that did not record one): fall
            // back to time, but a newer — or unknown — date keeps both sides
            // instead of dropping the draft.
            guard let modified else { return .keepBothAsCopy }
            return modified > draft.savedAt ? .keepBothAsCopy : .applyToFile
        }
    }
}
