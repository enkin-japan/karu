import AppKit
import Foundation
import Testing
@testable import KaruCore

// M17 T17.1 — sparse lexical checkpoints: lookup, spacing and edit
// invalidation (including CR/LF merging and splitting at the edit boundary).

private func state(_ quotes: Int) -> LexicalState {
    var s = PythonTokenizer.State()
    for _ in 0..<quotes { s.frames.append(PythonTokenizer.Frame(quote: 34, width: 3)) }
    return .python(s)
}

private func offsets(_ store: CheckpointStore) -> [Int] { store.entries.map(\.offset) }

@Suite("CheckpointStore")
struct CheckpointStoreTests {
    let spacing = CheckpointStore.spacing

    @Test func nearestFindsGreatestOffsetAtOrBefore() {
        var store = CheckpointStore()
        #expect(store.nearest(atOrBefore: 10) == nil)
        store.record(offset: 0, state: state(0))
        store.record(offset: spacing, state: state(1))
        store.record(offset: 2 * spacing, state: state(2))
        #expect(store.nearest(atOrBefore: -1) == nil)
        #expect(store.nearest(atOrBefore: 0)?.offset == 0)
        #expect(store.nearest(atOrBefore: spacing - 1)?.offset == 0)
        #expect(store.nearest(atOrBefore: spacing)?.offset == spacing)
        #expect(store.nearest(atOrBefore: spacing + 5)?.state == state(1))
        #expect(store.nearest(atOrBefore: Int.max)?.offset == 2 * spacing)
    }

    @Test func recordKeepsAscendingOrderAndSpacing() {
        var store = CheckpointStore()
        store.record(offset: 2 * spacing, state: state(2))
        store.record(offset: spacing, state: state(1))        // before an existing entry
        store.record(offset: 4 * spacing, state: state(4))
        #expect(offsets(store) == [spacing, 2 * spacing, 4 * spacing])
        // Within spacing/2 of a neighbour (either side): ignored.
        store.record(offset: spacing + spacing / 2 - 1, state: state(9))
        store.record(offset: 4 * spacing - spacing / 2 + 1, state: state(9))
        store.record(offset: 2 * spacing, state: state(9))    // duplicate offset
        #expect(offsets(store) == [spacing, 2 * spacing, 4 * spacing])
        #expect(store.nearest(atOrBefore: 2 * spacing)?.state == state(2))
        // Exactly spacing/2 away from both neighbours: kept.
        store.record(offset: 3 * spacing, state: state(3))
        #expect(offsets(store) == [spacing, 2 * spacing, 3 * spacing, 4 * spacing])
        store.record(offset: -5, state: state(0))
        #expect(offsets(store).first == spacing)
        store.removeAll()
        #expect(store.entries.isEmpty)
    }

    /// Lines of `width` units (LF included) starting at multiples of `width`.
    private func lines(_ count: Int, width: Int = 10) -> String {
        String(repeating: String(repeating: "a", count: width - 1) + "\n", count: count)
    }

    @Test func invalidateDropsFromTheEditedLineOn() {
        var store = CheckpointStore()
        // Sparse entries need spacing; use a doc with many short lines and pick
        // line starts that are far apart.
        let text = lines(30_000) as NSString            // 300 000 units
        let starts = [0, 70_000, 140_000, 210_000]       // all multiples of 10 → line starts
        for (i, offset) in starts.enumerated() { store.record(offset: offset, state: state(i)) }
        #expect(offsets(store) == starts)

        // Edit inside the line that starts at 140 000: that entry and later go.
        var edited = store
        edited.invalidate(editedRange: NSRange(location: 140_004, length: 1), changeInLength: 1, in: text)
        #expect(offsets(edited) == [0, 70_000])

        // Edit at a line start: the `- 1` reaches back to the previous line,
        // so the entry at that line start is dropped too.
        edited = store
        edited.invalidate(editedRange: NSRange(location: 140_000, length: 0), changeInLength: -3, in: text)
        #expect(offsets(edited) == [0, 70_000])

        // Edit in the line just before an entry: the entry after it is dropped.
        edited = store
        edited.invalidate(editedRange: NSRange(location: 139_995, length: 2), changeInLength: 2, in: text)
        #expect(offsets(edited) == [0, 70_000])

        // Edit in the line just after an entry's line keeps that entry.
        edited = store
        edited.invalidate(editedRange: NSRange(location: 140_015, length: 0), changeInLength: -1, in: text)
        #expect(offsets(edited) == [0, 70_000, 140_000])
    }

    @Test func invalidateAtDocumentStartDropsEverything() {
        var store = CheckpointStore()
        let text = lines(30_000) as NSString
        store.record(offset: 0, state: state(0))
        store.record(offset: 100_000, state: state(1))
        store.invalidate(editedRange: NSRange(location: 0, length: 1), changeInLength: 1, in: text)
        #expect(store.entries.isEmpty)
    }

