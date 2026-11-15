import Foundation

// M17 T17.16 — completion inside import statements (plan §9 "T17.16 补充"):
// module names after `import` / `from`, the names `from x import` offers,
// JS / TS module specifiers in `from '…'` / `require('…')` / `import('…')`,
// and the names inside `import { … } from '…'`.
//
// - **Where** (`ImportSiteDetector`, pure text, no disk): the caret's
//   statement is read back from the caret (bounded windows: `\` line
//   continuations and a `from x import (` parenthesis for Python, the
//   current line for a specifier string, the braces and the `from '…'`
//   after them for named imports). The engine passes the lexical position
//   class: Python sites are code only; a JS / TS specifier is a string (the
//   only strings that pop), named imports are code.
// - **What** (`ImportService.importCompletions`, main thread): the
//   standard-library table's names; listings of the project root, the
//   document's venv and the interpreter's search roots, Python packages,
//   `node_modules` and relative directories (`ImportListing`, read on the
//   import queue, cached in the summary LRU and validated by directory
//   mtimes); export summaries already used for member completion
//   (`PythonTypeTables.moduleMembers`, `ScriptTypeTables.moduleMembers`);
//   Node's built-in module names (a static table). A listing or summary
//   still loading marks the answer pending: the controller refreshes the
//   popup when it arrives (the §9 refresh rule).
// - **Bounds**: a listed directory contributes at most
//   `directoryEntryLimit` entries; no process is started; privacy-protected
//   folders are only read inside the project folder (the existing rules of
//   `PythonSearchPaths` / `ScriptModuleLocator`).

/// An import-statement position (M17 T17.16).
public enum ImportSite: Sendable, Equatable {
    /// Python `import a.b.│`, `from a.│` (`parent` = `a.b` / `a`, "" at the
    /// top level; `level` leading dots of a relative `from`).
    case pythonModule(level: Int, parent: String)
    /// Python `from x import │` (`module` = `x`; "" for `from . import`).
    case pythonNames(level: Int, module: String)
    /// A JS / TS module specifier: `head` is the text before the caret's
    /// segment, through the last `/` ("" when none).
    case scriptSpecifier(head: String)
    /// `import { │ } from 'specifier'`.
    case scriptNames(specifier: String)

    var isPython: Bool {
        switch self {
        case .pythonModule, .pythonNames: return true
        case .scriptSpecifier, .scriptNames: return false
        }
    }

    /// A JS / TS module specifier (any text, not an identifier).
    var isSpecifier: Bool {
        if case .scriptSpecifier = self { return true }
        return false
    }
}

/// The import site at a caret, with the text the caret completes.
public struct ImportSiteMatch: Sendable, Equatable {
    public let site: ImportSite
    /// The typed text the candidates are matched against.
    public let prefix: String
    public let prefixRange: NSRange
    /// What accepting replaces: the whole last dotted segment (Python) /
    /// the identifier (named imports); after the last `/` up to the caret in
    /// a specifier string (the quotes and anything after the caret stay).
    public let replacementRange: NSRange
}

/// Candidates of one import site (T17.16).
public struct ImportCandidateBatch: Sendable {
    public struct Item: Sendable, Equatable {
        public let name: String
        public let kind: CandidateKind
        public let detail: String?
        /// Ranking depth (exports before submodules).
        public let depth: Int

        public init(name: String, kind: CandidateKind, detail: String? = nil, depth: Int = 0) {
            self.name = name
            self.kind = kind
            self.detail = detail
            self.depth = depth
        }
    }

    public var items: [Item]

    public init(items: [Item]) { self.items = items }
}

// MARK: - Detection

/// Finds the import site at a caret from the text alone (M17 T17.16).
enum ImportSiteDetector {
    /// Units read back for a statement (continuation lines, a parenthesis,
    /// braces) and forward for named imports' `from '…'`.
    static let windowUnits = 4_096

    static func isPython(_ languageIdentifier: String) -> Bool { languageIdentifier == "python" }

