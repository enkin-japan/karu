import Foundation
import Testing
@testable import KaruCore

// M17 T17.11a — the production parsers: grammar coverage of the gaps closed
// after the T17.9 prototype, the query API, incremental updates (random
// edits: the incremental tree equals a full re-parse node for node), a
// mutation fuzz, sliced builds, the module summary with on-demand statement
// parses, and the progress guards (step cap, nesting guard).
//
// The long randomized runs are opt-in: `KARU_PARSER_FUZZ=1 swift test
// --filter SyntaxParserTests` multiplies the edit counts and adds the corpus
// files.

private let fixturesRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/M17")
private let longRuns = ProcessInfo.processInfo.environment["KARU_PARSER_FUZZ"] == "1"

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func parse(_ source: String, _ dialect: SyntaxDialect) -> (SyntaxTree, NSString) {
    let text = source as NSString
    return (SyntaxBuild.parse(text, dialect: dialect), text)
}

private func nodes(_ tree: SyntaxTree, _ kind: SyntaxKind) -> [Int] {
    tree.nodes.indices.filter { tree.kind($0) == kind }
}

private func isClean(_ tree: SyntaxTree) -> Bool {
    let counts = tree.errorCounts
    return counts.errors == 0 && counts.recovered == 0
}

private func source(_ tree: SyntaxTree, _ text: NSString, _ i: Int) -> String { text.substring(with: tree.range(i)) }

/// Structural invariants of a post-order tree: sizes nest, children lie in
/// their parent's range in non-decreasing start order, the root spans the
/// text.
private func checkWellFormed(_ tree: SyntaxTree, length: Int) -> Bool { wellFormedProblem(tree, length: length) == nil }

private func wellFormedProblem(_ tree: SyntaxTree, length: Int) -> String? {
    guard !tree.nodes.isEmpty, tree[tree.root].kind == .module, Int(tree[tree.root].size) == tree.root,
          tree.textLength == length else { return "root" }
    for (i, n) in tree.nodes.enumerated() {
        guard n.start >= 0, n.start <= n.end, Int(n.end) <= length, Int(n.size) <= i else { return "node \(i) \(n)" }
        var prevStart: Int32 = -1
        var children: [Int] = []
        tree.forEachChildReversed(i) { children.append($0) }
        for c in children.reversed() {
            let cn = tree[c]
            if cn.start < n.start || cn.end > n.end || cn.start < prevStart {
                return "parent \(n.kind) \(n.start)-\(n.end) child \(cn.kind) \(cn.start)-\(cn.end) prevStart \(prevStart)"
            }
            prevStart = cn.start
        }
    }
    return nil
}

/// The committed valid samples plus the tolerance samples (caret stripped).
private func editSamples() throws -> [(name: String, text: String, dialect: SyntaxDialect)] {
    var out: [(String, String, SyntaxDialect)] = []
    for (url, dialect) in SyntaxCorpusTests.committedSamples() {
        out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8), dialect))
    }
    for (directory, dialect) in SyntaxParserToleranceTests.languages {
        let dir = fixturesRoot.appendingPathComponent("parser/\(directory)")
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where !file.hasSuffix(".json") {
            let (text, _) = try toleranceSample(dir.appendingPathComponent(file))
            out.append(("\(directory)/\(file)", text as String, dialect))
        }
    }
    if longRuns {
        // Real files from the corpora (when present): every 25th file under 120 KB.
        for corpus in SyntaxCorpusTests.corpora() {
            for (k, path) in SyntaxCorpusTests.files(corpus).enumerated() where k % 25 == 0 {
                let url = corpus.root.appendingPathComponent(path)
                guard let text = try? String(contentsOf: url, encoding: .utf8), text.utf16.count < 120_000 else { continue }
                out.append((path, text, corpus.dialect))
            }
        }
    }
    return out
}

