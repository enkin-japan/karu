#!/usr/bin/env python3
"""Compare Karu's highlight dump with the VS Code reference (M17 plan §13).

Both sides are directories of `<relative sample path>.colors.tsv` files with
lines `start<TAB>length<TAB>#rrggbb` (UTF-16 offsets into the sample as read
from disk). For every sample present on both sides this prints the share of
non-whitespace UTF-16 units whose colour agrees, then the largest disagreeing
spans with their text.

Colours in --neutral (default: the Dark Modern editor foreground and the
operator grey) count as "no colour", because Karu leaves those runs uncoloured
while VS Code paints some of them explicitly.

Usage:
  python3 -I scripts/m17/compare-colors.py <samples-root> <karu-dir> <vscode-dir> \
      [--neutral '#cccccc,#d4d4d4'] [--detail 8] [--only SUBSTRING]
"""
from __future__ import annotations

import argparse
import pathlib
import sys

NAMES = {
    "#569cd6": "keyword", "#c586c0": "control", "#ce9178": "string",
    "#b5cea8": "number", "#6a9955": "comment", "#4ec9b0": "type",
    "#4ec9b2": "type(karu)", "#dcdcaa": "function", "#9cdcfe": "variable",
    "#4fc1ff": "constant", "#d7ba7d": "escape", "#d16969": "regex",
    "#808080": "tag-punct", "#6796e6": "list-marker", "#f44747": "invalid",
    "#d4d4d4": "neutral", "#cccccc": "neutral", "": "none",
}


def utf16_units(text: str) -> list[str]:
    """One entry per UTF-16 code unit; a surrogate pair maps to two entries."""
    out: list[str] = []
    for ch in text:
        out.append(ch)
        if ord(ch) > 0xFFFF:
            out.append("")
    return out


def load_runs(path: pathlib.Path, length: int, neutral: set[str]) -> list[str]:
    colors = [""] * length
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        start, count, color = line.split("\t")
        color = color.lower()
        if color in neutral:
            continue
        s, n = int(start), int(count)
        for i in range(s, min(s + n, length)):
            colors[i] = color
    return colors


def name(color: str) -> str:
    return NAMES.get(color, color)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("samples")
    ap.add_argument("karu")
    ap.add_argument("vscode")
    ap.add_argument("--neutral", default="#cccccc,#d4d4d4")
    ap.add_argument("--detail", type=int, default=8)
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    neutral = {c.strip().lower() for c in args.neutral.split(",") if c.strip()}
    samples = pathlib.Path(args.samples)
    karu = pathlib.Path(args.karu)
    vscode = pathlib.Path(args.vscode)

    total_units = total_agree = 0
    rows = []
    for vfile in sorted(vscode.rglob("*.colors.tsv")):
        rel = vfile.relative_to(vscode).as_posix()[: -len(".colors.tsv")]
        if args.only and args.only not in rel:
            continue
        kfile = karu / f"{rel}.colors.tsv"
        sample = samples / rel
        if not kfile.exists() or not sample.exists():
            rows.append((rel, None, 0, []))
            continue
        units = utf16_units(sample.read_text(encoding="utf-8"))
        kc = load_runs(kfile, len(units), neutral)
        vc = load_runs(vfile, len(units), neutral)
        counted = agree = 0
        spans: list[tuple[int, int, str, str]] = []
        cur = None
        for i, u in enumerate(units):
            if u.isspace() or u == "":
                continue
            counted += 1
            if kc[i] == vc[i]:
                agree += 1
                cur = None
                continue
            if cur and cur[1] == i - 1 - _gap(units, cur[1], i) and cur[2] == kc[i] and cur[3] == vc[i]:
                cur[1] = i
            else:
                cur = [i, i, kc[i], vc[i]]
                spans.append(cur)  # type: ignore[arg-type]
        total_units += counted
        total_agree += agree
        rows.append((rel, (agree, counted), len(spans), [(s, e, k, v, "".join(units[s:e + 1])) for s, e, k, v in spans]))

    for rel, ratio, nspans, spans in rows:
        if ratio is None:
            print(f"{rel}: missing on one side")
            continue
        agree, counted = ratio
        pct = 100.0 * agree / counted if counted else 100.0
        print(f"{rel}: {pct:5.1f}% agree ({agree}/{counted} units), {nspans} disagreeing spans")
        for s, e, k, v, text in sorted(spans, key=lambda x: x[0] - x[1])[: args.detail]:
            snippet = text.replace("\n", "⏎")[:60]
            print(f"    @{s}+{e - s + 1}: karu={name(k)} vscode={name(v)}  {snippet!r}")
    if total_units:
        print(f"TOTAL: {100.0 * total_agree / total_units:.1f}% agree over {total_units} non-whitespace units")
    return 0


def _gap(units: list[str], last: int, i: int) -> int:
    """Whitespace units skipped between two disagreeing positions."""
    return sum(1 for j in range(last + 1, i) if units[j].isspace() or units[j] == "")


if __name__ == "__main__":
    sys.exit(main())