    static func isScript(_ languageIdentifier: String) -> Bool {
        ["javascript", "typescript", "typescriptreact"].contains(languageIdentifier)
    }

    /// The site at `caret` (a plain caret) in a document of
    /// `languageIdentifier` whose lexical position class there is `position`.
    static func detect(text: NSString, caret: Int, languageIdentifier: String,
                       position: CompletionContext.Position) -> ImportSiteMatch? {
        guard caret >= 0, caret <= text.length else { return nil }
        if isPython(languageIdentifier) {
            return position == .code ? python(text: text, caret: caret) : nil
        }
        if isScript(languageIdentifier) {
            switch position {
            case .string: return scriptSpecifier(text: text, caret: caret)
            case .code: return scriptNames(text: text, caret: caret)
            default: return nil
            }
        }
        return nil
    }

    // MARK: Python

    static func python(text: NSString, caret: Int) -> ImportSiteMatch? {
        guard let start = IdentifierText.runStart(before: caret, in: text, dollar: false) else { return nil }
        let end = IdentifierText.runEnd(after: caret, in: text, dollar: false)
        guard let statement = pythonStatement(before: start, in: text),
              let site = parsePython(statement) else { return nil }
        let prefixRange = NSRange(location: start, length: caret - start)
        return ImportSiteMatch(site: site, prefix: text.substring(with: prefixRange), prefixRange: prefixRange,
                               replacementRange: NSRange(location: start, length: end - start))
    }

    private static func lineStart(of offset: Int, in text: NSString) -> Int {
        var k = offset
        let floor = max(0, offset - windowUnits)
        while k > floor {
            let u = text.character(at: k - 1)
            if u == 10 || u == 13 { break }
            k -= 1
        }
        return k
    }

    /// The statement text from its start to `start` (newlines folded to
    /// spaces): `\` continuation lines joined, or the lines since an open
    /// `from x import (`; nil when it does not start with `import` / `from`.
    static func pythonStatement(before start: Int, in text: NSString) -> String? {
        var lineBegin = lineStart(of: start, in: text)
        var head = text.substring(with: NSRange(location: lineBegin, length: start - lineBegin))
        var joined = 0
        while lineBegin > 0, joined < 8 {
            var prevEnd = lineBegin - 1                                     // the newline
            if prevEnd > 0, text.character(at: prevEnd) == 10, text.character(at: prevEnd - 1) == 13 { prevEnd -= 1 }
            let prevBegin = lineStart(of: prevEnd, in: text)
            let previous = text.substring(with: NSRange(location: prevBegin, length: prevEnd - prevBegin))
            guard previous.hasSuffix("\\") else { break }
            head = String(previous.dropLast()) + " " + head
            lineBegin = prevBegin
            joined += 1
        }
        if startsImportStatement(lastStatement(head)) { return head }
        // Inside `from x import (` … : the parenthesis is open before `start`.
        var i = start - 1
        let floor = max(0, start - windowUnits)
        var open: Int?
        while i >= floor {
            switch text.character(at: i) {
            case 40: open = i                                               // (
            case 41, 59, 61, 91, 93, 123, 125, 34, 39: return nil          // ) ; = [ ] { } " '
            default: break
            }
            if open != nil { break }
            i -= 1
        }
        guard let paren = open else { return nil }
        let begin = lineStart(of: paren, in: text)
        let raw = text.substring(with: NSRange(location: begin, length: start - begin))
        // Comments end at their line; lines fold into one.
        let folded = raw.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { line -> Substring in line.firstIndex(of: "#").map { line[..<$0] } ?? line[...] }
            .joined(separator: " ")
        return startsImportStatement(lastStatement(folded)) ? folded : nil
    }

    private static func lastStatement(_ s: String) -> Substring {
        let tail = s.lastIndex(of: ";").map { s[s.index(after: $0)...] } ?? s[...]
        return tail.drop { $0 == " " || $0 == "\t" }
    }

    private static func startsImportStatement(_ s: Substring) -> Bool {
        keyword("import", at: s) != nil || keyword("from", at: s) != nil
    }

