import Foundation

/// Matches one typed prefix against candidate names (M17 T17.5, plan
/// §5.3.2): exact-case prefix > case-insensitive prefix > word-start
/// initials > bounded loose fuzzy, recording the matched UTF-16 ranges of the
/// name for T17.6's highlighting.
///
/// - **Word parts** (`partStarts`): a name splits at `_` / `-` / `$`
///   separators, lower→upper humps (`userDisplay`), the last capital of an
///   upper run followed by lowercase (`URLValue` → `URL`, `Value`) and
///   letter/digit changes (`utf8Name` → `utf`, `8`, `Name`); leading
///   separators are skipped.
/// - **Word start**: the first typed character matches the first part's
///   first character; each further one either continues the current part or
///   starts the *next* part (no part is skipped): `udn` → `userDisplayName`,
///   `user_display_name`; `usdn` → `userDisplayName`.
/// - **Fuzzy** (only offered for bounded sources): the first typed character
///   at any part start, the rest an ordered subsequence after it.
///
/// Case-insensitive comparisons fold per UTF-16 unit (`CaseFold`). Every
/// match of a longer prefix implies a match of its shorter prefixes in the
/// same or a better tier, which lets the engine refilter a previous result
/// while the prefix grows (plan §5.3.6).
struct CandidateMatcher: Sendable {
    let query: [UInt16]
    let folded: [UInt16]

    /// Longest prefix the word-start / fuzzy tiers try (longer: prefix tiers only).
    static let maximumLooseLength = 48

    init(_ prefix: String) {
        query = Array(prefix.utf16)
        folded = query.map(CaseFold.fold)
    }

    var isEmpty: Bool { query.isEmpty }

    func match(_ name: String, allowFuzzy: Bool) -> (tier: MatchTier, ranges: [NSRange])? {
        match(units: Array(name.utf16), allowFuzzy: allowFuzzy)
    }

    func match(units name: [UInt16], allowFuzzy: Bool) -> (tier: MatchTier, ranges: [NSRange])? {
        let q = query.count
        guard q > 0 else { return (.exactPrefix, []) }
        guard name.count >= q else {
            return q <= Self.maximumLooseLength ? loose(name, allowFuzzy: allowFuzzy) : nil
        }
        var exact = true
        var insensitive = true
        for i in 0..<q {
            let u = name[i]
            if u != query[i] {
                exact = false
                if CaseFold.fold(u) != folded[i] {
                    insensitive = false
                    break
                }
            }
        }
        let whole = [NSRange(location: 0, length: q)]
        if exact { return (.exactPrefix, whole) }
        if insensitive { return (.caseInsensitivePrefix, whole) }
        return q <= Self.maximumLooseLength ? loose(name, allowFuzzy: allowFuzzy) : nil
    }

    private func loose(_ name: [UInt16], allowFuzzy: Bool) -> (tier: MatchTier, ranges: [NSRange])? {
        let parts = Self.partStarts(name)
        guard !parts.isEmpty else { return nil }
        if let positions = wordStart(name, parts) { return (.wordStart, Self.ranges(positions)) }
        if allowFuzzy, let positions = fuzzy(name, parts) { return (.fuzzy, Self.ranges(positions)) }
        return nil
    }

    // MARK: - Parts

    @inline(__always) private static func isSeparator(_ u: UInt16) -> Bool { u == 95 || u == 45 || u == 36 }
    @inline(__always) private static func isDigit(_ u: UInt16) -> Bool { u >= 48 && u <= 57 }
    @inline(__always) private static func isUpper(_ u: UInt16) -> Bool { CaseFold.fold(u) != u }

    /// Indices where word parts begin.
    static func partStarts(_ name: [UInt16]) -> [Int] {
        var starts: [Int] = []
        var i = 0
        while i < name.count, isSeparator(name[i]) { i += 1 }
        guard i < name.count else { return [] }
        starts.append(i)
        var j = i + 1
        while j < name.count {
            let c = name[j]
            let p = name[j - 1]
            defer { j += 1 }
            if isSeparator(c) { continue }
            if isSeparator(p) { starts.append(j); continue }
            let cDigit = isDigit(c)
            let pDigit = isDigit(p)
            if cDigit != pDigit { starts.append(j); continue }
            if cDigit { continue }
            let cUpper = isUpper(c)
            let pUpper = isUpper(p)
            if cUpper, !pUpper { starts.append(j); continue }
            if cUpper, pUpper, j + 1 < name.count {
                let n = name[j + 1]
                if !isUpper(n), !isDigit(n), !isSeparator(n) { starts.append(j) }
            }
        }
        return starts
    }

    // MARK: - Word start

    private func wordStart(_ name: [UInt16], _ parts: [Int]) -> [Int]? {
        let q = folded.count
        guard CaseFold.fold(name[parts[0]]) == folded[0] else { return nil }
        // Part index of each position, and each part's end.
        var partEnd = [Int](repeating: name.count, count: parts.count)
        for k in 0..<parts.count {
            var end = k + 1 < parts.count ? parts[k + 1] : name.count
            // Trailing separators do not belong to a part.
            while end > parts[k] + 1, Self.isSeparator(name[end - 1]) { end -= 1 }
            partEnd[k] = end
        }
        var failed = Set<Int>()   // (qi, position) pairs known to fail
        var positions = [Int](repeating: 0, count: q)
        positions[0] = parts[0]
        // dfs(qi, part, next): query[qi...] with `next` the following
        // position in part `part`.
        func dfs(_ qi: Int, _ part: Int, _ next: Int) -> Bool {
            if qi == q { return true }
            let key = qi * (name.count + 1) + next
            if failed.contains(key) { return false }
            if next < partEnd[part], CaseFold.fold(name[next]) == folded[qi] {
                positions[qi] = next
                if dfs(qi + 1, part, next + 1) { return true }
            }
            if part + 1 < parts.count {
                let start = parts[part + 1]
                if CaseFold.fold(name[start]) == folded[qi] {
                    positions[qi] = start
                    if dfs(qi + 1, part + 1, start + 1) { return true }
                }
            }
            failed.insert(key)
            return false
        }
        return dfs(1, 0, parts[0] + 1) ? positions : nil
    }

    // MARK: - Fuzzy

    private func fuzzy(_ name: [UInt16], _ parts: [Int]) -> [Int]? {
        let q = folded.count
        for start in parts where CaseFold.fold(name[start]) == folded[0] {
            var positions = [start]
            var j = start + 1
            var qi = 1
            while qi < q, j < name.count {
                if CaseFold.fold(name[j]) == folded[qi] {
                    positions.append(j)
                    qi += 1
                }
                j += 1
            }
            if qi == q { return positions }
        }
        return nil
    }

    /// Ascending positions merged into ranges.
    static func ranges(_ positions: [Int]) -> [NSRange] {
        var out: [NSRange] = []
        for p in positions {
            if let last = out.last, NSMaxRange(last) == p {
                out[out.count - 1].length += 1
            } else {
                out.append(NSRange(location: p, length: 1))
            }
        }
        return out
    }
}
