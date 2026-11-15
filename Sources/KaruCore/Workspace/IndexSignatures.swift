import Foundation

// M17 T17.14 — signature summaries stored with the project-folder index
// (plan §10 "导出签名摘要"): the same compact text the inference layer shows
// for a member (plan §5.5), so a cross-file name in the completion list and
// a workspace-symbol row read like an inferred member.
//
// - Python: the export summary T17.13 builds for imported modules
//   (`PythonModuleSummarizer`): functions `(a: int, b=…) -> str`, a class's
//   constructor (its `__init__` without `self`), methods without `self`,
//   annotated variables and fields their type.
// - JavaScript / TypeScript: `ScriptModuleSummarizer` (annotations, JSDoc,
//   literal initialisers): functions and methods `(x: number) -> T`,
//   classes their construct signature, typed variables / fields their type.
// - Swift, Go, Rust, Java, C#, C, C++: the declaration itself
//   (`BraceStaticFile`, `BraceSummary.signature`): `(by factor: Int) -> Int`,
//   `(port int) error`, `(int n) : String`, a field's written type.
// - Otherwise the declaration-derived parameter names from
//   `IndexedSymbol.extract` stay (`(a, b)`).
//
// Every summary is fitted into `InferredMemberList.detailLimit`. Runs on the
// index queue; reads nothing but the file's text.

enum IndexSignatures {
    /// `symbols` (from `IndexedSymbol.extract` over `text`) with richer
    /// signatures where the language's summariser knows them. Updated in
    /// place (T17.15d): a caller passing its last reference (`consume`) gets
    /// the same storage back, no second array of the file's symbols.
    static func enrich(_ symbols: consuming [IndexedSymbol], text: NSString, language: String,
                       path: String = "") -> [IndexedSymbol] {
        guard !symbols.isEmpty else { return symbols }
        let lookup: (IndexedSymbol) -> String?
        if language == "python" {
            let summary = PythonModuleSummarizer.summarize(
                text, context: PythonSummaryContext(dotted: "__index__", isPackage: false, isStub: path.hasSuffix(".pyi"),
                                                    keyPrefix: "", isStdlib: { _ in false }),
                namesOnly: false)
            lookup = { python($0, summary.stub) }
        } else if let dialect = SyntaxDialect(languageIdentifier: language), dialect != .python {
            let summary = ScriptModuleSummarizer.summarize(
                text, context: ScriptSummaryContext(key: "§index:" + path, path: path, dialect: dialect) { _ in nil },
                namesOnly: false)
            lookup = { script($0, summary) }
        } else if let brace = BraceLanguage(identifier: language) {
            let file = BraceStaticFile(text: text, language: brace, identifier: language)
            lookup = { symbol in
                switch symbol.kind {
                case .function, .method, .property, .variable:
                    return file.signature(at: symbol.location, kind: symbol.kind)
                default:
                    return nil
                }
            }
        } else {
            return symbols
        }
        for index in symbols.indices {
            let symbol = symbols[index]
            guard let rich = lookup(symbol), !rich.isEmpty else { continue }
            symbols[index] = IndexedSymbol(name: symbol.name, kind: symbol.kind, container: symbol.container,
                                           location: symbol.location, line: symbol.line,
                                           signature: InferredMemberList.shortened(rich))
        }
        return symbols
    }

    // MARK: - Python

    private static func python(_ symbol: IndexedSymbol, _ stub: PythonModuleStub) -> String? {
        if let container = symbol.container {
            guard let cls = stub.class(named: container), let member = cls.member(named: symbol.name) else { return nil }
            return PythonTypeTables.detail(member, bindings: [:])
        }
        switch symbol.kind {
        case .function, .method:
            return stub.function(named: symbol.name)?.overloads.first
                .map { PythonTypeTables.signatureText($0, dropFirst: false, bindings: [:]) }
        case .class:
            guard let cls = stub.class(named: symbol.name), let initializer = cls.member(named: "__init__"),
                  let sig = initializer.overloads.first else { return nil }
            return PythonTypeTables.signatureText(sig, dropFirst: true, bindings: [:])
        default:
            return stub.variable(named: symbol.name)?.type
        }
    }

    // MARK: - JavaScript / TypeScript

    private static func script(_ symbol: IndexedSymbol, _ summary: ScriptModuleSummary) -> String? {
        if let container = symbol.container {
            if let member = summary.symbols[container]?.interface?.member(named: symbol.name) {
                return ScriptTypeTables.detail(member, bindings: [:])
            }
            // A namespace member is a symbol of its own (`NS.name`).
            guard let nested = summary.symbols[container + "." + symbol.name] else { return nil }
            return topLevel(nested)
        }
        return summary.symbols[symbol.name].flatMap(topLevel)
    }

    private static func topLevel(_ symbol: TSGlobalSymbol) -> String? {
        if let function = symbol.function, let sig = function.overloads.first {
            return ScriptTypeTables.signatureText(sig, bindings: [:])
        }
        if symbol.isClass, let sig = symbol.interface?.constructSignatures.first {
            // A constructor: its parameters (the result is the class itself).
            let text = ScriptTypeTables.signatureText(sig, bindings: [:])
            guard let arrow = text.range(of: ") -> ", options: .backwards) else { return text }
            return String(text[..<arrow.lowerBound]) + ")"
        }
        return symbol.variable?.type
    }
}
