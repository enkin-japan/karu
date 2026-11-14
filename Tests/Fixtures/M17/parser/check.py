#!/usr/bin/env python3
"""Validate the M17 parser error-tolerance sample set."""
import json, os, re, sys
ROOT = os.path.dirname(os.path.abspath(__file__))
EXT = {"python": ".py", "typescript": ".ts", "tsx": ".tsx"}
MIN = {"python": 24, "typescript": 20, "tsx": 6}
M = "‸"
errs = []
for lang, ext in EXT.items():
    d = os.path.join(ROOT, lang)
    files = sorted(f for f in os.listdir(d) if f.endswith(ext))
    exp = json.load(open(os.path.join(d, "expected.json"), encoding="utf-8"))
    if len(files) < MIN[lang]:
        errs.append(f"{lang}: {len(files)} files < {MIN[lang]}")
    for f in files:
        if f not in exp: errs.append(f"{lang}/{f}: no expected entry")
    for f in exp:
        if f not in files: errs.append(f"{lang}/{f}: expected entry without file")
    for f in files:
        text = open(os.path.join(d, f), encoding="utf-8").read()
        if text.count(M) != 1: errs.append(f"{lang}/{f}: {text.count(M)} markers")
        n = text.count("\n")
        if not 15 <= n <= 60: errs.append(f"{lang}/{f}: {n} lines")
        e = exp.get(f)
        if e is None: continue
        if set(e) != {"topLevel", "enclosing", "params", "receiver"}:
            errs.append(f"{lang}/{f}: keys {sorted(e)}"); continue
        for k in ("topLevel", "enclosing", "params"):
            if not (isinstance(e[k], list) and all(isinstance(x, str) for x in e[k])):
                errs.append(f"{lang}/{f}: {k} must be list[str]")
        if not (e["receiver"] is None or isinstance(e["receiver"], str)):
            errs.append(f"{lang}/{f}: receiver type")
        before = text.split(M)[0]
        m = re.search(r"\??\.[A-Za-z_$][\w$]*$|\??\.$", before)
        if (e["receiver"] is not None) != bool(m):
            errs.append(f"{lang}/{f}: receiver presence disagrees with text before caret")
        if e["receiver"] and e["receiver"] not in before:
            errs.append(f"{lang}/{f}: receiver text not found before caret")
    print(f"{lang}: {len(files)} files, {len(exp)} expected entries")
if errs:
    print("\n".join(errs)); sys.exit(1)
print("OK")
