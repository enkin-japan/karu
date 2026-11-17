import Foundation

/// One language the sniffer considers plausible for a text.
public struct LanguageGuess: Equatable, Sendable {
    /// A `LanguageDefinition.identifier` (e.g. `"python"`).
    public let identifier: String
    /// Evidence score; only the order within one ranking is meaningful.
    public let score: Double

    public init(identifier: String, score: Double) {
        self.identifier = identifier
        self.score = score
    }
}

/// What the sniffer makes of a text: the language it would set on its own, and
/// the languages worth offering when it would not.
public struct LanguageRanking: Equatable, Sendable {
    /// The language clear enough to apply without asking, or `nil`.
    public let confident: String?
    /// Up to three plausible languages, best first. Empty when the text shows
    /// no code evidence. When `confident` is set it is the first entry.
    public let candidates: [LanguageGuess]

    public init(confident: String?, candidates: [LanguageGuess]) {
        self.confident = confident
        self.candidates = candidates
    }

    public static let none = LanguageRanking(confident: nil, candidates: [])
}

/// Content-based language detection, used as a fallback when a file's extension
/// resolves to no registered language (or the document has no name yet — pasted
/// / untitled buffers), and by "run" when an Auto-mode buffer is still Plain
/// Text. Pure logic, no AppKit, so it stays trivially testable.
///
/// Only the leading 8 KB of text is inspected: sniffing runs on every paste /
/// edit of an untitled buffer, so the cost is capped regardless of document
/// size (ARCHITECTURE.md §1 performance budget).
///
/// Decision structure (LEDGER「无扩展名文本的语言识别改造」, after VS Code):
/// 1. Unambiguous markers at the start of the document decide on their own: a
///    shebang, `<?xml` / a plist doctype, an HTML doctype or `<html`, and text
///    that parses as JSON or JSONL.
/// 2. Otherwise every language accumulates weighted evidence from a single pass
///    over the lines (`LanguageEvidenceScanner`, weights in `SniffFeature`).
/// 3. A language is `confident` only when its score clears its own threshold
///    and leads the runner-up by a margin; collision-prone languages (YAML,
///    TOML, CSS, SQL, Markdown) need more. Close families are refined after
///    the decision: TypeScript needs real type syntax (else JavaScript), C++
///    needs C++-only syntax (else C), TypeScript JSX needs JSX.
/// 4. Languages above a lower threshold are offered as `candidates`. Getting a
///    language wrong is worse than not detecting one, so doubt yields
///    candidates without `confident`.
public enum LanguageSniffer {
    /// Ranks the languages `text` could be. Callers that only want a language
    /// to apply automatically use `sniff`; callers that can ask the user offer
    /// `candidates` when `confident` is `nil`.
    public static func rank(_ text: String) -> LanguageRanking {
        let sample = truncate(text, toBytes: sampleByteLimit)
        guard sample.contains(where: { !$0.isWhitespace }) else { return .none }
        if let marker = markerLanguage(sample) {
            return LanguageRanking(confident: marker, candidates: [LanguageGuess(identifier: marker, score: 100)])
        }
        var scanner = LanguageEvidenceScanner(sample)
        scanner.scan()
        return decide(scanner, shebangHint: shebangHint(sample))
    }

    /// Returns the language identifier (matching `LanguageDefinition.identifier`,
    /// e.g. `"python"`) clear enough to apply without asking, or `nil`.
    public static func sniff(_ text: String) -> String? {
        rank(text).confident
    }

    /// Maximum number of leading bytes inspected.
    private static let sampleByteLimit = 8 * 1024

    /// Minimum lead over the runner-up, absolute and relative to the top score.
    private static let marginAbsolute = 2.5
    private static let marginRelative = 0.3

    // MARK: - Markers

    private static func markerLanguage(_ sample: String) -> String? {
        let firstLine = sample.prefix { $0 != "\n" }
        if firstLine.hasPrefix("#!") {
            let line = String(firstLine)
            if line.contains("python") { return "python" }
            if matches(line, "\\b(ts-node|tsx)\\b") { return typeScriptFlavour(sample) }
            if matches(line, "\\bswift\\b") { return "swift" }
            if matches(line, "\\b(deno|bun)\\b") {
                return looksTypeScript(sample) ? typeScriptFlavour(sample) : "javascript"
            }
            if matches(line, "\\b(bash|zsh|sh)\\b") { return "bash" }
            if line.contains("node") { return "javascript" }
        }

        // Markup markers count only at the start of the document: the first
        // non-blank line, at column 0 (an indented `<html>` is embedded text).
        let head = sample.drop { $0 == "\n" || $0 == "\r" || $0 == "\u{FEFF}" }.prefix(64).lowercased()
        if head.hasPrefix("<?xml") || head.hasPrefix("<!doctype plist") { return "xml" }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return "html" }

