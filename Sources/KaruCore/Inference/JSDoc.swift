import Foundation

// M17 T17.11c — JSDoc types for JavaScript (plan §8.1: "JS 文件读取 JSDoc 的
// `@type`、`@param`、`@returns`"), plus basic `@typedef` / `@property` and
// `@template`. Comments are not in the syntax tree: the `/** … */` block
// right before a declaration is read from the text. JSDoc type syntax is
// normalised to TypeScript (`?T` → `T | null`, `!T` → `T`, `T=` → `T`,
// `*` → `any`, `Array.<T>` → `Array<T>`, `Object.<K, V>` → `Record<K, V>`)
// and parsed with `TypeExpr`.

struct JSDocComment: Equatable {
    struct Param: Equatable {
        let name: String
        let type: String
        let isOptional: Bool
    }

    var type: String?
    var params: [Param] = []
    var returns: String?
    var templates: [String] = []
    /// `@typedef {T} Name` (with `@property` lines when `T` is `Object`).
    var typedef: (name: String, type: String?, properties: [Param])?

    static func == (a: JSDocComment, b: JSDocComment) -> Bool {
        a.type == b.type && a.params == b.params && a.returns == b.returns && a.templates == b.templates
            && a.typedef?.name == b.typedef?.name && a.typedef?.type == b.typedef?.type
            && a.typedef?.properties == b.typedef?.properties
    }

    func param(named name: String) -> Param? { params.first { $0.name == name } }

    var isEmpty: Bool { type == nil && params.isEmpty && returns == nil && typedef == nil && templates.isEmpty }

    /// Parses the body of a `/** … */` comment (delimiters included or not).
    init(_ comment: String) {
        var body = comment
        if body.hasPrefix("/**") { body.removeFirst(3) }
        if body.hasSuffix("*/") { body.removeLast(2) }
        // Lines without the leading ` * `.
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }).map { line -> Substring in
            var l = line.drop { $0 == " " || $0 == "\t" }
            if l.hasPrefix("*") { l = l.dropFirst() }
            return l
        }
        // Tags with their following lines (a type in braces may span lines).
        var tags: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("@") { tags.append(trimmed) } else if !tags.isEmpty, !trimmed.isEmpty {
                tags[tags.count - 1] += " " + trimmed
            }
        }
        var typedefProperties: [Param] = []
        for tag in tags {
            var rest = Substring(tag)
            let name = rest.prefix { !$0.isWhitespace && $0 != "{" }
            rest = rest.dropFirst(name.count).drop { $0.isWhitespace }
            let braced = Self.braced(&rest)
            rest = rest.drop { $0.isWhitespace }
            switch name {
            case "@type":
                if let t = braced { type = t }
            case "@param", "@arg", "@argument", "@property", "@prop":
                guard let t = braced, let parsed = Self.paramName(&rest) else { continue }
                var paramName = parsed.0
                let optional = parsed.1
                // `@param {T} opts.key`: a nested property, skipped.
                if paramName.contains(".") { continue }
                if paramName.hasPrefix("...") { paramName.removeFirst(3) }
                let p = Param(name: paramName, type: t, isOptional: optional || t.hasSuffix("="))
                if name == "@property" || name == "@prop" { typedefProperties.append(p) } else { params.append(p) }
            case "@returns", "@return":
                if let t = braced { returns = t }
            case "@template":
                for part in rest.split(whereSeparator: { $0 == "," || $0 == " " }) {
                    let n = part.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty, n.first!.isLetter || n.first == "_" { templates.append(n) }
                }
            case "@typedef":
                let n = rest.prefix { !$0.isWhitespace }
                if !n.isEmpty { typedef = (String(n), braced, []) }
            default:
                continue
            }
        }
        if typedef != nil { typedef!.properties = typedefProperties }
    }

    /// `{…}` at the start of `s` (balanced), consumed; nil when none.
    private static func braced(_ s: inout Substring) -> String? {
        guard s.first == "{" else { return nil }
        var depth = 0
        var end = s.startIndex
        for i in s.indices {
            if s[i] == "{" { depth += 1 }
            if s[i] == "}" {
                depth -= 1
                if depth == 0 { end = i; break }
            }
        }
        guard depth == 0, end > s.startIndex else { return nil }
        let inner = s[s.index(after: s.startIndex)..<end]
        s = s[s.index(after: end)...]
        return inner.trimmingCharacters(in: .whitespaces)
    }

    /// `name`, `[name]` or `[name=default]`.
    private static func paramName(_ s: inout Substring) -> (String, Bool)? {
        if s.first == "[" {
            guard let close = s.firstIndex(of: "]") else { return nil }
            let inner = s[s.index(after: s.startIndex)..<close]
            let n = inner.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
            s = s[s.index(after: close)...]
            return n.isEmpty ? nil : (n, true)
        }
        let n = s.prefix { !$0.isWhitespace }
        s = s.dropFirst(n.count)
        return n.isEmpty ? nil : (String(n), false)
    }

}

/// JSDoc helpers: type normalisation and finding the comment in the text.
enum JSDoc {
    /// A JSDoc type in TypeScript syntax (nil: not understood).
    static func typeScriptText(_ jsdoc: String) -> String? {
        var t = jsdoc.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t == "*" || t == "?" { return "any" }
        if t.hasSuffix("=") { t.removeLast() }
        if t.hasPrefix("...") { t = String(t.dropFirst(3)) + "[]" }
        var nullable = false
        if t.hasPrefix("?") { t.removeFirst(); nullable = true }
        if t.hasPrefix("!") { t.removeFirst() }
        if t.hasSuffix("?"), !t.hasSuffix("?)") { t.removeLast(); nullable = true }
        t = t.replacingOccurrences(of: ".<", with: "<")
        if t.hasPrefix("Object<") { t = "Record<" + t.dropFirst("Object<".count) }
        // `function(…)` types are not modelled.
        if t.hasPrefix("function(") || t.contains("function(") { return nil }
        if t == "Object" { return "object" }
        if t.hasPrefix("("), t.hasSuffix(")"), !t.contains("=>") { t = String(t.dropFirst().dropLast()) }
        return nullable ? t + " | null" : t
    }

    /// The `/** … */` comment ending right before `offset` (only whitespace
    /// between), or nil.
    static func comment(before offset: Int, in text: NSString) -> String? {
        var k = offset - 1
        while k >= 0 {
            let u = text.character(at: k)
            if u == 32 || u == 9 || u == 10 || u == 13 { k -= 1; continue }
            break
        }
        guard k >= 3, text.character(at: k) == 47, text.character(at: k - 1) == 42 else { return nil }   // `*/`
        // Back to the `/**` opener (bounded).
        let end = k + 1
        var j = k - 2
        let limit = max(0, end - 16 * 1024)
        while j >= limit + 1 {
            if text.character(at: j) == 42, text.character(at: j - 1) == 47 {               // `/*`
                guard j + 1 < end, text.character(at: j + 1) == 42 else { return nil }      // `/**`
                return text.substring(with: NSRange(location: j - 1, length: end - (j - 1)))
            }
            j -= 1
        }
        return nil
    }
}
