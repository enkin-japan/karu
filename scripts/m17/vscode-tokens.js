// M17 T17.0: VS Code reference colours for the highlight fixtures (plan §13).
//
// Tokenizes files with VS Code's own TextMate engine (vscode-textmate +
// vscode-oniguruma), grammars and theme, all taken from a pinned VS Code
// install, and writes one TSV per file in the same format as Karu's baseline
// dump: `start<TAB>length<TAB>#rrggbb`, UTF-16 offsets into the file as read
// from disk (line endings preserved), maximal runs, runs in the editor's
// default foreground omitted. Semantic highlighting is not involved: this is
// the TextMate layer only, which is what the plan compares against.
//
// Run it with VS Code's bundled Electron in node mode (it can read asar):
//   ELECTRON_RUN_AS_NODE=1 "<VS Code.app>/Contents/MacOS/Code" scripts/m17/vscode-tokens.js \
//       "<VS Code.app>" <theme-file-basename> <out-dir> <in-root> [files…]
// e.g. theme dark_modern or 2026-dark. With no files, every file under
// <in-root> is processed. Files whose extension has no VS Code grammar are
// listed as skipped.
'use strict';
const fs = require('fs');
const path = require('path');

const [appBundle, themeName, outDir, inRoot, ...explicit] = process.argv.slice(2);
if (!appBundle || !themeName || !outDir || !inRoot) {
  console.error('usage: vscode-tokens.js <VS Code.app> <theme> <out-dir> <in-root> [files…]');
  process.exit(2);
}
const appRoot = path.join(appBundle, 'Contents', 'Resources', 'app');
const tm = require(path.join(appRoot, 'node_modules.asar', 'vscode-textmate'));
const onig = require(path.join(appRoot, 'node_modules.asar', 'vscode-oniguruma'));
const extRoot = path.join(appRoot, 'extensions');

// Some fixture names map to a VS Code language explicitly (extension alone is ambiguous).
const EXTENSION_OVERRIDES = { '.jsonl': 'jsonl' };

function readJSONC(file) {
  let text = fs.readFileSync(file, 'utf8');
  text = text.replace(/^\s*\/\/.*$/gm, '').replace(/,(\s*[}\]])/g, '$1');
  return JSON.parse(text);
}

// ---- Grammar and language catalogue from every built-in extension ----
const scopeToFile = new Map();
const langToScope = new Map();
const extToLang = new Map();
const injections = new Map(); // target scope -> [injector scope]
for (const dir of fs.readdirSync(extRoot)) {
  const pkgPath = path.join(extRoot, dir, 'package.json');
  if (!fs.existsSync(pkgPath)) continue;
  let pkg;
  try { pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8')); } catch { continue; }
  const c = pkg.contributes || {};
  for (const lang of c.languages || []) {
    for (const ext of lang.extensions || []) {
      if (!extToLang.has(ext.toLowerCase())) extToLang.set(ext.toLowerCase(), lang.id);
    }
  }
  for (const g of c.grammars || []) {
    if (!g.scopeName || !g.path) continue;
    scopeToFile.set(g.scopeName, path.join(extRoot, dir, g.path));
    if (g.language && !langToScope.has(g.language)) langToScope.set(g.language, g.scopeName);
    for (const target of g.injectTo || []) {
      if (!injections.has(target)) injections.set(target, []);
      injections.get(target).push(g.scopeName);
    }
  }
}

// ---- Theme: follow the include chain, VS Code order (included rules first) ----
function loadTheme(file) {
  const t = readJSONC(file);
  let rules = [];
  let colors = {};
  if (t.include) {
    const inc = loadTheme(path.join(path.dirname(file), t.include));
    rules = rules.concat(inc.rules);
    colors = Object.assign(colors, inc.colors);
  }
  if (typeof t.tokenColors === 'string') {
    rules = rules.concat(readJSONC(path.join(path.dirname(file), t.tokenColors)).settings || []);
  } else if (Array.isArray(t.tokenColors)) {
    rules = rules.concat(t.tokenColors);
  }
  Object.assign(colors, t.colors || {});
  return { rules, colors };
}
const themeFile = path.join(extRoot, 'theme-defaults', 'themes', `${themeName}.json`);
const theme = loadTheme(themeFile);
const defaultFg = (theme.colors['editor.foreground'] || '#D4D4D4').toLowerCase();
const defaultBg = (theme.colors['editor.background'] || '#1E1E1E').toLowerCase();

async function main() {
  const wasm = fs.readFileSync(path.join(appRoot, 'node_modules.asar.unpacked', 'vscode-oniguruma', 'release', 'onig.wasm'));
  await onig.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
  const registry = new tm.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (p) => new onig.OnigScanner(p),
      createOnigString: (s) => new onig.OnigString(s),
    }),
    loadGrammar: async (scopeName) => {
      const file = scopeToFile.get(scopeName);
      if (!file) return null;
      return tm.parseRawGrammar(fs.readFileSync(file, 'utf8'), file);
    },
    getInjections: (scopeName) => injections.get(scopeName) || [],
  });
  registry.setTheme({
    name: themeName,
    settings: [{ settings: { foreground: defaultFg, background: defaultBg } }].concat(theme.rules),
  });
  const colorMap = registry.getColorMap();

  const files = explicit.length ? explicit : walk(inRoot);
  const skipped = [];
  for (const file of files) {
    const ext = path.extname(file).toLowerCase();
    const lang = EXTENSION_OVERRIDES[ext] || extToLang.get(ext);
    const scope = lang && langToScope.get(lang);
    const grammar = scope ? await registry.loadGrammar(scope) : null;
    if (!grammar) { skipped.push(`${path.relative(inRoot, file)} (${ext} → ${lang || '?'})`); continue; }
    const text = fs.readFileSync(file, 'utf8');
    const runs = [];
    let ruleStack = tm.INITIAL;
    let offset = 0;
    const re = /\r\n|\n|\r/g;
    let lineStart = 0;
    const lines = [];
    let m;
    while ((m = re.exec(text)) !== null) { lines.push([text.slice(lineStart, m.index), m[0].length]); lineStart = m.index + m[0].length; }
    lines.push([text.slice(lineStart), 0]);
    for (const [line, eolLen] of lines) {
      const r = grammar.tokenizeLine2(line, ruleStack);
      const toks = r.tokens;
      for (let i = 0; i < toks.length; i += 2) {
        const start = toks[i];
        const end = i + 2 < toks.length ? toks[i + 2] : line.length;
        if (end <= start) continue;
        const meta = toks[i + 1];
        const fg = (meta >>> 15) & 0x1ff;
        const color = (colorMap[fg] || defaultFg).toLowerCase();
        if (color === defaultFg) continue;
        const absStart = offset + start;
        const last = runs[runs.length - 1];
        if (last && last[2] === color && last[0] + last[1] === absStart) last[1] += end - start;
        else runs.push([absStart, end - start, color]);
      }
      ruleStack = r.ruleStack;
      offset += line.length + eolLen;
    }
    const rel = path.relative(inRoot, file);
    const out = path.join(outDir, `${rel}.colors.tsv`);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, runs.map((r) => `${r[0]}\t${r[1]}\t${r[2]}`).join('\n') + (runs.length ? '\n' : ''));
    console.log(`${rel}: ${lang} ${scope} runs=${runs.length}`);
  }
  for (const s of skipped) console.log(`SKIPPED ${s}`);
  console.log(`theme=${themeName} editor.foreground=${defaultFg}`);
}

function walk(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (!e.name.startsWith('.')) out.push(p);
  }
  return out.sort();
}

main().catch((e) => { console.error(e); process.exit(1); });
