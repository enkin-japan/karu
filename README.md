# Karu（軽）

**English** | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md)

A deliberately tiny, native plain-text editor for macOS. **~30 MB resident
memory, cold start under a second.**

Karu (軽, "light" in Japanese) is built on one belief: a text editor should cost
almost nothing. Every feature is admitted against a hard memory budget, and
features that can't fit are rejected — the way kei cars stay light because the
rules say they must.

## Features

- Syntax highlighting for 21 languages: Markdown, JSON, JSONL, YAML, TOML,
  Python, HTML, CSS, JavaScript, TypeScript, TSX, C, C++, C#, Java, Go, Rust,
  Swift, Bash, SQL, XML (plist files are handled as XML). Only the visible part
  of the file is colored. Colors follow VS Code's Dark Modern and Light Modern
  themes. Embedded code is highlighted in its own language: `<script>` and
  `<style>` in HTML, fenced code in Markdown, JSX and TSX
- Code folding, line numbers, VS Code-style indent rainbow
- One-key fold/unfold (⌥⌘[ / ⌥⌘]), fold/unfold all (⌘K ⌘0 / ⌘K ⌘J) — fold state
  persists across edits
- Regex find & replace
- Cursor-word highlight, invisible-character & bidirectional-control-character
  warnings, inline CSS color swatches
- Completion is scope-aware, shows each item's kind and lists the most likely
  items first. After a dot, it lists the members of the preceding value, using
  inferred types for Python and JavaScript/TypeScript, and declared types for C,
  C++, Swift, Go, Rust, Java and C#. It also completes import statements,
  including modules from a Python virtual environment or `node_modules`
- All of this runs inside Karu's own process: there is no language server or
  helper process, and Karu never executes project code to learn about it
- Project folders: add folders in Settings › Code › Project Folders…; Karu
  indexes them in the background. Completion then uses symbols from your other
  files, and Edit › Workspace Symbols… (⌘T) jumps to any symbol in those files
- Run (⌘R, stop with ⌘.): runs the current text, saved or not, as a
  single-file program in Python, JavaScript, TypeScript, Bash, C, C++, Swift,
  Go, Rust, Java or C#. Output appears in a panel below the editor, and the
  program can read input you type there. For each language, the toolchain can be
  one that Karu installs through Settings › Run (Python, Node.js, Go, Temurin JDK,
  .NET SDK, Zig for C/C++; fixed versions with checksum-verified downloads, kept
  in Karu's own Application Support folder), one found on the system PATH, or one
  at a custom path. Karu does not change PATH or shell configuration. Swift and
  Rust use the toolchain already installed on the system
- Jump to Symbol (⌘⇧O), one-key formatting for JSON/JSONL/XML/plist (⌥⇧F)
- Comment toggle (⌘/), line move/duplicate/delete (⌥↑↓ / ⇧⌥↑↓ / ⌘⇧K),
  auto-closing brackets/quotes with selection wrapping, bracket-pair highlight
  & jump (⌘⇧\)
- Command palette (⌘⇧P)
- Plain-text-only paste (rich formatting stripped at the door)
- Automatic encoding detection + manual reopening with an encoding fallback;
  files are always saved as UTF-8, regardless of the encoding they were opened in
- Line-ending (LF/CRLF/CR) display and conversion
- Indent-width auto-detection, per-language configuration
- UI in English / 简体中文 / 日本語, switchable live
- Feature modules (highlight, completion, format, run, type inference and
  cross-file index) can each be switched off to release their runtime state
- Auto-save on focus loss (optional, off by default), selection character count,
  font zoom (⌘+ / ⌘- / ⌘0)
- `karu` CLI: open files from the terminal
- One-click in-app updates (Sparkle, from v0.7.0)

- Ordered scratchpad lists renumber following sibling items when inserting a line, with one-step undo.
- Python f-strings highlight interpolation expressions and nested format fields.
- Settings → Keyboard Shortcuts: search, record, clear, restore defaults, and detect conflicts within Karu, including the global scratchpad binding.

Settings also provides default file application management and JSON preference export/import. macOS groups extensions by content type and may request confirmation; ambiguous non-text types are omitted. Backups contain Karu preferences and shortcuts, excluding documents, notes, sessions, and system file associations. Import replaces preferences and restores omitted options to their defaults.

XML/plist formatting preserves text values, mixed content, and `xml:space="preserve"`. Format Document refuses to format a JSON or XML document nested more than 512 levels deep, or one whose result would be far larger than the input, and leaves the document unchanged. Crash recovery also runs when opening a file from Finder or the command line. If the scratchpad cannot be saved, it stays open and quitting is canceled so you can retry or save the text elsewhere.

If another program has changed a file since Karu opened it, Karu prompts before saving (Save As…, Overwrite, Cancel) instead of overwriting silently. A file opened through a symbolic link is saved to the link's target, and the link is preserved. If a recovered draft and the file on disk have both changed, Karu keeps both: the draft opens as a separate copy.

## The budget (enforced, not aspirational)

| Metric | Ceiling |
|---|---|
| Empty document, idle | 99 MB |
| 1 MB file open | 99 MB |
| 10 MB file open | 99 MB |
| Cold start | < 1 s |

The three memory rows show `phys_footprint` readings taken by
`scripts/mem-benchmark.sh` with the default 800×600 window (an empty document,
a 1 MB JSON file, a 10 MB Python file). `scripts/preflight.sh` runs it alongside
the tests before every release, and a run that cannot show what it actually
measured does not count as a pass. Stress inputs outside these three scenarios,
such as a 5 MB file consisting of a single line, can exceed the ceiling.

Deliberately excluded, forever: LSP/language servers, Electron/web views, heavy
formatters, plugin systems.

## Install

Download the notarized DMG from
[Releases](https://github.com/enkin-japan/karu/releases), drag to Applications.

CLI helper (optional):

```sh
ln -s /Applications/Karu.app/Contents/Resources/karu /usr/local/bin/karu
```

## Build from source

Requires only Swift (Command Line Tools — no Xcode needed). The deployment
target is macOS 13. Recent releases have been built and tested only on macOS 27
on Apple silicon; older macOS versions are not retested for each release. The
released DMG is an Apple silicon (arm64) build.

```sh
swift build                    # debug build
bash scripts/test.sh           # run the full test suite
bash scripts/bundle-macos.sh   # → build/Karu.app (SIGN_IDENTITY=- for ad-hoc)
```

`scripts/test.sh` runs `swift test` with limited parallelism because unlimited
parallelism causes timing-sensitive tests to fail; a subset can be run with
`swift test --filter <name>`.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the budget table and the design
  rules that keep Karu small (Chinese)
- [docs/LEDGER.md](docs/LEDGER.md) — the full engineering ledger (Chinese)
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) — build, test and measurement notes
  (Chinese)

## License

[MIT](LICENSE) © 2026 enkin
