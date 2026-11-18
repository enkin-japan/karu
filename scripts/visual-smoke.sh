#!/bin/bash
# 视觉冒烟：启动 app 自渲染快照（KARU_SNAPSHOT 钩子，无需录屏权限），
# 校验编辑区真的画出来了——防止 v0.2.0 "空白窗口" 一类的合成回归。
#
# 用法：scripts/visual-smoke.sh [release|debug]   构建并运行真实 App（默认 release）
#       scripts/visual-smoke.sh --selftest         只用合成图像自检校验器，不启动 App
#
# 隔离：每次启动都设置自建的临时 KARU_DIAGNOSTIC_DIRECTORY（退出时连同诊断
# defaults 域一起删除），不会恢复开发者自己的会话、草稿或草稿本。
#
# 快照钩子另写几何旁注 <snapshot>.json（DiagnosticHost.swift）：显示的文档
# （realpath）、文本区 / 行号栏 / 第一行文字在快照像素中的矩形、行数、backing scale。
# 校验（任一失败即退出 1，并打印哪一项失败）：
#   DOCUMENT  显示的正是脚本创建的样例文件；
#   TEXT      文本区内有深色（文字）像素，且第一行矩形内有；
#   GUTTER    行号栏内有非背景像素，且按行分成的墨迹带不少于应显示的行号数；
#   VISUAL    整图大面积亮色 + 少量深色（原有的整体健全性检查）；
#   FOLD      一键折叠后的真实 App 几何（原有的折叠几何检查）。
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="run"
CONFIG="release"
case "${1:-}" in
    --selftest) MODE="selftest" ;;
    "") ;;
    *) CONFIG="$1" ;;
esac

TMP="$(cd "$(mktemp -d -t karu-smoke)" && pwd -P)"
TAG="$(basename "$TMP")"
cleanup() {
    local d domain
    for d in "$TMP"/diag-*; do
        [[ -d "$d" ]] || continue
        domain="dev.enkin.Karu.Diagnostics.$(basename "$d")"
        defaults delete "$domain" >/dev/null 2>&1 || true
        # 会话被清空的域 `defaults delete` 报"不存在"，空 plist 仍在；按确切文件名删。
        rm -f "$HOME/Library/Preferences/$domain.plist"
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

# 校验器：`check <png> <sidecar.json> <期望文档路径>` 做 DOCUMENT/TEXT/GUTTER/VISUAL 四项；
# `fixture <变体> <png> <json> <文档路径>` 生成自检用的合成快照与旁注。
cat > "$TMP/smokecheck.swift" <<'EOF'
import AppKit
import Foundation

struct PixelRect: Decodable {
    let x: Int, y: Int, width: Int, height: Int
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var text: String { "(\(x),\(y) \(width)x\(height))" }
}
struct Geometry: Decodable {
    let documentPath: String
    let lineCount: Int
    let backingScaleFactor: Double
    let imageWidth: Int
    let imageHeight: Int
    let textArea: PixelRect
    let gutter: PixelRect
    let firstLine: PixelRect
}

/// RGBA8 pixels, top-left origin.
struct Pixels {
    let width: Int, height: Int
    var bytes: [UInt8]

    init?(png path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return nil }
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
    }
    func luminance(_ x: Int, _ y: Int) -> Double {
        let (r, g, b) = rgb(x, y)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    /// HSB brightness (max component) — what the original whole-image check used.
    func brightness(_ x: Int, _ y: Int) -> Double {
        let (r, g, b) = rgb(x, y)
        return max(r, g, b)
    }

    func clamped(_ r: PixelRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        (max(0, r.x), max(0, r.y), min(width, r.x + r.width), min(height, r.y + r.height))
    }

    /// Most common luminance (1/64 buckets) inside `r`: the background.
    func background(in r: PixelRect) -> Double {
        let c = clamped(r)
        var counts = [Int](repeating: 0, count: 65)
        for y in c.y0..<max(c.y0, c.y1) { for x in c.x0..<max(c.x0, c.x1) {
            counts[Int((luminance(x, y) * 64).rounded())] += 1
        } }
        let best = counts.indices.max { counts[$0] < counts[$1] } ?? 64
        return Double(best) / 64
    }

    /// Pixels inside `r` whose luminance differs from the background by more
    /// than `threshold` (`darkOnly`: only darker ones), and the number of
    /// horizontal ink bands they form once columns inked over most of the
    /// height (separators, borders) are dropped.
    func ink(in r: PixelRect, threshold: Double, darkOnly: Bool) -> (count: Int, bands: Int) {
        let c = clamped(r)
        guard c.x1 > c.x0, c.y1 > c.y0 else { return (0, 0) }
        let bg = background(in: r)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let d = luminance(x, y) - bg
            return darkOnly ? d < -threshold : abs(d) > threshold
        }
        let rows = c.y1 - c.y0
        var keep = [Bool](repeating: true, count: c.x1 - c.x0)
        for x in c.x0..<c.x1 {
            var n = 0
            for y in c.y0..<c.y1 where isInk(x, y) { n += 1 }
            if Double(n) > 0.6 * Double(rows) { keep[x - c.x0] = false }
        }
        var count = 0, bands = 0, inBand = false, gap = 0
        for y in c.y0..<c.y1 {
            var rowInk = 0
            for x in c.x0..<c.x1 where keep[x - c.x0] && isInk(x, y) { rowInk += 1 }
            count += rowInk
            if rowInk > 0 {
                if !inBand { bands += 1; inBand = true }
                gap = 0
            } else if inBand {
                gap += 1
                if gap > 1 { inBand = false }
            }
        }
        return (count, bands)
    }
}