        // JSON / JSONL: only when the first non-space glyph opens a container.
        if let first = sample.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
            return sniffJSON(lines: sample.components(separatedBy: "\n"))
        }
        return nil
    }

    /// An unknown interpreter in a shebang still says "script": a light hint
    /// toward the shells, nothing more.
    private static func shebangHint(_ sample: String) -> Bool {
        sample.hasPrefix("#!")
    }

    private static func looksTypeScript(_ sample: String) -> Bool {
        var scanner = LanguageEvidenceScanner(sample)
        scanner.scan()
        return typeScriptEvidence(scanner) >= 2
    }

    private static func typeScriptFlavour(_ sample: String) -> String {
        var scanner = LanguageEvidenceScanner(sample)
        scanner.scan()
        return scanner.jsxSeen ? "typescriptreact" : "typescript"
    }

    // MARK: - Decision

    /// Per-language scores: each feature's capped count times its weights.
    static func scores(_ scanner: LanguageEvidenceScanner, shebangHint: Bool) -> [Double] {
        var scores = [Double](repeating: 0, count: SniffLanguage.allCases.count)
        for feature in SniffFeature.allCases {
            let n = scanner.count(feature)
            guard n > 0 else { continue }
            let effect = SniffEffects.table[feature.rawValue]
            let counted = Double(min(n, effect.cap))
            for (language, weight) in effect.weights { scores[language.rawValue] += counted * weight }
        }
        if shebangHint { scores[SniffLanguage.bash.rawValue] += 1 }
        return scores
    }

    /// Diagnostic for tuning: the features found in `text` and the resulting
    /// scores, one line each. Not used by the app.
    static func evidenceReport(_ text: String) -> String {
        let sample = truncate(text, toBytes: sampleByteLimit)
        var scanner = LanguageEvidenceScanner(sample)
        scanner.scan()
        let features = SniffFeature.allCases.filter { scanner.count($0) > 0 }
            .map { "\($0)×\(scanner.count($0))" }.joined(separator: " ")
        let scores = scores(scanner, shebangHint: shebangHint(sample))
        let ranked = SniffLanguage.allCases.filter { scores[$0.rawValue] != 0 }
            .sorted { scores[$0.rawValue] > scores[$1.rawValue] }
            .map { "\($0)=\(String(format: "%.1f", scores[$0.rawValue]))" }.joined(separator: " ")
        return "features: \(features)\nscores: \(ranked)"
    }

    private static func decide(_ scanner: LanguageEvidenceScanner, shebangHint: Bool) -> LanguageRanking {
        let scores = scores(scanner, shebangHint: shebangHint)

        // Best first; ties keep the declaration order.
        let order = SniffLanguage.allCases.sorted { lhs, rhs in
            let l = scores[lhs.rawValue], r = scores[rhs.rawValue]
            return l != r ? l > r : lhs.rawValue < rhs.rawValue
        }
        let top = order[0]
        let topScore = scores[top.rawValue]
        let runnerUp = max(scores[order[1].rawValue], 0)
        let lead = topScore - runnerUp
        let isConfident = topScore >= top.confidentThreshold
            && lead >= max(marginAbsolute, marginRelative * topScore)

        var candidates: [LanguageGuess] = []
        for language in order where candidates.count < 3 {
            let score = scores[language.rawValue]
            guard score >= language.candidateThreshold else { continue }
            let identifier = refine(language, scanner)
            candidates.append(LanguageGuess(identifier: identifier, score: (score * 100).rounded() / 100))
        }
        guard isConfident, let first = candidates.first else {
            return LanguageRanking(confident: nil, candidates: candidates)
        }
        return LanguageRanking(confident: first.identifier, candidates: candidates)
    }

    /// The family member a family entry stands for.
    private static func refine(_ language: SniffLanguage, _ scanner: LanguageEvidenceScanner) -> String {
        switch language {
        case .c:
            let cpp = SniffFeature.cppOnly.contains { scanner.count($0) > 0 } || scanner.count(.braceClass) > 0
                && scanner.count(.cInclude) > 0
            return cpp ? "cpp" : "c"
        case .javascript:
            guard typeScriptEvidence(scanner) >= 2 else { return "javascript" }
            return scanner.jsxSeen ? "typescriptreact" : "typescript"
        default:
            return String(describing: language)
        }
    }

    private static func typeScriptEvidence(_ scanner: LanguageEvidenceScanner) -> Double {
        SniffFeature.typeScriptOnly.reduce(0) { sum, entry in
            sum + Double(min(scanner.count(entry.0), 2)) * entry.1
        }
    }

    // MARK: - JSON / JSONL

    /// Distinguishes a single JSON document from a JSONL stream. A JSON document
    /// parses whole (first 50 lines as a sample); a JSONL stream instead has
    /// every non-empty line parse as its own value, with two or more such lines.
    /// A truncated-and-therefore-unparseable sample falls through to scoring.
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

    /// Returns the leading `maxBytes` UTF-8 bytes of `text` as a string. A cut
    /// that lands mid-scalar is tolerated (decoded lossily) — sniffing does not
    /// need byte-exact fidelity at the boundary.
    private static func truncate(_ text: String, toBytes maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        return String(decoding: Array(utf8.prefix(maxBytes)), as: UTF8.self)
    }
}