/// A random edit of the kinds a user makes: single characters typed or
/// deleted, pastes, joined lines, and unterminated strings / brackets.
private func randomEdit(_ text: NSString, _ rng: inout SeededGenerator) -> (range: NSRange, insert: String) {
    let length = text.length
    let at = Int.random(in: 0...length, using: &rng)
    switch Int.random(in: 0..<10, using: &rng) {
    case 0, 1, 2:
        let pieces = ["x", ".", "(", ")", "{", "}", "[", "]", "\n", ":", "'", "\"", "`", "/", "<", ">", "=",
                      ",", ";", "#", " ", "\t", "\\", "@", "*", "$", "a", "_", "0", "é", "😀"]
        return (NSRange(location: at, length: 0), pieces.randomElement(using: &rng)!)
    case 3, 4:
        let n = min(length - at, Int.random(in: 1...3, using: &rng))
        return (NSRange(location: at, length: max(0, n)), "")
    case 5:
        // Paste a slice of the document elsewhere.
        guard length > 0 else { return (NSRange(location: 0, length: 0), "x") }
        let from = Int.random(in: 0..<length, using: &rng)
        let n = min(length - from, Int.random(in: 1...200, using: &rng))
        let slice = text.substring(with: (text as NSString).rangeOfComposedCharacterSequences(
            for: NSRange(location: from, length: n)))
        return (NSRange(location: at, length: 0), slice)
    case 6:
        // Join a line with the next.
        let lineBreak = text.range(of: "\n", options: [], range: NSRange(location: at, length: length - at))
        if lineBreak.location != NSNotFound { return (lineBreak, "") }
        return (NSRange(location: at, length: 0), "\n")
    case 7:
        let openers = ["\"", "'", "\"\"\"", "`", "(", "[", "{", "/*", "f\"{", "${", "<div>", "def f(", "class "]
        return (NSRange(location: at, length: 0), openers.randomElement(using: &rng)!)
    default:
        // Replace a short run.
        let n = min(length - at, Int.random(in: 0...8, using: &rng))
        let words = ["foo", "self.", "await ", "return ", "if ", "=> ", "async ", "match x:\n    case 1:\n", "x: int"]
        return (NSRange(location: at, length: max(0, n)), words.randomElement(using: &rng)!)
    }
}

/// Snaps an edit range off surrogate pairs (NSTextStorage never splits them).
private func snapped(_ text: NSString, _ range: NSRange) -> NSRange {
    guard text.length > 0 else { return range }
    var r = range
    if r.location > 0, r.location < text.length, UTF16.isTrailSurrogate(text.character(at: r.location)) {
        r.location -= 1
        if r.length > 0 { r.length += 1 }
    }
    let end = NSMaxRange(r)
    if end > 0, end < text.length, UTF16.isTrailSurrogate(text.character(at: end)) { r.length += 1 }
    return r
}

@Suite("Syntax parser")
struct SyntaxParserTests {

    // MARK: - Grammar: Python

