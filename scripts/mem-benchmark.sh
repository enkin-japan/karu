#!/bin/bash
# Karu 内存基准脚本（T5.1；R11 起"通过"必须有证据）
# 对照 docs/ARCHITECTURE.md §1 硬性预算表，采样 .build/release/KaruApp
# 在若干场景下的 phys_footprint 常驻内存，并输出对照报告。
#
# 隔离：每次运行自建临时诊断目录（mktemp -d，退出时删除），每轮一个子目录，
# 每次启动都设置 KARU_DIAGNOSTIC_DIRECTORY（调用方设置的值被覆盖），会话、崩溃草稿、
# 草稿本都不碰开发者自己的；对应的诊断 defaults 域在退出时删除。
#
# 证据：每轮启动都带 KARU_BENCH_REPORT=<临时文件>，App 在首个窗口就绪后写出
# 实际打开的文档（realpath，未命名为空）、UTF-16 长度、窗口尺寸、是否可见 /
# 未被遮挡 / 在当前空间、backing scale、编辑窗口数（DiagnosticHost.swift）。
# 脚本核对：空文档轮必须是未命名且长度 0；文件轮必须正是该轮的文件且长度 > 0；
# 编辑窗口恰好 1 个且窗口可见。被遮挡只警告（读数与在屏运行不可比），不判无证据。
#
# 读数 = 数值 + 口径：优先 footprint 的 phys_footprint；footprint 不可用时回退到
# ps 的 RSS，但报告在每个数字旁标出口径，且 RSS 或混合口径的轮次一律判"无证据"
# ——预算按 phys_footprint 定义，两者不可比。
#
# 退出码：
#   0  每一轮都有证据且不超上限（超目标未超上限仍是 0，表中标出）。
#   1  至少一轮"有效证据"超过上限（优先于 2）。
#   2  无证据可判通过：任一轮回退到 RSS/混合口径、被跳过、读数未稳定、
#      没有读数、App 报告缺失或打开的不是预期文件；构建失败或二进制缺失也是 2。
#   其他非 0 值是脚本自身出错。
# 汇总行写明哪些轮缺证据及原因。
#
# 报告头记录：二进制路径与 SHA-256、git HEAD、工作树是否有未提交改动、分配器模式、
# macOS 版本与架构；每轮记录 App 报告字段，以及 footprint 分类中 IOSurface 与
# CoreAnimation 的 dirty 值（分类缺失时为 n/a，不推测）。
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
# KARU_BENCH_APP_BIN=<二进制> 指定被测构建（跳过 swift build）；
# KARU_BENCH_MALLOC_SPACE_EFFICIENT=0 关闭 MallocSpaceEfficient（默认开，与打包 App 相同）；
# KARU_BENCH_REPORT_WAIT_SECONDS（默认 10）：读数稳定后再等 App 报告的最长时间。
#
# 判定逻辑与启动采样分开：KARU_BENCH_LIB_ONLY=1 时 source 本脚本只定义函数，
# 供 scripts/tests/mem-benchmark-selftest.sh 用假采样器驱动（不启动 App）。

# ======================================================================
# 函数库（判定、采样解析、报告核对）
# ======================================================================

STABLE_SECONDS="${KARU_BENCH_STABLE_SECONDS:-2}"
STABLE_TOLERANCE_KB="${KARU_BENCH_STABLE_TOLERANCE_KB:-512}"
MAX_WAIT_SECONDS="${KARU_BENCH_MAX_WAIT_SECONDS:-20}"
MIN_WAIT_SECONDS="${KARU_BENCH_MIN_WAIT_SECONDS:-0}"
REPORT_WAIT_SECONDS="${KARU_BENCH_REPORT_WAIT_SECONDS:-10}"
# 最短观察时间之后至少还要留出一个稳定窗口。
MAX_WAIT_SECONDS=$(awk -v m="$MAX_WAIT_SECONDS" -v n="$MIN_WAIT_SECONDS" -v w="$STABLE_SECONDS" \
    'BEGIN{ x = n + w; if (m + 0 < x) print x; else print m }')

