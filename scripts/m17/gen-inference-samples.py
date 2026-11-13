#!/usr/bin/env python3
"""Generate the M17 inference memory samples (plan §8.3, T17.0).

Writes two ~1000-line files with many *distinct* names and types, so memory
measurements reflect a realistic symbol population instead of the repeated
names of the large mem-benchmark fixture:

  Tests/Fixtures/M17/inference/sample_1000.py
  Tests/Fixtures/M17/inference/sample_1000.ts

Output is deterministic (fixed vocabulary, no randomness), so the files can be
regenerated and diffed. Usage: python3 -I scripts/m17/gen-inference-samples.py
"""
from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests" / "Fixtures" / "M17" / "inference"

ENTITIES = [
    "Invoice", "Customer", "Shipment", "Warehouse", "Ledger", "Supplier",
    "Payment", "Refund", "Coupon", "Voucher", "Courier", "Parcel",
    "Tenant", "Lease", "Booking", "Ticket", "Venue", "Artist",
    "Patient", "Clinic", "Course", "Lesson", "Sensor", "Reading",
    "Campaign",
]
# (field name, python type, typescript type, python sample, ts sample)
FIELDS = [
    ("label", "str", "string", '"alpha"', '"alpha"'),
    ("amount", "float", "number", "12.5", "12.5"),
    ("quantity", "int", "number", "3", "3"),
    ("tags", "list[str]", "string[]", '["x", "y"]', '["x", "y"]'),
    ("created_at", "datetime", "Date", "datetime(2026, 1, 2)", "new Date(2026, 0, 2)"),
    ("notes", "Optional[str]", "string | undefined", "None", "undefined"),
    ("weights", "dict[str, float]", "Record<string, number>", '{"a": 1.0}', '{ a: 1.0 }'),
    ("active", "bool", "boolean", "True", "true"),
    ("region", "str", "string", '"apac"', '"apac"'),
    ("priority", "int", "number", "1", "1"),
    ("owner_id", "int", "number", "42", "42"),
    ("source_url", "str", "string", '"https://example.invalid"', '"https://example.invalid"'),
]
TARGET_LINES = 1000
STATUSES = ["DRAFT", "OPEN", "PENDING", "SETTLED", "ARCHIVED", "FAILED"]


def snake(name: str) -> str:
    out = []
    for i, ch in enumerate(name):
        if ch.isupper() and i:
            out.append("_")
        out.append(ch.lower())
    return "".join(out)


def camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(p.title() for p in rest)


def fields_for(index: int) -> list[tuple[str, str, str, str, str]]:
    # Rotate through the field pool so every entity has a different shape.
    count = 5 + index % 3
    return [FIELDS[(index * 5 + k) % len(FIELDS)] for k in range(count)]


