#!/bin/bash
# 视觉冒烟：启动 app 自渲染快照（KARU_SNAPSHOT 钩子，无需录屏权限），
# 校验编辑区真的画出来了——防止 v0.2.0 "空白窗口" 一类的合成回归。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG" 2>&1 | tail -1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '# Heading\n\ndef hello():\n    return 42\n' > "$TMP/sample.md"

KARU_SNAPSHOT="$TMP/snap.png" ".build/$CONFIG/KaruApp" "$TMP/sample.md"

# 校验快照：必须同时存在大面积亮色（纸面）与少量深色（文字/行号）。
cat > "$TMP/check.swift" <<'EOF'
import AppKit
let path = CommandLine.arguments[1]
guard let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path))) else {
    print("FAIL: unreadable png"); exit(1)
}
var bright = 0, dark = 0, total = 0
for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
    for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        let lum = c.brightnessComponent
        total += 1
        if lum > 0.93 { bright += 1 }
        if lum < 0.45 { dark += 1 }
    }
}
let brightPct = Double(bright) / Double(total) * 100
let darkPct = Double(dark) / Double(total) * 100
print(String(format: "bright %.1f%%  dark %.2f%%", brightPct, darkPct))
if brightPct > 50 && darkPct > 0.05 { print("VISUAL OK"); exit(0) }
print("VISUAL FAIL: editor area did not render (blank-window regression?)")
exit(1)
EOF
swift "$TMP/check.swift" "$TMP/snap.png"

# 折叠几何守门（T13.9）：真实 app 的 typesetter 对 .null 字形的断行处理与
# 单元测试环境不同（rig 里断行、app 里熔合），折叠渲染回归只能在真 app 里抓。
# 一键折叠 test 夹具后，闭合行片段必须紧贴头行（headerMaxY == closerMinY），
# 否则就是"幽灵行/闭合括号消失"回归（2026-07-28 用户 bug）。
printf '{\n  "a": {\n    "x": 1\n  }\n}\n' > "$TMP/fold.json"
KARU_FOLDTEST=all KARU_FOLDTEST_GEO="$TMP/foldgeo.txt" \
    KARU_SNAPSHOT="$TMP/foldsnap.png" ".build/$CONFIG/KaruApp" "$TMP/fold.json"
python3 - "$TMP/foldgeo.txt" <<'EOF'
import re, sys
lines = {}
for m in re.finditer(r"L(\d+) .*fragY=([\d.]+) fragH=([\d.]+)", open(sys.argv[1]).read()):
    lines[int(m.group(1))] = (float(m.group(2)), float(m.group(3)))
header_y, header_h = lines[1]
closer_y, closer_h = lines[max(lines)]
hidden_ok = all(h == 0.0 for line, (_, h) in lines.items() if 1 < line < max(lines))
adjacent = abs(closer_y - (header_y + header_h)) < 0.5
print(f"fold geometry: closer at {closer_y} (header ends {header_y + header_h}), hidden collapsed: {hidden_ok}")
if adjacent and hidden_ok and closer_h > 0:
    print("FOLD GEOMETRY OK")
else:
    print("FOLD GEOMETRY FAIL: ghost row / missing closer regression")
    sys.exit(1)
EOF
