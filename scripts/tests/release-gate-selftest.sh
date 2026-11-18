#!/bin/bash
# 发布门禁自测：不构建、不签名、不公证、不联网，只在临时目录里验证
#   scripts/lib/check-preflight-record.py
#   scripts/lib/verify-sparkle-tools.py
#   scripts/release-macos.sh --check
# 在各种“不该放行”的情形下确实拒绝，在该放行时放行。任何一例不符即以非零退出。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
# expect <期望退出码> <说明> <命令…>
expect() {
    local want="$1" label="$2"; shift 2
    local got=0
    "$@" >"$WORK/last.out" 2>&1 || got=$?
    if [[ "$got" -eq "$want" ]]; then
        PASS=$((PASS + 1)); echo "PASS  $label"
    else
        FAIL=$((FAIL + 1)); echo "FAIL  $label（期望退出码 $want，实际 $got）"; sed 's/^/      /' "$WORK/last.out"
    fi
}

# ---------- 1. 发布前检查记录 ----------
REC="$WORK/records"; mkdir -p "$REC"
C="1111111111111111111111111111111111111111"
write_record() {  # <文件> <commit> <result> <steps json>
    printf '{"commit":"%s","result":"%s","finishedAt":"t","steps":%s}\n' "$2" "$3" "$4" > "$1"
}
GOOD_STEPS='[{"name":"tests","exit":0,"seconds":1},{"name":"visual-smoke","exit":0,"seconds":1},{"name":"mem-benchmark","exit":0,"seconds":1}]'
CHECK="python3 $ROOT/scripts/lib/check-preflight-record.py"

expect 1 "记录：不存在 → 拒绝" $CHECK "$REC" "$C"
write_record "$REC/$C.json" "$C" pass "$GOOD_STEPS"
expect 0 "记录：完整通过 → 放行" $CHECK "$REC" "$C"
write_record "$REC/$C.json" "2222222222222222222222222222222222222222" pass "$GOOD_STEPS"
expect 1 "记录：里面的提交号不符 → 拒绝" $CHECK "$REC" "$C"
write_record "$REC/$C.json" "$C" fail "$GOOD_STEPS"
expect 1 "记录：结论不是通过 → 拒绝" $CHECK "$REC" "$C"
write_record "$REC/$C.json" "$C" pass '[{"name":"tests","exit":0,"seconds":1},{"name":"visual-smoke","exit":0,"seconds":1}]'
expect 1 "记录：缺少内存基准步骤 → 拒绝" $CHECK "$REC" "$C"
write_record "$REC/$C.json" "$C" pass '[{"name":"tests","exit":0,"seconds":1},{"name":"visual-smoke","exit":0,"seconds":1},{"name":"mem-benchmark","exit":2,"seconds":1}]'
expect 1 "记录：内存基准退出码 2 → 拒绝" $CHECK "$REC" "$C"
echo 'not json' > "$REC/$C.json"
expect 1 "记录：不是 JSON → 拒绝" $CHECK "$REC" "$C"

# ---------- 2. Sparkle 工具核对 ----------
REV=""
SUM="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# make_fixture <目录> <resolved 版本> <产物 URL 里的版本> <state 里的校验值> <manifest 里的校验值>
make_fixture() {
    local dir="$1" pinned="$2" urlver="$3" statesum="$4" manifestsum="$5"
    rm -rf "$dir"; mkdir -p "$dir/.build/checkouts/Sparkle" "$dir/.build/artifacts/sparkle/Sparkle/bin"
    printf 'let checksum = "%s"\n' "$manifestsum" > "$dir/.build/checkouts/Sparkle/Package.swift"
    git -C "$dir/.build/checkouts/Sparkle" init -q
    git -C "$dir/.build/checkouts/Sparkle" add Package.swift
    git -C "$dir/.build/checkouts/Sparkle" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m fixture
    REV="$(git -C "$dir/.build/checkouts/Sparkle" rev-parse HEAD)"
    printf '#!/bin/sh\necho "sparkle:edSignature=\\"fixture\\" length=\\"1\\""\n' > "$dir/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    chmod +x "$dir/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    cat > "$dir/Package.resolved" <<JSON
{"pins":[{"identity":"sparkle","kind":"remoteSourceControl","location":"https://github.com/sparkle-project/Sparkle","state":{"revision":"$REV","version":"$pinned"}}],"version":2}
JSON
    cat > "$dir/.build/workspace-state.json" <<JSON
{"object":{"artifacts":[{"packageRef":{"identity":"sparkle"},"source":{"checksum":"$statesum","type":"remote","url":"https://github.com/sparkle-project/Sparkle/releases/download/$urlver/Sparkle-for-Swift-Package-Manager.zip"}}],
 "dependencies":[{"packageRef":{"identity":"sparkle"},"state":{"checkoutState":{"revision":"$REV","version":"$pinned"}}}]}}
JSON
}
VERIFY="python3 $ROOT/scripts/lib/verify-sparkle-tools.py"
F="$WORK/sparkle"