def python_sample(ents: list[str]) -> str:
    lines = [
        '"""Generated M17 inference sample: many distinct names and types."""',
        "from __future__ import annotations",
        "",
        "import json",
        "import os",
        "import re",
        "from collections import Counter, defaultdict",
        "from dataclasses import dataclass, field",
        "from datetime import datetime, timedelta",
        "from enum import Enum",
        "from functools import reduce",
        "from itertools import chain",
        "from pathlib import Path",
        "from typing import Iterable, Optional, TypeVar",
        "",
        'T = TypeVar("T")',
        "",
    ]
    for i, ent in enumerate(ents):
        fs = fields_for(i)
        low = snake(ent)
        status = f"{ent}Status"
        lines += [
            "",
            f"class {status}(Enum):",
        ]
        for s in STATUSES[: 3 + i % 3]:
            lines.append(f'    {s} = "{s.lower()}_{low}"')
        lines += [
            "",
            "",
            "@dataclass",
            f"class {ent}:",
            f"    {low}_id: int",
        ]
        for fname, ptype, _, psample, _ in fs:
            if ptype.startswith(("list", "dict")):
                factory = "list" if ptype.startswith("list") else "dict"
                lines.append(f"    {low}_{fname}: {ptype} = field(default_factory={factory})")
            else:
                lines.append(f"    {low}_{fname}: {ptype} = {psample}")
        lines += [
            f"    status: {status} = {status}.{STATUSES[0]}",
            "",
            "    @property",
            f"    def display_{low}(self) -> str:",
            f'        return f"{ent}#{{self.{low}_id}}"',
            "",
            f"    def to_{low}_dict(self) -> dict[str, object]:",
            f'        payload = {{"id": self.{low}_id, "status": self.status.value}}',
            "        return payload",
            "",
            "",
            f"class {ent}Repository:",
            "    def __init__(self, root: Path) -> None:",
            f"        self.{low}_root = root",
            f"        self.{low}_items: dict[int, {ent}] = {{}}",
            f"        self.{low}_history: list[tuple[int, datetime]] = []",
            "",
            f"    def add_{low}(self, item: {ent}) -> None:",
            f"        self.{low}_items[item.{low}_id] = item",
            f"        self.{low}_history.append((item.{low}_id, datetime.now()))",
            "",
            f"    def find_{low}(self, key: int) -> Optional[{ent}]:",
            f"        return self.{low}_items.get(key)",
            "",
            f"    def active_{low}s(self) -> list[{ent}]:",
            f"        return [x for x in self.{low}_items.values() if x.status is not {status}.{STATUSES[0]}]",
            "",
            f"    def save_{low}s(self) -> Path:",
            f'        target = self.{low}_root / "{low}s.json"',
            f"        rows = [entry.to_{low}_dict() for entry in self.{low}_items.values()]",
            '        with open(target, "w", encoding="utf-8") as handle:',
            "            json.dump(rows, handle)",
            "        return target",
            "",
            "",
            f"def summarize_{low}s(items: Iterable[{ent}]) -> dict[str, int]:",
            f"    {low}_counter: Counter[str] = Counter()",
            "    for item in items:",
            f"        {low}_counter[item.status.value] += 1",
            f"    return dict({low}_counter)",
            "",
            "",
            f"def group_{low}s(items: list[{ent}]) -> dict[str, list[{ent}]]:",
            f"    {low}_groups: defaultdict[str, list[{ent}]] = defaultdict(list)",
            "    for item in items:",
            f"        {low}_groups[item.status.name].append(item)",
            f"    return {low}_groups",
            "",
            "",
            f"def parse_{low}_line(line: str) -> Optional[{ent}]:",
            rf"    match = re.match(r'(\d+)\s+(\w+)', line)",
            "    if match is None:",
            "        return None",
            f"    {low}_key = int(match.group(1))",
            f"    return {ent}({low}_id={low}_key)",
        ]
    lines += [
        "",
        "",
        "def first_or_default(values: list[T], default: T) -> T:",
        "    return values[0] if values else default",
        "",
        "",
        "def build_report(root: Path) -> str:",
        '    report_lines: list[str] = []',
        "    deadline = datetime.now() + timedelta(days=7)",
        '    env_name = os.environ.get("KARU_SAMPLE_ENV", "dev")',
    ]
    for ent in ents[:12]:
        low = snake(ent)
        lines += [
            f"    {low}_repo = {ent}Repository(root)",
            f"    {low}_summary = summarize_{low}s({low}_repo.active_{low}s())",
            f'    report_lines.append(f"{low}: {{{low}_summary}} until {{deadline:%Y-%m-%d}} on {{env_name}}")',
        ]
    lines += [
        '    flat = list(chain.from_iterable(line.split(":") for line in report_lines))',
        "    total = reduce(lambda acc, part: acc + len(part), flat, 0)",
        '    return "\\n".join(report_lines) + f"\\n{total}"',
        "",
    ]
    return "\n".join(lines) + "\n"


