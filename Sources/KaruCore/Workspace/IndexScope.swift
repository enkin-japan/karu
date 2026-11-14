import Foundation

/// What the project-folder index reads (M17 T17.12, plan §10 "范围控制").
///
/// - **Skipped directories** (any depth, exact name): `.git`, `node_modules`,
///   `.build`, `build`, `dist`, `out`, `target`, `DerivedData`, `__pycache__`,
///   `.venv`, `venv`, `.mypy_cache`, `.pytest_cache`, `.next`, `.cache`.
///   `node_modules` is read on demand by import resolution (T17.13), never
///   indexed. Symbolic links are never followed (no cycles, no escaping the
///   folder).
/// - **`.gitignore`**: the folder's and every nested one, each relative to its
///   own directory; see `GitIgnoreRule` for the supported subset.
/// - **Files**: languages with declaration walkers only (`DeclarationScan`:
///   Python incl. `.pyi`, JS / JSX, TS / TSX, Swift, Go, Rust, Java, C#, C,
///   C++); larger than `maxFileBytes` (2 MB) skipped.
/// - **Cap**: at most `maxFiles` (50,000) indexable files per folder; past it
///   the walk stops and the folder is flagged over the limit.
///
/// Pure value code (no AppKit, no shared mutable state).
public struct IndexScope: Sendable, Equatable {
    public static let defaultMaxFileBytes = 2 * 1024 * 1024
    public static let defaultMaxFiles = 50_000

    public static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "out", "target", "DerivedData",
        "__pycache__", ".venv", "venv", ".mypy_cache", ".pytest_cache", ".next", ".cache",
    ]

    public var maxFileBytes: Int
    public var maxFiles: Int

    public init(maxFileBytes: Int = IndexScope.defaultMaxFileBytes, maxFiles: Int = IndexScope.defaultMaxFiles) {
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    /// The walker language of a file name, or nil when the file is not indexed.
    public static func languageIdentifier(forFileName name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        let id = ext == "pyi" ? "python" : LanguageRegistry.identifier(forExtension: ext)
        guard let id, DeclarationScan.usesWalker(id) else { return nil }
        return id
    }

    public static func isSkippedDirectory(_ name: String) -> Bool {
        skippedDirectoryNames.contains(name)
    }
}

/// One `.gitignore` line (T17.12). Supported subset:
/// - blank lines and `#` comments are ignored; a leading `\#` / `\!` escapes;
///   trailing unescaped spaces are trimmed;
/// - `!pattern` negates (last matching rule wins; a file inside an excluded
///   directory cannot be re-included, as in git, because the walk never
///   enters that directory);
/// - a trailing `/` matches directories only;
/// - a pattern without a `/` (other than a trailing one) matches the name at
///   any depth below the `.gitignore`'s directory; with a leading or inner
///   `/` it is anchored to that directory;
/// - globs: `*` and `?` (never across `/`), `[abc]` / `[a-z]` / `[!a]`,
///   `**` (any run including `/`: `**/x`, `a/**`, `a/**/b`), `\` escapes.
/// Not supported: `core.excludesFile`, `.git/info/exclude`, and git's
/// tracked-file exception (a tracked file matching a pattern is skipped too).
public struct GitIgnoreRule: Sendable, Equatable {
    /// Directory of the `.gitignore` relative to the project folder ("" = root).
    public let base: String
    public let pattern: [UInt8]
    public let negated: Bool
    public let directoryOnly: Bool
    public let anchored: Bool