func check(_ args: [String]) -> Int32 {
    guard args.count == 3 else { print("usage: check <png> <json> <expected-document>"); return 2 }
    let (pngPath, jsonPath, expected) = (args[0], args[1], args[2])
    guard let px = Pixels(png: pngPath) else { print("VISUAL FAIL: unreadable png \(pngPath)"); return 1 }
    guard let data = FileManager.default.contents(atPath: jsonPath),
          let geo = try? JSONDecoder().decode(Geometry.self, from: data) else {
        print("GEOMETRY FAIL: missing or unreadable sidecar \(jsonPath)"); return 1
    }
    var failed: [String] = []
    print("snapshot \(px.width)x\(px.height) px, scale \(geo.backingScaleFactor), lines \(geo.lineCount)")
    if geo.imageWidth != px.width || geo.imageHeight != px.height {
        print("GEOMETRY FAIL: sidecar is for \(geo.imageWidth)x\(geo.imageHeight), image is \(px.width)x\(px.height)")
        failed.append("GEOMETRY")
    }

    // DOCUMENT: the window shows the file the script created.
    if geo.documentPath == expected {
        print("DOCUMENT OK: \(geo.documentPath)")
    } else {
        print("DOCUMENT FAIL: window shows '\(geo.documentPath)', expected '\(expected)'")
        failed.append("DOCUMENT")
    }

    // TEXT: dark glyph pixels in the text area, and specifically in line 1.
    let scale = max(1, geo.backingScaleFactor)
    let area = px.ink(in: geo.textArea, threshold: 0.25, darkOnly: true)
    let first = px.ink(in: geo.firstLine, threshold: 0.25, darkOnly: true)
    let minArea = Int(40 * scale * scale), minFirst = Int(15 * scale * scale)
    print("text area \(geo.textArea.text): \(area.count) dark px; first line \(geo.firstLine.text): \(first.count) dark px")
    if geo.textArea.isEmpty || geo.firstLine.isEmpty {
        print("TEXT FAIL: text area or first-line rect is empty in the sidecar")
        failed.append("TEXT")
    } else if area.count < minArea || first.count < minFirst {
        print("TEXT FAIL: no text rendered (need ≥\(minArea) dark px in the text area and ≥\(minFirst) in line 1)")
        failed.append("TEXT")
    } else {
        print("TEXT OK")
    }

    // GUTTER: line numbers — non-background ink forming one band per number.
    let gutter = px.ink(in: geo.gutter, threshold: 0.15, darkOnly: false)
    // One band per line number that fits in the gutter (line height taken
    // from the first line's rect).
    let fitting = geo.firstLine.height > 0 ? geo.gutter.height / geo.firstLine.height : 1
    let needBands = max(1, min(geo.lineCount, fitting))
    let minGutter = Int(10 * scale * scale)
    print("gutter \(geo.gutter.text): \(gutter.count) ink px in \(gutter.bands) bands (need ≥\(needBands))")
    if geo.gutter.isEmpty {
        print("GUTTER FAIL: gutter rect is empty (ruler hidden?)")
        failed.append("GUTTER")
    } else if gutter.count < minGutter || gutter.bands < needBands {
        print("GUTTER FAIL: line numbers missing (need ≥\(minGutter) ink px in ≥\(needBands) bands)")
        failed.append("GUTTER")
    } else {
        print("GUTTER OK")
    }

    // VISUAL: the original whole-image sanity check (paper + some ink).
    var bright = 0, dark = 0, total = 0
    for y in stride(from: 0, to: px.height, by: 4) {
        for x in stride(from: 0, to: px.width, by: 4) {
            let lum = px.brightness(x, y)
            total += 1
            if lum > 0.93 { bright += 1 }
            if lum < 0.45 { dark += 1 }
        }
    }
    let brightPct = Double(bright) / Double(max(total, 1)) * 100
    let darkPct = Double(dark) / Double(max(total, 1)) * 100
    print(String(format: "bright %.1f%%  dark %.2f%%", brightPct, darkPct))
    if brightPct > 50 && darkPct > 0.05 {
        print("VISUAL OK")
    } else {
        print("VISUAL FAIL: editor area did not render (blank-window regression?)")
        failed.append("VISUAL")
    }

    if failed.isEmpty { print("SNAPSHOT CHECKS OK"); return 0 }
    print("SNAPSHOT CHECKS FAILED: \(failed.joined(separator: ", "))")
    return 1
}