    /// The text after `word` when `s` starts with it followed by whitespace
    /// (or `(` for `import (`).
    private static func keyword(_ word: String, at s: Substring, allowParen: Bool = false) -> Substring? {
        guard s.hasPrefix(word) else { return nil }
        let rest = s.dropFirst(word.count)
        guard let next = rest.first, next == " " || next == "\t" || (allowParen && next == "(") else { return nil }
        return rest
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    /// A dotted name of identifier parts, each non-empty (`a.b`).
    private static func isDottedName(_ s: Substring) -> Bool {
        !s.isEmpty && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.allSatisfy(isIdentifierCharacter) && !($0.first?.isNumber ?? false)
        }
    }

    /// The site of a statement that ends where the caret's segment starts.
    static func parsePython(_ statement: String) -> ImportSite? {
        let s = lastStatement(statement)
        if let rest = keyword("import", at: s) {
            // `import a, b.c│`: the last item; `import a as │` is no module position.
            let item = (rest.split(separator: ",", omittingEmptySubsequences: false).last ?? rest)
                .drop { $0 == " " || $0 == "\t" }
            if item.isEmpty { return .pythonModule(level: 0, parent: "") }
            guard item.hasSuffix("."), isDottedName(item.dropLast()) else { return nil }
            return .pythonModule(level: 0, parent: String(item.dropLast()))
        }
        guard let rest = keyword("from", at: s) else { return nil }
        var r = rest.drop { $0 == " " || $0 == "\t" }
        let level = r.prefix { $0 == "." }.count
        r = r.dropFirst(level)
        let token = r.prefix { isIdentifierCharacter($0) || $0 == "." }
        let after = r.dropFirst(token.count)
        if after.isEmpty {
            // `from a.b.│` / `from .│` / `from │`.
            if token.isEmpty { return .pythonModule(level: level, parent: "") }
            guard token.hasSuffix("."), isDottedName(token.dropLast()) else { return nil }
            return .pythonModule(level: level, parent: String(token.dropLast()))
        }
        guard after.first == " " || after.first == "\t" else { return nil }
        guard level > 0 ? (token.isEmpty || isDottedName(token)) : isDottedName(token) else { return nil }
        guard let names = keyword("import", at: after.drop { $0 == " " || $0 == "\t" }, allowParen: true) else {
            return nil
        }
        var list = names.drop { $0 == " " || $0 == "\t" }
        if list.first == "(" { list = list.dropFirst() }
        // `from x import a, │`; `a as │` / `a │` are no name positions.
        let item = (list.split(separator: ",", omittingEmptySubsequences: false).last ?? list)
        guard item.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return .pythonNames(level: level, module: String(token))
    }

    // MARK: JS / TS

    @inline(__always) private static func isWhitespace(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 10 || u == 13 }