# 采样函数名；自检脚本可换成假采样器。签名：<sampler> <pid>，
# 输出 "<KB> <口径>"（口径 phys_footprint 或 rss），失败返回 1。
BENCH_SAMPLER="${BENCH_SAMPLER:-sample_footprint}"

now_seconds() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# stdin 为 `footprint -f bytes` 输出，打印 phys_footprint 的 KB（找不到时不输出）。
parse_phys_footprint_kb() {
    awk '
        /phys_footprint:/ {
            val = $2; unit = $3
            if (unit == "B") val = int(val / 1024)
            else if (unit == "KB") val = int(val)
            else if (unit == "MB") val = int(val * 1024)
            else if (unit == "GB") val = int(val * 1024 * 1024)
            print val
            exit
        }
    '
}

# stdin 为 `footprint -f bytes <pid>`（带分类）输出，打印
# "<IOSurface dirty KB|n/a> <CoreAnimation dirty KB|n/a>"。
# 分类行形如 "<dirty> B <clean> B <reclaimable> B <regions> <名称…>"。
parse_footprint_categories() {
    awk '
        $2 == "B" && $4 == "B" && $6 == "B" && NF >= 8 {
            name = $8
            for (i = 9; i <= NF; i++) name = name " " $i
            if (name == "IOSurface") ios = $1
            if (name == "CoreAnimation") ca = $1
        }
        END {
            printf "%s %s\n", (ios == "" ? "n/a" : int(ios / 1024)), (ca == "" ? "n/a" : int(ca / 1024))
        }
    '
}

# 真实采样器：优先 footprint 的 phys_footprint，失败回退 ps 的 RSS（KB），并标明口径。
sample_footprint() {
    local pid="$1" kb=""
    # -f bytes：默认格式按整 MB 取整，稳定判定需要更细的读数。
    kb=$(footprint -f bytes --noCategories "$pid" 2>/dev/null | parse_phys_footprint_kb || true)
    if [[ -n "$kb" ]]; then
        echo "$kb phys_footprint"
        return 0
    fi
    kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    if [[ -n "$kb" ]]; then
        echo "$kb rss"
        return 0
    fi
    return 1
}

# 当前 pid 的 IOSurface / CoreAnimation 分类读数（"<KB|n/a> <KB|n/a>"）。
sample_categories() {
    local pid="$1"
    footprint -f bytes "$pid" 2>/dev/null | parse_footprint_categories || echo "n/a n/a"
}

# 轮询 pid 的内存直到稳定。参数：pid、启动时刻（now_seconds）。
# 输出一行 "<KB> <口径> <稳定时刻s|UNSTABLE>"；稳定时刻为稳定区间起点距启动的秒数。
# 口径：全部读数都是 phys_footprint 才是 phys_footprint；全是 rss 为 rss；否则 mixed。
# 一次读数都拿不到时返回 1。
wait_for_stable_footprint() {
    local pid="$1" t0="$2"
    local ts="" kbs="" kb="" kind="" sample="" last_kb="" t="" settled=""
    local seen_phys=0 seen_rss=0 overall_kind=""
    while :; do
        t=$(awk -v a="$(now_seconds)" -v b="$t0" 'BEGIN{printf "%.2f", a-b}')
        if sample=$("$BENCH_SAMPLER" "$pid"); then
            read -r kb kind <<< "$sample"
            if [[ "$kind" == "phys_footprint" ]]; then seen_phys=1; else seen_rss=1; fi
            if [[ $seen_phys -eq 1 && $seen_rss -eq 0 ]]; then overall_kind="phys_footprint"
            elif [[ $seen_phys -eq 0 ]]; then overall_kind="rss"
            else overall_kind="mixed"; fi
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
                echo "$kb $overall_kind $settled"
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
    echo "$last_kb $overall_kind UNSTABLE"
}

# App 报告（KARU_BENCH_REPORT）中某个键的值；文件或键不存在时输出空。
report_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file"
}

