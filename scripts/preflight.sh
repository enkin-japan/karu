#!/bin/bash
# Karu 发布前检查：在干净的工作区上跑完整测试、视觉冒烟和内存基准，全部通过后
# 把结果记到 build/preflight/<提交号>.json。scripts/release-macos.sh 没有当前提交的
# 通过记录就拒绝继续。
#
# 规则：
# - 工作区必须干净（含未跟踪文件）。检查的是“这个提交”，不是“这个提交加上手头的改动”。
# - 三步按顺序跑，任何一步失败就停，不写记录。内存基准退出码 2（没有通过证据）也算失败。
# - 跑完后再核对一次：提交号没变、工作区仍然干净，才写记录。
# - 本脚本不签名、不公证、不安装，也不读写任何密钥。
#
# 各步的完整输出在 build/preflight/<提交号>-<步骤>.log。
set -euo pipefail
cd "$(dirname "$0")/.."

RECORD_DIR="build/preflight"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "PREFLIGHT REFUSED：工作区不干净，先提交或清理。" >&2
    git status --short >&2
    exit 1
fi

COMMIT="$(git rev-parse HEAD)"
RECORD="$RECORD_DIR/$COMMIT.json"
mkdir -p "$RECORD_DIR"
# 重跑时先作废旧记录：中途失败不能留下一份“通过”。
rm -f "$RECORD"

STEP_NAMES=()
STEP_EXITS=()
STEP_SECONDS=()

# run_step <名称> <命令…>：输出同时写到日志和终端，记录退出码与耗时；失败即停。
run_step() {
    local name="$1"; shift
    local log="$RECORD_DIR/$COMMIT-$name.log"
    local started=$SECONDS status=0
    echo ""
    echo "== 发布前检查：$name =="
    set +e
    "$@" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    STEP_NAMES+=("$name")
    STEP_EXITS+=("$status")
    STEP_SECONDS+=("$((SECONDS - started))")
    if [[ "$status" -ne 0 ]]; then
        echo "" >&2
        echo "PREFLIGHT FAILED：$name 退出码 $status（日志：$log）。未写入通过记录。" >&2
        if [[ "$name" == "mem-benchmark" && "$status" -eq 2 ]]; then
            echo "退出码 2 表示内存基准没有拿到通过证据（回退到 RSS、读数未稳定、文件没有真的打开等），不是超预算。" >&2
        fi
        exit 1
    fi
}

run_step tests scripts/test.sh
run_step visual-smoke scripts/visual-smoke.sh
run_step mem-benchmark scripts/mem-benchmark.sh

if [[ "$(git rev-parse HEAD)" != "$COMMIT" || -n "$(git status --porcelain)" ]]; then
    echo "PREFLIGHT FAILED：检查期间提交号或工作区发生了变化。未写入通过记录。" >&2
    git status --short >&2
    exit 1
fi

TOOLCHAIN="$(swift --version 2>&1 | head -1)"
MACOS="$(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
python3 - "$RECORD" "$COMMIT" "$TOOLCHAIN" "$MACOS" \
    "${STEP_NAMES[*]}" "${STEP_EXITS[*]}" "${STEP_SECONDS[*]}" <<'PY'
import datetime
import json
import sys

record, commit, toolchain, macos, names, exits, seconds = sys.argv[1:8]
steps = [
    {"name": name, "exit": int(code), "seconds": int(duration)}
    for name, code, duration in zip(names.split(), exits.split(), seconds.split())
]
with open(record, "w", encoding="utf-8") as handle:
    json.dump({
        "commit": commit,
        "result": "pass",
        "finishedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "toolchain": toolchain,
        "macOS": macos,
        "steps": steps,
    }, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

echo ""
echo "PREFLIGHT OK：$RECORD"
