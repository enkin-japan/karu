#!/bin/bash
# mem-benchmark.sh 判定逻辑自检（R11）：不启动 App。
# 以 KARU_BENCH_LIB_ONLY=1 source 脚本，只拿到函数；用手工轮次记录、假 App 报告
# 和假采样器驱动 bench_evaluate_rounds / verify_open / wait_for_stable_footprint，
# 核对退出码规则：0 = 全部有证据且未超上限；1 = 有效证据超上限（优先）；
# 2 = 无证据可判通过。每个用例打印 PASS/FAIL，有 FAIL 时退出码非 0。
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d -t karu-bench-selftest)"
trap 'rm -rf "$WORK"' EXIT

# 假采样器要快：窗口 0.6 s，最长 1.6 s。
export KARU_BENCH_STABLE_SECONDS=0.6
export KARU_BENCH_STABLE_TOLERANCE_KB=512
export KARU_BENCH_MAX_WAIT_SECONDS=1.6
export KARU_BENCH_MIN_WAIT_SECONDS=0
KARU_BENCH_LIB_ONLY=1 . "$HERE/../mem-benchmark.sh"

FAILS=0
CASES=0
check() { # 名称 期望 实际
    CASES=$((CASES + 1))
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"
    else
        echo "FAIL  $1: expected [$2], got [$3]"
        FAILS=$((FAILS + 1))
    fi
}
check_contains() { # 名称 子串 实际
    CASES=$((CASES + 1))
    case "$3" in
        *"$2"*) echo "PASS  $1" ;;
        *) echo "FAIL  $1: [$3] does not contain [$2]"; FAILS=$((FAILS + 1)) ;;
    esac
}

# 一轮"一切正常"的记录：phys_footprint、已稳定、打开核对通过。
ok_round() { bench_add_round "$1" "20-30" "99" "measured" "${2:-25000} phys_footprint 2.1" "ok"; }

# 写一份假 App 报告。参数：文件、documentPath、documentLength、editorWindows、windowVisible。
fake_report() {
    printf 'format=karu-bench-report/1\ndocumentPath=%s\ndocumentLength=%s\nwindowWidth=800\nwindowHeight=600\nwindowVisible=%s\nwindowOcclusionVisible=1\nwindowOnActiveSpace=1\nbackingScaleFactor=2\neditorWindows=%s\ncomplete=1\n' \
        "$2" "$3" "$5" "$4" > "$1"
}

# ---- 判定规则 ----
bench_reset_rounds
ok_round "空文档"; ok_round "medium" 40000; ok_round "large" 60000
bench_evaluate_rounds
check "all rounds fine -> 0" 0 "$BENCH_EXIT"

bench_reset_rounds
ok_round "空文档"; ok_round "large" 70000
bench_evaluate_rounds
check "above target, under limit -> 0" 0 "$BENCH_EXIT"
check "above target is flagged" "PASS-ABOVE-TARGET" "${R_VERDICT[1]}"

bench_reset_rounds
ok_round "空文档"; ok_round "large" $((100 * 1024))
bench_evaluate_rounds
check "one round over hard limit -> 1" 1 "$BENCH_EXIT"
check "over round verdict" "OVER" "${R_VERDICT[1]}"

bench_reset_rounds
ok_round "空文档"; bench_add_round "medium" "30-45" "99" "measured" "38000 rss 2.0" "ok"
bench_evaluate_rounds
check "RSS fallback -> 2" 2 "$BENCH_EXIT"
check_contains "RSS fallback named in summary" "medium（口径为 rss" "$BENCH_SUMMARY"

bench_reset_rounds
ok_round "空文档"; bench_add_round "medium" "30-45" "99" "measured" "38000 mixed 2.0" "ok"
bench_evaluate_rounds
check "mixed phys/rss -> 2" 2 "$BENCH_EXIT"

bench_reset_rounds
ok_round "空文档"; bench_add_round "ref.py" "-" "99" "skipped:缺少样本" "" "n/a"
bench_evaluate_rounds
check "skipped round -> 2" 2 "$BENCH_EXIT"
check_contains "skip reason in summary" "ref.py（跳过:缺少样本）" "$BENCH_SUMMARY"

