import Foundation
import Testing
@testable import KaruCore

// R07 / D4 — the pure decision behind crash-draft recovery. The AppKit side
// (`AppDelegate.restoreDrafts()` carrying the decision out on real files) is
// covered in `CrashDraftTests`.

struct DraftRecoveryTests {

    private static let savedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let before = savedAt.addingTimeInterval(-600)
    private static let after = savedAt.addingTimeInterval(600)

    private static func digest(_ text: String) -> Data {
        DiskState.digest(of: Data(text.utf8))
    }

    /// A base whose stamp is deliberately unrelated to anything on "disk", so
    /// any test that passes proves stamps play no part in the decision.
    private static func base(_ text: String) -> DiskState {
        DiskState(stamp: .init(device: 1, inode: 42, size: 7,
                               modificationSeconds: 1, modificationNanoseconds: 0),
                  digest: digest(text))
    }

    private static func draft(_ content: String = "A\nmine\n",
                              path: String? = "/doc.txt",
                              base: DiskState? = nil,
                              isLegacy: Bool = false) -> DraftStore.Draft {
        DraftStore.Draft(id: UUID(), content: content, originalPath: path,
                         savedAt: savedAt, base: base, isLegacy: isLegacy)
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let draft: DraftStore.Draft
        let disk: DraftRecovery.Disk
        let expected: DraftRecovery.Decision
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // Untitled drafts and missing files: the draft is the only copy.
        Case(name: "untitled draft",
             draft: draft(path: nil), disk: .missing, expected: .recoverAsUntitled),
        Case(name: "untitled draft ignores any disk facts",
             draft: draft(path: nil), disk: .present(digest: digest("A\nmine\n"), modified: after),
             expected: .recoverAsUntitled),
        Case(name: "file gone, with base",
             draft: draft(base: base("A\n")), disk: .missing, expected: .recoverAsUntitled),
        Case(name: "file gone, no base",
             draft: draft(), disk: .missing, expected: .recoverAsUntitled),

        // Disk already holds exactly the draft's bytes.
        Case(name: "disk equals draft, with base",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\nmine\n"), modified: after), expected: .discard),
        Case(name: "disk equals draft, no base, disk newer",
             draft: draft(), disk: .present(digest: digest("A\nmine\n"), modified: after),
             expected: .discard),
        Case(name: "disk equals draft, unknown date",
             draft: draft(isLegacy: true), disk: .present(digest: digest("A\nmine\n"), modified: nil),
             expected: .discard),
        Case(name: "empty draft against an empty file",
             draft: draft("", base: base("x")), disk: .present(digest: digest(""), modified: nil),
             expected: .discard),

        // With a base: digests decide, dates never do.
        Case(name: "base matches disk, disk date older",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\n"), modified: before), expected: .applyToFile),
        Case(name: "base matches disk, disk touched after the draft",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\n"), modified: after), expected: .applyToFile),
        Case(name: "base matches disk, unknown date",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\n"), modified: nil), expected: .applyToFile),
        Case(name: "base differs from disk, disk date older",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\ntheirs\n"), modified: before), expected: .keepBothAsCopy),
        Case(name: "base differs from disk, disk newer",
             draft: draft(base: base("A\n")),
             disk: .present(digest: digest("A\ntheirs\n"), modified: after), expected: .keepBothAsCopy),

        // No base (legacy pair or a writer without one): the time rule, but a
        // newer or unknown date keeps both instead of deleting.
        Case(name: "legacy, disk not modified since",
             draft: draft(isLegacy: true),
             disk: .present(digest: digest("A\n"), modified: before), expected: .applyToFile),
        Case(name: "legacy, disk modified at savedAt exactly",
             draft: draft(isLegacy: true),
             disk: .present(digest: digest("A\n"), modified: savedAt), expected: .applyToFile),
        Case(name: "legacy, disk modified later",
             draft: draft(isLegacy: true),
             disk: .present(digest: digest("A\n"), modified: after), expected: .keepBothAsCopy),
        Case(name: "no base, disk modified later",
             draft: draft(), disk: .present(digest: digest("A\n"), modified: after),
             expected: .keepBothAsCopy),
        Case(name: "no base, unknown date",
             draft: draft(), disk: .present(digest: digest("A\n"), modified: nil),
             expected: .keepBothAsCopy),

        // Unreadable file: nothing can be proved, so keep both.
        Case(name: "unreadable, with base",
             draft: draft(base: base("A\n")), disk: .present(digest: nil, modified: before),
             expected: .keepBothAsCopy),
        Case(name: "unreadable, no base, disk older",
             draft: draft(), disk: .present(digest: nil, modified: before),
             expected: .keepBothAsCopy),
        Case(name: "unreadable, unknown date",
             draft: draft(isLegacy: true), disk: .present(digest: nil, modified: nil),
             expected: .keepBothAsCopy),
    ]

    @Test(arguments: cases)
    func decides(_ testCase: Case) {
        #expect(DraftRecovery.decide(draft: testCase.draft, disk: testCase.disk)
                == testCase.expected)
    }

    /// The safety invariant, checked over every combination: the only decision
    /// that lets go of the draft (`discard`) requires the disk to hold its
    /// exact bytes.
    @Test func onlyIdenticalBytesEverDiscardTheDraft() {
        let digests: [Data?] = [nil, Self.digest("A\n"), Self.digest("A\ntheirs\n"),
                                Self.digest("A\nmine\n")]
        let dates: [Date?] = [nil, Self.before, Self.savedAt, Self.after]
        let bases: [DiskState?] = [nil, Self.base("A\n"), Self.base("A\ntheirs\n")]
        let mine = Self.digest("A\nmine\n")
        for digest in digests {
            for date in dates {
                for base in bases {
                    let decision = DraftRecovery.decide(
                        draft: Self.draft(base: base),
                        disk: .present(digest: digest, modified: date))
                    if decision == .discard { #expect(digest == mine) }
                    if digest == mine { #expect(decision == .discard) }
                }
            }
        }
    }
}