    /// Parses the lines of a `.gitignore` in `base`.
    public static func parse(_ text: String, base: String) -> [GitIgnoreRule] {
        var rules: [GitIgnoreRule] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = Substring(rawLine)
            // Trailing spaces unless escaped.
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line = line.dropLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line = line.dropFirst()
            } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
                line = line.dropFirst()
            }
            var directoryOnly = false
            while line.hasSuffix("/") {
                directoryOnly = true
                line = line.dropLast()
            }
            var anchored = line.contains("/")
            if line.hasPrefix("/") {
                line = line.drop(while: { $0 == "/" })
                anchored = true
            }
            // `**/name` is "name at any depth" — the unanchored form. With a
            // `/` after it (`**/a/b`) the `**` stays and the glob handles it.
            if line.hasPrefix("**/") {
                let rest = line.drop(while: { $0 == "*" || $0 == "/" })
                if !rest.isEmpty, !rest.contains("/") {
                    line = rest
                    anchored = false
                }
            }
            guard !line.isEmpty else { continue }
            rules.append(GitIgnoreRule(base: base, pattern: Array(line.utf8), negated: negated,
                                       directoryOnly: directoryOnly, anchored: anchored))
        }
        return rules
    }

    /// Whether this rule matches `path` (relative to the project folder);
    /// false when `path` is not below `base`.
    public func matches(_ path: String, isDirectory: Bool) -> Bool {
        if directoryOnly, !isDirectory { return false }
        let relative: Substring
        if base.isEmpty {
            relative = Substring(path)
        } else {
            let prefix = base + "/"
            guard path.hasPrefix(prefix), path.utf8.count > prefix.utf8.count else { return false }
            relative = path.dropFirst(prefix.count)
        }
        if anchored {
            return Glob.match(pattern, Array(relative.utf8))
        }
        let name = relative.split(separator: "/").last.map { Array($0.utf8) } ?? Array(relative.utf8)
        return Glob.match(pattern, name)
    }

    /// The verdict of `rules` (in file order, outer `.gitignore`s first) for
    /// `path`: true = ignored.
    public static func isIgnored(_ path: String, isDirectory: Bool, rules: [GitIgnoreRule]) -> Bool {
        var ignored = false
        for rule in rules where rule.matches(path, isDirectory: isDirectory) {
            ignored = !rule.negated
        }
        return ignored
    }
}

/// Minimal gitignore-style glob over UTF-8 bytes.
enum Glob {
    static func match(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
        match(pattern, 0, text, 0)
    }

    private static let slash = UInt8(ascii: "/")

    private static func match(_ p: [UInt8], _ pi: Int, _ t: [UInt8], _ ti: Int) -> Bool {
        var pi = pi, ti = ti
        while pi < p.count {
            let c = p[pi]
            switch c {
            case UInt8(ascii: "*"):
                if pi + 1 < p.count, p[pi + 1] == UInt8(ascii: "*") {
                    // `**`: any run including `/`. `a/**/b` also matches `a/b`.
                    var next = pi + 2
                    if next < p.count, p[next] == slash {
                        next += 1
                        if match(p, next, t, ti) { return true }
                    }
                    var k = ti
                    while k <= t.count {
                        if match(p, next, t, k) { return true }
                        k += 1
                    }
                    return false
                }
                var k = ti
                while true {
                    if match(p, pi + 1, t, k) { return true }
                    if k >= t.count || t[k] == slash { return false }
                    k += 1
                }
            case UInt8(ascii: "?"):
                guard ti < t.count, t[ti] != slash else { return false }
                pi += 1; ti += 1
            case UInt8(ascii: "["):
                guard ti < t.count, t[ti] != slash else { return false }
                guard let (matched, end) = bracket(p, pi, t[ti]) else {
                    // Unterminated `[`: a literal.
                    guard t[ti] == c else { return false }
                    pi += 1; ti += 1
                    continue
                }
                guard matched else { return false }
                pi = end; ti += 1
            case UInt8(ascii: "\\") where pi + 1 < p.count:
                guard ti < t.count, t[ti] == p[pi + 1] else { return false }
                pi += 2; ti += 1
            default:
                guard ti < t.count, t[ti] == c else { return false }
                pi += 1; ti += 1
            }
        }
        return ti == t.count
    }

    /// Matches `u` against the class starting at `p[start] == "["`; returns
    /// (matched, index after `]`) or nil when unterminated.
    private static func bracket(_ p: [UInt8], _ start: Int, _ u: UInt8) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") {
            negate = true
            i += 1
        }
        var matched = false
        var first = true
        while i < p.count {
            if p[i] == UInt8(ascii: "]"), !first { return (matched != negate, i + 1) }
            first = false
            var lo = p[i]
            if lo == UInt8(ascii: "\\"), i + 1 < p.count { i += 1; lo = p[i] }
            if i + 2 < p.count, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != UInt8(ascii: "]") {
                let hi = p[i + 2]
                if lo <= u && u <= hi { matched = true }
                i += 3
            } else {
                if lo == u { matched = true }
                i += 1
            }
        }
        return nil
    }
}