    /// An ASCII-or-not identifier unit for keyword checks (`$` included).
    @inline(__always) private static func isWordUnit(_ u: UInt16) -> Bool {
        (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 || u == 36 || u >= 128
    }

    /// The word ending right before `end` (exclusive), and its start.
    private static func word(endingAt end: Int, in text: NSString) -> (String, Int) {
        var k = end
        let floor = max(0, end - 64)
        while k > floor, isWordUnit(text.character(at: k - 1)) { k -= 1 }
        return (text.substring(with: NSRange(location: k, length: end - k)), k)
    }

    /// `end` moved back over whitespace (bounded).
    private static func skipWhitespace(backFrom end: Int, in text: NSString, limit: Int = 256) -> Int {
        var k = end
        let floor = max(0, end - limit)
        while k > floor, isWhitespace(text.character(at: k - 1)) { k -= 1 }
        return k
    }

    /// `word` ends at `end` as a keyword (not a member or part of a name).
    private static func isKeyword(_ expected: Set<String>, endingAt end: Int, in text: NSString) -> Bool {
        let (w, start) = word(endingAt: end, in: text)
        guard expected.contains(w) else { return false }
        if start > 0, text.character(at: start - 1) == 46 { return false }        // obj.from
        return true
    }

    /// The caret in a specifier string: `from '…'`, `import '…'`,
    /// `require('…')`, `import('…')`.
    static func scriptSpecifier(text: NSString, caret: Int) -> ImportSiteMatch? {
        var q = caret - 1
        let floor = max(0, caret - 512)
        var quote: UInt16 = 0
        while q >= floor {
            let u = text.character(at: q)
            if u == 39 || u == 34 || u == 96 { quote = u; break }               // ' " `
            if isWhitespace(u) || u == 92 || u == 36 { return nil }            // whitespace \ $
            q -= 1
        }
        guard quote != 0 else { return nil }
        var k = skipWhitespace(backFrom: q, in: text)
        if k > 0, text.character(at: k - 1) == 40 {                           // (
            k = skipWhitespace(backFrom: k - 1, in: text)
            guard isKeyword(["require", "import"], endingAt: k, in: text) else { return nil }
        } else {
            guard isKeyword(["from", "import"], endingAt: k, in: text) else { return nil }
        }
        let content = text.substring(with: NSRange(location: q + 1, length: caret - q - 1)) as NSString
        let slash = content.range(of: "/", options: .backwards)
        let headLength = slash.location == NSNotFound ? 0 : slash.location + 1
        let head = content.substring(to: headLength)
        let prefixStart = q + 1 + headLength
        let prefixRange = NSRange(location: prefixStart, length: caret - prefixStart)
        return ImportSiteMatch(site: .scriptSpecifier(head: head), prefix: text.substring(with: prefixRange),
                               prefixRange: prefixRange, replacementRange: prefixRange)
    }

    /// The caret in `import { a, │ } from 'x'` (also `import type { … }`,
    /// `import def, { … }`): the specifier is read after the braces.
    static func scriptNames(text: NSString, caret: Int) -> ImportSiteMatch? {
        guard let start = IdentifierText.runStart(before: caret, in: text, dollar: true) else { return nil }
        let end = IdentifierText.runEnd(after: caret, in: text, dollar: true)
        // Back to the opening brace: names, commas, whitespace, `as`, `type`.
        var i = start - 1
        let floor = max(0, start - windowUnits)
        var brace: Int?
        var lastComma: Int?
        while i >= floor {
            let u = text.character(at: i)
            if u == 123 { brace = i; break }                                    // {
            if u == 44, lastComma == nil { lastComma = i }                      // ,
            if !(isWordUnit(u) || isWhitespace(u) || u == 44) { return nil }
            i -= 1
        }
        guard let open = brace else { return nil }
        // The item being typed: nothing before it but an optional `type`.
        let itemStart = (lastComma ?? open) + 1
        let item = text.substring(with: NSRange(location: itemStart, length: start - itemStart))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.isEmpty || item == "type" else { return nil }
        // Before the brace: `import`, `import type`, `import def,`.
        var k = skipWhitespace(backFrom: open, in: text)
        if k > 0, text.character(at: k - 1) == 44 {
            k = skipWhitespace(backFrom: k - 1, in: text)
            let (_, defStart) = word(endingAt: k, in: text)
            guard defStart < k else { return nil }
            k = skipWhitespace(backFrom: defStart, in: text)
        }
        if word(endingAt: k, in: text).0 == "type" {
            k = skipWhitespace(backFrom: word(endingAt: k, in: text).1, in: text)
        }
        guard isKeyword(["import"], endingAt: k, in: text) else { return nil }
        // Forward: `… } from 'x'`.
        var j = end
        let ceiling = min(text.length, end + windowUnits)
        var close: Int?
        while j < ceiling {
            let u = text.character(at: j)
            if u == 125 { close = j; break }                                    // }
            if !(isWordUnit(u) || isWhitespace(u) || u == 44) { return nil }
            j += 1
        }
        guard let closing = close, let specifier = specifierAfterFrom(closing + 1, in: text) else { return nil }
        let prefixRange = NSRange(location: start, length: caret - start)
        return ImportSiteMatch(site: .scriptNames(specifier: specifier), prefix: text.substring(with: prefixRange),
                               prefixRange: prefixRange, replacementRange: NSRange(location: start, length: end - start))
    }

    /// `from 'x'` starting at `from` (after whitespace): `x`.
    private static func specifierAfterFrom(_ from: Int, in text: NSString) -> String? {
        var k = from
        let ceiling = min(text.length, from + 512)
        while k < ceiling, isWhitespace(text.character(at: k)) { k += 1 }
        guard k + 4 < ceiling, text.substring(with: NSRange(location: k, length: 4)) == "from" else { return nil }
        k += 4
        while k < ceiling, isWhitespace(text.character(at: k)) { k += 1 }
        guard k < ceiling else { return nil }
        let quote = text.character(at: k)
        guard quote == 39 || quote == 34 else { return nil }
        var m = k + 1
        while m < ceiling {
            let u = text.character(at: m)
            if u == quote { break }
            if u == 10 || u == 13 { return nil }
            m += 1
        }
        guard m < ceiling, m > k + 1 else { return nil }
        return text.substring(with: NSRange(location: k + 1, length: m - k - 1))
    }
}

// MARK: - Node built-ins

/// Node's built-in module names (a static table; plan §9 T17.16: names
/// only — their members come from `@types/node`, which is not resolved).
enum NodeBuiltinModules {
    /// Importable with or without `node:`.
    static let names = [
        "assert", "assert/strict", "async_hooks", "buffer", "child_process", "cluster", "console", "constants",
        "crypto", "dgram", "diagnostics_channel", "dns", "dns/promises", "domain", "events", "fs", "fs/promises",
        "http", "http2", "https", "inspector", "inspector/promises", "module", "net", "os", "path", "path/posix",
        "path/win32", "perf_hooks", "process", "punycode", "querystring", "readline", "readline/promises", "repl",
        "stream", "stream/consumers", "stream/promises", "stream/web", "string_decoder", "sys", "timers",
        "timers/promises", "tls", "trace_events", "tty", "url", "util", "util/types", "v8", "vm", "wasi",
        "worker_threads", "zlib",
    ]
    /// Only with the `node:` scheme.
    static let schemeOnly = ["sea", "sqlite", "test", "test/reporters"]
}

// MARK: - Candidates (main thread)

extension ImportService {
    /// The answer to one import site: candidates (already filtered for
    /// privacy-by-underscore) and whether a listing or summary is still loading.
    struct ImportCompletionAnswer {
        var batch: ImportCandidateBatch
        var pending: Bool
    }

