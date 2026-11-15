#!/bin/bash
# Karu 内存基准脚本（T5.1）
# 对照 docs/ARCHITECTURE.md §1 硬性预算表，采样 .build/release/KaruApp
# 在若干场景下的 phys_footprint 常驻内存，并输出对照报告。
#
# 稳定采样：每轮启动后持续轮询 phys_footprint，直到最近 2 s 内的读数
# 波动不超过 0.5 MB 才取值（最长等 20 s；超时取最后读数并标注“未稳定”），
# 并输出读数稳定的时刻（距启动秒数）。固定 3 s 采样会随启动时序落在一次
# 数十 MB 阶跃之前或之后，造成假回归。可用环境变量调整：
#   KARU_BENCH_STABLE_SECONDS（默认 2）、KARU_BENCH_STABLE_TOLERANCE_KB（默认 512）、
#   KARU_BENCH_MAX_WAIT_SECONDS（默认 20）、KARU_BENCH_MIN_WAIT_SECONDS（默认 0）。
# KARU_BENCH_MIN_WAIT_SECONDS（T17.15d）为最短观察时间：启动后这段时间内的读数
# 不参与稳定判定，稳定区间必须整个落在它之后，因此读数最早在
# 「最短观察时间 + 稳定窗口」时取得。用于主线程阻塞、内存暂时不动而被提前取值的
# 构建（如 v0.12.0 打开 10 MB 时 1.2 s 取到台阶前的 63 MB，3.7 s 才跳到 104 MB）。
# 最长等待不足「最短观察时间 + 稳定窗口」时自动延长到该值。默认 0 与旧版行为相同。
set -euo pipefail
cd "$(dirname "$0")/.."

# KARU_BENCH_APP_BIN 可覆盖被测二进制（例如同机 A/B 对照的基线版构建）；
# 覆盖时不执行 swift build。未设置时行为不变。
APP_BIN="${KARU_BENCH_APP_BIN:-.build/release/KaruApp}"

if [[ -n "${KARU_BENCH_APP_BIN:-}" ]]; then
    echo "== [1/4] 使用 KARU_BENCH_APP_BIN=$APP_BIN（跳过 swift build） =="
else
    echo "== [1/4] swift build -c release =="
    swift build -c release
