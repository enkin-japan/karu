#!/usr/bin/env python3
"""Release gate: is there a passing preflight record for this commit?

Usage: check-preflight-record.py <record-directory> <commit>

Exit 0 and print one line when build/preflight/<commit>.json exists, names the
same commit, says "pass", and every step in it passed. Exit 1 with the reason
otherwise. The record is written by scripts/preflight.sh; this script never
writes anything.
"""
import json
import os
import sys

REQUIRED_STEPS = ("tests", "visual-smoke", "mem-benchmark")


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    directory, commit = sys.argv[1], sys.argv[2]
    path = os.path.join(directory, commit + ".json")
    if not os.path.isfile(path):
        print(f"没有当前提交的发布前检查记录：{path}", file=sys.stderr)
        return 1
    try:
        with open(path, encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"发布前检查记录读不出来：{path}（{error}）", file=sys.stderr)
        return 1
    if record.get("commit") != commit:
        print(f"记录里的提交号与当前提交不符：{record.get('commit')!r} != {commit!r}", file=sys.stderr)
        return 1
    if record.get("result") != "pass":
        print(f"记录的结论不是通过：{record.get('result')!r}", file=sys.stderr)
        return 1
    steps = {step.get("name"): step for step in record.get("steps", []) if isinstance(step, dict)}
    for name in REQUIRED_STEPS:
        step = steps.get(name)
        if step is None:
            print(f"记录缺少步骤：{name}", file=sys.stderr)
            return 1
        if step.get("exit") != 0:
            print(f"记录里步骤 {name} 的退出码不是 0：{step.get('exit')!r}", file=sys.stderr)
            return 1
    print(f"发布前检查记录有效：{path}（完成于 {record.get('finishedAt', '?')}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