# 报告是否写完（以 complete=1 结尾）。
report_complete() {
    [[ "$(report_value "$1" complete)" == "1" ]]
}

# 核对 App 报告是否证明打开的正是本轮预期的文档。参数：报告文件、预期路径
# （空 = 空文档轮，期望未命名且长度 0；否则应为 `pwd -P` 形式的绝对路径）。
# 输出 "ok" 或缺证据的原因。
verify_open() {
    local file="$1" intended="$2"
    if ! report_complete "$file"; then
        echo "App 未写出报告（KARU_BENCH_REPORT）"
        return 0
    fi
    local doc len nwin vis
    doc="$(report_value "$file" documentPath)"
    len="$(report_value "$file" documentLength)"
    nwin="$(report_value "$file" editorWindows)"
    vis="$(report_value "$file" windowVisible)"
    if [[ "$nwin" != "1" ]]; then
        echo "打开了 ${nwin:-?} 个编辑窗口（应为 1）"
    elif [[ "$vis" != "1" ]]; then
        echo "窗口不可见"
    elif [[ -z "$intended" ]]; then
        if [[ -n "$doc" || "$len" != "0" ]]; then
            echo "应为未命名空文档，实际为 '${doc}'（${len:-?} 单元）"
        else
            echo "ok"
        fi
    elif [[ "$doc" != "$intended" ]]; then
        echo "打开的不是预期文件：'${doc}'"
    elif [[ -z "$len" || "$len" == "0" ]]; then
        echo "文件打开后为空（长度 ${len:-?}）"
    else
        echo "ok"
    fi
}

# ---- 轮次记录（bash 3.2 无关联数组，用并行下标数组） ----
bench_reset_rounds() {
    ROUND_COUNT=0
    R_NAME=(); R_TARGET=(); R_LIMIT=(); R_STATUS=(); R_KB=(); R_KIND=(); R_STABLE=()
    R_OPEN=(); R_VERDICT=(); R_REASON=()
    R_DOC=(); R_LEN=(); R_WIN=(); R_VIS=(); R_OCC=(); R_SPACE=(); R_SCALE=(); R_NWIN=()
    R_IOS=(); R_CA=()
}

# 记录一轮。参数：名称、目标（如 "20-30"，参考轮为 "-"）、上限 MB、
# 状态（measured|skipped:<原因>）、读数行 "<KB> <口径> <稳定时刻|UNSTABLE>"（无读数为空）、
# 打开核对结果（verify_open 的输出）。返回后 ROUND_COUNT-1 为本轮下标。
bench_add_round() {
    local i=$ROUND_COUNT kb="" kind="" stable=""
    read -r kb kind stable <<< "$5" || true
    R_NAME[$i]="$1"; R_TARGET[$i]="$2"; R_LIMIT[$i]="$3"; R_STATUS[$i]="$4"
    R_KB[$i]="$kb"; R_KIND[$i]="$kind"; R_STABLE[$i]="$stable"; R_OPEN[$i]="$6"
    R_VERDICT[$i]=""; R_REASON[$i]=""
    R_DOC[$i]=""; R_LEN[$i]=""; R_WIN[$i]=""; R_VIS[$i]=""; R_OCC[$i]=""
    R_SPACE[$i]=""; R_SCALE[$i]=""; R_NWIN[$i]=""; R_IOS[$i]="n/a"; R_CA[$i]="n/a"
    ROUND_COUNT=$((i + 1))
}

