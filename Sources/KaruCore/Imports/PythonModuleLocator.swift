import Foundation

/// Where a dotted Python module lives on disk (M17 T17.13, plan §9).
struct PythonModuleLocation: Sendable, Equatable {
    let dotted: String
    /// `__init__.py[i]` / `name.py[i]`; nil for a namespace package.
    let file: String?
    let isPackage: Bool
    /// Where submodules are searched (several for a namespace package).
    let packageDirectories: [String]
    /// The search root the top-level package came from.
    let root: PythonSearchRoot

    var isStub: Bool { file?.hasSuffix(".pyi") ?? false }
}

/// Finds modules in a context's search roots (background queue only).
///
/// - **Root order** (plan §9): ① project root, ② venv site-packages (and
///   its `.pth` paths), ③ the interpreter's stdlib and site-packages. The
///   first root holding a *regular* module or package wins; a namespace
///   package (a directory without `__init__`) is used only when no root has
///   a regular one — as Python's import system does. Standard-library names
///   never get here: they resolve to the built-in typeshed tables first
///   (`ImportService`).
/// - **Stubs first**: in each directory `name-stubs/` (PEP 561, site-packages
///   only), `name/__init__.pyi`, `name.pyi`, then `name/__init__.py`,
///   `name.py`.
enum PythonModuleLocator {
    static func locate(_ dotted: String, in paths: PythonSearchPaths, fs: ImportFileSystem) -> PythonModuleLocation? {
        let parts = dotted.split(separator: ".").map(String.init)
        guard let head = parts.first, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var current: PythonModuleLocation?
        var namespace: [String] = []
        var namespaceRoot: PythonSearchRoot?
        for root in paths.roots {
            if let found = candidate(in: root.path, name: head, dotted: head, allowStubPackage: root.isSitePackages,
                                     root: root, fs: fs) {
                current = found
                break
            }
            let dir = ImportPath.join(root.path, head)
            if fs.isDirectory(dir) {
                namespace.append(dir)
                if namespaceRoot == nil { namespaceRoot = root }
            }
        }
        if current == nil, let root = namespaceRoot {
            current = PythonModuleLocation(dotted: head, file: nil, isPackage: true, packageDirectories: namespace, root: root)
        }
        guard var location = current else { return nil }
        var prefix = head
        for part in parts.dropFirst() {
            guard location.isPackage else { return nil }
            prefix += "." + part
            var next: PythonModuleLocation?
            var dirs: [String] = []
            for dir in location.packageDirectories {
                if let found = candidate(in: dir, name: part, dotted: prefix, allowStubPackage: false,
                                         root: location.root, fs: fs) {
                    next = found
                    break
                }
                let sub = ImportPath.join(dir, part)
                if fs.isDirectory(sub) { dirs.append(sub) }
            }
            if next == nil, !dirs.isEmpty {
                next = PythonModuleLocation(dotted: prefix, file: nil, isPackage: true, packageDirectories: dirs,
                                            root: location.root)
            }
            guard let found = next else { return nil }
            location = found
        }
        return location
    }

    /// A regular module or package `name` directly in `dir`.
    private static func candidate(in dir: String, name: String, dotted: String, allowStubPackage: Bool,
                                  root: PythonSearchRoot, fs: ImportFileSystem) -> PythonModuleLocation? {
        if allowStubPackage {
            let stubs = ImportPath.join(dir, name + "-stubs")
            let initStub = ImportPath.join(stubs, "__init__.pyi")
            if fs.isFile(initStub) {
                return PythonModuleLocation(dotted: dotted, file: initStub, isPackage: true, packageDirectories: [stubs], root: root)
            }
        }
        let package = ImportPath.join(dir, name)
        let initStub = ImportPath.join(package, "__init__.pyi")
        if fs.isFile(initStub) {
            return PythonModuleLocation(dotted: dotted, file: initStub, isPackage: true, packageDirectories: [package], root: root)
        }
        let moduleStub = ImportPath.join(dir, name + ".pyi")
        if fs.isFile(moduleStub) {
            return PythonModuleLocation(dotted: dotted, file: moduleStub, isPackage: false, packageDirectories: [], root: root)
        }
        let initSource = ImportPath.join(package, "__init__.py")
        if fs.isFile(initSource) {
            return PythonModuleLocation(dotted: dotted, file: initSource, isPackage: true, packageDirectories: [package], root: root)
        }
        let moduleSource = ImportPath.join(dir, name + ".py")
        if fs.isFile(moduleSource) {
            return PythonModuleLocation(dotted: dotted, file: moduleSource, isPackage: false, packageDirectories: [], root: root)
        }
        return nil
    }

    /// The absolute module a relative import names: `level` dots in a module
    /// `dotted` (a package when `isPackage`), then `name` (may be empty).
    /// Nil when it climbs above the top level; "" for the top level itself
    /// (`from . import x` in a module at a search root: `x` is top-level).
    static func absolute(level: Int, name: String, from dotted: String, isPackage: Bool) -> String? {
        guard level > 0 else { return name }
        var base = dotted.isEmpty ? [] : dotted.split(separator: ".").map(String.init)
        if !isPackage {
            guard !base.isEmpty else { return nil }
            base.removeLast()
        }
        guard level - 1 <= base.count else { return nil }
        base.removeLast(level - 1)
        if !name.isEmpty { base.append(contentsOf: name.split(separator: ".").map(String.init)) }
        return base.joined(separator: ".")
    }
}