    /// Candidates for `match` in the document at `documentPath` (nil:
    /// unsaved). Schedules the listings / summaries it needs (sent to the
    /// queue before returning); `pythonTables` / `scriptTables`: the tables
    /// the window's type inference reads (registered with this service).
    func importCompletions(_ match: ImportSiteMatch, documentPath: String?, pythonTables: PythonTypeTables,
                           scriptTables: ScriptTypeTables) -> ImportCompletionAnswer {
        let scope = scope(forDocument: documentPath)
        let requestsBefore = requestCount
        var items: [ImportCandidateBatch.Item] = []
        var seen = Set<String>()
        func add(_ name: String, _ kind: CandidateKind = .module, detail: String? = nil, depth: Int = 0) {
            if seen.insert(name).inserted { items.append(.init(name: name, kind: kind, detail: detail, depth: depth)) }
        }
        func addListing(_ listing: ImportListing?, directories: Bool = false, depth: Int = 0) {
            for entry in listing?.entries ?? [] {
                add(directories && entry.isPackage ? entry.name + "/" : entry.name, depth: depth)
            }
        }
        switch match.site {
        case .pythonModule(let level, let parent):
            for name in pythonSubmodules(level: level, parent: parent, scope: scope) { add(name) }
        case .pythonNames(let level, let module):
            if level > 0, module.isEmpty, scope.relativeBaseIsRoot(level: level) {
                // `from . import` at the project root: the root's modules.
                for name in pythonSubmodules(level: level, parent: "", scope: scope) { add(name, depth: 1) }
            } else {
                if let key = scope.python(module, level: level) {
                    for candidate in InferredMemberList.candidates(pythonTables.moduleMembers(key)) {
                        add(candidate.name, candidate.kind, detail: candidate.detail)
                    }
                }
                for name in pythonSubmodules(level: level, parent: module, scope: scope) { add(name, depth: 1) }
            }
        case .scriptSpecifier(let head):
            scriptSpecifiers(head: head, prefix: match.prefix, scope: scope, add: { add($0) },
                             addListing: { addListing($0, directories: $1) })
        case .scriptNames(let specifier):
            if let key = scope.script(specifier) {
                for candidate in InferredMemberList.candidates(scriptTables.moduleMembers(key)) {
                    add(candidate.name, candidate.kind, detail: candidate.detail)
                }
            }
        }
        // Python modules starting with `_` only for an `_` prefix (plan §9 T17.16).
        if match.site.isPython, !match.prefix.hasPrefix("_") {
            items.removeAll { $0.kind == .module && $0.name.hasPrefix("_") }
        }
        let pending = scope.hasPending || requestCount != requestsBefore
        flush()
        return ImportCompletionAnswer(batch: ImportCandidateBatch(items: items), pending: pending)
    }