def ts_sample(ents: list[str]) -> str:
    lines = [
        "// Generated M17 inference sample: many distinct names and types.",
        "",
        "type Identifier = number;",
        "type Maybe<T> = T | undefined;",
        "",
        "interface Page<T> {",
        "  items: T[];",
        "  cursor: Maybe<string>;",
        "  total: number;",
        "}",
        "",
        "function firstOrDefault<T>(values: T[], fallback: T): T {",
        "  return values.length > 0 ? values[0] : fallback;",
        "}",
    ]
    for i, ent in enumerate(ents):
        fs = fields_for(i)
        low = camel(snake(ent))
        status = f"{ent}Status"
        lines += ["", f"export enum {status} {{"]
        for s in STATUSES[: 3 + i % 3]:
            lines.append(f'  {s.title()} = "{s.lower()}_{low}",')
        lines += [
            "}",
            "",
            f"export interface {ent}Record {{",
            f"  {low}Id: Identifier;",
        ]
        for fname, _, ttype, _, _ in fs:
            lines.append(f"  {low}{camel(fname)[0].upper()}{camel(fname)[1:]}: {ttype};")
        lines += [
            f"  status: {status};",
            "}",
            "",
            f"export class {ent}Store {{",
            f"  private readonly {low}Items = new Map<Identifier, {ent}Record>();",
            f"  private {low}Log: Array<[Identifier, Date]> = [];",
            "",
            f"  constructor(private readonly {low}Endpoint: string) {{}}",
            "",
            f"  add{ent}(record: {ent}Record): void {{",
            f"    this.{low}Items.set(record.{low}Id, record);",
            f"    this.{low}Log.push([record.{low}Id, new Date()]);",
            "  }",
            "",
            f"  find{ent}(key: Identifier): Maybe<{ent}Record> {{",
            f"    return this.{low}Items.get(key);",
            "  }",
            "",
            f"  active{ent}s(): {ent}Record[] {{",
            f"    return [...this.{low}Items.values()].filter((x) => x.status !== {status}.{STATUSES[0].title()});",
            "  }",
            "",
            f"  async fetch{ent}Page(cursor?: string): Promise<Page<{ent}Record>> {{",
            f"    const response = await fetch(`${{this.{low}Endpoint}}?cursor=${{cursor ?? \"\"}}`);",
            f"    const body = (await response.json()) as Page<{ent}Record>;",
            "    return body;",
            "  }",
            "}",
            "",
            f"export function summarize{ent}s(items: {ent}Record[]): Record<string, number> {{",
            f"  const {low}Counts: Record<string, number> = {{}};",
            "  for (const item of items) {",
            f"    {low}Counts[item.status] = ({low}Counts[item.status] ?? 0) + 1;",
            "  }",
            f"  return {low}Counts;",
            "}",
            "",
            f"export const group{ent}s = (items: {ent}Record[]): Map<{status}, {ent}Record[]> => {{",
            f"  const {low}Groups = new Map<{status}, {ent}Record[]>();",
            "  items.forEach((item) => {",
            f"    const bucket = {low}Groups.get(item.status) ?? [];",
            "    bucket.push(item);",
            f"    {low}Groups.set(item.status, bucket);",
            "  });",
            f"  return {low}Groups;",
            "};",
            "",
            f"export function parse{ent}Line(line: string): Maybe<Pick<{ent}Record, \"{low}Id\" | \"status\">> {{",
            r"  const match = /^(\d+)\s+(\w+)/.exec(line);",
            "  if (!match) {",
            "    return undefined;",
            "  }",
            f"  return {{ {low}Id: Number(match[1]), status: {status}.{STATUSES[0].title()} }};",
            "}",
        ]
    lines += [
        "",
        "export async function buildReport(endpoint: string): Promise<string> {",
        "  const reportLines: string[] = [];",
        "  const deadline = new Date(Date.now() + 7 * 24 * 3600 * 1000);",
    ]
    for ent in ents[:12]:
        low = camel(snake(ent))
        lines += [
            f"  const {low}Store = new {ent}Store(endpoint);",
            f"  const {low}Summary = summarize{ent}s({low}Store.active{ent}s());",
            f"  reportLines.push(`{low}: ${{JSON.stringify({low}Summary)}} until ${{deadline.toISOString()}}`);",
        ]
    lines += [
        "  const flat = reportLines.flatMap((line) => line.split(\":\"));",
        "  const total = flat.reduce((acc, part) => acc + part.length, 0);",
        "  return `${reportLines.join(\"\\n\")}\\n${total}`;",
        "}",
        "",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    def sized(build) -> str:
        # Largest entity count whose output stays at or under ~1000 lines.
        best = build(ENTITIES[:1])
        for n in range(2, len(ENTITIES) + 1):
            text = build(ENTITIES[:n])
            if text.count("\n") > TARGET_LINES:
                break
            best = text
        return best

    for name, text in (("sample_1000.py", sized(python_sample)), ("sample_1000.ts", sized(ts_sample))):
        path = OUT / name
        path.write_text(text, encoding="utf-8")
        print(f"{path.relative_to(ROOT)}: {text.count(chr(10))} lines, {len(text.encode())} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
