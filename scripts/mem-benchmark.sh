#!/bin/bash
# TinyEditor 内存基准脚本（T5.1）
# 对照 docs/ARCHITECTURE.md §1 硬性预算表，采样 .build/release/TinyEditorApp
# 在若干场景下的 phys_footprint 常驻内存，并输出对照报告。
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BIN=".build/release/TinyEditorApp"

echo "== [1/4] swift build -c release =="
swift build -c release

if [[ ! -x "$APP_BIN" ]]; then
    echo "ERROR: $APP_BIN not found or not executable after build" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

EMPTY_FILE="$TMP_DIR/empty.json"
MEDIUM_FILE="$TMP_DIR/medium.json"
LARGE_FILE="$TMP_DIR/large.py"

echo ""
echo "== [2/4] 生成测试文件（${TMP_DIR}） =="

# empty.json：空文件
: > "$EMPTY_FILE"

# medium.json：约 1 MB 的合法 JSON 数组，几万行，用循环生成
medium_target_bytes=$((1 * 1024 * 1024))
sample_line='  {"id":1,"name":"item-1"},'
line_bytes=$(( ${#sample_line} + 1 )) # 含换行符
medium_count=$(( medium_target_bytes / line_bytes ))
if (( medium_count < 20000 )); then
    medium_count=20000
fi
{
    echo "["
    for ((i = 1; i <= medium_count; i++)); do
        if (( i < medium_count )); then
            printf '  {"id":%d,"name":"item-%d"},\n' "$i" "$i"
        else
            printf '  {"id":%d,"name":"item-%d"}\n' "$i" "$i"
        fi
    done
    echo "]"
} > "$MEDIUM_FILE"

# large.py：约 10 MB 的重复 Python 函数文本，用 yes 生成
py_block=$(cat <<'PYEOF'
def sample_function(a, b, c):
    """Auto-generated function for TinyEditor memory benchmark."""
    result = a + b + c
    for i in range(10):
        result += i
    return result

PYEOF
)
large_target_bytes=$((10 * 1024 * 1024))
# `yes` 在 `head -c` 读满字节后会收到 SIGPIPE（退出码 141），
# 在 pipefail 下会被误判为管道失败，此处临时关闭 pipefail 规避。
set +o pipefail
yes "$py_block" | head -c "$large_target_bytes" > "$LARGE_FILE"
set -o pipefail

echo "empty.json : $(wc -c < "$EMPTY_FILE") bytes"
echo "medium.json: $(wc -c < "$MEDIUM_FILE") bytes ($medium_count 行 JSON 数组)"
echo "large.py   : $(wc -c < "$LARGE_FILE") bytes"

echo ""
echo "== [3/4] 检查 CLI 打开文件能力 =="
# 已确认 Sources/TinyEditorApp/main.swift 和
# Sources/TinyEditorCore/Editor/EditorWindowController.swift 均无 CommandLine
# 参数解析或 application(_:openFile:) / application(_:open:) 处理路径，
# 因此该 app 不支持通过命令行参数打开文件。带文件的两轮采样标记为 SKIPPED。
CLI_OPEN_SUPPORTED=0
if grep -rq "CommandLine" Sources/TinyEditorApp Sources/TinyEditorCore 2>/dev/null \
    || grep -rq "openFile\|application(_ application: NSApplication, open" Sources/TinyEditorCore 2>/dev/null; then
    CLI_OPEN_SUPPORTED=1
fi

if [[ "$CLI_OPEN_SUPPORTED" -eq 1 ]]; then
    echo "检测到 CLI 打开路径，带文件轮将尝试实际打开 medium.json / large.py。"
else
    echo "未检测到 CLI 打开路径：medium.json / large.py 两轮将标记为 SKIPPED。"
fi

# 采样 phys_footprint（KB）。优先使用 footprint，无权限或不可用时回退到 ps -o rss=（已是 KB）。
sample_phys_footprint_kb() {
    local pid="$1"
    local kb=""
    kb=$(footprint "$pid" 2>/dev/null | awk '
        /phys_footprint:/ {
            val = $2; unit = $3
            if (unit == "MB") val = val * 1024
            else if (unit == "GB") val = val * 1024 * 1024
            print val
            exit
        }
    ' || true)
    if [[ -n "$kb" ]]; then
        echo "$kb"
        return 0
    fi
    # 回退：ps 的 rss 列单位固定为 KB
    kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$kb" ]]; then
        echo "$kb"
        return 0
    fi
    return 1
}

# 运行一轮采样。参数：轮次名称，其余参数作为传给 app 的启动参数（可为空）。
run_round() {
    local round_name="$1"
    shift
    local -a launch_args=("$@")

    echo "" >&2
    echo "---- 轮次: $round_name ----" >&2
    # macOS 自带 bash 3.2 下，空数组的 "${arr[@]}" 在 set -u 时会报
    # unbound variable，因此按数组是否为空分两种方式启动。
    if [[ ${#launch_args[@]} -gt 0 ]]; then
        "$APP_BIN" "${launch_args[@]}" &
    else
        "$APP_BIN" &
    fi
    local pid=$!
    sleep 3

    local kb=""
    if ! kb=$(sample_phys_footprint_kb "$pid"); then
        echo "WARN: 无法采样 pid=$pid 的内存（footprint 与 ps 均失败）" >&2
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo "$kb"
}

echo ""
echo "== [4/4] 三轮采样 =="

ROUND1_KB="$(run_round "空文档启动基线")"
echo "空文档启动基线 phys_footprint: ${ROUND1_KB:-N/A} KB" >&2

if [[ "$CLI_OPEN_SUPPORTED" -eq 1 ]]; then
    ROUND2_KB="$(run_round "打开 medium.json" "$MEDIUM_FILE")"
    ROUND2_STATUS="MEASURED"
    echo "打开 medium.json phys_footprint: ${ROUND2_KB:-N/A} KB" >&2

    ROUND3_KB="$(run_round "打开 large.py" "$LARGE_FILE")"
    ROUND3_STATUS="MEASURED"
    echo "打开 large.py phys_footprint: ${ROUND3_KB:-N/A} KB" >&2
else
    ROUND2_KB=""
    ROUND2_STATUS="SKIPPED"
    ROUND3_KB=""
    ROUND3_STATUS="SKIPPED"
    echo "打开 medium.json / large.py 两轮已跳过：app 无 CLI 打开文件路径。" >&2
fi

# ---- 生成对照表 ----
echo ""
echo "== 内存基准对照表（对照 docs/ARCHITECTURE.md §1） =="
echo ""

OVERALL_FAIL=0

kb_to_mb_str() {
    local kb="$1"
    if [[ -z "$kb" ]]; then
        echo "N/A"
        return
    fi
    awk -v kb="$kb" 'BEGIN{printf "%.1f", kb/1024}'
}

printf '%-22s | %-10s | %-12s | %-8s | %s\n' "轮次" "实测(MB)" "预算目标(MB)" "上限(MB)" "结果"
printf '%-22s-+-%-10s-+-%-12s-+-%-8s-+-%s\n' "----------------------" "----------" "------------" "--------" "------"

# 轮次 1：空文档启动基线，预算见 ARCHITECTURE.md：目标 20-30 MB，上限 35 MB
ROUND1_MB="$(kb_to_mb_str "$ROUND1_KB")"
ROUND1_RESULT="FAIL"
if [[ -n "$ROUND1_KB" ]]; then
    if awk -v mb="$ROUND1_MB" 'BEGIN{exit !(mb <= 35)}'; then
        ROUND1_RESULT="PASS"
    else
        ROUND1_RESULT="FAIL"
        OVERALL_FAIL=1
    fi
else
    ROUND1_RESULT="FAIL"
    OVERALL_FAIL=1
fi
printf '%-22s | %-10s | %-12s | %-8s | %s\n' "空文档启动基线" "$ROUND1_MB" "20-30" "35" "$ROUND1_RESULT"

# 轮次 2：打开中等文件（全功能空闲常驻），预算：目标 30-45 MB，上限 50 MB
if [[ "$ROUND2_STATUS" == "SKIPPED" ]]; then
    printf '%-22s | %-10s | %-12s | %-8s | %s\n' "打开 medium.json" "N/A" "30-45" "50" "SKIPPED"
else
    ROUND2_MB="$(kb_to_mb_str "$ROUND2_KB")"
    ROUND2_RESULT="FAIL"
    if [[ -n "$ROUND2_KB" ]] && awk -v mb="$ROUND2_MB" 'BEGIN{exit !(mb <= 50)}'; then
        ROUND2_RESULT="PASS"
    else
        OVERALL_FAIL=1
    fi
    printf '%-22s | %-10s | %-12s | %-8s | %s\n' "打开 medium.json" "$ROUND2_MB" "30-45" "50" "$ROUND2_RESULT"
fi

# 轮次 3：打开大文件（同样按全功能空闲常驻预算对照，量级参考）
if [[ "$ROUND3_STATUS" == "SKIPPED" ]]; then
    printf '%-22s | %-10s | %-12s | %-8s | %s\n' "打开 large.py" "N/A" "30-45" "50" "SKIPPED"
else
    ROUND3_MB="$(kb_to_mb_str "$ROUND3_KB")"
    ROUND3_RESULT="FAIL"
    if [[ -n "$ROUND3_KB" ]] && awk -v mb="$ROUND3_MB" 'BEGIN{exit !(mb <= 50)}'; then
        ROUND3_RESULT="PASS"
    else
        OVERALL_FAIL=1
    fi
    printf '%-22s | %-10s | %-12s | %-8s | %s\n' "打开 large.py" "$ROUND3_MB" "30-45" "50" "$ROUND3_RESULT"
fi

echo ""
if [[ "$CLI_OPEN_SUPPORTED" -eq 0 ]]; then
    echo "说明：TinyEditorApp 当前无命令行参数打开文件的路径"
    echo "（Sources/TinyEditorApp/main.swift、Sources/TinyEditorCore/Editor/EditorWindowController.swift"
    echo " 均未检测到 CommandLine 参数解析或 application(_:open:) 处理），"
    echo "因此“打开 medium.json”“打开 large.py”两轮标记为 SKIPPED，仅完成空文档启动基线一轮实测。"
fi

if [[ "$OVERALL_FAIL" -ne 0 ]]; then
    echo ""
    echo "RESULT: 存在 FAIL 项，退出码非 0。"
    exit 1
fi

echo ""
echo "RESULT: 全部已执行轮次 PASS。"
exit 0
