import Foundation

/// Type inference for completion (M17 T17.11b, plan §5.4 / §8): the members
/// of a member access's receiver, as `inferredType` candidates with
/// signature summaries. One per completion controller (window), created on
/// the first member request and released with the completion or
/// type-inference module.
///
/// - **Languages.** `SyntaxDialect.python` evaluates with `PythonEvaluator`;
///   T17.11c adds a JS / TS evaluator behind the same entry
///   (`memberCandidates`), sharing the type model (`InferredType`), member
///   lists (`InferredMember`), candidates (`InferredMemberList`) and caches.
/// - **Work per request (plan §8.3).** The current syntax snapshot
///   (`DocumentAnalysis.ensureSyntax()`: an incremental update after a
///   keystroke) is read; only the receiver and what it depends on are
///   evaluated. A document over `SyntaxBuild.fullTreeUnitLimit` uses its
///   module summary and parses statements on demand; with no published
///   summary yet (or an unmappable journal) the request gets no inferred
///   members instead of blocking on a full build.
/// - **Caches.** A session (module-name memo, document class / function
///   models, MROs) lives per snapshot version. Inferred return types of
///   document functions persist across versions in a byte-capped LRU keyed
///   by the function's text and validated against the module-level names it
///   read. Converted stub types and table member lists are process-wide
///   (`PythonTypeTables`, byte-capped). While the caret types the name after
///   the same `.`, the receiver's members are reused (edits after the dot do
///   not change the receiver).
/// - **Budget.** Each request has a step and time budget
///   (`InferenceBudget`, 25 ms including the syntax update); exceeding it
///   yields nil (the usage-evidence path), never a partial list, and the
///   same dot is not retried while the caret types after it.
/// - **Precision (plan §13).** Unknown receivers give nil; unions list only
///   members every non-`None` constituent has.
@MainActor
final class TypeInferenceService {
    static let returnCacheBytes = 512 * 1024

    struct Statistics: Equatable {
        var requests = 0
        var inferred = 0
        var reused = 0
        var aborted = 0
        var skippedLarge = 0
        var sessions = 0
        var returnCacheHits = 0
        var returnInferences = 0
        var lastNanoseconds: UInt64 = 0
        /// Of `lastNanoseconds`: bringing the syntax snapshot up to date.
        var lastSyntaxNanoseconds: UInt64 = 0
        var nameIndexBuilds = 0
    }

    let tables: PythonTypeTables
    private let returnCache = ByteLRU<String, CachedReturn>(byteLimit: TypeInferenceService.returnCacheBytes,
                                                            countLimit: 2_048)
    private var session: (version: UInt64, module: PyModuleView)?
    /// The last answer: its dot, the line's text up to and including the
    /// dot, and the candidates (reused while the caret types after it).
    private var last: (dot: Int, lineStart: Int, linePrefix: String, candidates: [Candidate]?)?
    /// Module-level names → binding statements, kept across versions.
    private let names = PyNameIndex()
    private(set) var statistics = Statistics()
    /// Test hook: budget for the next requests.
    var budgetMilliseconds = InferenceBudget.defaultMilliseconds
    var budgetSteps = InferenceBudget.defaultSteps

    init(tables: PythonTypeTables) {
        self.tables = tables
    }

    var isReleased: Bool { session == nil && last == nil && returnCache.isEmpty && names.isEmpty }

    /// Bytes this window's inference holds (the shared tables are separate).
    var retainedBytes: Int { returnCache.bytes + names.retainedBytes }

    func release() {
        session = nil
        last = nil
        returnCache.removeAll()
        names.removeAll()
    }

    /// A character edit (`editedRange` in the new text, as the text storage
    /// reports it — possibly widened to whole lines).
    func noteEdit(editedRange: NSRange, changeInLength delta: Int) {
        // An edit before the dot's line changes the receiver; one on that
        // line is checked against the line's text at the next request.
        if let l = last, editedRange.location < l.lineStart { last = nil }
        names.record(editedRange: editedRange, changeInLength: delta)
    }

    private static func lineStart(of offset: Int, in text: NSString) -> Int {
        var k = offset
        while k > 0 {
            let u = text.character(at: k - 1)
            if u == 10 || u == 13 { break }
            k -= 1
        }
        return k
    }

