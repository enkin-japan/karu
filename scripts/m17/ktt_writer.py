#!/usr/bin/env python3
"""Writer for Karu type-table files (.ktt), M17 T17.10.

The format is documented next to the reader, in
Sources/KaruCore/Inference/TypeTableFile.swift, and summarised in
docs/ARCHITECTURE.md. This module is shared by both generators:

- gen_python_types.py imports it to encode typeshed modules;
- `python3 -I ktt_writer.py ts <model.json> <out.ktt>` encodes the JSON model
  produced by gen-ts-types.mjs (TypeScript lib declarations).

Everything is written in a deterministic order (sorted names, first-use string
ids), so identical inputs give byte-identical files.
"""
from __future__ import annotations

import json
import struct
import sys

MAGIC = b"KTT1"
FORMAT_VERSION = 1

# Parameter kinds (low 3 bits) and flags
P_POSITIONAL_ONLY, P_POSITIONAL, P_VAR_POSITIONAL, P_KEYWORD_ONLY, P_VAR_KEYWORD = 0, 1, 2, 3, 4
P_HAS_DEFAULT = 1 << 3          # Python default value / TypeScript `?`
# Member kinds (low 4 bits of the kind varint) and flags (shifted left by 4)
M_METHOD, M_CLASSMETHOD, M_STATICMETHOD, M_PROPERTY, M_FIELD = 0, 1, 2, 3, 4
MF_READONLY = 1 << 0
MF_CLASSVAR = 1 << 1            # ClassVar / TS static
MF_FINAL = 1 << 2
MF_ABSTRACT = 1 << 3
MF_DEPRECATED = 1 << 4
MF_ASSIGNED = 1 << 5            # `x = value` without annotation (e.g. enum members)
MF_OPTIONAL = 1 << 6            # TS `name?:`

# TypeScript entry presence flags
TS_INTERFACE, TS_VAR, TS_FUNCTION, TS_ALIAS, TS_NAMESPACE, TS_CLASS, TS_DOM_AUGMENTED = 1, 2, 4, 8, 16, 32, 64


def _varint(out: bytearray, n: int):
    if n < 0:
        raise ValueError(n)
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


class Blob:
    def __init__(self, section: "Section"):
        self.section = section
        self.data = bytearray()

    def v(self, n: int):
        _varint(self.data, n)

    def s(self, text: str):
        _varint(self.data, self.section.intern(text))


class Section:
    def __init__(self, section_id: int):
        self.section_id = section_id
        self.strings: dict[str, int] = {"": 0}
        self.order: list[str] = [""]
        self.entries: list[tuple[bytes, int, bytes]] = []

    def intern(self, text: str) -> int:
        sid = self.strings.get(text)
        if sid is None:
            sid = len(self.order)
            self.strings[text] = sid
            self.order.append(text)
        return sid

    def string_count(self) -> int:
        return len(self.order)

    def blob(self) -> Blob:
        return Blob(self)

    def add(self, name: str, blob: Blob):
        self.entries.append((name.encode("utf-8"), self.intern(name), bytes(blob.data)))


def _pad4(buf: bytearray):
    while len(buf) % 4:
        buf.append(0)


class KTTWriter:
    """Header (16 bytes) + section directory (32 bytes each) + per-section
    index / string table / blobs, every region 4-byte aligned."""

    def __init__(self, language: int):
        self.language = language
        self.sections: list[Section] = []

    def section(self, section_id: int) -> Section:
        s = Section(section_id)
        self.sections.append(s)
        return s

    def finish(self) -> bytes:
        head = bytearray(MAGIC)
        head += struct.pack("<HHII", FORMAT_VERSION, self.language, len(self.sections), 0)
        body = bytearray()
        base = len(head) + 32 * len(self.sections)
        directory = bytearray()
        for sec in self.sections:
            entries = sorted(sec.entries, key=lambda e: e[0])
            names = [e[0] for e in entries]
            if len(set(names)) != len(names):
                raise SystemExit(f"duplicate entry names in section {sec.section_id}")
            # blobs
            blobs = bytearray()
            index = bytearray()
            for _, name_id, data in entries:
                index += struct.pack("<III", name_id, len(blobs), len(data))
                blobs += data
            # strings
            encoded = [t.encode("utf-8") for t in sec.order]
            strings = bytearray(struct.pack("<I", len(encoded)))
            offset = 0
            offsets = [0]
            for e in encoded:
                offset += len(e)
                offsets.append(offset)
            strings += struct.pack(f"<{len(offsets)}I", *offsets)
            for e in encoded:
                strings += e

            _pad4(body)
            index_off = base + len(body); body += index; _pad4(body)
            strings_off = base + len(body); body += strings; _pad4(body)
            blobs_off = base + len(body); body += blobs; _pad4(body)
            directory += struct.pack("<8I", sec.section_id, len(entries), index_off, strings_off,
                                     len(strings), blobs_off, len(blobs), 0)
        return bytes(head + directory + body)


