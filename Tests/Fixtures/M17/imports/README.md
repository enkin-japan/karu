# M17 T17.13 import-resolution fixtures

Small, hand-written projects read by `ImportResolutionTests` through an
injected project-folder root and interpreter (never the user's folders).

- `python/` — a project folder: packages with `__init__` re-exports and
  `__all__`, relative imports (`.` / `..`), a re-export chain for the depth
  limit, a project module shadowing a venv package, and a fake `.venv`
  (`pyvenv.cfg` + `site-packages` with a `.pyi`-stubbed package, a `.py`-only
  package, a `.pth` file with one path line and one `import` line).
- `interp/` — a fake interpreter install layout (`bin/python3`,
  `lib/python3.13/` stdlib dir and `site-packages`) for lookup path ③.
- `ts/` — a JS / TS project folder: relative imports with `index.ts`,
  `export * from`, `export { … } from`, CommonJS `module.exports` / `require`,
  and `node_modules` with a `types` package, an `exports`-conditions package,
  an `@types/*` package, a `.js`-only package and a scoped package.
- `node_modules/` (here, above `ts/`) — must never be found from `ts/`
  (the upward walk stops at the project folder).