fi

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
    """Auto-generated function for Karu memory benchmark."""
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
# 已确认 Sources/KaruApp/main.swift 和
# Sources/KaruCore/Editor/EditorWindowController.swift 均无 CommandLine
# 参数解析或 application(_:openFile:) / application(_:open:) 处理路径，
# 因此该 app 不支持通过命令行参数打开文件。带文件的两轮采样标记为 SKIPPED。
CLI_OPEN_SUPPORTED=0
if grep -rq "CommandLine" Sources/KaruApp Sources/KaruCore 2>/dev/null \
    || grep -rq "openFile\|application(_ application: NSApplication, open" Sources/KaruCore 2>/dev/null; then
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
    # -f bytes：默认格式按整 MB 取整，稳定判定需要更细的读数。
    kb=$(footprint -f bytes --noCategories "$pid" 2>/dev/null | awk '
        /phys_footprint:/ {
            val = $2; unit = $3
            if (unit == "B") val = int(val / 1024)
            else if (unit == "MB") val = val * 1024
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

STABLE_SECONDS="${KARU_BENCH_STABLE_SECONDS:-2}"
STABLE_TOLERANCE_KB="${KARU_BENCH_STABLE_TOLERANCE_KB:-512}"
MAX_WAIT_SECONDS="${KARU_BENCH_MAX_WAIT_SECONDS:-20}"
MIN_WAIT_SECONDS="${KARU_BENCH_MIN_WAIT_SECONDS:-0}"
# 最短观察时间之后至少还要留出一个稳定窗口。
MAX_WAIT_SECONDS=$(awk -v m="$MAX_WAIT_SECONDS" -v n="$MIN_WAIT_SECONDS" -v w="$STABLE_SECONDS" \
    'BEGIN{ x = n + w; if (m + 0 < x) print x; else print m }')

now_seconds() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# 轮询 pid 的 phys_footprint 直到稳定。参数：pid、启动时刻（now_seconds）。
# 输出一行 "<KB> <稳定时刻s|UNSTABLE>"；稳定时刻为稳定区间起点距启动的秒数。
# 一次读数都拿不到时返回 1。
wait_for_stable_footprint() {
    local pid="$1" t0="$2"
    local ts="" kbs="" kb="" last_kb="" t="" settled=""
    while :; do
        t=$(awk -v a="$(now_seconds)" -v b="$t0" 'BEGIN{printf "%.2f", a-b}')
        if kb=$(sample_phys_footprint_kb "$pid"); then
            last_kb="$kb"
            ts="$ts $t"; kbs="$kbs $kb"
            # 从最新读数向前回看：区间内 max-min 不超过容差且跨度达到窗口即视为稳定。
            # 早于最短观察时间（KARU_BENCH_MIN_WAIT_SECONDS）的读数不算进区间。
            settled=$(awk -v ts="$ts" -v kbs="$kbs" -v win="$STABLE_SECONDS" -v tol="$STABLE_TOLERANCE_KB" \
                -v minw="$MIN_WAIT_SECONDS" 'BEGIN{
                n = split(ts, T, " "); split(kbs, K, " ")
                mn = K[n]; mx = K[n]
                for (i = n; i >= 1; i--) {
                    if (T[i] + 0 < minw + 0) break
                    if (K[i] + 0 < mn) mn = K[i] + 0
                    if (K[i] + 0 > mx) mx = K[i] + 0
                    if (mx - mn > tol) break
                    if (T[n] - T[i] >= win) { printf "%.1f", T[i]; exit }
                }
            }')
            if [[ -n "$settled" ]]; then
                echo "$kb $settled"
                return 0
            fi
        elif ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if awk -v t="$t" -v m="$MAX_WAIT_SECONDS" 'BEGIN{exit !(t >= m)}'; then
            break
        fi
        sleep 0.2
    done
    [[ -n "$last_kb" ]] || return 1
    echo "$last_kb UNSTABLE"
}

# 运行一轮采样。参数：轮次名称，其余参数作为传给 app 的启动参数（可为空）。
# 标准输出一行 "<KB> <稳定时刻s|UNSTABLE>"（采样失败时为空）。
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
    local t0
    t0=$(now_seconds)

    local result=""
    if ! result=$(wait_for_stable_footprint "$pid" "$t0"); then
        echo "WARN: 无法采样 pid=$pid 的内存（footprint 与 ps 均失败）" >&2
        result=""
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    echo "$result"
}

# "<稳定时刻>" → 显示文本（UNSTABLE 显示为“未稳定(>N s)”）。
stable_str() {
    case "$1" in
        "") echo "N/A" ;;
        UNSTABLE) echo "未稳定(>${MAX_WAIT_SECONDS}s)" ;;
        *) echo "${1}s" ;;
    esac
}

echo ""
echo "== [4/4] 三轮采样 =="
if awk -v n="$MIN_WAIT_SECONDS" 'BEGIN{exit !(n + 0 > 0)}'; then
    echo "最短观察时间 ${MIN_WAIT_SECONDS}s（KARU_BENCH_MIN_WAIT_SECONDS），最长等待 ${MAX_WAIT_SECONDS}s"
fi

read -r ROUND1_KB ROUND1_STABLE <<< "$(run_round "空文档启动基线")" || true
echo "空文档启动基线 phys_footprint: ${ROUND1_KB:-N/A} KB（稳定于 $(stable_str "${ROUND1_STABLE:-}")）" >&2

if [[ "$CLI_OPEN_SUPPORTED" -eq 1 ]]; then
    read -r ROUND2_KB ROUND2_STABLE <<< "$(run_round "打开 medium.json" "$MEDIUM_FILE")" || true
    ROUND2_STATUS="MEASURED"
    echo "打开 medium.json phys_footprint: ${ROUND2_KB:-N/A} KB（稳定于 $(stable_str "${ROUND2_STABLE:-}")）" >&2

    read -r ROUND3_KB ROUND3_STABLE <<< "$(run_round "打开 large.py" "$LARGE_FILE")" || true
    ROUND3_STATUS="MEASURED"
    echo "打开 large.py phys_footprint: ${ROUND3_KB:-N/A} KB（稳定于 $(stable_str "${ROUND3_STABLE:-}")）" >&2