# 由轮次记录得出每轮判定（R_VERDICT：PASS / PASS-ABOVE-TARGET / OVER / NO-EVIDENCE，
# R_REASON 为原因）与总体结果：BENCH_EXIT（0/1/2）、BENCH_SUMMARY（一行说明）。
# 规则：任何缺证据（RSS/混合口径、跳过、无读数、未稳定、打开核对未通过）→ NO-EVIDENCE，
# 不看数字；证据有效且超上限 → OVER。有 OVER 则 1；否则有 NO-EVIDENCE 则 2；否则 0。
bench_evaluate_rounds() {
    local i=0 over="" missing="" above=""
    while [[ $i -lt $ROUND_COUNT ]]; do
        local reason="" status="${R_STATUS[$i]}" kb="${R_KB[$i]}" kind="${R_KIND[$i]}"
        if [[ "$status" == skipped* ]]; then
            reason="跳过${status#skipped}"
        elif [[ -z "$kb" ]]; then
            reason="没有读数"
        elif [[ "$kind" != "phys_footprint" ]]; then
            reason="口径为 ${kind:-未知}，不是 phys_footprint"
        elif [[ "${R_STABLE[$i]}" == "UNSTABLE" ]]; then
            reason="读数未稳定"
        elif [[ "${R_OPEN[$i]}" != "ok" ]]; then
            reason="${R_OPEN[$i]:-未核对打开的文档}"
        fi
        if [[ -n "$reason" ]]; then
            R_VERDICT[$i]="NO-EVIDENCE"; R_REASON[$i]="$reason"
            missing="${missing}${missing:+；}${R_NAME[$i]}（${reason}）"
        elif awk -v kb="$kb" -v lim="${R_LIMIT[$i]}" 'BEGIN{exit !(kb + 0 > lim * 1024)}'; then
            R_VERDICT[$i]="OVER"; R_REASON[$i]="超过上限 ${R_LIMIT[$i]} MB"
            over="${over}${over:+；}${R_NAME[$i]}"
        else
            local upper="${R_TARGET[$i]##*-}"
            if [[ "${R_TARGET[$i]}" != "-" && -n "$upper" ]] \
                && awk -v kb="$kb" -v up="$upper" 'BEGIN{exit !(kb + 0 > up * 1024)}'; then
                R_VERDICT[$i]="PASS-ABOVE-TARGET"; R_REASON[$i]="超出目标 ${R_TARGET[$i]} MB，未超上限"
                above="${above}${above:+；}${R_NAME[$i]}"
            else
                R_VERDICT[$i]="PASS"; R_REASON[$i]=""
            fi
        fi
        i=$((i + 1))
    done
    if [[ $ROUND_COUNT -eq 0 ]]; then
        BENCH_EXIT=2
        BENCH_SUMMARY="RESULT: exit 2 — 无证据可判通过：一轮都没有执行。"
    elif [[ -n "$over" ]]; then
        BENCH_EXIT=1
        BENCH_SUMMARY="RESULT: exit 1 — 超过上限：${over}。"
        [[ -z "$missing" ]] || BENCH_SUMMARY="${BENCH_SUMMARY} 另有缺证据的轮次：${missing}。"
    elif [[ -n "$missing" ]]; then
        BENCH_EXIT=2
        BENCH_SUMMARY="RESULT: exit 2 — 无证据可判通过：${missing}。"
    else
        BENCH_EXIT=0
        BENCH_SUMMARY="RESULT: exit 0 — 全部 ${ROUND_COUNT} 轮有证据且未超上限。"
        [[ -z "$above" ]] || BENCH_SUMMARY="${BENCH_SUMMARY} 超出目标（预警）：${above}。"
    fi
}

kb_to_mb_str() {
    if [[ -z "$1" ]]; then echo "N/A"; return; fi
    awk -v kb="$1" 'BEGIN{printf "%.1f", kb/1024}'
}

# "<稳定时刻>" → 显示文本（UNSTABLE 显示为“未稳定(>N s)”）。
stable_str() {
    case "$1" in
        "") echo "N/A" ;;
        UNSTABLE) echo "未稳定(>${MAX_WAIT_SECONDS}s)" ;;
        *) echo "${1}s" ;;
    esac
}

