import AppKit
import CoreGraphics
import Foundation

// Q Studio 图标：白色背景 + 圆润大写 Q。
// 关键：尾巴从圆环右下外缘沿切线方向甩出，绝不侵入圆环内部。

func drawQ(size: Int, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let s = CGFloat(size)
    let scale = s / 1024.0

    // 白色背景
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    let ink = CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1) // 近黑，略带冷调

    // ---- 圆环 ----
    // 中心略偏左上，给右下尾巴留空间
    let cx: CGFloat = 470 * scale
    let cy: CGFloat = 554 * scale
    let radius: CGFloat = 250 * scale
    let stroke: CGFloat = 92 * scale

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let ring = CGRect(x: cx - radius, y: cy - radius,
                      width: radius * 2, height: radius * 2)
    ctx.strokeEllipse(in: ring)

    // ---- 尾巴 ----
    // CoreGraphics 原点在左下，y 向上。右下 = (x增大, y减小)。
    // 起点在圆环右下 45° 外缘，沿径向向外延伸 —— 离圆心越来越远，绝不侵入圆的内部。
    let angle: CGFloat = -45.0 * .pi / 180
    // 起点略微外移到圆环外半，确保尾巴内侧边缘也不会探进圆环内缘
    let startR = radius + stroke * 0.28
    let sx = cx + startR * cos(angle)
    let sy = cy + startR * sin(angle)
    let dirx: CGFloat = cos(angle)   // 0.707 向右
    let diry: CGFloat = sin(angle)   // -0.707 向下（径向朝外）
    let len: CGFloat = 105 * scale
    let ex = sx + dirx * len
    let ey = sy + diry * len

    ctx.setLineWidth(stroke * 0.92)
    ctx.move(to: CGPoint(x: sx, y: sy))
    ctx.addLine(to: CGPoint(x: ex, y: ey))
    ctx.strokePath()

    // 输出
    guard let cg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: draw_icon <size> <out.png>")
    exit(1)
}
let size = Int(args[1])!
drawQ(size: size, to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) at \(size)x\(size)")