else
    ROUND2_KB=""; ROUND2_STABLE=""
    ROUND2_STATUS="SKIPPED"
    ROUND3_KB=""; ROUND3_STABLE=""
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

printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "轮次" "实测(MB)" "预算目标(MB)" "上限(MB)" "结果" "稳定于"
printf '%-22s-+-%-10s-+-%-12s-+-%-8s-+-%-6s-+-%s\n' "----------------------" "----------" "------------" "--------" "------" "------"

# 轮次 1：空文档启动基线，预算见 ARCHITECTURE.md：目标 20-30 MB，上限 99 MB
ROUND1_MB="$(kb_to_mb_str "$ROUND1_KB")"
ROUND1_RESULT="FAIL"
if [[ -n "$ROUND1_KB" ]]; then
    if awk -v mb="$ROUND1_MB" 'BEGIN{exit !(mb <= 99)}'; then
        ROUND1_RESULT="PASS"
    else
        ROUND1_RESULT="FAIL"
        OVERALL_FAIL=1
    fi
else
    ROUND1_RESULT="FAIL"
    OVERALL_FAIL=1
fi
printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "空文档启动基线" "$ROUND1_MB" "20-30" "99" "$ROUND1_RESULT" "$(stable_str "${ROUND1_STABLE:-}")"

# 轮次 2：打开中等文件（全功能空闲常驻），预算：目标 30-45 MB，上限 99 MB
if [[ "$ROUND2_STATUS" == "SKIPPED" ]]; then
    printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "打开 medium.json" "N/A" "30-45" "99" "SKIPPED" "N/A"
else
    ROUND2_MB="$(kb_to_mb_str "$ROUND2_KB")"
    ROUND2_RESULT="FAIL"
    if [[ -n "$ROUND2_KB" ]] && awk -v mb="$ROUND2_MB" 'BEGIN{exit !(mb <= 99)}'; then
        ROUND2_RESULT="PASS"
    else
        OVERALL_FAIL=1
    fi
    printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "打开 medium.json" "$ROUND2_MB" "30-45" "99" "$ROUND2_RESULT" "$(stable_str "${ROUND2_STABLE:-}")"
fi

# 轮次 3：打开大文件（~10 MB），预算：目标 50-60 MB，上限 99 MB（ARCHITECTURE.md §1）
if [[ "$ROUND3_STATUS" == "SKIPPED" ]]; then
    printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "打开 large.py" "N/A" "50-60" "99" "SKIPPED" "N/A"
else
    ROUND3_MB="$(kb_to_mb_str "$ROUND3_KB")"
    ROUND3_RESULT="FAIL"
    if [[ -n "$ROUND3_KB" ]] && awk -v mb="$ROUND3_MB" 'BEGIN{exit !(mb <= 99)}'; then
        ROUND3_RESULT="PASS"
    else
        OVERALL_FAIL=1
    fi
    printf '%-22s | %-10s | %-12s | %-8s | %-6s | %s\n' "打开 large.py" "$ROUND3_MB" "50-60" "99" "$ROUND3_RESULT" "$(stable_str "${ROUND3_STABLE:-}")"
fi

echo ""
if [[ "$CLI_OPEN_SUPPORTED" -eq 0 ]]; then
    echo "说明：KaruApp 当前无命令行参数打开文件的路径"
    echo "（Sources/KaruApp/main.swift、Sources/KaruCore/Editor/EditorWindowController.swift"
    echo " 均未检测到 CommandLine 参数解析或 application(_:open:) 处理），"
    echo "因此“打开 medium.json”“打开 large.py”两轮标记为 SKIPPED，仅完成空文档启动基线一轮实测。"
fi

