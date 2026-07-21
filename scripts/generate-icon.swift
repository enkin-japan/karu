#!/usr/bin/env swift
//
// generate-icon.swift — TinyEditor App 图标生成器 (T6.5)
//
// 逐尺寸离屏绘制 App 图标并写出完整 iconset。运行方式：
//     swift scripts/generate-icon.swift
// 产出 assets/AppIcon.iconset/ 下 10 张 PNG，随后由 iconutil 打成 .icns。
//
// 设计：macOS Big Sur 风格圆角方形（squircle 近似，圆角 ≈ 边长 22.37%），
// 极浅暖白纸色渐变背景 + 4 条纤细灰色文本行 + 第 2 行行尾一根系统蓝光标条
// （唯一强调色）。大量留白 + 元素纤细传达"简洁、轻量"。
// 16/32 小图降为 3 行并加粗线条以保可读。
//
import AppKit
import CoreGraphics

// MARK: - 颜色（sRGB 0~1）
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255, alpha: CGFloat(a))
}
let bgTop = rgb(250, 250, 248)   // #FAFAF8 纸色（上）
let bgBottom = rgb(240, 239, 234) // #F0EFEA 纸色（下）
let lineGray = rgb(200, 199, 194) // #C8C7C2 文本行
let accent = rgb(10, 132, 255)    // #0A84FF 系统蓝光标
let edgeStroke = rgb(0, 0, 0, 20.0 / 255.0) // #00000014 极淡描边

// MARK: - 单尺寸绘制
func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
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

    // 1) 背景纸色渐变（自上而下）
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs,
                          colors: [bgTop, bgBottom] as CFArray,
                          locations: [0, 1])!
    // CG 原点在左下：top = maxY, bottom = minY
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // 圆角端点的横条（胶囊）
    func capsule(x: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, color: CGColor) {
        let r = CGRect(x: x, y: cy - h / 2, width: w, height: h)
        let radius = min(h / 2, w / 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    // 2) 文本行布局：整组垂直居中，左右留白 ~22%
    let small = size <= 32
    let n = small ? 3 : 4
    let lineH = side * (small ? 0.06 : 0.03)
    let spacing = side * (small ? 0.17 : 0.13) // 行距（中心到中心）
    let groupH = CGFloat(n - 1) * spacing
    let topCY = rect.midY + groupH / 2          // 最上一行中心（CG y 向上）

    let leftX = rect.minX + side * 0.22
    let fullW = side * 0.56
    let shortW = side * 0.34
    let shortIdx = 1 // 第 2 行短

    var line2CY: CGFloat = topCY
    for i in 0 ..< n {
        let cy = topCY - CGFloat(i) * spacing
        let w = (i == shortIdx) ? shortW : fullW
        capsule(x: leftX, cy: cy, w: w, h: lineH, color: lineGray)
        if i == shortIdx { line2CY = cy }
    }

    // 3) 点睛：第 2 行行尾竖直光标条（唯一强调色）
    let cursorW = side * 0.035
    let cursorH = spacing * 1.5
    let cursorX = leftX + shortW + side * 0.025
    let cr = CGRect(x: cursorX, y: line2CY - cursorH / 2, width: cursorW, height: cursorH)
    let cRadius = cursorW / 2
    ctx.addPath(CGPath(roundedRect: cr, cornerWidth: cRadius,
                       cornerHeight: cRadius, transform: nil))
    ctx.setFillColor(accent)
    ctx.fillPath()

    // 5) 边缘极淡描边增加层次（0.5% 宽，描在内侧避免被裁掉）
    let sw = max(side * 0.005, 0.5)
    let strokeRect = rect.insetBy(dx: sw / 2, dy: sw / 2)
    let strokePath = CGPath(roundedRect: strokeRect,
                            cornerWidth: corner - sw / 2,
                            cornerHeight: corner - sw / 2, transform: nil)
    ctx.addPath(strokePath)
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