/// Synthetic snapshot + sidecar for the self-test: an 800x600 light window
/// with a toolbar band, a gutter with five line numbers and five lines of
/// text. Variants blank out one part.
func fixture(_ args: [String]) -> Int32 {
    guard args.count == 4 else { print("usage: fixture <variant> <png> <json> <document>"); return 2 }
    let (variant, pngPath, jsonPath, document) = (args[0], args[1], args[2], args[3])
    let w = 800, h = 600
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left pixel rects → CoreGraphics' bottom-left origin.
    func fill(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, gray: CGFloat) {
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: x, y: h - y - rh, width: rw, height: rh))
    }
    fill(0, 0, w, h, gray: 1)
    fill(0, 0, w, 52, gray: 0.9)          // toolbar
    fill(10, 18, 16, 16, gray: 0.3)       // a toolbar icon (visible even with a blank editor)
    fill(48, 52, 1, h - 52, gray: 0.85)   // gutter hairline
    for line in 0..<5 {
        let top = 60 + line * 20
        if variant != "blank-gutter" { fill(30, top + 4, 8, 11, gray: 0.55) }      // line number
        if variant != "blank-text" && line != 1 {                                // line 2 is empty
            for glyph in 0..<(line == 0 ? 9 : 12) { fill(56 + glyph * 9, top + 4, 6, 11, gray: 0.1) }
        }
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return 1 }
    try! png.write(to: URL(fileURLWithPath: pngPath))
    let shown = variant == "wrong-document" ? "/private/tmp/some-other-file.md" : document
    let json: [String: Any] = [
        "format": "karu-snapshot-geometry/1", "documentPath": shown, "lineCount": 5,
        "backingScaleFactor": 1, "imageWidth": w, "imageHeight": h,
        "textArea": ["x": 49, "y": 52, "width": w - 49, "height": h - 52],
        "gutter": ["x": 0, "y": 52, "width": 49, "height": h - 52],
        "firstLine": ["x": 52, "y": 60, "width": 90, "height": 20],
    ]
    try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        .write(to: URL(fileURLWithPath: jsonPath))
    return 0
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "check": exit(check(Array(argv.dropFirst())))
case "fixture": exit(fixture(Array(argv.dropFirst())))
default: print("usage: smokecheck check|fixture …"); exit(2)
}
EOF
swiftc -O -o "$TMP/smokecheck" "$TMP/smokecheck.swift" 2>&1 | grep -v '^$' || true
[[ -x "$TMP/smokecheck" ]] || { echo "SMOKE FAIL: checker did not compile"; exit 1; }

