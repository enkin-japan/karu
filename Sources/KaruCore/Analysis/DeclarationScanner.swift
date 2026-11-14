import Foundation

/// Accumulates one scan's declarations and scopes, then derives the
/// `DeclarationScan` products in bounded steps (M17 T17.4a).
///
/// Declarations arrive in document order (the walkers emit at the binding
/// token as they pass it) and are varint-encoded on the fly. Scopes are kept
/// in small transient arrays (start / end / kind / name by creation id, plus
/// `order`: ids sorted by start, parent before child) because a JS block's
/// scope is created lazily — only when a block-scoped declaration appears in
/// it — after scopes nested in it may already exist; `insertScope` puts it at
/// its sorted place (scanning back from the end, so the cost is the number of
/// scopes opened since the block's `{`). The outline is encoded at the end.
struct DeclarationBuilder: Sendable {
    let languageIdentifier: String

    private(set) var names: [String] = []
    private var nameIndex: [String: Int32] = [:]
    /// Per name: 1 listed function / method, 2 listed class / type,
    /// 4 listed other, 8 declared at all (scope-only included), 16 called
    /// (a table-only reference, T17.4b), 32 referenced as a type (table-only).
    private var masks: [UInt8] = []
    private(set) var encoded: [UInt8] = []
    private var lastLocation = 0
    /// Declarations encoded so far, and a seek point (`encoded` index,
    /// running location before it) every `DeclarationScan.seekStride` of
    /// them (T17.7: the highlighter decodes only its band).
    private var declarationCount = 0
    private var seeks: [Int32] = []
    /// Declarations that arrived out of document order and were dropped
    /// (a walker bug; tests assert it stays 0).
    private(set) var droppedOutOfOrder = 0

    private var scopeStart: [Int32] = []
    private var scopeEnd: [Int32] = []
    private var scopeKind: [UInt8] = []
    private var scopeName: [Int32] = []
    private var order: [Int32] = []

    // Finishing state.
    private var outline: [UInt8] = []
    private var encodeCursor = 0
    private var previousStart = 0
    private var classifyCursor = 0
    private var functions = Set<String>()
    private var types = Set<String>()
    private var variableCandidates: [Int] = []
    private var phase = 0

    /// Declarations are scope-only (T17.8c: an embedding host's regions):
    /// recorded with their kinds for `visibleBindings`, never entered into
    /// the table / completion symbols (nor references).
    let scopeOnly: Bool

    init(languageIdentifier: String, scopeOnly: Bool = false) {
        self.languageIdentifier = languageIdentifier
        self.scopeOnly = scopeOnly
    }

    var scopeCount: Int { order.count }

    // MARK: - Declarations

