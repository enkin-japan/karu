import Foundation

/// Finds the file a JS / TS module specifier names (M17 T17.13, plan §9,
/// the JS / TS row). Background queue only; reads files through the
/// injected `ImportFileSystem`, never above the project folder.
///
/// - **Relative** (`./x`, `../x`): against the importing file's directory;
///   an explicit extension first (a `.js` / `.mjs` / `.cjs` specifier also
///   tries the TypeScript source next to it, as `tsc` does), then
///   `x.ts`, `.tsx`, `.d.ts`, `.js`, `.jsx`, `.mjs`, `.cjs`, then the
///   directory: its `package.json` (`types` / `typings` / `main`), then
///   `index.*`.
/// - **Packages** (`pkg`, `pkg/sub`, `@scope/pkg/sub`): `node_modules` from
///   the importing file's directory upward, stopping at the project folder.
///   In each `node_modules`: the package's own declarations, then
///   `@types/<pkg>` (`@types/scope__pkg`), then the package's JavaScript.
///   `package.json`: `exports` (conditions `types`, `import`, `require`,
///   `default`; subpaths, `./*` patterns), else `types` / `typings`, else
///   `main`; a JavaScript target prefers its `.d.ts` sibling.
enum ScriptModuleLocator {
    static let sourceExtensions = [".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mjs", ".cjs"]
    static let typeScriptExtensions = [".ts", ".tsx", ".d.ts", ".mts", ".cts", ".d.mts", ".d.cts"]
    static let conditions = ["types", "import", "require", "default"]

    /// The file `specifier` names when imported from `importer`, inside `projectRoot`.
    static func resolve(_ specifier: String, from importer: String, projectRoot: String,
                        fs: ImportFileSystem) -> String? {
        guard !specifier.isEmpty else { return nil }
        if specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier == "." || specifier == ".." {
            let target = ImportPath.normalized(ImportPath.join(ImportPath.parent(importer), specifier))
            guard ImportPath.isInside(target, projectRoot) else { return nil }
            return file(target, fs: fs, typeScriptOnly: false) ?? directory(target, fs: fs, typeScriptOnly: false)
        }
        guard !specifier.hasPrefix("/"), !specifier.contains(":") || specifier.hasPrefix("@") else { return nil }
        let (package, subpath) = splitPackage(specifier)
        guard !package.isEmpty else { return nil }
        var dir = ImportPath.parent(importer)
        while ImportPath.isInside(dir, projectRoot) {
            let modules = ImportPath.join(dir, "node_modules")
            if fs.isDirectory(modules) {
                let packageDir = ImportPath.join(modules, package)
                let typesDir = ImportPath.join(ImportPath.join(modules, "@types"), typesName(package))
                let hasPackage = fs.isDirectory(packageDir)
                let hasTypes = fs.isDirectory(typesDir)
                if hasPackage, let found = inPackage(packageDir, subpath, fs: fs, typeScriptOnly: true) { return found }
                if hasTypes, let found = inPackage(typesDir, subpath, fs: fs, typeScriptOnly: true) { return found }
                if hasPackage, let found = inPackage(packageDir, subpath, fs: fs, typeScriptOnly: false) { return found }
                if hasPackage || hasTypes { return nil }
            }
            if dir == projectRoot || dir == "/" { break }
            dir = ImportPath.parent(dir)
        }
        return nil
    }

    /// `@scope/pkg/a/b` → (`@scope/pkg`, `a/b`); `pkg/a` → (`pkg`, `a`).
    static func splitPackage(_ specifier: String) -> (String, String) {
        let parts = specifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if specifier.hasPrefix("@") {
            guard parts.count >= 2 else { return ("", "") }
            return (parts[0] + "/" + parts[1], parts.dropFirst(2).joined(separator: "/"))
        }
        return (parts[0], parts.dropFirst().joined(separator: "/"))
    }

    /// `@scope/pkg` → `scope__pkg` (the DefinitelyTyped name).
    static func typesName(_ package: String) -> String {
        guard package.hasPrefix("@") else { return package }
        return String(package.dropFirst()).replacingOccurrences(of: "/", with: "__")
    }

    static func isTypeScript(_ path: String) -> Bool { typeScriptExtensions.contains { path.hasSuffix($0) } }

    // MARK: - Files and directories

    /// `base` as a file: as written, then with each extension.
    private static func file(_ base: String, fs: ImportFileSystem, typeScriptOnly: Bool) -> String? {
        func accept(_ path: String) -> String? {
            guard fs.isFile(path), !typeScriptOnly || isTypeScript(path) else { return nil }
            return path
        }
        // `./x.js` written in TypeScript ESM style names `x.ts`.
        for (js, ts) in [(".js", [".ts", ".tsx", ".d.ts"]), (".jsx", [".tsx"]), (".mjs", [".mts", ".d.mts"]),
                         (".cjs", [".cts", ".d.cts"])] where base.hasSuffix(js) {
            let stem = String(base.dropLast(js.count))
            for ext in ts { if let found = accept(stem + ext) { return found } }
        }
        if sourceExtensions.contains(where: { base.hasSuffix($0) }) || [".mts", ".cts", ".json"].contains(where: { base.hasSuffix($0) }) {
            return accept(base)
        }
        for ext in sourceExtensions { if let found = accept(base + ext) { return found } }
        return nil
    }