bench_reset_rounds
ok_round "空文档"; bench_add_round "large" "50-60" "99" "measured" "55000 phys_footprint UNSTABLE" "ok"
bench_evaluate_rounds
check "unstable round -> 2" 2 "$BENCH_EXIT"
check_contains "unstable named in summary" "large（读数未稳定）" "$BENCH_SUMMARY"

bench_reset_rounds
ok_round "空文档"; bench_add_round "medium" "30-45" "99" "measured" "" "ok"
bench_evaluate_rounds
check "no reading -> 2" 2 "$BENCH_EXIT"

# 打开了别的文件：经 verify_open 核对假报告。
fake_report "$WORK/wrong.txt" "/private/tmp/other.json" 12 1 1
open_check="$(verify_open "$WORK/wrong.txt" "/private/tmp/medium.json")"
bench_reset_rounds
ok_round "空文档"; bench_add_round "medium" "30-45" "99" "measured" "38000 phys_footprint 2.0" "$open_check"
bench_evaluate_rounds
check "wrong file open -> 2" 2 "$BENCH_EXIT"
check_contains "wrong file named in summary" "打开的不是预期文件：'/private/tmp/other.json'" "$BENCH_SUMMARY"

bench_reset_rounds
ok_round "空文档"; ok_round "large" $((120 * 1024))
bench_add_round "medium" "30-45" "99" "measured" "38000 rss 2.0" "ok"
bench_evaluate_rounds
check "over limit plus missing evidence -> 1" 1 "$BENCH_EXIT"
check_contains "summary also lists missing evidence" "另有缺证据的轮次：medium" "$BENCH_SUMMARY"

bench_reset_rounds
ok_round "空文档"; bench_add_round "large" "50-60" "99" "measured" "$((150 * 1024)) rss 2.0" "ok"
bench_evaluate_rounds
check "over limit only on RSS (not valid evidence) -> 2" 2 "$BENCH_EXIT"

bench_reset_rounds
bench_evaluate_rounds
check "no rounds at all -> 2" 2 "$BENCH_EXIT"

# ---- verify_open ----
fake_report "$WORK/untitled.txt" "" 0 1 1
check "verify_open: untitled empty doc ok" "ok" "$(verify_open "$WORK/untitled.txt" "")"
fake_report "$WORK/restored.txt" "/Users/x/notes.md" 120 1 1
check_contains "verify_open: empty round showing a restored file" "应为未命名空文档" "$(verify_open "$WORK/restored.txt" "")"
fake_report "$WORK/right.txt" "/private/tmp/medium.json" 1048576 1 1
check "verify_open: intended file ok" "ok" "$(verify_open "$WORK/right.txt" "/private/tmp/medium.json")"
fake_report "$WORK/two.txt" "/private/tmp/medium.json" 1048576 2 1
check_contains "verify_open: two editor windows" "2 个编辑窗口" "$(verify_open "$WORK/two.txt" "/private/tmp/medium.json")"
fake_report "$WORK/hidden.txt" "/private/tmp/medium.json" 1048576 1 0
check "verify_open: window not visible" "窗口不可见" "$(verify_open "$WORK/hidden.txt" "/private/tmp/medium.json")"
fake_report "$WORK/emptyfile.txt" "/private/tmp/medium.json" 0 1 1
check_contains "verify_open: intended file opened empty" "文件打开后为空" "$(verify_open "$WORK/emptyfile.txt" "/private/tmp/medium.json")"
check_contains "verify_open: missing report" "App 未写出报告" "$(verify_open "$WORK/none.txt" "")"
grep -v '^complete=' "$WORK/right.txt" > "$WORK/partial.txt"
check_contains "verify_open: partially written report" "App 未写出报告" "$(verify_open "$WORK/partial.txt" "/private/tmp/medium.json")"