    private mutating func appendVarint(_ value: Int) {
        var v = value
        while v >= 0x80 {
            encoded.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        encoded.append(UInt8(v))
    }

    /// Records the declaration named by `token`; returns its name index.
    @discardableResult
    mutating func declare(_ text: NSString, _ token: DeclToken, kind: DeclarationScan.DeclarationKind,
                          listed: Bool) -> Int32 {
        guard token.end > token.start else { return -1 }
        guard token.start >= lastLocation else {
            droppedOutOfOrder += 1
            return -1
        }
        let name = text.substring(with: NSRange(location: token.start, length: token.end - token.start))
        let index: Int32
        if let known = nameIndex[name] {
            index = known
        } else {
            index = Int32(names.count)
            nameIndex[name] = index
            names.append(name)
            masks.append(0)
        }
        var bit: UInt8 = 8
        let listed = listed && !scopeOnly
        if listed {
            switch kind.symbolKind {
            case .function: bit |= 1
            case .type: bit |= 2
            case .variable: bit |= 4
            }
        }
        masks[Int(index)] |= bit
        if declarationCount > 0, declarationCount % DeclarationScan.seekStride == 0 {
            seeks.append(Int32(clamping: encoded.count))
            seeks.append(Int32(clamping: lastLocation))
        }
        declarationCount += 1
        appendVarint(token.start - lastLocation)
        appendVarint(Int(index) << 4 | DeclarationScan.code(kind, listed: listed))
        lastLocation = token.start
        return index
    }

    /// Records a table-only reference (T17.4b, the brace languages that the
    /// regex path coloured by `name(` calls and `class` / `struct` names):
    /// the name enters the colour table / completion symbols as a function
    /// (unless it is also a type) or a type, but is no declaration — no
    /// location, no binding.
    mutating func noteReference(_ text: NSString, _ token: DeclToken, kind: WordIndex.SymbolKind) {
        guard token.end > token.start, !scopeOnly else { return }
        let name = text.substring(with: NSRange(location: token.start, length: token.end - token.start))
        let index: Int
        if let known = nameIndex[name] {
            index = Int(known)
        } else {
            index = names.count
            nameIndex[name] = Int32(index)
            names.append(name)
            masks.append(0)
        }
        masks[index] |= kind == .type ? 32 : 16
    }

    /// Interns a name without declaring it (scope names of namespaces /
    /// impls; no table entry).
    mutating func intern(_ text: NSString, _ token: DeclToken) -> Int32 {
        guard token.end > token.start else { return -1 }
        let name = text.substring(with: NSRange(location: token.start, length: token.end - token.start))
        if let known = nameIndex[name] { return known }
        let index = Int32(names.count)
        nameIndex[name] = index
        names.append(name)
        masks.append(0)
        return index
    }

    /// Interns `name` without declaring it (an embedded region's language).
    mutating func intern(name: String) -> Int32 {
        if let known = nameIndex[name] { return known }
        let index = Int32(names.count)
        nameIndex[name] = index
        names.append(name)
        masks.append(0)
        return index
    }

    /// Names a scope after it was opened (a Go method's scope opens at its
    /// receiver, before the name).
    mutating func nameScope(_ id: Int32, _ name: Int32) {
        let i = Int(id)
        guard i >= 0, i < scopeName.count else { return }
        scopeName[i] = name
    }

    // MARK: - Scopes

    /// Opens a scope starting at or after every scope opened so far.
    mutating func openScope(_ kind: DeclarationScan.ScopeKind, at start: Int, name: Int32 = -1) -> Int32 {
        let id = Int32(scopeStart.count)
        scopeStart.append(Int32(clamping: start))
        scopeEnd.append(-1)
        scopeKind.append(kind.rawValue)
        scopeName.append(name)
        order.append(id)
        return id
    }

    /// Opens a scope whose start may precede scopes opened since (a lazily
    /// created JS block scope); `order` stays sorted, ties keep creation order.
    mutating func insertScope(_ kind: DeclarationScan.ScopeKind, at start: Int, name: Int32 = -1) -> Int32 {
        let id = Int32(scopeStart.count)
        scopeStart.append(Int32(clamping: start))
        scopeEnd.append(-1)
        scopeKind.append(kind.rawValue)
        scopeName.append(name)
        var position = order.count
        while position > 0, scopeStart[Int(order[position - 1])] > Int32(clamping: start) { position -= 1 }
        order.insert(id, at: position)
        return id
    }

    mutating func closeScope(_ id: Int32, at end: Int) {
        let i = Int(id)
        guard i >= 0, i < scopeEnd.count else { return }
        scopeEnd[i] = max(scopeStart[i], Int32(clamping: end))
    }

    // MARK: - Finishing

    /// Encodes the outline and classifies the names, about `units` items per
    /// call. Returns true when done.
    mutating func finishStep(units: Int, documentLength: Int) -> Bool {
        var budget = max(64, units)
        let length = Int32(clamping: documentLength)
        while budget > 0 {
            budget -= 1
            switch phase {
            case 0:
                // Outline, pre-order (ascending start, parent first).
                guard encodeCursor < order.count else { phase = 1; continue }
                let id = Int(order[encodeCursor])
                encodeCursor += 1
                let start = min(scopeStart[id], length)
                let end = min(max(scopeEnd[id] < 0 ? length : scopeEnd[id], start), length)
                appendOutlineVarint(Int(start) - previousStart)
                let hasName = scopeName[id] >= 0
                appendOutlineVarint(Int(end - start) << 4 | Int(scopeKind[id]) << 1 | (hasName ? 1 : 0))
                if hasName { appendOutlineVarint(Int(scopeName[id])) }
                previousStart = Int(start)
            case 1:
                // Functions / types first (variables are demoted against them).
                guard classifyCursor < names.count else { phase = 3; continue }
                let i = classifyCursor
                classifyCursor += 1
                let mask = masks[i]
                // A call is a function unless the name is (also) a type; the
                // regex path's control-word filter applies to calls.
                if mask & 1 != 0
                    || mask & 16 != 0 && mask & (2 | 32) == 0 && !WordIndex.cLikeNonSymbols.contains(names[i]) {
                    functions.insert(names[i])
                }
                if mask & (2 | 32) != 0 { types.insert(names[i]) }
                if mask & 4 != 0 { variableCandidates.append(i) }
            default:
                return true
            }
        }
        return phase >= 3
    }

    private mutating func appendOutlineVarint(_ value: Int) {
        var v = value
        while v >= 0x80 {
            outline.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        outline.append(UInt8(v))
    }

    /// The finished scan (after `finishStep` returned true).
    func makeScan(documentLength: Int) -> DeclarationScan {
        let excluded = WordIndex.nonVariableNames(for: languageIdentifier)
        var variables = Set<String>()
        for i in variableCandidates {
            let name = names[i]
            if functions.contains(name) || types.contains(name) || excluded.contains(name) { continue }
            variables.insert(name)
        }
        let table = WordIndex.SymbolTable(functions: functions, types: types, variables: variables)
        // Exact-size copies: the streams grew by doubling and are held for
        // as long as the version is current.
        return DeclarationScan(languageIdentifier: languageIdentifier, table: table,
                               completionSymbols: table.all, names: Array(names[...]),
                               encodedLocations: encoded.withUnsafeBufferPointer { Array($0) },
                               outline: outline.withUnsafeBufferPointer { Array($0) },
                               scopeCount: order.count, documentLength: documentLength,
                               declarationSeeks: seeks.withUnsafeBufferPointer { Array($0) },
                               hasEmbeddedRegions: scopeOnly)
    }
}

/// The resumable declaration pass (M17 T17.4a, plan §3 "调度"): lexer state,
/// tokenizer, walker and builder in one value, advanced in bounded steps so
/// `DocumentAnalysis` can run it through `AnalysisScheduler` in ~4 ms slices
/// and publish the snapshot only when complete.
///
/// - `step(_:budgetUnits:)` lexes about `budgetUnits` UTF-16 units (to the
///   next lexer safe point), tokenizes the code segments and lets the walker
///   consume what it can; after the end of the text, further steps encode
///   the outline and classify names. Returns true when finished.
/// - The text must not change between steps (the caller checks the document
///   version before each slice and drops the scanner on any edit).
/// - Running with any budgets yields an equal `DeclarationScan` (chunks end
///   at lexer safe points, the tokenizer is chunk-independent, and the
///   walkers only decide once their lookahead is available or the text has
///   ended). `finish(_:)` runs to completion (`DeclarationScan.scan`).
/// - **Embedding hosts** (HTML, Markdown; T17.8c): the host's scanner
///   reports each run's language; every maximal run of one child language
///   with a walker (a `<script>` body, a fence body) is an embedded region,
///   walked by a fresh walker of that child (created when the region
///   opens, dropped when it closes) under its own `.embedded` scope named
///   after the child. At the region's end the walker finishes there, so
///   every scope it left open closes at the region end and nothing leaks
///   into the next region. The declarations are scope-only (no table,
///   completion symbols or navigator entries). Children without a walker
///   (CSS, JSON, Bash, …) contribute nothing.
/// - Languages without a walker (no declarations: Bash, SQL, data formats)
///   finish in a single step with empty products.
public struct DeclarationScanner: Sendable {
    public let languageIdentifier: String
    private var walker: WalkerScan?
    private var result: DeclarationScan?

    public init(languageIdentifier: String) {
        self.languageIdentifier = languageIdentifier
        if DeclarationScan.usesWalker(languageIdentifier)
            || DeclarationScan.embeddingProfile(languageIdentifier) != nil {
            walker = WalkerScan(languageIdentifier: languageIdentifier)
        }
    }

    public var isFinished: Bool { result != nil }

    /// The finished scan, or nil while steps remain.
    public var scan: DeclarationScan? { result }

    /// Declarations dropped for arriving out of order (should be 0; tests).
    var droppedOutOfOrder: Int { walker?.builder.droppedOutOfOrder ?? 0 }

    /// Advances by about `budgetUnits` units of work; true when finished.
    @discardableResult
    public mutating func step(_ text: NSString, budgetUnits: Int) -> Bool {
        if result != nil { return true }
        guard walker != nil else {
            result = DeclarationScan.regexScan(text, languageIdentifier: languageIdentifier)
            return true
        }
        if walker!.step(text, budgetUnits: max(1, budgetUnits)) {
            result = walker!.builder.makeScan(documentLength: walker!.documentLength)
            walker = nil
            return true
        }
        return false
    }

    /// Units per step when running to completion: small enough that the
    /// token buffer between tokenizer and walker stays a few hundred KB (a
    /// 1 M-unit step buffered ~200 K tokens, whose freed blocks stayed dirty).
    static let finishStepUnits = 16_384

    /// Runs to completion and returns the scan.
    public mutating func finish(_ text: NSString) -> DeclarationScan {
        while !step(text, budgetUnits: Self.finishStepUnits) {}
        return result!
    }
}

/// One walker family with its tokenizer and token buffer: the Python, the
/// JavaScript / TypeScript or the brace walker of one language.
struct LanguageWalker: Sendable {
    let python: Bool
    let brace: BraceLanguage?
    var tokenizer: DeclTokenizer
    var buffer = DeclTokenBuffer()
    var pythonWalker: PythonDeclarationWalker?
    var jsWalker: JavaScriptDeclarationWalker?
    var braceWalker: BraceDeclarationWalker?

    /// The walker of `languageIdentifier`, nil for a language without one.
    init?(languageIdentifier: String) {
        guard DeclarationScan.usesWalker(languageIdentifier) else { return nil }
        python = languageIdentifier == "python"
        brace = BraceLanguage(identifier: languageIdentifier)
        if let brace {
            tokenizer = DeclTokenizer(brace: brace)
            braceWalker = BraceDeclarationWalker(language: brace)
        } else if python {
            tokenizer = DeclTokenizer(python: true)
            pythonWalker = PythonDeclarationWalker()
        } else {
            // JSX (T17.8b) reaches the walker as literals and `{…}` as interpolations.
            tokenizer = DeclTokenizer(python: false)
            jsWalker = JavaScriptDeclarationWalker(typescript: languageIdentifier == "typescript"
                                                       || languageIdentifier == "typescriptreact")
        }
    }

    /// The lexical profile the walker reads for `languageIdentifier`.
    static func profile(for languageIdentifier: String) -> LexicalProfile {
        if let brace = BraceLanguage(identifier: languageIdentifier) { return brace.lexicalProfile }
        if languageIdentifier == "python" { return PythonLanguage.analysisProfile }
        return JavaScriptLanguage.lexicalProfile(forIdentifier: languageIdentifier) ?? JavaScriptLanguage.lexicalProfile
    }

    /// Starts the walk under `scope` (the module, or an embedded region).
    mutating func begin(scope: Int32) {
        jsWalker?.begin(moduleScope: scope)
        braceWalker?.begin(moduleScope: scope)
    }

    mutating func tokenize(_ text: NSString, from: Int, to: Int, segments: [(NSRange, LexicalSegment)]) {
        tokenizer.tokenize(text, from: from, to: to, segments: segments, into: &buffer)
    }

    mutating func finishTokens(at end: Int) {
        tokenizer.finish(at: end, into: &buffer)
    }

    mutating func process(_ text: NSString, final: Bool, _ builder: inout DeclarationBuilder) {
        if python {
            pythonWalker!.process(&buffer, text, final: final, &builder)
        } else if brace != nil {
            braceWalker!.process(&buffer, text, final: final, &builder)
        } else {
            jsWalker!.process(&buffer, text, final: final, &builder)
        }
    }

    /// Ends the walk at `end`: every scope the walker opened and left open
    /// closes there.
    mutating func finish(at end: Int, _ builder: inout DeclarationBuilder) {
        if python {
            pythonWalker!.finish(at: end, &builder)
        } else if brace != nil {
            braceWalker!.finish(at: end, &builder)
        } else {
            jsWalker!.finish(at: end, &builder)
        }
    }
}

/// The walker-language state behind `DeclarationScanner`: one walker over
/// the whole text, or — for an embedding host (T17.8c) — a walker per
/// embedded region.
struct WalkerScan: Sendable {
    let scanner: LexicalScanner
    var lexState = LexicalScanState()
    var position = 0
    var documentLength = -1
    /// The document's walker (nil for an embedding host).
    var walker: LanguageWalker?
    /// An embedding host: the open region (its child language index, its
    /// scope, its walker — nil for a child without one).
    let embeds: Bool
    var region: (language: Int, scope: Int32, walker: LanguageWalker?)?
    var builder: DeclarationBuilder
    var moduleScope: Int32 = -1
    /// 0 scanning, 1 finishing.
    var phase = 0

    init(languageIdentifier: String) {
        if let host = DeclarationScan.embeddingProfile(languageIdentifier) {
            embeds = true
            scanner = LexicalScanner(profile: host)
            builder = DeclarationBuilder(languageIdentifier: languageIdentifier, scopeOnly: true)
        } else {
            embeds = false
            scanner = LexicalScanner(profile: LanguageWalker.profile(for: languageIdentifier))
            walker = LanguageWalker(languageIdentifier: languageIdentifier)
            builder = DeclarationBuilder(languageIdentifier: languageIdentifier)
        }
    }

    mutating func step(_ text: NSString, budgetUnits: Int) -> Bool {
        if documentLength < 0 {
            documentLength = text.length
            moduleScope = builder.openScope(.module, at: 0)
            walker?.begin(scope: moduleScope)
        }
        let length = documentLength
        if phase == 1 {
            return builder.finishStep(units: budgetUnits / 16, documentLength: length)
        }
        if text.length != length {
            // The text changed between steps (the caller's contract is that it
            // does not): never read it again; finish with what was emitted.
            if embeds {
                closeRegion(at: position, text: nil)
            } else {
                walker!.buffer.removeAll()
                walker!.finish(at: position, &builder)
            }
            builder.closeScope(moduleScope, at: length)
            phase = 1
            return false
        }
        if embeds { return stepRegions(text, budgetUnits: budgetUnits) }
        if position < length {
            let target = min(length, position + budgetUnits)
            var state = lexState
            var segments: [(NSRange, LexicalSegment)] = []
            let end = scanner.segments(text, from: position, to: length, stoppingAtSafePointFrom: target,
                                       state: &state) { range, segment in segments.append((range, segment)) }
            lexState = state
            walker!.tokenize(text, from: position, to: end, segments: segments)
            position = max(end, position + 1 > length ? length : end)
            if position >= length { walker!.finishTokens(at: length) }
        } else {
            walker!.finishTokens(at: length)
        }
        let final = position >= length
        walker!.process(text, final: final, &builder)
        if final {
            walker!.finish(at: length, &builder)
            builder.closeScope(moduleScope, at: length)
            walker!.buffer.removeAll()
            phase = 1
        }
        return false
    }

    // MARK: - Embedded regions (T17.8c)

    /// One step of an embedding host: lexes a chunk with languages, opens /
    /// closes regions where the run language changes and feeds each region's
    /// runs to its walker.
    ///
    /// A host lexes half of `budgetUnits` per step: a unit costs more here
    /// (child scanners, per-run languages, region switches), and the halved
    /// step keeps a slice's overshoot past its deadline like the walker
    /// languages'.
    private mutating func stepRegions(_ text: NSString, budgetUnits: Int) -> Bool {
        let length = documentLength
        if position < length {
            let target = min(length, position + max(1, budgetUnits / 2))
            var state = lexState
            var runs: [(NSRange, LexicalSegment, Int)] = []
            let end = scanner.segments(text, from: position, to: length, stoppingAtSafePointFrom: target,
                                       state: &state) { range, segment, language in
                runs.append((range, segment, language))
            }
            lexState = state
            var i = 0
            while i < runs.count {
                let language = runs[i].2
                var j = i + 1
                while j < runs.count, runs[j].2 == language { j += 1 }
                let start = runs[i].0.location
                if language == 0 {
                    closeRegion(at: start, text: text)
                } else {
                    if let open = region, open.language != language { closeRegion(at: start, text: text) }
                    if region == nil { openRegion(language, at: start) }
                    if region!.walker != nil {
                        let groupEnd = NSMaxRange(runs[j - 1].0)
                        region!.walker!.tokenize(text, from: start, to: groupEnd,
                                                 segments: runs[i..<j].map { ($0.0, $0.1) })
                        region!.walker!.process(text, final: false, &builder)
                    }
                }
                i = j
            }
            position = max(end, position + 1 > length ? length : end)
        }
        if position >= length {
            closeRegion(at: length, text: text)
            builder.closeScope(moduleScope, at: length)
            phase = 1
        }
        return false
    }

    private mutating func openRegion(_ language: Int, at start: Int) {
        guard let identifier = scanner.embeddedIdentifier(language),
              var walker = LanguageWalker(languageIdentifier: identifier) else {
            region = (language, -1, nil)
            return
        }
        let scope = builder.openScope(.embedded, at: start, name: builder.intern(name: identifier))
        walker.begin(scope: scope)
        region = (language, scope, walker)
    }

    /// Closes the open region at `end` (nil `text`: the text changed, drop
    /// the buffered tokens unread).
    private mutating func closeRegion(at end: Int, text: NSString?) {
        guard var open = region.take(), open.walker != nil else { return }
        if let text {
            open.walker!.finishTokens(at: end)
            open.walker!.process(text, final: true, &builder)
        }
        open.walker!.buffer.removeAll()
        open.walker!.finish(at: end, &builder)
        builder.closeScope(open.scope, at: end)
    }
}
