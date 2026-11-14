import Foundation
import Testing
@testable import KaruCore

// M17 T17.11a — the parser tolerance samples (Tests/Fixtures/M17/parser, 58
// partially typed files with a caret marker): the four facts of the
// fixture README (topLevel, enclosing, params, receiver), read strictly from
// the production syntax tree plus the source text, must equal the
// expectations for every sample.

private let parserFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/M17/parser")

struct ToleranceFacts: Codable, Equatable {
    var topLevel: [String]
    var enclosing: [String]
    var params: [String]
    var receiver: String?
}

/// The fixture README's four facts, from the tree (no sample-specific rules).
struct ToleranceFactExtractor {
    let tree: SyntaxTree
    let text: NSString
    let caret: Int
    var nodes: [SyntaxNode] { tree.nodes }
    var python: Bool { tree.dialect == .python }

    func extract() -> ToleranceFacts {
        var chain: [(name: String, function: Int?)] = []
        walk(tree.root, &chain)
        var params: [String] = []
        if let f = chain.last(where: { $0.function != nil })?.function { params = paramNames(f) }
        return ToleranceFacts(topLevel: topLevel(), enclosing: chain.map(\.name), params: params, receiver: receiver())
    }

    func str(_ i: Int) -> String { text.substring(with: nodes[i].range) }

    func child(_ i: Int, _ kind: SyntaxKind) -> Int? { tree.firstChild(i, kind: kind) }

    // MARK: topLevel

    func topLevel() -> [String] {
        var out: [String] = []
        for s in tree.topLevelStatements { declaredNames(s, &out) }
        return out
    }

    func declaredNames(_ s: Int, _ out: inout [String]) {
        let n = nodes[s]
        switch n.kind {
        case .funcDef, .classDef, .funcDecl, .classDecl, .interfaceDecl, .typeAlias, .enumDecl:
            if let name = child(s, .name) { out.append(str(name)) }
        case .assign:
            let cs = tree.children(s)
            for t in cs.dropLast() where nodes[t].kind == .name { out.append(str(t)) }
        case .annAssign:
            let cs = tree.children(s)
            if cs.count >= 3, nodes[cs[0]].kind == .name { out.append(str(cs[0])) }
        case .varDecl:
            for d in tree.children(s) where nodes[d].kind == .declarator {
                if let b = tree.children(d).first { boundNames(b, &out) }
            }
        case .exportDecl:
            if n.aux & ~SyntaxAux.typeOnly <= 1 { for c in tree.children(s) { declaredNames(c, &out) } }
        default:
            break
        }
    }

    func boundNames(_ b: Int, _ out: inout [String]) {
        switch nodes[b].kind {
        case .name:
            out.append(str(b))
        case .objectPattern, .arrayPattern:
            for c in tree.children(b) { boundNames(c, &out) }
        case .patternProp:
            let cs = tree.children(b)
            if nodes[b].aux == 1 { if let f = cs.first { boundNames(f, &out) } }
            else if cs.count >= 2 { boundNames(cs[1], &out) }
        case .assignPattern, .restElement:
            if let f = tree.children(b).first { boundNames(f, &out) }
        default:
            break
        }
    }

    // MARK: enclosing

    func blankLineColumn(_ offset: Int) -> Int {
        var p = offset
        var blanks: [unichar] = []
        while p > 0 {
            let u = text.character(at: p - 1)
            if u == 10 || u == 13 { break }
            if u != 32 && u != 9 { return Int.max }
            blanks.append(u)
            p -= 1
        }
        var col = 0
        for u in blanks.reversed() { col = u == 9 ? (col / 8 + 1) * 8 : col + 1 }
        return col
    }

    func lineIndent(_ offset: Int32) -> Int {
        var p = Int(offset)
        while p > 0 {
            let u = text.character(at: p - 1)
            if u == 10 || u == 13 { break }
            p -= 1
        }
        var col = 0
        while p < text.length {
            let u = text.character(at: p)
            if u == 32 { col += 1 } else if u == 9 { col = (col / 8 + 1) * 8 } else { break }
            p += 1
        }
        return col
    }

    func contains(_ i: Int) -> Bool { Int(nodes[i].start) <= caret && caret <= Int(nodes[i].end) }

    /// Python: caret after the last statement of `stmt`'s block, before the
    /// next statement — inside when its blank-line column is deeper than the
    /// statement's header (or the caret shares a line with code).
    func trailingInside(_ stmt: Int) -> Bool {
        guard python, Int(nodes[stmt].end) < caret else { return false }
        var p = Int(nodes[stmt].end)
        var inComment = false
        while p < caret {
            let u = text.character(at: p)
            if u == 35 { inComment = true }
            if u == 10 || u == 13 { inComment = false }
            if !inComment && !(u == 32 || u == 9 || u == 10 || u == 13 || u == 12) { return false }
            p += 1
        }
        return blankLineColumn(caret) > lineIndent(nodes[stmt].start)
    }