    /// `dir` as a directory: its `package.json` entry, then `index.*`.
    private static func directory(_ dir: String, fs: ImportFileSystem, typeScriptOnly: Bool) -> String? {
        guard fs.isDirectory(dir) else { return nil }
        if let manifest = packageJSON(dir, fs: fs) {
            for key in ["types", "typings", "main"] {
                guard let entry = manifest[key] as? String, !entry.isEmpty else { continue }
                let target = ImportPath.normalized(ImportPath.join(dir, entry))
                if let found = declarationFirst(target, fs: fs, typeScriptOnly: typeScriptOnly) { return found }
            }
        }
        return file(ImportPath.join(dir, "index"), fs: fs, typeScriptOnly: typeScriptOnly)
    }

    /// A package entry: its declaration sibling first (`x.js` → `x.d.ts`),
    /// then the file, then the path as a directory.
    private static func declarationFirst(_ target: String, fs: ImportFileSystem, typeScriptOnly: Bool) -> String? {
        for (js, dts) in [(".js", ".d.ts"), (".mjs", ".d.mts"), (".cjs", ".d.cts")] where target.hasSuffix(js) {
            let sibling = String(target.dropLast(js.count)) + dts
            if fs.isFile(sibling) { return sibling }
        }
        if let found = file(target, fs: fs, typeScriptOnly: typeScriptOnly) { return found }
        return directory(target, fs: fs, typeScriptOnly: typeScriptOnly)
    }

    /// A `package.json` of this size or more is ignored, and never read (R09).
    static let manifestByteLimit = 1 << 20

    private static func packageJSON(_ dir: String, fs: ImportFileSystem) -> [String: Any]? {
        guard let data = fs.contents(ImportPath.join(dir, "package.json"), maxBytes: manifestByteLimit - 1) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `subpath` ("" for the package itself) inside package directory `dir`.
    private static func inPackage(_ dir: String, _ subpath: String, fs: ImportFileSystem, typeScriptOnly: Bool) -> String? {
        let manifest = packageJSON(dir, fs: fs)
        if let exports = manifest?["exports"] {
            // `exports` is authoritative when present.
            guard let target = exportTarget(exports, subpath: subpath.isEmpty ? "." : "./" + subpath) else { return nil }
            let path = ImportPath.normalized(ImportPath.join(dir, target))
            guard ImportPath.isInside(path, dir) else { return nil }
            return declarationFirst(path, fs: fs, typeScriptOnly: typeScriptOnly)
        }
        if subpath.isEmpty {
            if let manifest {
                for key in ["types", "typings", "main"] {
                    guard let entry = manifest[key] as? String, !entry.isEmpty else { continue }
                    if key == "main", typeScriptOnly {
                        // A JavaScript main only counts through its declaration.
                        let target = ImportPath.normalized(ImportPath.join(dir, entry))
                        if let found = declarationFirst(target, fs: fs, typeScriptOnly: true) { return found }
                        continue
                    }
                    let target = ImportPath.normalized(ImportPath.join(dir, entry))
                    if let found = declarationFirst(target, fs: fs, typeScriptOnly: typeScriptOnly) { return found }
                }
            }
            return file(ImportPath.join(dir, "index"), fs: fs, typeScriptOnly: typeScriptOnly)
        }
        let target = ImportPath.normalized(ImportPath.join(dir, subpath))
        return file(target, fs: fs, typeScriptOnly: typeScriptOnly) ?? directory(target, fs: fs, typeScriptOnly: typeScriptOnly)
    }

    /// The target of `subpath` (`.` or `./x`) in an `exports` value.
    static func exportTarget(_ exports: Any, subpath: String) -> String? {
        if let map = exports as? [String: Any], map.keys.contains(where: { $0.hasPrefix(".") }) {
            if let value = map[subpath] { return conditionTarget(value) }
            // `./*` patterns: the longest matching prefix.
            var best: (prefix: String, suffix: String, value: Any)?
            for (key, value) in map {
                guard let star = key.firstIndex(of: "*") else { continue }
                let prefix = String(key[..<star]), suffix = String(key[key.index(after: star)...])
                guard subpath.hasPrefix(prefix), subpath.hasSuffix(suffix), subpath.count >= prefix.count + suffix.count else { continue }
                if best == nil || prefix.count > best!.prefix.count { best = (prefix, suffix, value) }
            }
            guard let best, let target = conditionTarget(best.value) else { return nil }
            let middle = String(subpath.dropFirst(best.prefix.count).dropLast(best.suffix.count))
            return target.replacingOccurrences(of: "*", with: middle)
        }
        return subpath == "." ? conditionTarget(exports) : nil
    }

    /// A string, the first matching condition (`types` → `import` →
    /// `require` → `default`), or the first resolvable array element.
    static func conditionTarget(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let array = value as? [Any] {
            for item in array { if let t = conditionTarget(item) { return t } }
            return nil
        }
        guard let map = value as? [String: Any] else { return nil }
        for condition in conditions { if let v = map[condition], let t = conditionTarget(v) { return t } }
        return nil
    }

    /// The dialect a module file parses with.
    static func dialect(of path: String) -> SyntaxDialect {
        if path.hasSuffix(".tsx") { return .typescriptReact }
        if isTypeScript(path) { return .typescript }
        return .javascript
    }
}