# --- shared record encoders ----------------------------------------------------
# Type parameter: (name, bound, default, kindFlags)
# Signature: {"async": bool, "tparams": [...], "params": [(name, kind, type)], "returns": str}
# Class / interface: {"name", "flags", "tparams", "bases", "members": {name: member},
#                     "calls": [sig], "constructs": [sig], "indexes": [(key, keyType, valueType, flags)]}
# Member: {"kind", "flags", "type", "overloads": [sig]}

def put_tparam(b: Blob, tp):
    name, bound, default, kind = tp
    b.s(name); b.s(bound); b.s(default); b.v(kind)


def put_signature(b: Blob, sig):
    b.v(1 if sig.get("async") else 0)
    b.v(len(sig["tparams"]))
    for tp in sig["tparams"]:
        put_tparam(b, tp)
    b.v(len(sig["params"]))
    for name, kind, ann in sig["params"]:
        b.s(name); b.v(kind); b.s(ann)
    b.s(sig["returns"])


def put_class(b: Blob, cls):
    b.s(cls["name"]); b.v(cls["flags"])
    b.v(len(cls["tparams"]))
    for tp in cls["tparams"]:
        put_tparam(b, tp)
    b.v(len(cls["bases"]))
    for base in cls["bases"]:
        b.s(base)
    members = cls["members"]
    b.v(len(members))
    for name in sorted(members, key=lambda n: n.encode("utf-8")):
        mem = members[name]
        b.s(name); b.v(mem["kind"] | (mem["flags"] << 4)); b.s(mem["type"])
        b.v(len(mem["overloads"]))
        for sig in mem["overloads"]:
            put_signature(b, sig)
    for key in ("calls", "constructs"):
        sigs = cls.get(key, [])
        b.v(len(sigs))
        for sig in sigs:
            put_signature(b, sig)
    idx = cls.get("indexes", [])
    b.v(len(idx))
    for key_name, key_type, value_type, flags in idx:
        b.s(key_name); b.s(key_type); b.s(value_type); b.v(flags)


# --- TypeScript: JSON model -> .ktt -------------------------------------------

def encode_ts_entry(section: Section, entry) -> Blob:
    b = section.blob()
    flags = 0
    if entry.get("interface"): flags |= TS_INTERFACE
    if entry.get("var"): flags |= TS_VAR
    if entry.get("function"): flags |= TS_FUNCTION
    if entry.get("alias"): flags |= TS_ALIAS
    if entry.get("namespace") is not None: flags |= TS_NAMESPACE
    if entry.get("isClass"): flags |= TS_CLASS
    if entry.get("domAugmented"): flags |= TS_DOM_AUGMENTED
    b.v(flags)
    if flags & TS_INTERFACE:
        put_class(b, entry["interface"])
    if flags & TS_VAR:
        text, vflags = entry["var"]
        b.s(text); b.v(vflags)
    if flags & TS_FUNCTION:
        fn = entry["function"]
        b.v(fn["flags"]); b.v(len(fn["overloads"]))
        for sig in fn["overloads"]:
            put_signature(b, sig)
    if flags & TS_ALIAS:
        tparams, text = entry["alias"]
        b.v(len(tparams))
        for tp in tparams:
            put_tparam(b, tp)
        b.s(text)
    if flags & TS_NAMESPACE:
        names = entry["namespace"]
        b.v(len(names))
        for n in names:
            b.s(n)
    return b


def encode_ts(model_path: str, out_path: str):
    with open(model_path, encoding="utf-8") as f:
        model = json.load(f)
    w = KTTWriter(language=2)
    counts = {}
    for section_id, key in ((2, "es"), (3, "dom")):
        sec = w.section(section_id)
        symbols = model[key]
        for name in sorted(symbols, key=lambda n: n.encode("utf-8")):
            sec.add(name, encode_ts_entry(sec, symbols[name]))
        members = sum(len(e["interface"]["members"]) for e in symbols.values() if e.get("interface"))
        counts[key] = (len(symbols), members, sec.string_count())
    data = w.finish()
    with open(out_path, "wb") as f:
        f.write(data)
    print(f"typescript-lib.ktt: {len(data)} bytes; "
          + "; ".join(f"{k}: {n} symbols, {m} interface members, {s} strings" for k, (n, m, s) in counts.items()))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "ts":
        encode_ts(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit("usage: ktt_writer.py ts <model.json> <out.ktt>")
