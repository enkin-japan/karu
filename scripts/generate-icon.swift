#!/usr/bin/env swift
//
// generate-icon.swift — Karu App 图标生成器 (T6.5；2026-11 改为「浅色代码」方案)
//
// 逐尺寸离屏绘制 App 图标并写出完整 iconset。运行方式：
//     swift scripts/generate-icon.swift
// 产出 assets/AppIcon.iconset/ 下 10 张 PNG，随后由 iconutil 打成 .icns：
//     iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
//
// 设计：macOS Big Sur 风格圆角方形（squircle 近似，圆角 ≈ 边长 22.37%），
// 纸色渐变背景 + 四行彩色代码行（紫、青绿、橙、金，普通文字用灰色）+ 第 3 行
// 行尾一根系统蓝光标条。浅色底传达"简洁、轻量"，彩色行表明是代码编辑器。
// 16/32 像素降为 3 行、加粗并对齐像素，保证小尺寸可读。
//
import AppKit
import CoreGraphics

// MARK: - 颜色（sRGB）
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((h >> 16) & 0xFF) / 255,
                                                 CGFloat((h >> 8) & 0xFF) / 255,
                                                 CGFloat(h & 0xFF) / 255, a])!
}
let bgTop = hex(0xFFFFFF)      // 纸色（上）
let bgBottom = hex(0xEFEEE9)   // 纸色（下）
let textGray = hex(0xA9A8A3)   // 普通文字
let purple = hex(0xB45FD9)     // 关键字
let teal = hex(0x1FAE95)       // 类型
let orange = hex(0xE8843C)     // 字符串
let gold = hex(0xE2A93B)       // 函数
let accent = hex(0x0A84FF)     // 系统蓝光标
let edgeStroke = hex(0x000000, 0.10)
let dropShadow = hex(0x000000, 0.28)

// MARK: - 单尺寸绘制
func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("无法创建 CGContext (size=\(size))") }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // squircle 内容区：参照 Big Sur 网格，内容占画布 ~80.47%，四周留透明边距。
    let inset = s * 0.09765625
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let side = rect.width
    let corner = side * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner,
                          cornerHeight: corner, transform: nil)

    // 1) 底部的柔和投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: dropShadow)
    ctx.addPath(squircle)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // 2) 背景纸色渐变（自上而下；CG 原点在左下：top = maxY）
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: colorSpace, colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // 归一化坐标：u 向右、v 向下，都是 0…1（相对内容区）。小尺寸把每个
    // 胶囊对齐到整像素，避免 1–2 像素的线条被抗锯齿抹淡。
    let small = size <= 32
    func fill(_ r: CGRect, _ color: CGColor) {
        var r = r
        if small {
            let w = max(1, r.width.rounded()), h = max(1, r.height.rounded())
            r = CGRect(x: r.minX.rounded(), y: (r.midY - h / 2).rounded(), width: w, height: h)
        }
        let radius = min(r.width, r.height) / 2
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    /// 横向胶囊（代码行的一段）：u0…u1，中心在 v，粗细 h。
    func segment(_ u0: CGFloat, _ u1: CGFloat, v: CGFloat, h: CGFloat, _ color: CGColor) {
        fill(CGRect(x: rect.minX + u0 * side, y: rect.maxY - v * side - h * side / 2,
                    width: (u1 - u0) * side, height: h * side), color)
    }
    /// 光标：中心在 u，v0…v1，宽 w（小尺寸至少 2 像素）。
    func cursor(u: CGFloat, _ v0: CGFloat, _ v1: CGFloat, w: CGFloat) {
        let width = small ? max(2, (w * side).rounded()) : w * side
        fill(CGRect(x: rect.minX + u * side - width / 2, y: rect.maxY - v1 * side,
                    width: width, height: (v1 - v0) * side), accent)
    }

    if small {
        // 3 行、加粗：关键字 + 文字 / 缩进的类型 + 光标 / 缩进的字符串
        let h: CGFloat = 0.12
        segment(0.17, 0.40, v: 0.30, h: h, purple)
        segment(0.47, 0.76, v: 0.30, h: h, textGray)
        segment(0.31, 0.52, v: 0.50, h: h, teal)
        cursor(u: 0.70, 0.36, 0.64, w: 0.11)
        segment(0.31, 0.66, v: 0.70, h: h, orange)
    } else {
        let h: CGFloat = 0.07
        segment(0.18, 0.33, v: 0.29, h: h, purple)
        segment(0.38, 0.66, v: 0.29, h: h, textGray)
        segment(0.30, 0.50, v: 0.43, h: h, teal)
        segment(0.55, 0.78, v: 0.43, h: h, orange)
        segment(0.30, 0.47, v: 0.57, h: h, gold)
        cursor(u: 0.54, 0.49, 0.65, w: 0.05)
        segment(0.18, 0.30, v: 0.71, h: h, textGray)
    }

    // 3) 边缘极淡描边增加层次（0.5% 宽，描在内侧避免被裁掉）
    let sw = max(side * 0.005, 0.5)
    let strokeRect = rect.insetBy(dx: sw / 2, dy: sw / 2)
    ctx.addPath(CGPath(roundedRect: strokeRect, cornerWidth: corner - sw / 2,
                       cornerHeight: corner - sw / 2, transform: nil))
    ctx.setStrokeColor(edgeStroke)
    ctx.setLineWidth(sw)
    ctx.strokePath()

    guard let img = ctx.makeImage() else { fatalError("makeImage 失败 (size=\(size))") }
    return img
}

// MARK: - 写 PNG
func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败: \(url.lastPathComponent)")
    }
    try! data.write(to: url)
}

// MARK: - 主流程
// 定位仓库根：脚本在 scripts/ 下，assets/ 与 scripts/ 同级。
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetDir = repoRoot.appendingPathComponent("assets/AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconsetDir,
                                         withIntermediateDirectories: true)

// iconset 规格：(文件名, 像素尺寸)
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in specs {
    let img = drawIcon(size: px)
    let url = iconsetDir.appendingPathComponent(name)
    writePNG(img, to: url)
    print("  ✓ \(name) (\(px)x\(px))")
}
print("iconset 已生成: \(iconsetDir.path)")