if [[ "$MODE" == "selftest" ]]; then
    # 证明校验会咬人：正常合成图通过；空白文本区、空白行号栏、错误文档各自失败，
    # 且失败的正是对应那一项（其他各项仍通过，所以不是整体亮度检查在起作用）。
    doc="$TMP/sample.md"
    fails=0
    run_case() { # 变体 期望退出码 期望失败项（空 = 无）
        local variant="$1" want="$2" item="$3" out code
        "$TMP/smokecheck" fixture "$variant" "$TMP/$variant.png" "$TMP/$variant.json" "$doc"
        set +e
        out="$("$TMP/smokecheck" check "$TMP/$variant.png" "$TMP/$variant.json" "$doc")"
        code=$?
        set -e
        local failed_items
        failed_items="$(printf '%s\n' "$out" | sed -n 's/^\([A-Z]*\) FAIL.*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
        if [[ "$code" == "$want" && "$failed_items" == "$item" ]]; then
            echo "PASS  $variant: exit $code${item:+, fails $item}"
        else
            echo "FAIL  $variant: expected exit $want failing [${item}], got exit $code failing [${failed_items}]"
            printf '%s\n' "$out" | sed 's/^/        /'
            fails=$((fails + 1))
        fi
    }
    run_case good 0 ""
    run_case blank-text 1 "TEXT"
    run_case blank-gutter 1 "GUTTER"
    run_case wrong-document 1 "DOCUMENT"
    if [[ $fails -eq 0 ]]; then
        echo "visual-smoke selftest: all 4 cases PASS"
        exit 0
    fi
    echo "visual-smoke selftest: $fails of 4 cases FAIL"
    exit 1
fi

swift build -c "$CONFIG" 2>&1 | tail -1
APP=".build/$CONFIG/KaruApp"
unset KARU_BENCH_REPORT KARU_SNAPSHOT_SCROLLEND KARU_SNAPSHOT_APPEARANCE

printf '# Heading\n\ndef hello():\n    return 42\n' > "$TMP/sample.md"
mkdir -p "$TMP/diag-$TAG-1" "$TMP/diag-$TAG-2"

KARU_DIAGNOSTIC_DIRECTORY="$TMP/diag-$TAG-1" KARU_SNAPSHOT="$TMP/snap.png" "$APP" "$TMP/sample.md"
"$TMP/smokecheck" check "$TMP/snap.png" "$TMP/snap.png.json" "$TMP/sample.md"

# 折叠几何守门（T13.9）：真实 app 的 typesetter 对 .null 字形的断行处理与
# 单元测试环境不同（rig 里断行、app 里熔合），折叠渲染回归只能在真 app 里抓。
# 一键折叠 test 夹具后，闭合行片段必须紧贴头行（headerMaxY == closerMinY），
# 否则就是"幽灵行/闭合括号消失"回归（2026-07-28 用户 bug）。
printf '{\n  "a": {\n    "x": 1\n  }\n}\n' > "$TMP/fold.json"
KARU_DIAGNOSTIC_DIRECTORY="$TMP/diag-$TAG-2" KARU_FOLDTEST=all KARU_FOLDTEST_GEO="$TMP/foldgeo.txt" \
    KARU_SNAPSHOT="$TMP/foldsnap.png" "$APP" "$TMP/fold.json"
python3 -I - "$TMP/foldgeo.txt" <<'EOF'
import re, sys
lines = {}
for m in re.finditer(r"L(\d+) .*fragY=([\d.]+) fragH=([\d.]+)", open(sys.argv[1]).read()):
    lines[int(m.group(1))] = (float(m.group(2)), float(m.group(3)))
if not lines:
    print("FOLD GEOMETRY FAIL: no geometry dump")
    sys.exit(1)
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
echo "VISUAL SMOKE OK"