    @Test func invalidateAtDocumentEndKeepsEarlierEntries() {
        var store = CheckpointStore()
        let text = lines(30_000) as NSString             // ends with "\n"
        store.record(offset: 100_000, state: state(1))
        store.record(offset: 299_990, state: state(2))   // start of the last line
        // Append at the very end (location == length after the edit).
        let appended = (text as String + "x") as NSString
        var edited = store
        edited.invalidate(editedRange: NSRange(location: text.length, length: 1), changeInLength: 1, in: appended)
        #expect(offsets(edited) == [100_000])
        // Delete the tail: the edit location equals the new length.
        let shortened = text.substring(to: 250_005) as NSString
        edited = store
        edited.invalidate(editedRange: NSRange(location: 250_005, length: 0),
                          changeInLength: -(text.length - 250_005), in: shortened)
        #expect(offsets(edited) == [100_000])
        // Everything deleted.
        edited = store
        edited.invalidate(editedRange: NSRange(location: 0, length: 0), changeInLength: -text.length, in: "")
        #expect(edited.entries.isEmpty)
    }

    @Test func invalidateHandlesCRLFMergeAndSplitAtTheBoundary() {
        // Lines of 100 000 units (99 998 "a"s + CRLF) keep entries far apart:
        // line starts at 0, 100 000, 200 000.
        let body = String(repeating: "a", count: 99_998)
        let head = body + "\r\n" + body + "\r\n"

        // Merge: a lone CR at 299 998, entry at 299 999 (start of "bbb").
        // Inserting "\n" there turns the CR into a CRLF, so 299 999 is no
        // longer a line start; the line holding the CR starts at 200 000.
        let crOnly = head + body + "\r" + "bbb\n"
        var store = CheckpointStore()
        store.record(offset: 100_000, state: state(1))
        store.record(offset: 299_999, state: state(2))
        #expect(offsets(store) == [100_000, 299_999])
        let merged = NSMutableString(string: crOnly)
        merged.insert("\n", at: 299_999)
        var edited = store
        edited.invalidate(editedRange: NSRange(location: 299_999, length: 1), changeInLength: 1, in: merged)
        #expect(offsets(edited) == [100_000])

        // Split: "x" inserted between the CR (299 998) and LF (299 999) of a
        // CRLF; the entry after the pair (300 000) goes, the earlier one stays.
        let crlf = head + body + "\r\n" + "ccc\n"
        store = CheckpointStore()
        store.record(offset: 100_000, state: state(1))
        store.record(offset: 300_000, state: state(2))
        let split = NSMutableString(string: crlf)
        split.insert("x", at: 299_999)
        edited = store
        edited.invalidate(editedRange: NSRange(location: 299_999, length: 1), changeInLength: 1, in: split)
        #expect(offsets(edited) == [100_000])

        // Deleting the LF of a CRLF right before an entry's line (location
        // 199 999): the entry at 200 000 is dropped. The one at 100 000 is the
        // start of the edited line, but that line is longer than twice
        // `editMargin`, so the cut is `editMargin` before the edit and the
        // entry stays (T17.15d-A; a short line still loses its start, see
        // `invalidateDropsFromTheEditedLineOn`).
        store = CheckpointStore()
        store.record(offset: 0, state: state(0))
        store.record(offset: 100_000, state: state(1))
        store.record(offset: 200_000, state: state(2))
        let joined = NSMutableString(string: crlf)
        joined.deleteCharacters(in: NSRange(location: 199_999, length: 1))
        edited = store
        edited.invalidate(editedRange: NSRange(location: 199_999, length: 0), changeInLength: -1, in: joined)
        #expect(offsets(edited) == [0, 100_000])
    }

    // MARK: - T17.15d-A: long lines, pending entries, walking

    @Test func longLineKeepsInLineEntriesWellBeforeTheEdit() {
        // One 400 000-unit line: entries are in-line safe points.
        let text = String(repeating: "a", count: 400_000) as NSString
        var store = CheckpointStore()
        for k in 1...5 { store.record(offset: k * spacing, state: state(k)) }
        let editAt = 3 * spacing + 100
        store.invalidate(editedRange: NSRange(location: editAt, length: 1), changeInLength: 1, in: text)
        // Before `editAt - 1 - editMargin`: kept; the rest goes or is pending.
        #expect(offsets(store) == [spacing, 2 * spacing])
        #expect(store.entries.allSatisfy { $0.offset < editAt - 1 - CheckpointStore.editMargin })
        // After the edit (shifted by +1, beyond the margin): pending.
        #expect(store.pending.map(\.offset) == [4 * spacing + 1, 5 * spacing + 1])
    }

