# Karu（軽）

**English** | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md)

A deliberately tiny, native plain-text editor for macOS. **~30 MB resident
memory, cold start under a second.**

Karu (軽, "light" in Japanese) is built on one belief: a text editor should cost
almost nothing. Every feature is admitted against a hard memory budget, and
features that can't fit are rejected — the way kei cars stay light because the
rules say they must.

## Features

- Syntax highlighting for 20 languages (Markdown, JSON/JSONL, YAML, TOML, Python,
  HTML, CSS, JavaScript/TypeScript, C, C++, C#, Java, Go, Rust, Swift, Bash, SQL,
  XML/plist) — viewport-only, VS Code Modern-style colors, light & dark
- Code folding, line numbers, VS Code-style indent rainbow
- One-key fold/unfold (⌥⌘[ / ⌥⌘]), fold/unfold all (⌘K ⌘0 / ⌘K ⌘J) — fold state
  persists across edits
- Regex find & replace
- Cursor-word highlight, invisible-character & bidirectional-control-character
  warnings, inline CSS color swatches
- Completion: keywords, document words, and in-document symbols
- Jump to Symbol (⌘⇧O), one-key formatting for JSON/JSONL/XML/plist (⌥⇧F)
- Comment toggle (⌘/), line move/duplicate/delete (⌥↑↓ / ⇧⌥↑↓ / ⌘⇧K),
  auto-closing brackets/quotes with selection wrapping, bracket-pair highlight
  & jump (⌘⇧\)
- Command palette (⌘⇧P)
- Plain-text-only paste (rich formatting stripped at the door)
- Automatic encoding detection + manual re-open with encoding fallback
- Line-ending (LF/CRLF/CR) display and conversion
- Indent-width auto-detection, per-language configuration
- UI in English / 简体中文 / 日本語, switchable live
- Feature modules (highlight / completion / format) can be toggled off, releasing
  their runtime state entirely
- Auto-save on focus loss (optional, off by default), selection character count,
  font zoom (⌘+ / ⌘- / ⌘0)
- `karu` CLI: open files from the terminal
- One-click in-app updates (Sparkle, from v0.7.0)

- Ordered scratchpad lists renumber following sibling items when inserting a line, with one-step undo.
- Python f-strings highlight interpolation expressions and nested format fields.
- Settings → Keyboard Shortcuts: search, record, clear, restore defaults, and detect conflicts within Karu, including the global scratchpad binding.

XML/plist formatting preserves text values, mixed content, and `xml:space="preserve"`. Crash recovery also runs when opening a file from Finder or the command line. If the scratchpad cannot be saved, it stays open and quitting is cancelled so you can retry or save the text elsewhere.

## The budget (enforced, not aspirational)

| Metric | Ceiling |
|---|---|
| Empty document, idle | 35 MB |
| 1 MB file open | 50 MB |
| 10 MB file open | 65 MB |
| App bundle | 10 MB |
| Cold start | < 1 s |

Measured by `scripts/mem-benchmark.sh` on every release. Deliberately excluded,
forever: LSP/language servers, tree-sitter, Electron/web views, heavy formatters,
plugin systems.

## Install

Download the notarized DMG from
[Releases](https://github.com/enkin-japan/karu/releases), drag to Applications.

CLI helper (optional):

```sh
ln -s /Applications/Karu.app/Contents/Resources/karu /usr/local/bin/karu
```

## Build from source

Requires only Swift (Command Line Tools — no Xcode needed), macOS 13+.

```sh
swift build            # debug build
swift test             # run the full test suite
bash scripts/bundle-macos.sh   # → build/Karu.app (SIGN_IDENTITY=- for ad-hoc)
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — the budget table and the design
  rules that keep Karu small (Chinese)
- [docs/LEDGER.md](docs/LEDGER.md) — the full engineering ledger (Chinese)

## License

[MIT](LICENSE) © 2026 enkin