    /// Modules / packages directly under `parent` ("" = the top level):
    /// standard-library names from the table (never the disk), the rest
    /// from listings of the search roots or the package's directories.
    private func pythonSubmodules(level: Int, parent: String, scope: ImportScope) -> [String] {
        var absolute = parent
        if level > 0 {
            guard let doc = scope.pythonDocument,
                  let a = PythonModuleLocator.absolute(level: level, name: parent, from: doc.dotted,
                                                       isPackage: doc.isPackage) else { return [] }
            absolute = a
        }
        var out: [String] = []
        if absolute.isEmpty {
            if level == 0 {
                out += stdlibModuleNames.filter { !$0.contains(".") }
            }
            guard let context = scope.context else {
                scope.notePending()
                return out
            }
            // Relative from the root: the project root only; else every root.
            if level > 0 {
                guard context.projectRoot != nil else { return out }
                out += (listing(.pythonProjectTop, context: context, scope: scope)?.entries ?? []).map(\.name)
            } else {
                out += (listing(.pythonTop, context: context, scope: scope)?.entries ?? []).map(\.name)
            }
            return out
        }
        let head = String(absolute.split(separator: ".").first ?? "")
        if level == 0, isStdlib(head) {
            let lead = absolute + "."
            for name in stdlibModuleNames where name.hasPrefix(lead) {
                let rest = name.dropFirst(lead.count)
                if !rest.isEmpty, !rest.contains(".") { out.append(String(rest)) }
            }
            return out
        }
        guard let context = scope.context else {
            scope.notePending()
            return out
        }
        return (listing(.pythonPackage(absolute), context: context, scope: scope)?.entries ?? []).map(\.name)
    }