    /// The inferred members of the receiver of the `.` at `dot` (the caret
    /// is after it, in the identifier being typed); nil when the receiver's
    /// type is unknown (or the budget ran out).
    func memberCandidates(analysis: DocumentAnalysis, text: NSString, dot: Int) -> [Candidate]? {
        statistics.requests += 1
        guard dot >= 0, dot < text.length,
              SyntaxDialect(languageIdentifier: analysis.languageIdentifier) == .python else { return nil }
        let lineStart = Self.lineStart(of: dot, in: text)
        let linePrefix = text.substring(with: NSRange(location: lineStart, length: dot + 1 - lineStart))
        if let l = last, l.dot == dot, l.lineStart == lineStart, l.linePrefix == linePrefix {
            statistics.reused += 1
            return l.candidates
        }
        let start = DispatchTime.now().uptimeNanoseconds
        defer { statistics.lastNanoseconds = DispatchTime.now().uptimeNanoseconds &- start }
        let budgetNanoseconds = UInt64(budgetMilliseconds * 1_000_000)
        // A large document without a mappable published summary would need a
        // full synchronous build: answer unknown instead (plan §8.3).
        if SyntaxBuild.mode(forLength: text.length) == .summary, analysis.syntax == nil {
            guard let published = analysis.publishedSyntax, published.snapshot.summary != nil,
                  !published.journal.isUnmappable else {
                statistics.skippedLarge += 1
                return nil
            }
        }
        let syntaxStart = DispatchTime.now().uptimeNanoseconds
        let ensured = analysis.ensureSyntax()
        statistics.lastSyntaxNanoseconds = DispatchTime.now().uptimeNanoseconds &- syntaxStart
        guard let snapshot = ensured, snapshot.dialect == .python else { return nil }
        let module: PyModuleView
        if let s = session, s.version == snapshot.version {
            module = s.module
        } else {
            let storage: PyModuleView.Storage
            switch snapshot.content {
            case .tree(let tree): storage = .tree(PyUnit(tree))
            case .summary(let summary): storage = .summary(summary)
            }
            module = PyModuleView(storage: storage, text: text, parseStatement: { [weak analysis] offset in
                analysis?.syntaxStatement(at: offset).map(\.tree)
            })
            if !names.isUsable(forLength: text.length) {
                names.rebuild(from: module)
                statistics.nameIndexBuilds += 1
            }
            module.nameIndex = names
            session = (snapshot.version, module)
            statistics.sessions += 1
        }
        guard let statement = module.topLevelStatement(containing: dot),
              let member = Self.memberNode(in: statement, dot: dot) else {
            last = (dot, lineStart, linePrefix, nil)
            return nil
        }
        // The budget covers the whole request: what the syntax update and the
        // preparation used is not available to the evaluation.
        let spent = DispatchTime.now().uptimeNanoseconds &- start
        guard spent < budgetNanoseconds else {
            statistics.aborted += 1
            last = (dot, lineStart, linePrefix, nil)
            return nil
        }
        let remaining = Double(budgetNanoseconds - spent) / 1_000_000
        let evaluator = PythonEvaluator(text: text, module: module, tables: tables, returnCache: returnCache,
                                        budget: InferenceBudget(maxSteps: budgetSteps, milliseconds: remaining))
        defer { evaluator.tearDown() }
        let receiver = evaluator.receiverType(of: member)
        var members = evaluator.isAborted ? nil : evaluator.members(of: receiver)
        statistics.returnCacheHits += evaluator.returnCacheHits
        statistics.returnInferences += evaluator.returnInferences
        if evaluator.isAborted {
            statistics.aborted += 1
            members = nil
        }
        let candidates = members.flatMap { $0.isEmpty ? nil : InferredMemberList.candidates($0) }
        if candidates != nil { statistics.inferred += 1 }
        // An aborted request is not retried while the caret stays after this
        // dot (it would block every key again): unknown until it moves.
        last = (dot, lineStart, linePrefix, candidates)
        return candidates
    }

    /// The `.member` node whose dot is at `dot`, inside `statement`.
    static func memberNode(in statement: PyNode, dot: Int) -> PyNode? {
        let tree = statement.unit.tree
        var found: PyNode?
        var stack = [statement.i]
        while let i = stack.popLast(), found == nil {
            let n = tree.nodes[i]
            guard Int(n.start) <= dot, dot <= Int(n.end) else { continue }
            if n.kind == .member, let object = tree.firstChild(i),
               Int(tree.nodes[object].end) + Int(n.aux) == dot {
                found = PyNode(unit: statement.unit, i: i)
                break
            }
            tree.forEachChildReversed(i) { stack.append($0) }
        }
        return found
    }
}