# 对照表 + 每轮证据。须先调用 bench_evaluate_rounds。
bench_print_report() {
    local fmt='%-26s | %-8s | %-14s | %-8s | %-6s | %-17s | %s\n'
    printf "$fmt" "轮次" "实测(MB)" "口径" "目标(MB)" "上限" "结果" "稳定于"
    printf "$fmt" "--------------------------" "--------" "--------------" "--------" "------" "-----------------" "------"
    local i=0
    while [[ $i -lt $ROUND_COUNT ]]; do
        printf "$fmt" "${R_NAME[$i]}" "$(kb_to_mb_str "${R_KB[$i]}")" "${R_KIND[$i]:-n/a}" \
            "${R_TARGET[$i]}" "${R_LIMIT[$i]}" "${R_VERDICT[$i]}" "$(stable_str "${R_STABLE[$i]}")"
        i=$((i + 1))
    done
    echo ""
    echo "== 每轮证据（App 报告 KARU_BENCH_REPORT + footprint 分类） =="
    i=0
    while [[ $i -lt $ROUND_COUNT ]]; do
        echo "[$((i + 1))] ${R_NAME[$i]}: ${R_KB[$i]:-N/A} KB ${R_KIND[$i]:-n/a}，判定 ${R_VERDICT[$i]}${R_REASON[$i]:+（${R_REASON[$i]}）}"
        echo "    打开核对: ${R_OPEN[$i]:-n/a}"
        echo "    documentPath='${R_DOC[$i]}' documentLength=${R_LEN[$i]:-n/a} editorWindows=${R_NWIN[$i]:-n/a}"
        echo "    window=${R_WIN[$i]:-n/a} pt visible=${R_VIS[$i]:-n/a} occlusionVisible=${R_OCC[$i]:-n/a} onActiveSpace=${R_SPACE[$i]:-n/a} backingScale=${R_SCALE[$i]:-n/a}"
        echo "    IOSurface ${R_IOS[$i]} KB, CoreAnimation ${R_CA[$i]} KB（footprint dirty；n/a = 分类不存在或 footprint 不可用）"
        if [[ "${R_OCC[$i]}" == "0" ]]; then
            echo "    WARN: 窗口被遮挡或不在屏上，窗口显示相关内存与在屏运行不可比。"
        fi
        i=$((i + 1))
    done
}