    /// JS / TS specifiers after `head`: relative directories, packages
    /// (`@scope/pkg` whole; `@scope/` its packages; `pkg/…/` its files) and
    /// Node built-ins (`node:` forms when the typed text asks for them).
    private func scriptSpecifiers(head: String, prefix: String, scope: ImportScope, add: (String) -> Void,
                                  addListing: (ImportListing?, Bool) -> Void) {
        let context = scope.scriptContext
        let importer = context.projectRoot != nil ? scope.documentPath : nil
        let importerDirectory = importer.map(ImportPath.parent)
        if head.isEmpty {
            for name in NodeBuiltinModules.names where !name.contains("/") { add(name) }
            let wantsScheme = prefix.hasPrefix("node:") || (!prefix.isEmpty && "node:".hasPrefix(prefix))
            if wantsScheme {
                for name in NodeBuiltinModules.names + NodeBuiltinModules.schemeOnly where !name.contains("/") {
                    add("node:" + name)
                }
            }
            if let directory = importerDirectory {
                addListing(listing(.scriptPackages(directory: directory, scope: nil), context: context, scope: scope),
                           false)
            }
            return
        }
        // Built-in subpaths: `fs/` → `promises`.
        let builtinHead = head.hasPrefix("node:") ? String(head.dropFirst(5)) : head
        let builtins = NodeBuiltinModules.names + (head.hasPrefix("node:") ? NodeBuiltinModules.schemeOnly : [])
        for name in builtins where name.hasPrefix(builtinHead) {
            let rest = name.dropFirst(builtinHead.count)
            if !rest.isEmpty, !rest.contains("/") { add(String(rest)) }
        }
        guard let root = context.projectRoot, let importer, let directory = importerDirectory else { return }
        if head.hasPrefix("./") || head.hasPrefix("../") {
            let target = ImportPath.resolvingDots(ImportPath.join(directory, head))
            guard ImportPath.isInside(target, root) else { return }
            let listed = listing(.scriptDirectory(target), context: context, scope: scope)
            // The document itself is not offered next to its siblings.
            let own = target == directory ? Self.scriptStem(ImportPath.lastComponent(importer)) : nil
            addListing(listed.map { ImportListing(entries: $0.entries.filter { $0.isPackage || $0.name != own }) }, true)
            return
        }
        guard !head.hasPrefix("/"), !head.hasPrefix("node:") else { return }
        let path = String(head.dropLast())                     // without the trailing `/`
        if path.hasPrefix("@"), !path.contains("/") {
            addListing(listing(.scriptPackages(directory: directory, scope: path), context: context, scope: scope), false)
            return
        }
        let (package, subpath) = ScriptModuleLocator.splitPackage(path)
        guard !package.isEmpty, !package.hasSuffix("/") else { return }
        addListing(listing(.scriptPackageDirectory(directory: directory, package: package, subpath: subpath),
                           context: context, scope: scope), true)
    }

    /// Extensions a relative listing strips (plan §9 T17.16), longest first.
    nonisolated static let strippedScriptExtensions = [".d.ts", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]

    /// A file name as a specifier: a script extension stripped.
    nonisolated static func scriptStem(_ name: String) -> String {
        for ext in strippedScriptExtensions where name.hasSuffix(ext) && name.count > ext.count {
            return String(name.dropLast(ext.count))
        }
        return name
    }
}

// MARK: - Listings (import queue)

extension ImportWorker {
    /// Entries one directory contributes at most (plan §9 T17.16).
    static let directoryEntryLimit = 2_000

