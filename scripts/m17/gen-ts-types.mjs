// M17 T17.10 — TypeScript lib declarations -> JSON model for ktt_writer.py.
//
// Usage: node scripts/m17/gen-ts-types.mjs <typescript package dir> <out.ktt>
//
// Reads lib.esnext.d.ts and everything it references (`/// <reference lib>`),
// i.e. lib.es5 … lib.esnext.* plus lib.decorators*, and separately lib.dom,
// lib.dom.iterable and lib.dom.asynciterable, with the TypeScript compiler API
// (syntax only; no type checking). Interfaces, namespaces and functions are
// merged across files (declaration merging). Namespace members get qualified
// names (`Intl.DateTimeFormat`). Symbols declared in a DOM file go to the DOM
// section; an ES symbol that a DOM file augments (only `ImportMeta`) keeps its
// ES declarations in the ES section, flagged, and the DOM part in the DOM section.
//
// Files that are modules (`export {}`, e.g. lib.es2025.iterator) contribute only
// their `declare global { … }` block; their module-local helpers are not global
// and are skipped (type texts may still name them; inference treats them as
// unknown).
//
// Type texts are printed by the compiler's printer without comments, then
// whitespace outside string / template literals is collapsed to single spaces.
// The model is handed to `ktt_writer.py ts`, which writes the binary table.

import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const [pkgDir, outPath] = process.argv.slice(2);
if (!pkgDir || !outPath) {
  console.error('usage: node gen-ts-types.mjs <typescript package dir> <out.ktt>');
  process.exit(2);
}
const ts = createRequire(import.meta.url)(path.join(pkgDir, 'lib', 'typescript.js'));
const libDir = path.join(pkgDir, 'lib');

// Parameter / member constants: keep in sync with ktt_writer.py.
const P_POSITIONAL_ONLY = 0, P_POSITIONAL = 1, P_VAR_POSITIONAL = 2, P_HAS_DEFAULT = 8;
const M_METHOD = 0, M_PROPERTY = 3, M_FIELD = 4;
const MF_READONLY = 1, MF_CLASSVAR = 2, MF_ABSTRACT = 8, MF_DEPRECATED = 16, MF_OPTIONAL = 64;
const VF_CONST = 1;
const CF_ABSTRACT = 1 << 7; // class flag (TypeScript abstract class)

// --- lib file sets -------------------------------------------------------------
function libRefs(name) {
  const text = fs.readFileSync(path.join(libDir, `lib.${name}.d.ts`), 'utf8');
  return [...text.matchAll(/^\/\/\/ <reference lib="([^"]+)"\s*\/>/gm)].map((m) => m[1]);
}
function closure(roots, stop = new Set()) {
  const order = [];
  const seen = new Set(stop);
  const visit = (n) => {
    if (seen.has(n)) return;
    seen.add(n);
    for (const r of libRefs(n)) visit(r);
    order.push(n);
  };
  roots.forEach(visit);
  return order;
}
const esFiles = closure(['esnext']);
const domFiles = closure(['dom', 'dom.iterable', 'dom.asynciterable'], new Set(esFiles));
for (const f of domFiles) {
  if (!f.startsWith('dom')) throw new Error(`unexpected non-DOM lib pulled in by DOM: ${f}`);
}

