import Foundation

/// Content-based language detection, used as a fallback when a file's extension
/// resolves to no registered language (or the document has no name yet — pasted
/// / untitled buffers), and by "run" when an Auto-mode buffer is still Plain
/// Text. Pure logic, no AppKit, so it stays trivially testable.
///
/// Only the leading 8 KB of text is inspected: sniffing runs on every paste /
/// edit of an untitled buffer, so the cost is capped regardless of document
/// size (ARCHITECTURE.md §1 performance budget). Detection is deliberately
/// conservative — an unrecognised buffer returns `nil` rather than guessing.
/// Code rules need two independent signals unless one is unambiguous (a
/// shebang, `#include <iostream>`, `public static void main(String`, …).
/// Patterns are compiled once and matched over the whole sample with
/// `^`/`$` anchored at line boundaries.
public enum LanguageSniffer {
    /// Maximum number of leading bytes inspected.
    private static let sampleByteLimit = 8 * 1024

    /// Returns a language identifier (matching `LanguageDefinition.identifier`,
    /// e.g. `"python"`) inferred from `text`, or `nil` when nothing matches.
    /// Rules are applied in priority order (see inline notes).
    public static func sniff(_ text: String) -> String? {
        let sample = truncate(text, toBytes: sampleByteLimit)
        guard !sample.isEmpty else { return nil }
        let lines = sample.components(separatedBy: "\n")
        let probe = Probe(sample)

        // 1. Shebang: the interpreter name pins the language.
        if let first = lines.first, first.hasPrefix("#!") {
            if first.contains("python") { return "python" }
            if matches(first, "\\b(ts-node|tsx)\\b") { return "typescript" }
            if matches(first, "\\bswift\\b") { return "swift" }
            if matches(first, "\\b(deno|bun)\\b") { return probe.looksTypeScript ? "typescript" : "javascript" }
            if matches(first, "\\b(bash|zsh|sh)\\b") { return "bash" }
            if first.contains("node") { return "javascript" }
        }

        // 2. XML / HTML document markers (case-insensitive).
        let lower = sample.lowercased()
        if lower.contains("<?xml") || lower.contains("<!doctype plist") { return "xml" }
        if lower.contains("<!doctype html") || lower.contains("<html") { return "html" }

        // 3. JSON / JSONL: only when the first non-space glyph opens a container.
        if let firstNonWS = sample.first(where: { !$0.isWhitespace }),
           firstNonWS == "{" || firstNonWS == "[" {
            if let id = sniffJSON(lines: lines) { return id }
        }

        // 4. Markdown: at least two heading / fence features in the first 10 lines.
        var markdownFeatures = 0
        for line in lines.prefix(10) {
            if line.range(of: "^#{1,6} ", options: .regularExpression) != nil { markdownFeatures += 1 }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { markdownFeatures += 1 }
        }
        if markdownFeatures >= 2 { return "markdown" }

        // 5–10. Compiled / typed languages with distinctive markers. They run
        // before the Python rule because Java / Swift files routinely open
        // with two or more `import` lines, which that rule would claim.
        if probe.isCSharp { return "csharp" }
        if probe.isJava { return "java" }
        if probe.isGo { return "go" }
        if probe.isRust { return "rust" }
        if probe.has(Pattern.lineStartInclude) {
            return probe.hasCppHeader || probe.cppSignalCount >= 1 ? "cpp" : "c"
        }
        if probe.isSwift { return "swift" }

        // 11. ES-module imports (`import X from 'y'`) are JavaScript-only syntax —
        // Python spells it `from y import X` — so this must outrank the Python
        // rule, whose `^import\s` would otherwise claim these lines.
        if countMatchingLines(lines, "^import .* from ") >= 2 { return probe.looksTypeScript ? "typescript" : "javascript" }

        // 12. Python: two or more statement-leading keywords.
        if countMatchingLines(lines, "^(def|class|import|from)\\s") >= 2 { return "python" }

        // 13. JavaScript; refined to TypeScript when clear type syntax appears.
        if countMatchingLines(lines, "^(import .* from|const |let |function )") >= 2 {
            return probe.looksTypeScript ? "typescript" : "javascript"
        }

        // 14. TypeScript without enough JS statement lines: two TS-only signals.
        if probe.typeScriptSignalCount >= 2 { return "typescript" }

        // 15. C++ without an include: two C++-only signals.
        if probe.cppSignalCount >= 2 { return "cpp" }

        // 16. C family: an angle-bracket include anywhere in the sample.
        if sample.range(of: "#include\\s*<", options: .regularExpression) != nil { return "c" }

        // 17. SQL: a statement keyword opening the first non-empty line.
        if let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           firstNonEmpty.range(of: "(?i)^(select|insert|create|update)\\b", options: .regularExpression) != nil {
            return "sql"
        }

        return nil
    }

