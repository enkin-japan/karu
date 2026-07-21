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
