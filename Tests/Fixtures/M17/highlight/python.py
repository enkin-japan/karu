#!/usr/bin/env python3
"""Report builder for the nightly export job.

The module docstring spans several lines and mentions code-like words:
def not_a_function(): return 42  # still inside the docstring
class NotAClass: pass
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# A comment that contains a triple quote """ must not open a string.
# Another one with ''' and a "lonely quote.
PATTERN = re.compile(r"^(?P<key>[a-z_]+)\s*=\s*(?P<value>.+)$")
RAW_WINDOWS = r"C:\temp\new_folder\x41"
BYTES_BLOB = b"\x00\x01binary\"quote"
SINGLE = 'it\'s escaped'

SQL_TEMPLATE = """
SELECT id, name  -- not a Python comment
FROM users
WHERE name = '{name}'   # also not a comment
"""

RAW_BLOCK = r'''
Backslashes \n stay literal \t here.
The closing quote style differs: """ does not end this block.
'''


@dataclass
class Row:
    """A single exported row.

    Attributes:
        key: the identifier, e.g. "user_42".
        tags: free-form labels.
    """

    key: str
    value: float = 0.0
    tags: list[str] = field(default_factory=list)

    def label(self) -> str:
        return f"{self.key}={self.value:.2f}"

    def describe(self, verbose: bool = False) -> str:
        # Nested quotes inside an f-string replacement field.
        extra = f"tags={', '.join(t for t in self.tags)}" if verbose else ""
        return f"Row({self.key!r}, {self.value}, {extra or 'no tags'})"


def render_table(rows: list[Row], title: str = "Report") -> str:
    header = f"""
    <h1>{title.upper()}</h1>
    <p>Total: {len(rows)} rows, sum={sum(r.value for r in rows):.1f}</p>
    """
    body = "\n".join(
        f"<tr><td>{r.key}</td><td>{r.value}</td></tr>" for r in rows
    )
    nested = f"{'{'}literal braces{'}'} and {{doubled}} braces"
    deep = f"{rows[0].describe(verbose=True) if rows else f'empty {title!s}'}"
    return header + body + nested + deep


def parse_line(line: str) -> Row | None:
    match = PATTERN.match(line)
    if not match:
        return None
    key, raw = match.group("key"), match.group("value")
    try:
        value = float(raw)
    except ValueError:
        value = float("nan")  # "nan" is a string, not a keyword
    return Row(key, value)


def load(path: Path) -> list[Row]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            if line.startswith("#"):
                continue
            row = parse_line(line.rstrip("\n"))
            if row is None:
                print(f"skip line {number}: {line!r}")
                continue
            rows.append(row)
    return rows


MULTI_FSTRING = f"""Summary for {Path.home()}:
  * pattern: {PATTERN.pattern!r}
  * quote styles: {"double"} and {'single'}
"""

TRAILING = 'done'  # final line has a comment