# ---- 推断样本（参考，M17 T17.0）----
# 1000 行量级、名字与类型多样的 Python / TS 样本（scripts/m17/gen-inference-samples.py
# 生成），仅作参考读数：只检查 99 MB 上限，不设预算目标，不改动上面三个正式场景。
REF_PY="Tests/Fixtures/M17/inference/sample_1000.py"
REF_TS="Tests/Fixtures/M17/inference/sample_1000.ts"

echo ""
echo "== 推断样本（参考） =="
echo ""
# 上面各轮以 kill 结束，未标记正常退出；未隔离时下一次启动会恢复上一轮打开的临时文件，
# 参考轮读数会混入它们。调用方未设置 KARU_DIAGNOSTIC_DIRECTORY 时，仅为参考轮设置
# 一个临时诊断目录（每次启动清空诊断会话），正式三轮的运行方式不变。
REF_DIAG_DOMAIN=""
if [[ -z "${KARU_DIAGNOSTIC_DIRECTORY:-}" ]]; then
    export KARU_DIAGNOSTIC_DIRECTORY="$TMP_DIR/karu-bench-diag"
    mkdir -p "$KARU_DIAGNOSTIC_DIRECTORY"
    REF_DIAG_DOMAIN="dev.enkin.Karu.Diagnostics.karu-bench-diag"
    echo "（参考轮使用临时诊断目录隔离会话；正式三轮未隔离。按 LEDGER 口径应整体设置 KARU_DIAGNOSTIC_DIRECTORY 运行。）"
fi
if [[ "$CLI_OPEN_SUPPORTED" -eq 1 ]]; then
    REF1_KB=""; REF2_KB=""; REF1_STABLE=""; REF2_STABLE=""
    if [[ -f "$REF_PY" ]]; then
        read -r REF1_KB REF1_STABLE <<< "$(run_round "打开 sample_1000.py（参考）" "$REF_PY")" || true
    fi
    if [[ -f "$REF_TS" ]]; then
        read -r REF2_KB REF2_STABLE <<< "$(run_round "打开 sample_1000.ts（参考）" "$REF_TS")" || true
    fi
    printf '%-22s | %-10s | %-8s | %-6s | %s\n' "轮次" "实测(MB)" "上限(MB)" "结果" "稳定于"
    printf '%-22s-+-%-10s-+-%-8s-+-%-6s-+-%s\n' "----------------------" "----------" "--------" "------" "------"
    for pair in "sample_1000.py|$REF_PY|$REF1_KB|$REF1_STABLE" "sample_1000.ts|$REF_TS|$REF2_KB|$REF2_STABLE"; do
        IFS='|' read -r ref_name ref_path ref_kb ref_stable <<< "$pair"
        if [[ ! -f "$ref_path" ]]; then
            printf '%-22s | %-10s | %-8s | %-6s | %s\n' "打开 $ref_name" "N/A" "99" "SKIPPED（缺少样本）" "N/A"
            continue
        fi
        ref_mb="$(kb_to_mb_str "$ref_kb")"
        ref_result="FAIL"
        if [[ -n "$ref_kb" ]] && awk -v mb="$ref_mb" 'BEGIN{exit !(mb <= 99)}'; then
            ref_result="PASS"
        else
            OVERALL_FAIL=1
        fi
        printf '%-22s | %-10s | %-8s | %-6s | %s\n' "打开 $ref_name" "$ref_mb" "99" "$ref_result" "$(stable_str "$ref_stable")"
    done
else
    echo "推断样本两轮已跳过：app 无 CLI 打开文件路径。"
fi
# 清理上面为参考轮临时创建的诊断 defaults 域。
if [[ -n "$REF_DIAG_DOMAIN" ]]; then
    defaults delete "$REF_DIAG_DOMAIN" >/dev/null 2>&1 || true
fi

if [[ "$OVERALL_FAIL" -ne 0 ]]; then
    echo ""
    echo "RESULT: 存在 FAIL 项，退出码非 0。"
    exit 1
fi

echo ""
echo "RESULT: 全部已执行轮次 PASS。"
exit 0