    @Test func pythonMatchStatementsGetPatternNodes() {
        let (tree, text) = parse("""
        match command:
            case Point(x=0, y=0) | Point(1, 2) as p:
                pass
            case [first, *rest]:
                pass
            case {"k": (a, b), **others}:
                pass
            case asyncio.Queue() | -1 | 2 + 3j | "s" | None:
                pass
            case 1, *tail:
                pass
            case _:
                pass

        """, .python)
        #expect(isClean(tree))
        #expect(nodes(tree, .caseClause).count == 6)
        let classes = nodes(tree, .patternClass)
        #expect(classes.map { source(tree, text, $0) } == ["Point(x=0, y=0)", "Point(1, 2)", "asyncio.Queue()"])
        #expect(nodes(tree, .patternKeyword).map { source(tree, text, $0) } == ["x=0", "y=0"])
        #expect(nodes(tree, .patternAs).count == 1)
        #expect(nodes(tree, .patternOr).count == 2)
        let sequences = nodes(tree, .patternSequence)
        #expect(sequences.map { tree[$0].aux } == [1, 2, 0])   // [..], (a, b), bare `1, *tail`
        #expect(nodes(tree, .patternMapping).count == 1)
        #expect(nodes(tree, .patternPair).count == 1)
        #expect(nodes(tree, .patternStar).map { tree[$0].aux } == [1, 2, 1])
        let captures = nodes(tree, .patternCapture)
        #expect(captures.map { source(tree, text, $0) } == ["first", "a", "b", "_"])
        #expect(captures.filter { tree[$0].aux == 1 }.map { source(tree, text, $0) } == ["_"])
        #expect(nodes(tree, .patternValue).map { source(tree, text, $0) }
                == ["0", "0", "1", "2", "-1", "2 + 3j", "\"s\"", "None", "1"])
    }

    @Test func pythonWalrusAndFStringInternals() {
        let (tree, text) = parse("""
        if (n := len(items)) > 1:
            print(f"{value:>{width}.{precision}f} {n=} {x!r}", f"{v:#x}", f'{w:#o}')

        """, .python)
        #expect(isClean(tree))
        #expect(nodes(tree, .walrus).count == 1)
        let specs = nodes(tree, .formatSpec)
        #expect(specs.count == 1 || specs.count >= 1)
        // The nested fields of the format spec are expressions.
        let specNames = specs.flatMap { spec in tree.subtree(spec).filter { tree.kind($0) == .name } }
            .map { source(tree, text, $0) }
        #expect(specNames.contains("width") && specNames.contains("precision"))
        // `#` in a format spec is no comment: the call keeps its three arguments.
        let call = nodes(tree, .call).first { source(tree, text, $0).hasPrefix("print") }!
        let args = tree.firstChild(call, kind: .args)!
        #expect(tree.childCount(args) == 3)
    }

    @Test func pythonAsyncGeneratorsDecoratorsAndTypeParameters() {
        let (tree, text) = parse("""
        @decorator(arg)
        @other.attr
        async def fetch[T: int](url: str, /, *args: *Ts, key: T = 1, **kw) -> T:
            async with a as b:
                async for x in b:
                    yield x
            return [y async for y in z if await y]

        type Pair[K, V = int] = tuple[K, V]

        """, .python)
        #expect(isClean(tree))
        let def = nodes(tree, .funcDef).first!
        #expect(tree[def].has(SyntaxFlags.async))
        #expect(tree.children(def).filter { tree.kind($0) == .decorator }.count == 2)
        #expect(tree.firstChild(def, kind: .typeParams) != nil)
        let params = tree.children(tree.firstChild(def, kind: .params)!).map { tree[$0].aux }
        #expect(params == [0, 4, 1, 0, 2])
        #expect(nodes(tree, .withStmt).allSatisfy { tree[$0].has(SyntaxFlags.async) })
        #expect(nodes(tree, .compFor).allSatisfy { tree[$0].has(SyntaxFlags.async) })
        #expect(nodes(tree, .typeAliasStmt).count == 1)
        #expect(source(tree, text, nodes(tree, .typeParams).last!) == "[K, V = int]")
    }

    // MARK: - Grammar: TypeScript / JavaScript

    @Test func destructuringAssignmentBecomesPatterns() {
        let (tree, text) = parse("""
        [a, , b = 2, ...rest] = list;
        ({ a, b = 3, c: { d }, e: [f] = [], ...others } = source());
        for ([k, v] of pairs) {}
        x = y;

        """, .typescript)
        #expect(isClean(tree))
        // Only the default value stays a literal.
        #expect(nodes(tree, .array).map { source(tree, text, $0) } == ["[]"] && nodes(tree, .object).isEmpty)
        #expect(nodes(tree, .arrayPattern).map { source(tree, text, $0) } == ["[a, , b = 2, ...rest]", "[f]", "[k, v]"])
        #expect(nodes(tree, .objectPattern).map { source(tree, text, $0) }
                == ["{ d }", "{ a, b = 3, c: { d }, e: [f] = [], ...others }"])
        #expect(nodes(tree, .restElement).count == 2)
        #expect(nodes(tree, .assignPattern).map { source(tree, text, $0) } == ["b = 2", "[f] = []"])
        let props = nodes(tree, .patternProp)
        #expect(props.map { tree[$0].aux } == [1, 1, 1, 2, 2])
        // A plain assignment keeps its expression target.
        #expect(nodes(tree, .assignExpr).count == 3)
    }

    @Test func typeOnlyImportsAndExportsAreMarked() {
        let (tree, text) = parse("""
        import type { A, B as C } from "./a";
        import { type D, E, type as as F } from "./d";
        import type G from "./g";
        import type from "./default";
        export type { A };
        export type * from "./types";
        export { E };

        """, .typescript)
        #expect(isClean(tree))
        let decls = nodes(tree, .importDecl).map { tree[$0].aux & SyntaxAux.typeOnly != 0 }
        #expect(decls == [true, false, true, false])
        let specs = nodes(tree, .importSpec).map { (source(tree, text, $0), tree[$0].aux & SyntaxAux.typeOnly != 0) }
        #expect(specs.map(\.0) == ["A", "B as C", "type D", "E", "type as as F", "G", "type"])
        #expect(specs.map(\.1) == [true, true, true, false, true, true, false])
        let exports = nodes(tree, .exportDecl).map { tree[$0].aux & SyntaxAux.typeOnly != 0 }
        #expect(exports == [true, true, false])
    }

    @Test func decoratorsAndAsyncGenerators() {
        let (tree, text) = parse("""
        @sealed
        export class A {
            @log accessor count = 0;
            constructor(@inject("x") private readonly x: X) {}
            @bound async *items(): AsyncGenerator<number> { yield* [1]; for await (const y of z) {} }
        }
        export @sealed class B {}
        const C = @sealed class {};
        class G<T extends { id: string }> implements I<T> {}

        """, .typescript)
        #expect(isClean(tree))
        #expect(nodes(tree, .decorator).map { source(tree, text, $0) }
                == ["@sealed", "@log", "@inject(\"x\")", "@bound", "@sealed", "@sealed"])
        let method = nodes(tree, .method).first { tree[$0].aux == 0 }!
        #expect(tree[method].has(SyntaxFlags.async) && tree[method].has(SyntaxFlags.generator))
        #expect(nodes(tree, .classExpr).count == 1)
        #expect(nodes(tree, .forOf).count == 1)
        #expect(nodes(tree, .classDecl).count == 3 && nodes(tree, .objectType).count == 1)
    }

    @Test func javascriptModeTurnsTypeScriptSyntaxOff() {
        let (js, jsText) = parse("""
        const less = a < b > (c);
        const pick = a ? (b) : c => c;
        type = 5;
        let x = y as z;

        """, .javascript)
        // `a < b > (c)` is two comparisons, the arrow is the else branch.
        #expect(nodes(js, .typeArgs).isEmpty && nodes(js, .call).isEmpty)
        #expect(nodes(js, .binary).count == 2)
        let ternary = nodes(js, .ternary).first!
        #expect(tree(js, lastChildOf: ternary) == .arrow)
        #expect(nodes(js, .typeAlias).isEmpty)
        // `as` is no operator in JavaScript.
        #expect(nodes(js, .asExpr).isEmpty)
        #expect(source(js, jsText, js.topLevelStatements[2]) == "type = 5;")

        let (ts, _) = parse("const pick = a ? (b) : c => c;\nconst less = f<T>(c);\n", .typescript)
        #expect(nodes(ts, .typeArgs).count == 1)

        let (jsx, _) = parse("const el = <div className=\"a\">{items.map(i => <Item key={i} />)}</div>;\n", .javascript)
        #expect(isClean(jsx))
        #expect(nodes(jsx, .jsxElement).count == 2)
    }

    private func tree(_ tree: SyntaxTree, lastChildOf i: Int) -> SyntaxKind? { tree.lastChild(i).map { tree.kind($0) } }

    // MARK: - Query API

    @Test func queryAPIFindsNodesStatementsAndPaths() {
        let source = "import os\n\nclass A:\n    def f(self, x):\n        return x.y\n\nz = 1\n"
        let (tree, text) = parse(source, .python)
        #expect(tree.topLevelStatements.map { tree.kind($0) } == [.importStmt, .classDef, .assign])
        let caret = text.range(of: "x.y").location + 2   // on the dot's right
        let path = tree.path(to: caret)
        let kinds = path.map { tree.kind($0) }
        #expect(kinds.first == .module)
        #expect(kinds.contains(.classDef) && kinds.contains(.funcDef) && kinds.contains(.returnStmt))
        #expect(tree.enclosing(caret, kinds: [.classDef, .funcDef]).map { tree.kind($0) } == [.classDef, .funcDef])
        let inner = tree.node(at: text.range(of: "x.y").location + 3)!
        #expect(tree.kind(inner) == .name && text.substring(with: tree.range(inner)) == "y")
        #expect(tree.topLevelStatement(at: text.range(of: "return").location).map { tree.kind($0) } == .classDef)
        #expect(tree.topLevelStatement(at: text.length - 1).map { tree.kind($0) } == .assign)
        let def = nodes(tree, .funcDef).first!
        #expect(tree.children(def).map { tree.kind($0) } == [.name, .params, .block])
        #expect(tree.childCount(def) == 3)
        #expect(tree.firstChild(def).map { tree.kind($0) } == .name)
        #expect(tree.lastChild(def).map { tree.kind($0) } == .block)
    }

    // MARK: - Incremental

    /// Applies random edits to every sample; after each, the incremental
    /// update of the previous tree must equal a full parse of the new text.
    /// Independent edits start from the original tree; chained edits build
    /// on the previous incremental result.
    @Test func incrementalUpdatesEqualFullParses() throws {
        var rng = SeededGenerator(state: 0x5359_4E54)
        var checked = 0
        for sample in try editSamples() {
            let base = sample.text as NSString
            let baseTree = SyntaxBuild.parse(base, dialect: sample.dialect)
            let big = base.length > 20_000
            let independent = longRuns ? 200 : (big ? 25 : 8)
            let chained = longRuns ? 200 : (big ? 25 : 8)
            for _ in 0..<independent {
                let (range0, insert) = randomEdit(base, &rng)
                let range = snapped(base, range0)
                let text = base.replacingCharacters(in: range, with: insert) as NSString
                let edit = SyntaxEdit(start: range.location, oldLength: range.length, newLength: (insert as NSString).length)
                let updated = SyntaxBuild.update(baseTree, edit: edit, text: text)
                let full = SyntaxBuild.parse(text, dialect: sample.dialect)
                #expect(updated == full, "\(sample.name): \(range) \(insert.debugDescription)")
                checked += 1
            }
            var text = base
            var tree = baseTree
            for _ in 0..<chained {
                let (range0, insert) = randomEdit(text, &rng)
                let range = snapped(text, range0)
                let next = text.replacingCharacters(in: range, with: insert) as NSString
                let edit = SyntaxEdit(start: range.location, oldLength: range.length, newLength: (insert as NSString).length)
                tree = SyntaxBuild.update(tree, edit: edit, text: next)
                let full = SyntaxBuild.parse(next, dialect: sample.dialect)
                #expect(tree == full, "\(sample.name) (chained): \(range) \(insert.debugDescription)")
                if tree != full { tree = full }
                text = next
                checked += 1
            }
        }
        #expect(checked > 800)
        print("incremental checks: \(checked)")
    }

    /// A keystroke reparses about two top-level statements.
    @Test func aKeystrokeReparsesFewStatements() throws {
        let text = try String(contentsOf: fixturesRoot.appendingPathComponent("inference/sample_1000.py"), encoding: .utf8)
            as NSString
        let tree = SyntaxBuild.parse(text, dialect: .python)
        let at = text.range(of: "\n", options: [], range: NSRange(location: text.length / 2, length: text.length / 2)).location
        let edited = text.replacingCharacters(in: NSRange(location: at, length: 0), with: "x") as NSString
        var build = SyntaxBuild(updating: .tree(tree), edit: SyntaxEdit(start: at, oldLength: 0, newLength: 1), text: edited)
        let result = build.finish(edited)!.tree!
        #expect(result == SyntaxBuild.parse(edited, dialect: .python))
        #expect(build.reparsedStatements <= 3)
        #expect(build.reusedStatements >= tree.topLevelStatements.count - 3)
    }

    /// The edit covering a journal reproduces the text change.
    @Test func editCoveringAJournal() {
        var rng = SeededGenerator(state: 0x4A4F_5552)
        for _ in 0..<200 {
            var text = "0123456789abcdefghij" as NSString
            let base = text
            var journal = EditJournal()
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let at = Int.random(in: 0...text.length, using: &rng)
                let n = Int.random(in: 0...min(3, text.length - at), using: &rng)
                let insert = String(repeating: "x", count: Int.random(in: 0...3, using: &rng))
                text = text.replacingCharacters(in: NSRange(location: at, length: n), with: insert) as NSString
                journal.record(editedRange: NSRange(location: at, length: (insert as NSString).length),
                               changeInLength: (insert as NSString).length - n)
            }
            let e = SyntaxEdit.covering(journal, baseLength: base.length)!
            let rebuilt = base.replacingCharacters(in: NSRange(location: e.start, length: e.oldLength),
                                                   with: text.substring(with: NSRange(location: e.start, length: e.newLength)))
            #expect(rebuilt == text as String)
        }
    }

    // MARK: - Fuzz

    /// Random unit-level mutations (any UTF-16 unit, including controls and
    /// lone surrogates) never crash, never exhaust the step cap, keep the
    /// tree well-formed, and keep the incremental update exact.
    @Test func mutationFuzzNeverCrashesOrExhaustsTheStepCap() throws {
        var rng = SeededGenerator(state: 0x4655_5A5A)
        let rounds = longRuns ? 60 : 6
        var mutations = 0
        defer { print("fuzz mutations: \(mutations)") }
        for sample in try editSamples() where sample.text.utf16.count < 60_000 {
            var units = Array(sample.text.utf16)
            var tree = SyntaxBuild.parse(String(decoding: units, as: UTF16.self) as NSString, dialect: sample.dialect)
            var text = NSString(characters: units, length: units.count)
            tree = SyntaxBuild.parse(text, dialect: sample.dialect)
            for _ in 0..<rounds {
                let at = Int.random(in: 0...units.count, using: &rng)
                let remove = Int.random(in: 0...min(4, units.count - at), using: &rng)
                let insert = (0..<Int.random(in: 0...4, using: &rng)).map { _ -> UInt16 in
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: return UInt16.random(in: 0...0x7F, using: &rng)
                    case 1: return [10, 13, 9, 32, 34, 39, 96, 123, 125, 40, 41, 91, 93, 35, 47, 60, 62, 92].randomElement(using: &rng)!
                    case 2: return UInt16.random(in: 0xD800...0xDFFF, using: &rng)
                    default: return UInt16.random(in: 0...0xFFFF, using: &rng)
                    }
                }
                units.replaceSubrange(at..<(at + remove), with: insert)
                mutations += 1
                let next = NSString(characters: units, length: units.count)
                var build = SyntaxBuild(dialect: sample.dialect, text: next, mode: .tree)
                let full = build.finish(next)!.tree!
                #expect(build.capHits == 0, "\(sample.name)")
                let problem = wellFormedProblem(full, length: units.count)
                #expect(problem == nil, "\(sample.name): \(problem ?? "") edit at \(at) -\(remove) +\(insert)")
                let updated = SyntaxBuild.update(tree, edit: SyntaxEdit(start: at, oldLength: remove, newLength: insert.count),
                                                 text: next)
                #expect(updated == full, "\(sample.name) at \(at)")
                tree = full
                text = next
            }
            _ = text
        }
    }

    // MARK: - Slicing

    /// Any step budgets give the one-pass result, in both modes.
    @Test func slicedBuildsEqualOnePass() throws {
        var rng = SeededGenerator(state: 0x534C_4943)
        for sample in try editSamples() {
            let text = sample.text as NSString
            for mode in [SyntaxBuild.Mode.tree, .summary] {
                var one = SyntaxBuild(dialect: sample.dialect, text: text, mode: mode)
                let oneShot = one.finish(text)!
                for budget in [1, 7, 64, 4096, -1] {
                    var build = SyntaxBuild(dialect: sample.dialect, text: text, mode: mode)
                    var steps = 0
                    while !build.step(text, budgetUnits: budget < 0 ? Int.random(in: 1...3000, using: &rng) : budget) {
                        steps += 1
                    }
                    #expect(build.result == oneShot, "\(sample.name) \(mode) budget \(budget)")
                }
            }
        }
    }

    /// A text changed between steps ends the build without a result.
    @Test func aTextChangedBetweenStepsEndsTheBuild() throws {
        let text = try String(contentsOf: fixturesRoot.appendingPathComponent("inference/sample_1000.ts"), encoding: .utf8)
            as NSString
        var build = SyntaxBuild(dialect: .typescript, text: text)
        let first = build.step(text, budgetUnits: 64)
        #expect(!first)
        let edited = text.replacingCharacters(in: NSRange(location: 10, length: 0), with: "x") as NSString
        let second = build.step(edited, budgetUnits: 64)
        #expect(second)
        #expect(build.isInvalidated && build.result == nil)
    }

    // MARK: - Summary mode

    /// The summary's statements are the full tree's top-level statements;
    /// an on-demand statement parse equals the full tree's subtree; the
    /// incremental summary update equals a fresh summary.
    @Test func summaryMatchesTheTreeAndOnDemandStatementsMatchItsSubtrees() throws {
        var rng = SeededGenerator(state: 0x5355_4D4D)
        for sample in try editSamples() {
            let text = sample.text as NSString
            let tree = SyntaxBuild.parse(text, dialect: sample.dialect)
            var build = SyntaxBuild(dialect: sample.dialect, text: text, mode: .summary)
            let summary = build.finish(text)!.summary!
            let statements = tree.topLevelStatements
            #expect(summary.statements.count == statements.count, "\(sample.name)")
            #expect(summary.syncStarts == tree.syncStarts)
            for (k, s) in statements.enumerated() where k < summary.statements.count {
                #expect(summary.statements[k].start == tree[s].start && summary.statements[k].end == tree[s].end)
                if k % 3 == 0 || k == statements.count - 1 {
                    let one = summary.parseStatement(k, in: text)
                    let expected = Array(tree.nodes[tree.subtree(s)])
                    #expect(Array(one.nodes.dropLast()) == expected, "\(sample.name) statement \(k)")
                    #expect(one[one.root].start == tree[s].start && one[one.root].end == tree[s].end)
                }
            }
            for _ in 0..<(longRuns ? 40 : 4) {
                let (range0, insert) = randomEdit(text, &rng)
                let range = snapped(text, range0)
                let next = text.replacingCharacters(in: range, with: insert) as NSString
                let edit = SyntaxEdit(start: range.location, oldLength: range.length, newLength: (insert as NSString).length)
                var update = SyntaxBuild(updating: .summary(summary), edit: edit, text: next)
                var fresh = SyntaxBuild(dialect: sample.dialect, text: next, mode: .summary)
                #expect(update.finish(next) == fresh.finish(next), "\(sample.name) \(range) \(insert.debugDescription)")
            }
        }
    }

    @Test func summaryRecordsNamesAndSignatures() {
        let py = "import os.path, json as j\nfrom x import (a, b as c)\n@dec\ndef f(x, y=1) -> int:\n    return x\n"
            + "class K(Base):\n    pass\nu, (v, *w) = 1, (2, 3)\nif cond:\n    def g(): pass\nelse:\n    g = None\n"
        let text = py as NSString
        var build = SyntaxBuild(dialect: .python, text: text, mode: .summary)
        let summary = build.finish(text)!.summary!
        func names(_ k: Int) -> [String] { summary.names(of: k).map { text.substring(with: $0) } }
        #expect(summary.statements.map(\.kind) == [.importStmt, .importFrom, .funcDef, .classDef, .assign, .ifStmt])
        #expect(names(0) == ["os", "j"])
        #expect(names(1) == ["a", "c"])
        #expect(names(2) == ["f"])
        #expect(text.substring(with: summary.statements[2].signatureRange) == "f(x, y=1) -> int")
        #expect(text.substring(with: summary.statements[3].signatureRange) == "K(Base)")
        #expect(names(4) == ["u", "v", "w"])
        #expect(names(5) == ["g", "g"])

        let ts = "export default class A<T> extends B implements C { x = 1 }\nexport const { p, q: [r] } = o;\n"
            + "import type D, { E } from \"m\";\ndeclare function h(a: number): void;\nexport { A as Z };\n"
        let tsText = ts as NSString
        var tsBuild = SyntaxBuild(dialect: .typescript, text: tsText, mode: .summary)
        let tsSummary = tsBuild.finish(tsText)!.summary!
        func tsNames(_ k: Int) -> [String] { tsSummary.names(of: k).map { tsText.substring(with: $0) } }
        #expect(tsSummary.statements.map(\.kind) == [.classDecl, .varDecl, .importDecl, .funcDecl, .exportDecl])
        #expect(tsSummary.statements[0].traits & ModuleSummary.Statement.exportDefault != 0)
        #expect(tsText.substring(with: tsSummary.statements[0].signatureRange) == "A<T> extends B implements C")
        #expect(tsNames(1) == ["p", "r"])
        #expect(tsNames(2) == ["D", "E"])
        #expect(tsSummary.statements[2].traits & ModuleSummary.Statement.typeOnly != 0)
        #expect(tsSummary.statements[3].traits & ModuleSummary.Statement.ambient != 0)
        #expect(tsText.substring(with: tsSummary.statements[3].signatureRange) == "h(a: number): void")
        #expect(tsNames(4).isEmpty)
    }

    @Test func subtreeCacheEvictsByBytes() {
        let (tree, _) = parse("def f():\n    return 1\n", .python)
        var cache = SyntaxSubtreeCache(byteLimit: tree.retainedBytes * 2 + 1)
        cache.insert(tree, startingAt: 0)
        cache.insert(tree, startingAt: 10)
        #expect(cache.count == 2)
        _ = cache.tree(startingAt: 0)            // 0 is now the most recent
        cache.insert(tree, startingAt: 20)       // evicts 10
        #expect(cache.count == 2)
        #expect(cache.tree(startingAt: 10) == nil && cache.tree(startingAt: 0) != nil)
        #expect(cache.bytes <= cache.byteLimit)
        var tiny = SyntaxSubtreeCache(byteLimit: 8)
        tiny.insert(tree, startingAt: 0)
        #expect(tiny.isEmpty)
    }

    // MARK: - Progress guards

    /// Pathological nesting stays within a 512 KB thread stack (the
    /// smallest a background queue gets) and terminates.
    @Test func deepNestingStaysWithinASmallThreadStack() {
        let depth = 3000
        let inputs: [(String, SyntaxDialect)] = [
            (String(repeating: "(", count: depth) + "x" + String(repeating: ")", count: depth), .typescript),
            (String(repeating: "[", count: depth), .javascript),
            ("x = " + String(repeating: "{a: ", count: depth), .typescript),
            (String(repeating: "- ", count: depth) + "x", .typescript),
            (String(repeating: "new ", count: depth) + "X", .typescript),
            (String(repeating: "a => ", count: depth) + "a", .typescript),
            ("let f: " + String(repeating: "() => ", count: depth) + "void", .typescript),
            ("type T = " + String(repeating: "A<", count: depth), .typescript),
            ("x = " + String(repeating: "a ? b : ", count: depth) + "c", .typescript),
            (String(repeating: "if (a) ", count: depth) + "b;", .typescript),
            (String(repeating: "{", count: depth), .typescript),
            ("x = " + String(repeating: "<a>", count: depth), .typescriptReact),
            ("let " + String(repeating: "[", count: depth) + "a] = b", .typescript),
            ("x = " + String(repeating: "`${", count: depth), .typescript),
            (String(repeating: "(", count: depth), .python),
            ("x = " + String(repeating: "not ", count: depth) + "y", .python),
            ("x = " + String(repeating: "lambda: ", count: depth) + "y", .python),
            ("x = " + String(repeating: "await ", count: depth) + "y", .python),
            ("x = " + String(repeating: "a if b else ", count: depth) + "c", .python),
            ("x = " + String(repeating: "f'{", count: 400), .python),
            ((0..<depth).map { String(repeating: " ", count: $0) + "if a:\n" }.joined() + String(repeating: " ", count: depth) + "pass\n",
             .python),
            ("match x:\n    case " + String(repeating: "[", count: depth) + ":\n        pass\n", .python),
        ]
        final class Box: @unchecked Sendable { var results: [Bool] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            for (source, dialect) in inputs {
                let text = source as NSString
                let tree = SyntaxBuild.parse(text, dialect: dialect)
                box.results.append(checkWellFormed(tree, length: text.length))
            }
            done.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        done.wait()
        #expect(box.results.count == inputs.count)
        #expect(box.results.allSatisfy { $0 })
    }

    /// The step cap bounds a statement whose parse reads far more tokens than
    /// it consumes; the parse then goes on at the next clean line start.
    @Test func stepCapBoundsQuadraticInputAndRecovers() {
        // Each `(` at an expression start looks ahead for its `)` (up to 4096
        // tokens): thousands of unclosed sibling ones make that quadratic.
        let source = "x = [" + String(repeating: "(, ", count: 6000) + "\nfunction after() {}\n"
        let text = source as NSString
        var build = SyntaxBuild(dialect: .typescript, text: text, mode: .tree)
        let tree = build.finish(text)!.tree!
        #expect(build.capHits == 1)
        #expect(checkWellFormed(tree, length: text.length))
        // The definition after the runaway statement is still found.
        #expect(tree.topLevelStatements.contains { tree.kind($0) == .funcDecl })
        // The bound holds in an incremental update too, with the same result.
        let edited = text.replacingCharacters(in: NSRange(location: 1, length: 0), with: "y") as NSString
        #expect(SyntaxBuild.update(tree, edit: SyntaxEdit(start: 1, oldLength: 0, newLength: 1), text: edited)
                == SyntaxBuild.parse(edited, dialect: .typescript))
    }
}