if [[ "${KARU_BENCH_LIB_ONLY:-}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ======================================================================
# 主流程（构建、生成文件、逐轮启动采样、报告）
# ======================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd -P)"

# KARU_BENCH_APP_BIN 可覆盖被测二进制（例如同机 A/B 对照的基线版构建）；
# 覆盖时不执行 swift build。未设置时行为不变。
APP_BIN="${KARU_BENCH_APP_BIN:-.build/release/KaruApp}"

if [[ -n "${KARU_BENCH_APP_BIN:-}" ]]; then
    echo "== [1/4] 使用 KARU_BENCH_APP_BIN=$APP_BIN（跳过 swift build） =="
else
    echo "== [1/4] swift build -c release =="
    if ! swift build -c release; then
        echo "RESULT: exit 2 — 无证据可判通过：swift build 失败。"
        exit 2
    fi
fi

# 打包后的 App 经 Info.plist 的 LSEnvironment 带 MallocSpaceEfficient=1 启动（bundle-macos.sh），
# 直接执行二进制拿不到，这里显式设置，读数才与用户实际运行的 App 一致。
# KARU_BENCH_MALLOC_SPACE_EFFICIENT=0 关闭（对照 2026-11-15 之前的读数口径）。
if [[ "${KARU_BENCH_MALLOC_SPACE_EFFICIENT:-1}" == "1" ]]; then
    export MallocSpaceEfficient=1
    ALLOCATOR_MODE="MallocSpaceEfficient=1（与打包后的 App 相同）"
else
    unset MallocSpaceEfficient
    ALLOCATOR_MODE="MallocSpaceEfficient 未设置（KARU_BENCH_MALLOC_SPACE_EFFICIENT=0）"
fi

if [[ ! -x "$APP_BIN" ]]; then
    echo "ERROR: $APP_BIN not found or not executable" >&2
    echo "RESULT: exit 2 — 无证据可判通过：被测二进制不存在。"
    exit 2
fi
APP_BIN_ABS="$(cd "$(dirname "$APP_BIN")" && pwd -P)/$(basename "$APP_BIN")"

# 物理路径（/var → /private/var），与 App 报告里的 realpath 可直接比较。
TMP_DIR="$(cd "$(mktemp -d -t karu-bench)" && pwd -P)"
DIAG_TAG="$(basename "$TMP_DIR")"
cleanup() {
    local d domain
    for d in "$TMP_DIR"/diag-*; do
        [[ -d "$d" ]] || continue
        domain="dev.enkin.Karu.Diagnostics.$(basename "$d")"
        defaults delete "$domain" >/dev/null 2>&1 || true
        # 会话被清空的域 `defaults delete` 报"不存在"，空 plist 仍在；按确切文件名删。
        rm -f "$HOME/Library/Preferences/$domain.plist"
    done
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT
# 采样中的 App 不应继承会改变其行为的探针变量。
unset KARU_SNAPSHOT KARU_BENCH_REPORT

MEDIUM_FILE="$TMP_DIR/medium.json"
LARGE_FILE="$TMP_DIR/large.py"

echo ""
echo "== 运行记录 =="
echo "binary     : $APP_BIN_ABS"
echo "sha256     : $(shasum -a 256 "$APP_BIN_ABS" | awk '{print $1}')"
GIT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1)" ]]; then
    GIT_DIRTY="dirty（有未提交改动或未跟踪文件）"
else
    GIT_DIRTY="clean"
fi
echo "git HEAD   : $GIT_HEAD（$GIT_DIRTY）"
if [[ -n "${KARU_BENCH_APP_BIN:-}" ]]; then
    echo "             注意：二进制由 KARU_BENCH_APP_BIN 指定，可能不是这个 HEAD 构建的。"
fi
echo "allocator  : $ALLOCATOR_MODE"
echo "macOS      : $(sw_vers -productVersion 2>/dev/null || echo ?) ($(sw_vers -buildVersion 2>/dev/null || echo ?)), $(uname -m)"
echo "isolation  : KARU_DIAGNOSTIC_DIRECTORY=$TMP_DIR/diag-*（每轮一个，退出时删除）"
echo "sampling   : 稳定窗口 ${STABLE_SECONDS}s / 容差 ${STABLE_TOLERANCE_KB} KB / 最长 ${MAX_WAIT_SECONDS}s / 最短观察 ${MIN_WAIT_SECONDS}s"

echo ""
echo "== [2/4] 生成测试文件（${TMP_DIR}） =="

# 空文档轮不传文件：测的是启动后的未命名空窗口。
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

echo "medium.json: $(wc -c < "$MEDIUM_FILE" | tr -d ' ') bytes ($medium_count 行 JSON 数组)"
echo "large.py   : $(wc -c < "$LARGE_FILE" | tr -d ' ') bytes"

# 运行一轮。参数：名称、目标、上限 MB、预期打开的文件（空 = 未命名空文档，不传参数）。
# App 以命令行参数打开文件（AppDelegate.applicationDidFinishLaunching）。
measure_round() {
    local name="$1" target="$2" limit="$3" intended="$4"
    local idx=$ROUND_COUNT
    local diag="$TMP_DIR/diag-${DIAG_TAG}-r$((idx + 1))"
    local report="$TMP_DIR/report-r$((idx + 1)).txt"
    mkdir -p "$diag"
    rm -f "$report"

    echo ""
    echo "---- 轮次 $((idx + 1)): $name ----"
    if [[ -n "$intended" ]]; then
        KARU_DIAGNOSTIC_DIRECTORY="$diag" KARU_BENCH_REPORT="$report" "$APP_BIN_ABS" "$intended" &
    else
        KARU_DIAGNOSTIC_DIRECTORY="$diag" KARU_BENCH_REPORT="$report" "$APP_BIN_ABS" &
    fi
    local pid=$!
    local t0
    t0=$(now_seconds)

    local result=""
    if ! result=$(wait_for_stable_footprint "$pid" "$t0"); then
        echo "WARN: 无法采样 pid=$pid 的内存（footprint 与 ps 均失败，或进程已退出）"
        result=""
    fi
    # 读数稳定后等 App 报告写完（通常启动后 0.5–3 s 已写出）。
    local waited=0
    while ! report_complete "$report" && kill -0 "$pid" 2>/dev/null \
        && awk -v w="$waited" -v m="$REPORT_WAIT_SECONDS" 'BEGIN{exit !(w < m)}'; do
        sleep 0.25
        waited=$(awk -v w="$waited" 'BEGIN{print w + 0.25}')
    done
    local cats="n/a n/a"
    if kill -0 "$pid" 2>/dev/null; then
        cats="$(sample_categories "$pid")"
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    bench_add_round "$name" "$target" "$limit" "measured" "$result" "$(verify_open "$report" "$intended")"
    R_DOC[$idx]="$(report_value "$report" documentPath)"
    R_LEN[$idx]="$(report_value "$report" documentLength)"
    if report_complete "$report"; then
        R_WIN[$idx]="$(report_value "$report" windowWidth)x$(report_value "$report" windowHeight)"
    fi
    R_VIS[$idx]="$(report_value "$report" windowVisible)"
    R_OCC[$idx]="$(report_value "$report" windowOcclusionVisible)"
    R_SPACE[$idx]="$(report_value "$report" windowOnActiveSpace)"
    R_SCALE[$idx]="$(report_value "$report" backingScaleFactor)"
    R_NWIN[$idx]="$(report_value "$report" editorWindows)"
    read -r R_IOS[$idx] R_CA[$idx] <<< "$cats" || true
    local kb kind stable
    read -r kb kind stable <<< "$result" || true
    echo "$name: ${kb:-N/A} KB ${kind:-n/a}（稳定于 $(stable_str "${stable:-}")），打开核对：${R_OPEN[$idx]}"
}

skip_round() {
    bench_add_round "$1" "$2" "$3" "skipped:$4" "" "n/a"
    echo ""
    echo "---- 轮次 $ROUND_COUNT: $1 ---- SKIPPED（$4）"
}

bench_reset_rounds

echo ""
echo "== [3/4] 正式三轮 + 推断样本两轮（参考，只查上限） =="
if awk -v n="$MIN_WAIT_SECONDS" 'BEGIN{exit !(n + 0 > 0)}'; then
    echo "最短观察时间 ${MIN_WAIT_SECONDS}s（KARU_BENCH_MIN_WAIT_SECONDS），最长等待 ${MAX_WAIT_SECONDS}s"
fi

# 预算见 ARCHITECTURE.md §1：目标 20-30 / 30-45 / 50-60 MB，上限 99 MB。
measure_round "空文档启动基线" "20-30" "99" ""
measure_round "打开 medium.json" "30-45" "99" "$MEDIUM_FILE"
measure_round "打开 large.py" "50-60" "99" "$LARGE_FILE"

# ---- 推断样本（参考，M17 T17.0）----
# 1000 行量级、名字与类型多样的 Python / TS 样本（scripts/m17/gen-inference-samples.py
# 生成），仅作参考读数：只检查 99 MB 上限，不设预算目标。
for ref in sample_1000.py sample_1000.ts; do
    ref_path="$REPO_ROOT/Tests/Fixtures/M17/inference/$ref"
    if [[ -f "$ref_path" ]]; then
        measure_round "打开 $ref（参考）" "-" "99" "$ref_path"
    else
        skip_round "打开 $ref（参考）" "-" "99" "缺少样本 $ref_path"
    fi
done

bench_evaluate_rounds

echo ""
echo "== [4/4] 内存基准对照表（对照 docs/ARCHITECTURE.md §1；口径 phys_footprint，800×600 默认窗口） =="
echo ""
bench_print_report
echo ""
echo "== 汇总 =="
echo "binary $APP_BIN_ABS @ $GIT_HEAD（$GIT_DIRTY），$ALLOCATOR_MODE"
echo "$BENCH_SUMMARY"
exit "$BENCH_EXIT"