    @Test func pendingEntriesOnlyBeyondTheMargin() {
        let text = lines(40_000) as NSString            // 400 000 units, 10-unit lines
        var store = CheckpointStore()
        for offset in [0, 70_000, 140_000, 210_000, 280_000] { store.record(offset: offset, state: state(1)) }
        // Insert 5 units at 140 004 (inside the line starting at 140 000).
        store.invalidate(editedRange: NSRange(location: 140_004, length: 5), changeInLength: 5, in: text)
        #expect(offsets(store) == [0, 70_000])
        // 140 000 is the edited line's start: dropped; 210 000 / 280 000 shift.
        #expect(store.pending.map(\.offset) == [210_005, 280_005])
        // An edit right before a pending entry drops it (within the margin).
        store.invalidate(editedRange: NSRange(location: 200_000, length: 0), changeInLength: -10, in: text)
        #expect(store.pending.map(\.offset) == [279_995])
        #expect(!store.isEmpty)
        store.removeAll()
        #expect(store.isEmpty && store.pending.isEmpty)
    }

    /// Lines alternating "x\n" text with a Python triple-quoted string that a
    /// one-unit edit can open or keep closed.
    private func walkPython(_ store: inout CheckpointStore, to target: Int, in text: NSString,
                            deadline: UInt64? = nil) -> (offset: Int, finished: Bool, units: Int) {
        let language = PythonLanguage.make()
        var units = 0
        let walked = store.walk(toward: target, in: text, stepEnd: target, initial: PythonTokenizer.State(),
                                unwrap: { if case .python(let s) = $0 { return s } else { return nil } },
                                wrap: { .python($0) },
                                advance: { from, to, state in
                                    units += to - from
                                    state = PythonTokenizer.state(in: text, before: to, language: language,
                                                                  from: from, initial: state)
                                },
                                advanceToSafePoint: nil, deadline: deadline)
        return (walked.offset, walked.finished, units)
    }

    @Test func walkReconfirmsPendingEntriesAfterAnEditThatKeepsTheState() {
        let line = "value = compute(item, 42)  # note\n"
        let original = String(repeating: line, count: 30_000)          // ~1 MB
        let text = NSMutableString(string: original)
        var store = CheckpointStore()
        _ = walkPython(&store, to: text.length, in: text)
        let built = store.entries
        #expect(built.count >= 10)
        // A same-state edit near the top: one more character in a line.
        text.insert("x", at: 5)
        store.invalidate(editedRange: NSRange(location: 5, length: 1), changeInLength: 1, in: text)
        #expect(store.entries.isEmpty && !store.pending.isEmpty)
        // The walk re-synchronises at the first pending entry: it scans one
        // chunk, not the document, and every entry is verified again.
        let walk = walkPython(&store, to: text.length, in: text)
        #expect(walk.finished)
        #expect(walk.units <= 2 * spacing, "walked \(walk.units) units")
        #expect(store.pending.isEmpty)
        #expect(store.entries.count >= built.count - 1)
        // Same states as a fresh walk over the edited text.
        var fresh = CheckpointStore()
        _ = walkPython(&fresh, to: text.length, in: text)
        for entry in store.entries {
            var probe = PythonTokenizer.State()
            if let nearest = fresh.nearest(atOrBefore: entry.offset), case .python(let s) = nearest.state {
                probe = PythonTokenizer.state(in: text, before: entry.offset, language: PythonLanguage.make(),
                                              from: nearest.offset, initial: s)
            }
            #expect(entry.state == .python(probe), "entry \(entry.offset)")
        }
    }

    @Test func walkRescansWhenTheEditChangesTheStateDownstream() {
        let line = "value = compute(item, 42)  # note\n"
        let text = NSMutableString(string: String(repeating: line, count: 30_000))
        var store = CheckpointStore()
        _ = walkPython(&store, to: text.length, in: text)
        // An unclosed triple quote at the top: every later state differs, so
        // no pending entry may be confirmed.
        text.insert("\"\"\"\n", at: 0)
        store.invalidate(editedRange: NSRange(location: 0, length: 4), changeInLength: 4, in: text)
        let walk = walkPython(&store, to: text.length, in: text)
        #expect(walk.finished)
        #expect(walk.units > text.length - 2 * spacing)
        #expect(store.pending.isEmpty)
        let inString = PythonTokenizer.state(in: text, before: store.entries.last!.offset, language: PythonLanguage.make())
        #expect(store.entries.last!.state == .python(inString))
        #expect(!inString.frames.isEmpty)
    }

    @Test func walkWithADeadlineStopsAndResumes() {
        let text = String(repeating: "value = 1\n", count: 100_000) as NSString   // 1 000 000 units
        var store = CheckpointStore()
        // An expired deadline: one chunk per call.
        var calls = 0
        var finished = false
        while !finished, calls < 1_000 {
            finished = walkPython(&store, to: text.length, in: text, deadline: 0).finished
            calls += 1
        }
        #expect(finished)
        #expect(calls > 5, "a sliced walk takes several calls (\(calls))")
        var whole = CheckpointStore()
        _ = walkPython(&whole, to: text.length, in: text)
        #expect(offsets(store) == offsets(whole))
    }
}