# ---- footprint 输出解析 ----
cat > "$WORK/fp.txt" <<'EOF'
======================================================================
KaruApp [123]: 64-bit    Footprint: 26214400 B (16384 bytes per page)
======================================================================

      Dirty         Clean   Reclaimable    Regions    Category
        ---           ---           ---        ---    ---
  8388608 B           0 B           0 B         10    Malloc Small
  2260992 B           0 B           0 B        110    CoreAnimation
  1622016 B           0 B           0 B         11    Owned physical footprint (unmapped) (graphics)
  4194304 B           0 B           0 B         31    IOSurface
        ---           ---           ---        ---    ---
 26214400 B           0 B           0 B        999    TOTAL

Auxiliary data:
    phys_footprint: 26214400 B
    phys_footprint_peak: 30000000 B
EOF
check "parse phys_footprint bytes -> KB" "25600" "$(parse_phys_footprint_kb < "$WORK/fp.txt")"
check "parse IOSurface / CoreAnimation" "4096 2208" "$(parse_footprint_categories < "$WORK/fp.txt")"
grep -v -e IOSurface -e CoreAnimation "$WORK/fp.txt" > "$WORK/fp-nocat.txt"
check "absent categories -> n/a" "n/a n/a" "$(parse_footprint_categories < "$WORK/fp-nocat.txt")"
check "no footprint output -> n/a" "n/a n/a" "$(parse_footprint_categories < /dev/null)"

# ---- 假采样器驱动稳定采样 ----
# 读数序列逐行取（"<KB> <口径>"），用完后重复最后一行；计数放在文件里，
# 因为采样器在命令替换的子 shell 里运行。
fake_sampler() {
    local n
    n=$(cat "$WORK/counter")
    echo $((n + 1)) > "$WORK/counter"
    awk -v n="$((n + 1))" 'NR == n { print; found = 1; exit } { last = $0 } END { if (!found) print last }' "$WORK/seq"
}
BENCH_SAMPLER=fake_sampler
run_fake() { # 序列（用 | 分隔）→ wait_for_stable_footprint 的输出
    echo 0 > "$WORK/counter"
    printf '%s\n' "$1" | tr '|' '\n' > "$WORK/seq"
    wait_for_stable_footprint $$ "$(now_seconds)"
}

out="$(run_fake "20000 phys_footprint|25000 phys_footprint|25010 phys_footprint")"
check_contains "fake sampler: settles as phys_footprint" "25010 phys_footprint" "$out"
bench_reset_rounds; bench_add_round "空文档" "20-30" "99" "measured" "$out" "ok"; bench_evaluate_rounds
check "fake sampler: settled reading -> 0" 0 "$BENCH_EXIT"

out="$(run_fake "25000 phys_footprint|25000 rss|25000 phys_footprint")"
check_contains "fake sampler: one RSS sample makes the round mixed" "mixed" "$out"
bench_reset_rounds; bench_add_round "空文档" "20-30" "99" "measured" "$out" "ok"; bench_evaluate_rounds
check "fake sampler: mixed -> 2" 2 "$BENCH_EXIT"

out="$(run_fake "25000 rss")"
check_contains "fake sampler: RSS-only round" "25000 rss" "$out"

out="$(run_fake "20000 phys_footprint|30000 phys_footprint|20000 phys_footprint|30000 phys_footprint|20000 phys_footprint|30000 phys_footprint|20000 phys_footprint|30000 phys_footprint|20000 phys_footprint|30000 phys_footprint|20000 phys_footprint|30000 phys_footprint")"
check_contains "fake sampler: oscillating never settles" "UNSTABLE" "$out"
bench_reset_rounds; bench_add_round "medium" "30-45" "99" "measured" "$out" "ok"; bench_evaluate_rounds
check "fake sampler: unstable -> 2" 2 "$BENCH_EXIT"

echo ""
if [[ $FAILS -eq 0 ]]; then
    echo "mem-benchmark selftest: all $CASES checks PASS"
    exit 0
fi
echo "mem-benchmark selftest: $FAILS of $CASES checks FAIL"
exit 1