    // MARK: - Code-rule patterns

    /// Precompiled patterns; `^` / `$` match at line boundaries.
    private enum Pattern {
        static func re(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }

        // C#
        static let csUsingSystem = re(#"^\s*using\s+System(\.[\w.]+)?\s*;"#)
        static let csConsole = re(#"\bConsole\.(WriteLine|Write|ReadLine|ReadKey|Read)\s*\("#)
        static let csMain = re(#"\bstatic\s+(async\s+)?(void|int|Task(<int>)?)\s+Main\s*\("#)
        static let csNamespace = re(#"^\s*namespace\s+[\w.]+\s*[;{]?\s*$"#)
        static let csStringArray = re(#"\bstring\[\]\s+\w+"#)
        static let csProperty = re(#"\{\s*get;\s*((set|init);\s*)?\}"#)
        static let csFileDirective = re(#"^#:(package|sdk|property)\s"#)
        static let csInterpolation = re(#"\$"[^"\n]*\{"#)
        static let csVarStatement = re(#"^\s*var\s+\w+\s*=.*;\s*$"#)

        // Java
        static let javaImport = re(#"^\s*import\s+(static\s+)?javax?\.[\w.]+(\.\*)?\s*;"#)
        static let javaMain = re(#"\bpublic\s+static\s+void\s+main\s*\(\s*String"#)
        static let javaPrint = re(#"\bSystem\.(out|err)\.print"#)
        static let javaPublicClass = re(#"\bpublic\s+((final|abstract)\s+)*class\s+\w+"#)
        static let javaPackage = re(#"^\s*package\s+[\w.]+\s*;"#)

        // Go
        static let goPackage = re(#"^package\s+\w+\s*$"#)
        static let goFunc = re(#"^func\s"#)
        static let goImport = re(#"^import\s*(\(|")"#)
        static let goFmt = re(#"\bfmt\.\w+\("#)

        // Rust
        static let rustFn = re(#"^\s*(pub(\([\w ]+\))?\s+)?(async\s+)?(unsafe\s+)?fn\s+\w+\s*(<[^>\n]*>)?\s*\("#)
        static let rustLetMut = re(#"\blet\s+mut\s"#)
        static let rustMacro = re(#"\b(println|print|eprintln|format|vec|panic|assert|assert_eq|write|writeln)!\s*[(\[{]"#)
        static let rustUse = re(#"^\s*use\s+(std|core|alloc|crate|super|self)::"#)
        static let rustImpl = re(#"^\s*impl\b"#)
        static let rustPub = re(#"^\s*pub\s+(fn|struct|enum|mod|trait|const|static)\b"#)

        // C / C++
        static let lineStartInclude = re(#"^\s*#\s*include\s*<"#)
        static let cppHeader = re(#"^\s*#\s*include\s*<(iostream|vector|string|string_view|map|unordered_map|set|unordered_set|memory|algorithm|fstream|sstream|iomanip|utility|functional|array|deque|list|queue|stack|thread|mutex|chrono|optional|variant|tuple|numeric|iterator|cstdio|cstdlib|cstring|cmath|cstdint|cassert|climits|bits/stdc\+\+\.h)>"#)
        static let cppStd = re(#"\bstd::"#)
        static let cppUsingNamespace = re(#"^\s*using\s+namespace\s+\w+\s*;"#)
        static let cppTemplate = re(#"\btemplate\s*<"#)
        static let cppAccess = re(#"^\s*(public|private|protected)\s*:\s*$"#)
        static let cppStream = re(#"\b(cout|cerr)\s*<<|\bcin\s*>>"#)
        static let cppNullptr = re(#"\bnullptr\b"#)

        // Swift
        static let swiftImport = re(#"^import\s+(Foundation|SwiftUI|UIKit|AppKit|Cocoa|Combine|Dispatch|Darwin|XCTest|Testing|Observation|CoreData|CoreGraphics|PackageDescription)\s*$"#)
        static let swiftArrowFunc = re(#"\bfunc\s+\w+\s*(<[^>\n]*>)?\s*\([^)\n]*\)\s*(async\s+)?(throws\s+|rethrows\s+)?->"#)
        static let swiftGuard = re(#"\bguard\s+(let|var)\s|\bguard\s+.+\belse\s*\{"#)
        static let swiftDecl = re(#"^\s*(let|var)\s+\w+(\s*:\s*[\w\[\]<>?, .]+)?\s*=\s*[^;\n]*$"#)
        static let swiftPrint = re(#"\bprint\("#)
        static let swiftConformance = re(#"^\s*((public|private|internal|fileprivate|final|open)\s+)*(struct|class|enum|protocol|extension|actor)\s+\w+:\s\w"#)
        static let swiftAttribute = re(#"^\s*@(main|MainActor|State|Binding|Published|ObservedObject|StateObject|Environment|objc|discardableResult|escaping|Observable)\b"#)
        static let swiftInterpolation = re(#""[^"\n]*\\\([^)\n]*\)[^"\n]*""#)
        static let pythonDefinition = re(#"^\s*def\s+\w+\s*\(|^from\s+[\w.]+\s+import\s"#)

        // TypeScript
        static let tsAnnotatedBinding = re(#"\b(const|let|var)\s+\w+\s*:\s*(string|number|boolean|any|unknown|bigint|symbol|object|never|void|null|undefined|Array<|Record<|Map<|Set<|Promise<|Partial<|Readonly<)"#)
        static let tsAnnotatedParam = re(#"\bfunction\s*\*?\s*\w*\s*(<[^>()\n]*>)?\s*\(\s*\w+\s*\??\s*:\s*[\w\[\]<>|'"]+|\(\s*\w+\s*\??\s*:\s*(string|number|boolean|any|unknown)\b"#)
        static let tsInterface = re(#"^\s*(export\s+)?(declare\s+)?interface\s+\w+(<[^>\n]*>)?\s*(extends\s+[^{\n]+)?\{"#)
        static let tsTypeAlias = re(#"^\s*(export\s+)?type\s+\w+(<[^>\n]*>)?\s*="#)
        static let tsAsConst = re(#"\bas\s+const\b"#)
        static let tsGenericFunction = re(#"\bfunction\s+\w+\s*<\w+"#)
        static let tsReturnType = re(#"\)\s*:\s*(string|number|boolean|void|any|unknown|never|Promise<[^>\n]*>)\s*(\{|=>)"#)
        static let tsImportType = re(#"^\s*import\s+type\s"#)
        static let tsMember = re(#"^\s*(public|private|protected|readonly)\s+(readonly\s+)?\w+\s*[?!]?:\s*\w"#)
    }

    /// Lazily evaluated signal checks over one sample.
    private struct Probe {
        let text: String
        let range: NSRange

        init(_ sample: String) {
            // Bridge once so every regex scans the same UTF-16 storage.
            let ns = NSString(string: sample)
            text = ns as String
            range = NSRange(location: 0, length: ns.length)
        }

        func has(_ regex: NSRegularExpression) -> Bool {
            regex.firstMatch(in: text, options: [], range: range) != nil
        }

        func count(_ regexes: [NSRegularExpression]) -> Int {
            regexes.reduce(0) { $0 + (has($1) ? 1 : 0) }
        }

        /// `using System;` or `Console.Write…` plus at least one more C# signal.
        var isCSharp: Bool {
            let anchor = has(Pattern.csUsingSystem) || has(Pattern.csConsole)
            guard anchor || has(Pattern.csFileDirective) else { return false }
            return count([Pattern.csUsingSystem, Pattern.csConsole, Pattern.csMain, Pattern.csNamespace,
                          Pattern.csStringArray, Pattern.csProperty, Pattern.csFileDirective,
                          Pattern.csInterpolation, Pattern.csVarStatement]) >= 2
        }

        /// `main(String` or a `java.` import alone; otherwise two signals.
        var isJava: Bool {
            if has(Pattern.javaMain) || has(Pattern.javaImport) { return true }
            return count([Pattern.javaPrint, Pattern.javaPublicClass, Pattern.javaPackage]) >= 2
        }

        /// A `package x` line plus `func` / `import` / `fmt.`.
        var isGo: Bool {
            has(Pattern.goPackage) && (has(Pattern.goFunc) || has(Pattern.goImport) || has(Pattern.goFmt))
        }

        /// An `fn` declaration plus another Rust-only signal.
        var isRust: Bool {
            has(Pattern.rustFn) && count([Pattern.rustLetMut, Pattern.rustMacro, Pattern.rustUse,
                                          Pattern.rustImpl, Pattern.rustPub]) >= 1
        }

        var hasCppHeader: Bool { has(Pattern.cppHeader) }

        var cppSignalCount: Int {
            count([Pattern.cppStd, Pattern.cppUsingNamespace, Pattern.cppTemplate,
                   Pattern.cppAccess, Pattern.cppStream, Pattern.cppNullptr])
        }

        /// Two Swift-only signals, never when Python definitions are present
        /// (PyObjC scripts also `import Foundation`).
        var isSwift: Bool {
            guard !has(Pattern.pythonDefinition) else { return false }
            let prints = has(Pattern.swiftPrint)
            let frameworkImport = has(Pattern.swiftImport)
            var signals = count([Pattern.swiftArrowFunc, Pattern.swiftGuard, Pattern.swiftConformance,
                                 Pattern.swiftAttribute, Pattern.swiftInterpolation])
            if frameworkImport { signals += 1 }
            // `print(` counts only alongside a Swift import or let/var
            // declarations (Python and Go also have `print(`).
            if prints && (frameworkImport || has(Pattern.swiftDecl)) { signals += 1 }
            return signals >= 2
        }

        var typeScriptSignalCount: Int {
            count([Pattern.tsAnnotatedBinding, Pattern.tsAnnotatedParam, Pattern.tsInterface,
                   Pattern.tsTypeAlias, Pattern.tsAsConst, Pattern.tsGenericFunction,
                   Pattern.tsReturnType, Pattern.tsImportType, Pattern.tsMember])
        }

        /// Any clear type syntax (used once the text is already JS-like).
        var looksTypeScript: Bool { typeScriptSignalCount >= 1 }
    }

    // MARK: - JSON / JSONL

    /// Distinguishes a single JSON document from a JSONL stream. A JSON document
    /// parses whole (first 50 lines as a sample); a JSONL stream instead has
    /// every non-empty line parse as its own value, with two or more such lines.
    /// A truncated-and-therefore-unparseable sample simply yields no match.
    private static func sniffJSON(lines: [String]) -> String? {
        let jsonSample = lines.prefix(50).joined(separator: "\n")
        if (try? JSONFormatter.prettyPrint(jsonSample)) != nil { return "json" }

        var total = 0
        var parsed = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            total += 1
            if (try? JSONFormatter.prettyPrint(trimmed)) != nil { parsed += 1 }
        }
        if total >= 2 && parsed == total { return "jsonl" }
        return nil
    }

    // MARK: - Helpers

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func countMatchingLines(_ lines: [String], _ pattern: String) -> Int {
        var count = 0
        for line in lines where line.range(of: pattern, options: .regularExpression) != nil {
            count += 1
        }
        return count
    }

    /// Returns the leading `maxBytes` UTF-8 bytes of `text` as a string. A cut
    /// that lands mid-scalar is tolerated (decoded lossily) — sniffing does not
    /// need byte-exact fidelity at the boundary.
    private static func truncate(_ text: String, toBytes maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        return String(decoding: Array(utf8.prefix(maxBytes)), as: UTF8.self)
    }
}