make_fixture "$F" 2.9.4 2.9.4 "$SUM" "$SUM"
expect 0 "Sparkle：版本、修订、校验值一致 → 放行" $VERIFY "$F/Package.resolved" "$F/.build"
make_fixture "$F" 2.9.4 2.6.0 "$SUM" "$SUM"
expect 1 "Sparkle：产物来自别的版本 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"
make_fixture "$F" 2.9.4 2.9.4 "$SUM" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
expect 1 "Sparkle：校验值与清单声明不符 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"
make_fixture "$F" 2.9.4 2.9.4 "$SUM" "$SUM"
sed -i '' "s/$REV/cccccccccccccccccccccccccccccccccccccccc/" "$F/Package.resolved"
expect 1 "Sparkle：Package.resolved 的修订与检出不符 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"
make_fixture "$F" 2.9.4 2.9.4 "$SUM" "$SUM"
chmod -x "$F/.build/artifacts/sparkle/Sparkle/bin/sign_update"
expect 1 "Sparkle：sign_update 不可执行 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"
rm -f "$F/.build/artifacts/sparkle/Sparkle/bin/sign_update"
expect 1 "Sparkle：sign_update 不存在 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"
rm -f "$F/.build/workspace-state.json"
expect 1 "Sparkle：从未构建过 → 拒绝" $VERIFY "$F/Package.resolved" "$F/.build"

# ---------- 3. release-macos.sh --check（临时仓库，打包脚本换成会留痕的桩） ----------
R="$WORK/repo"
make_fixture "$R" 2.9.4 2.9.4 "$SUM" "$SUM"
mkdir -p "$R/scripts/lib"
cp "$ROOT/scripts/release-macos.sh" "$R/scripts/"
cp "$ROOT/scripts/lib/check-preflight-record.py" "$ROOT/scripts/lib/verify-sparkle-tools.py" "$R/scripts/lib/"
printf '#!/bin/bash\ntouch "$(dirname "$0")/../BUNDLE_WAS_RUN"\nexit 1\n' > "$R/scripts/bundle-macos.sh"
chmod +x "$R/scripts/bundle-macos.sh"
printf '.build/\nbuild/\nBUNDLE_WAS_RUN\n' > "$R/.gitignore"
git -C "$R" init -q
git -C "$R" add .gitignore Package.resolved scripts
git -C "$R" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m fixture
HEAD_COMMIT="$(git -C "$R" rev-parse HEAD)"
RELEASE="$R/scripts/release-macos.sh"

expect 1 "发布脚本：没有检查记录 → 拒绝" "$RELEASE" --check
mkdir -p "$R/build/preflight"
write_record "$R/build/preflight/$C.json" "$C" pass "$GOOD_STEPS"
expect 1 "发布脚本：只有别的提交的记录 → 拒绝" "$RELEASE" --check
write_record "$R/build/preflight/$HEAD_COMMIT.json" "$HEAD_COMMIT" pass "$GOOD_STEPS"
expect 0 "发布脚本：记录有效、工具一致 → 门禁通过" "$RELEASE" --check
echo "// 检查之后又改了源码" >> "$R/Package.resolved.note"
expect 1 "发布脚本：检查后工作区有改动 → 拒绝" "$RELEASE" --check
rm -f "$R/Package.resolved.note"
chmod -x "$R/.build/artifacts/sparkle/Sparkle/bin/sign_update"
expect 1 "发布脚本：记录有效但 Sparkle 工具不可用 → 拒绝" "$RELEASE" --check
chmod +x "$R/.build/artifacts/sparkle/Sparkle/bin/sign_update"
rm -f "$R/build/preflight/$HEAD_COMMIT.json"
expect 0 "发布脚本：显式跳过开关 → 放行" env KARU_RELEASE_SKIP_PREFLIGHT=1 "$RELEASE" --check
if grep -q "警告" "$WORK/last.out"; then
    PASS=$((PASS + 1)); echo "PASS  发布脚本：跳过开关有醒目警告"
else
    FAIL=$((FAIL + 1)); echo "FAIL  发布脚本：跳过开关没有打印警告"
fi
expect 2 "发布脚本：未知参数 → 用法错误" "$RELEASE" --bogus
if [[ -e "$R/BUNDLE_WAS_RUN" ]]; then
    FAIL=$((FAIL + 1)); echo "FAIL  --check 不应调用打包脚本，但它被调用了"
else
    PASS=$((PASS + 1)); echo "PASS  --check 全程没有调用打包脚本"
fi
# 不带 --check 且没有记录：必须在调用打包脚本之前拒绝。
expect 1 "发布脚本：正式模式没有记录 → 在打包之前拒绝" "$RELEASE"
if [[ -e "$R/BUNDLE_WAS_RUN" ]]; then
    FAIL=$((FAIL + 1)); echo "FAIL  没有记录时仍然调用了打包脚本"
else
    PASS=$((PASS + 1)); echo "PASS  没有记录时没有调用打包脚本"
fi

echo ""
echo "release-gate-selftest：$PASS 通过，$FAIL 失败"
[[ "$FAIL" -eq 0 ]]