// --- printing ------------------------------------------------------------------
const printer = ts.createPrinter({ removeComments: true, newLine: ts.NewLineKind.LineFeed });
function collapse(text) {
  let out = '';
  let quote = null;
  let pendingSpace = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      out += c;
      if (c === '\\') { out += text[++i] ?? ''; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (/\s/.test(c)) { pendingSpace = out.length > 0; continue; }
    if (pendingSpace) {
      out += ' ';
      pendingSpace = false;
    }
    if (c === '"' || c === "'" || c === '`') quote = c;
    out += c;
  }
  return out;
}
let currentFile = null;
function typeText(node) {
  if (!node) return '';
  return collapse(printer.printNode(ts.EmitHint.Unspecified, node, currentFile));
}
function nameText(name) {
  if (!name) return '';
  if (ts.isIdentifier(name) || ts.isPrivateIdentifier(name)) return name.text;
  if (ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text;
  if (ts.isComputedPropertyName(name)) return `[${collapse(printer.printNode(ts.EmitHint.Expression, name.expression, currentFile))}]`;
  return name.getText(currentFile);
}

// --- model building ----------------------------------------------------------
function typeParams(decl) {
  return (decl.typeParameters ?? []).map((tp) => [tp.name.text, typeText(tp.constraint), typeText(tp.default), 0]);
}
function signature(decl) {
  const params = decl.parameters.map((p) => {
    let kind = p.dotDotDotToken ? P_VAR_POSITIONAL : (nameText(p.name) === 'this' ? P_POSITIONAL_ONLY : P_POSITIONAL);
    if (p.questionToken || p.initializer) kind |= P_HAS_DEFAULT;
    const name = ts.isIdentifier(p.name) ? p.name.text : collapse(p.name.getText(currentFile));
    return [name, kind, typeText(p.type)];
  });
  return { async: false, tparams: typeParams(decl), params, returns: typeText(decl.type) };
}
function isDeprecated(node) {
  return ts.getJSDocTags(node).some((t) => t.tagName.text === 'deprecated');
}
function hasModifier(node, kind) {
  return (ts.getModifiers?.(node) ?? node.modifiers ?? []).some((m) => m.kind === kind);
}

function newDecl(name) {
  return { name, flags: 0, tparams: [], bases: [], members: {}, calls: [], constructs: [], indexes: [] };
}
function newEntry() { return {}; }

function addMembers(decl, members) {
  for (const m of members) {
    let flags = 0;
    if (isDeprecated(m)) flags |= MF_DEPRECATED;
    if (hasModifier(m, ts.SyntaxKind.ReadonlyKeyword)) flags |= MF_READONLY;
    if (hasModifier(m, ts.SyntaxKind.StaticKeyword)) flags |= MF_CLASSVAR;
    if (hasModifier(m, ts.SyntaxKind.AbstractKeyword)) flags |= MF_ABSTRACT;
    if (m.questionToken) flags |= MF_OPTIONAL;
    if (ts.isPropertySignature(m) || ts.isPropertyDeclaration(m)) {
      decl.members[nameText(m.name)] = { kind: M_FIELD, flags, type: typeText(m.type), overloads: [] };
    } else if (ts.isMethodSignature(m) || ts.isMethodDeclaration(m)) {
      const name = nameText(m.name);
      let mem = decl.members[name];
      if (!mem || mem.kind !== M_METHOD) {
        mem = decl.members[name] = { kind: M_METHOD, flags: 0, type: '', overloads: [] };
      }
      mem.flags |= flags;
      mem.overloads.push(signature(m));
    } else if (ts.isGetAccessorDeclaration(m) || ts.isSetAccessorDeclaration(m)) {
      const name = nameText(m.name);
      let mem = decl.members[name];
      if (!mem || mem.kind !== M_PROPERTY) {
        mem = decl.members[name] = { kind: M_PROPERTY, flags: flags | MF_READONLY, type: '', overloads: [], _set: false };
      }
      if (ts.isGetAccessorDeclaration(m)) {
        mem.type = typeText(m.type);
      } else {
        mem.flags &= ~MF_READONLY;
        if (!mem.type) mem.type = typeText(m.parameters[0]?.type);
      }
      if (flags & MF_DEPRECATED) mem.flags |= MF_DEPRECATED;
    } else if (ts.isCallSignatureDeclaration(m)) {
      decl.calls.push(signature(m));
    } else if (ts.isConstructSignatureDeclaration(m) || ts.isConstructorDeclaration(m)) {
      decl.constructs.push(signature(m));
    } else if (ts.isIndexSignatureDeclaration(m)) {
      const p = m.parameters[0];
      decl.indexes.push([p.name.text, typeText(p.type), typeText(m.type), flags & MF_READONLY]);
    } else {
      throw new Error(`unhandled member ${ts.SyntaxKind[m.kind]} in ${decl.name}`);
    }
  }
}

function heritage(node) {
  const out = [];
  for (const clause of node.heritageClauses ?? []) {
    for (const t of clause.types) out.push(typeText(t));
  }
  return out;
}

// symbols: Map qualified name -> entry; namespaces track their member names.
function collect(files) {
  const symbols = new Map();
  const entry = (name) => {
    if (!symbols.has(name)) symbols.set(name, newEntry());
    return symbols.get(name);
  };
  const addToNamespace = (ns, name) => {
    if (!ns) return;
    const e = entry(ns);
    e.namespace ??= [];
    if (!e.namespace.includes(name)) e.namespace.push(name);
  };
  function visitStatements(statements, ns) {
    const q = (n) => (ns ? `${ns}.${n}` : n);
    for (const s of statements) {
      if (ts.isInterfaceDeclaration(s) || ts.isClassDeclaration(s)) {
        const name = q(s.name.text);
        addToNamespace(ns, s.name.text);
        const e = entry(name);
        e.interface ??= newDecl(name);
        const d = e.interface;
        if (ts.isClassDeclaration(s)) {
          e.isClass = true;
          if (hasModifier(s, ts.SyntaxKind.AbstractKeyword)) d.flags |= CF_ABSTRACT;
        }
        if (!d.tparams.length) d.tparams = typeParams(s);
        for (const b of heritage(s)) if (!d.bases.includes(b)) d.bases.push(b);
        addMembers(d, s.members);
      } else if (ts.isVariableStatement(s)) {
        const isConst = (s.declarationList.flags & ts.NodeFlags.Const) !== 0;
        for (const v of s.declarationList.declarations) {
          addToNamespace(ns, v.name.text);
          entry(q(v.name.text)).var = [typeText(v.type), isConst ? VF_CONST : 0];
        }
      } else if (ts.isFunctionDeclaration(s)) {
        addToNamespace(ns, s.name.text);
        const e = entry(q(s.name.text));
        e.function ??= { flags: 0, overloads: [] };
        if (isDeprecated(s)) e.function.flags |= MF_DEPRECATED;
        e.function.overloads.push(signature(s));
      } else if (ts.isTypeAliasDeclaration(s)) {
        addToNamespace(ns, s.name.text);
        entry(q(s.name.text)).alias = [typeParams(s), typeText(s.type)];
      } else if (ts.isModuleDeclaration(s)) {
        if (s.flags & ts.NodeFlags.GlobalAugmentation) {
          visitStatements(s.body.statements, ns);
          continue;
        }
        const name = q(s.name.text);
        addToNamespace(ns, s.name.text);
        entry(name).namespace ??= [];
        let body = s.body;
        let inner = name;
        while (body && ts.isModuleDeclaration(body)) { // namespace A.B { }
          entry(inner).namespace.push(body.name.text);
          inner = `${inner}.${body.name.text}`;
          entry(inner).namespace ??= [];
          body = body.body;
        }
        if (body) visitStatements(body.statements, inner);
      } else if (ts.isExportDeclaration(s) || ts.isEmptyStatement(s)) {
        // `export {}` marks a module file; handled by the caller.
      } else {
        throw new Error(`unhandled statement ${ts.SyntaxKind[s.kind]}`);
      }
    }
  }
  for (const f of files) {
    const file = path.join(libDir, `lib.${f}.d.ts`);
    currentFile = ts.createSourceFile(file, fs.readFileSync(file, 'utf8'), ts.ScriptTarget.Latest, true);
    if (ts.isExternalModule(currentFile)) {
      for (const s of currentFile.statements) {
        if (ts.isModuleDeclaration(s) && (s.flags & ts.NodeFlags.GlobalAugmentation)) visitStatements(s.body.statements, null);
      }
    } else {
      visitStatements(currentFile.statements, null);
    }
  }
  return symbols;
}

const es = collect(esFiles);
const dom = collect(domFiles);
for (const [name, e] of dom) {
  if (es.has(name)) es.get(name).domAugmented = true;
}
function toObject(map) {
  const out = {};
  for (const [k, v] of [...map].sort((a, b) => Buffer.compare(Buffer.from(a[0]), Buffer.from(b[0])))) {
    if (v.interface) for (const m of Object.values(v.interface.members)) delete m._set;
    if (v.namespace) v.namespace.sort();
    out[k] = v;
  }
  return out;
}
const model = { es: toObject(es), dom: toObject(dom), files: { es: esFiles, dom: domFiles } };
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'karu-ts-model-'));
try {
  const jsonPath = path.join(tmp, 'model.json');
  fs.writeFileSync(jsonPath, JSON.stringify(model));
  // Debugging aid: keep a copy of the intermediate model.
  if (process.env.KARU_TS_MODEL_JSON) fs.copyFileSync(jsonPath, process.env.KARU_TS_MODEL_JSON);
  const writer = path.join(path.dirname(fileURLToPath(import.meta.url)), 'ktt_writer.py');
  execFileSync('python3', ['-I', writer, 'ts', jsonPath, outPath], { stdio: 'inherit' });
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(`  ES files: ${esFiles.length}, DOM files: ${domFiles.length} (${domFiles.join(', ')})`);