    func walk(_ i: Int, _ chain: inout [(name: String, function: Int?)]) {
        let n = nodes[i]
        switch n.kind {
        case .funcDef, .classDef:
            if let body = child(i, .block) {
                let b = nodes[body]
                if Int(b.start) <= caret && (caret <= Int(b.end) || trailingInside(i)) {
                    let name = child(i, .name).map(str) ?? "<anon>"
                    chain.append((name, n.kind == .funcDef ? i : nil))
                    walkChildren(body, &chain)
                    return
                }
            }
        case .lambda:
            let cs = tree.children(i)
            if cs.count >= 2, let p = cs.first, Int(nodes[p].end) < caret, caret <= Int(n.end) {
                chain.append(("<anon>", i))
                if let body = cs.last { walk(body, &chain) }
                return
            }
        case .funcDecl, .funcExpr, .method:
            if let body = child(i, .block), insideBraces(body) {
                chain.append((functionName(i, binding: nil), i))
                walk(body, &chain)
                return
            }
        case .arrow:
            if arrowContains(i) {
                chain.append(("<anon>", i))
                walkChildren(i, &chain)
                return
            }
        case .declarator:
            let cs = tree.children(i)
            if nodes[i].aux & 2 != 0, let initNode = cs.last, cs.count >= 2,
               nodes[initNode].kind == .arrow || nodes[initNode].kind == .funcExpr,
               nodes[cs[0]].kind == .name {
                let binding = str(cs[0])
                if nodes[initNode].kind == .arrow, arrowContains(initNode) {
                    chain.append((binding, initNode))
                    walkChildren(initNode, &chain)
                    return
                }
                if nodes[initNode].kind == .funcExpr, let body = child(initNode, .block), insideBraces(body) {
                    chain.append((functionName(initNode, binding: binding), initNode))
                    walk(body, &chain)
                    return
                }
            }
        case .classDecl, .classExpr:
            if let body = child(i, .classBody), insideBraces(body) {
                chain.append((child(i, .name).map(str) ?? "<anon>", nil))
                walk(body, &chain)
                return
            }
        default:
            break
        }
        walkChildren(i, &chain)
    }

    func walkChildren(_ i: Int, _ chain: inout [(name: String, function: Int?)]) {
        let cs = tree.children(i)
        if let c = cs.first(where: contains) {
            walk(c, &chain)
            return
        }
        if python, let last = cs.last(where: { Int(nodes[$0].end) < caret }), trailingInside(last) {
            walk(last, &chain)
        }
    }

    func insideBraces(_ body: Int) -> Bool {
        let b = nodes[body]
        let open = Int(b.start) + 1
        if b.has(SyntaxFlags.missingClose) || b.has(SyntaxFlags.recovered) {
            return open <= caret && caret <= Int(b.end)
        }
        return open <= caret && caret < Int(b.end)
    }

    func arrowContains(_ i: Int) -> Bool {
        let cs = tree.children(i)
        guard cs.count >= 2, let body = cs.last else { return false }
        let b = nodes[body]
        if b.kind == .block { return insideBraces(body) }
        let before = nodes[cs[cs.count - 2]]
        return Int(before.end) < caret && caret <= max(Int(b.end), Int(b.start))
    }

    func functionName(_ i: Int, binding: String?) -> String {
        let n = nodes[i]
        if n.kind == .method {
            if n.aux == 3 { return "constructor" }
            for c in tree.children(i) where nodes[c].kind != .decorator { return str(c) }
        }
        if let name = child(i, .name) { return str(name) }
        return binding ?? "<anon>"
    }

    // MARK: params

    func paramNames(_ f: Int) -> [String] {
        guard let ps = child(f, .params) else { return [] }
        var out: [String] = []
        for p in tree.children(ps) where nodes[p].kind == .param {
            if python {
                if nodes[p].aux <= 2, let name = child(p, .name) { out.append(str(name)) }
            } else if let b = tree.children(p).first(where: { nodes[$0].kind != .decorator }) {
                if nodes[b].kind == .keywordLit { continue } // `this` parameter
                boundNames(b, &out)
            }
        }
        return out
    }

    // MARK: receiver

    func receiver() -> String? {
        var q = caret
        while q > 0 {
            let u = text.character(at: q - 1)
            if (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u >= 0x80 {
                q -= 1
            } else { break }
        }
        guard q > 0, text.character(at: q - 1) == 46 else { return nil }
        for (idx, n) in nodes.enumerated() where n.kind == .member {
            guard let obj = tree.firstChild(idx) else { continue }
            let dotLen = n.has(SyntaxFlags.optional) ? 2 : 1
            if Int(nodes[obj].end) + Int(n.aux) + dotLen == q { return str(obj) }
        }
        return nil
    }
}

/// A fixture's text without its caret marker (U+2038), and the caret offset.
func toleranceSample(_ url: URL) throws -> (text: NSString, caret: Int) {
    let raw = try String(contentsOf: url, encoding: .utf8)
    let ns = raw as NSString
    let marker = ns.range(of: "\u{2038}")
    precondition(marker.location != NSNotFound, "caret marker in \(url.lastPathComponent)")
    return (ns.replacingCharacters(in: marker, with: "") as NSString, marker.location)
}

@Suite("Syntax parser tolerance samples")
struct SyntaxParserToleranceTests {
    static let languages: [(directory: String, dialect: SyntaxDialect)] = [
        ("python", .python), ("typescript", .typescript), ("tsx", .typescriptReact),
    ]

    @Test func allSamplesYieldTheExpectedFacts() throws {
        var passed = 0, total = 0
        var failures: [String] = []
        for (directory, dialect) in Self.languages {
            let dir = parserFixtures.appendingPathComponent(directory)
            let expected = try JSONDecoder().decode([String: ToleranceFacts].self,
                                                    from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
            for file in expected.keys.sorted() {
                total += 1
                let (text, caret) = try toleranceSample(dir.appendingPathComponent(file))
                let tree = SyntaxBuild.parse(text, dialect: dialect)
                let facts = ToleranceFactExtractor(tree: tree, text: text, caret: caret).extract()
                if facts == expected[file] {
                    passed += 1
                } else {
                    failures.append("\(directory)/\(file): expected \(expected[file]!), got \(facts)")
                }
            }
        }
        #expect(total == 58)
        #expect(passed == total, "\(failures.joined(separator: "\n"))")
    }
}