    /// Builds the listing `request` of `context` (an empty listing when the
    /// directories do not exist; their parents' mtimes validate it).
    func list(_ request: ImportListingRequest, context: ImportContextSnapshot) -> ImportedModule {
        var entries: [ImportListing.Entry] = []
        var seen = Set<String>()
        var validators: [String: Double] = [:]
        func add(_ name: String, package: Bool) {
            if seen.insert(name).inserted { entries.append(.init(name: name, isPackage: package)) }
        }
        /// Sorted, capped entry names of `dir` (its mtime recorded).
        func names(_ dir: String) -> [String] {
            guard let info = fs.info(dir), info.isDirectory else { return [] }
            validators[dir] = info.modificationTime
            return Array((fs.list(dir) ?? []).sorted().prefix(Self.directoryEntryLimit))
        }
        func pythonDirectory(_ dir: String, stubPackages: Bool) {
            for name in names(dir) {
                for ext in [".pyi", ".py"] where name.hasSuffix(ext) {
                    let stem = String(name.dropLast(ext.count))
                    if stem != "__init__", Self.isPythonIdentifier(stem) { add(stem, package: false) }
                }
                if name.hasSuffix(".py") || name.hasSuffix(".pyi") { continue }
                var module = name
                if stubPackages, name.hasSuffix("-stubs") { module = String(name.dropLast("-stubs".count)) }
                // A top-level `tests` in site-packages is a packaging slip of
                // some distribution; the project's own `tests` package is real.
                guard Self.isPythonIdentifier(module), name != "__pycache__",
                      !(stubPackages && name == "tests"), !name.hasSuffix(".dist-info") else { continue }
                let package = ImportPath.join(dir, name)
                if fs.isFile(ImportPath.join(package, "__init__.py")) || fs.isFile(ImportPath.join(package, "__init__.pyi")) {
                    add(module, package: true)
                }
            }
        }
        func scriptDirectory(_ dir: String) {
            for name in names(dir) where !name.hasPrefix(".") && name != "node_modules" {
                guard let info = fs.info(ImportPath.join(dir, name)) else { continue }
                if info.isDirectory {
                    add(name, package: true)
                } else {
                    add(ImportService.scriptStem(name), package: false)
                }
            }
        }
        switch request {
        case .pythonTop:
            let paths = self.paths(context)
            validators.merge(paths.validators) { a, _ in a }
            for root in paths.roots { pythonDirectory(root.path, stubPackages: root.isSitePackages) }
        case .pythonProjectTop:
            if let root = context.projectRoot { pythonDirectory(root, stubPackages: false) }
        case .pythonPackage(let dotted):
            let paths = self.paths(context)
            validators.merge(paths.validators) { a, _ in a }
            if let location = PythonModuleLocator.locate(dotted, in: paths, fs: fs), location.isPackage {
                for dir in location.packageDirectories { pythonDirectory(dir, stubPackages: false) }
            }
        case .scriptDirectory(let dir):
            if let root = context.projectRoot, ImportPath.isInside(dir, root) { scriptDirectory(dir) }
        case .scriptPackages(let start, let scope):
            guard let root = context.projectRoot else { break }
            var dir = start
            while ImportPath.isInside(dir, root) {
                // A `node_modules` created later changes its parent's mtime.
                if let info = fs.info(dir) { validators[dir] = info.modificationTime }
                let modules = ImportPath.join(dir, "node_modules")
                if fs.isDirectory(modules) {
                    let types = ImportPath.join(modules, "@types")
                    if let scope {
                        for name in names(ImportPath.join(modules, scope)) where !name.hasPrefix(".") {
                            add(name, package: false)
                        }
                        let mangled = String(scope.dropFirst()) + "__"
                        for name in names(types) where name.hasPrefix(mangled) && name.count > mangled.count {
                            add(String(name.dropFirst(mangled.count)), package: false)
                        }
                    } else {
                        for name in names(modules) where !name.hasPrefix(".") {
                            if name == "@types" {
                                for typed in names(types) where !typed.hasPrefix(".") {
                                    // `@types/scope__pkg` names `@scope/pkg`.
                                    if let sep = typed.range(of: "__") {
                                        add("@" + typed[..<sep.lowerBound] + "/" + typed[sep.upperBound...], package: false)
                                    } else {
                                        add(typed, package: false)
                                    }
                                }
                            } else if name.hasPrefix("@") {
                                for inner in names(ImportPath.join(modules, name)) where !inner.hasPrefix(".") {
                                    add(name + "/" + inner, package: false)
                                }
                            } else {
                                add(name, package: false)
                            }
                        }
                    }
                }
                if dir == root || dir == "/" { break }
                dir = ImportPath.parent(dir)
            }
        case .scriptPackageDirectory(let start, let package, let subpath):
            guard let root = context.projectRoot else { break }
            var dir = start
            while ImportPath.isInside(dir, root) {
                if let info = fs.info(dir) { validators[dir] = info.modificationTime }
                let packageDir = ImportPath.join(ImportPath.join(dir, "node_modules"), package)
                if fs.isDirectory(packageDir) {
                    let target = ImportPath.resolvingDots(subpath.isEmpty ? packageDir : ImportPath.join(packageDir, subpath))
                    if ImportPath.isInside(target, packageDir) { scriptDirectory(target) }
                    break
                }
                if dir == root || dir == "/" { break }
                dir = ImportPath.parent(dir)
            }
        }
        return ImportedModule(content: .listing(ImportListing(entries: entries)), sourcePath: nil,
                              validators: validators, isProjectFile: false)
    }

    /// A module name Python can import (`stem` of `name.py`, a package directory).
    static func isPythonIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}
