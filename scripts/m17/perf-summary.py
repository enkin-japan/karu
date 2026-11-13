#!/usr/bin/env python3
"""Summarise a KARU_PERFLOG timing log (M17 T17.0).

The log is written by Sources/KaruCore/App/PerfLog.swift when Karu runs with
KARU_PERFLOG=<path>. Each line is tab-separated:

    uptime_ns  event  duration_us  key=value  key=value ...

Prints count, p50, p95 and max of duration_us per event, and additionally per
value of the `result=` field (e.g. completion.request result=shown|dismissed).
Percentiles use the nearest-rank method.

Usage: python3 -I scripts/m17/perf-summary.py <log.tsv> [<log.tsv> ...]
"""
from __future__ import annotations

import math
import sys
from collections import defaultdict


def nearest_rank(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return float("nan")
    rank = max(1, math.ceil(pct / 100.0 * len(sorted_values)))
    return sorted_values[min(rank, len(sorted_values)) - 1]


def main(paths: list[str]) -> int:
    if not paths:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    groups: dict[str, list[float]] = defaultdict(list)
    bad = 0
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                cols = raw.rstrip("\n").split("\t")
                if len(cols) < 3:
                    if raw.strip():
                        bad += 1
                    continue
                try:
                    duration = float(cols[2])
                except ValueError:
                    bad += 1
                    continue
                event = cols[1]
                groups[event].append(duration)
                fields = dict(c.split("=", 1) for c in cols[3:] if "=" in c)
                if "result" in fields:
                    groups[f"{event} result={fields['result']}"].append(duration)

    if not groups:
        print("no events")
        return 1
    width = max(len(k) for k in groups)
    header = f"{'event':<{width}}  {'count':>7}  {'p50_us':>10}  {'p95_us':>10}  {'max_us':>10}"
    print(header)
    print("-" * len(header))
    for key in sorted(groups):
        values = sorted(groups[key])
        print(f"{key:<{width}}  {len(values):>7}  {nearest_rank(values, 50):>10.1f}  "
              f"{nearest_rank(values, 95):>10.1f}  {values[-1]:>10.1f}")
    if bad:
        print(f"(skipped {bad} malformed line(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
