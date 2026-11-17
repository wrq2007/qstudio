import AppKit
import CoreGraphics

// 生成菜单栏模板图：对话气泡剪影 + 三个镂空点（app logo 的反相）。
// 模板图（isTemplate = true）只用 alpha 通道，颜色由系统按深浅色自动反色，
// 所以这里只画"哪里不透明"，不关心具体颜色。

/// 在 1024 画布上画气泡，尺寸参数都是相对画布的比例，便于按比例缩放到任意像素。
func drawBubble(in ctx: CGContext, canvas: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))

    let s = canvas
    // 气泡主体：左右留一点边，上下也留，保证 18pt 下不会糊成一坨
    let bw = s * 0.92
    let bh = s * 0.62
    let bx = (s - bw) / 2
    let by = s * 0.28
    let r = bh * 0.32
    let body = CGPath(roundedRect: CGRect(x: bx, y: by, width: bw, height: bh),
                      cornerWidth: r, cornerHeight: r, transform: nil)

    // 尾巴：左下角往下的三角，和主体连成一体
    let tail = CGMutablePath()
    let tx = bx + bw * 0.16
    tail.move(to: CGPoint(x: tx, y: by + s * 0.04))
    tail.addLine(to: CGPoint(x: tx + s * 0.03, y: s * 0.06))
    tail.addLine(to: CGPoint(x: tx + s * 0.28, y: by + s * 0.04))
    tail.closeSubpath()

    ctx.addPath(body)
    ctx.addPath(tail)
    ctx.fillPath()

    // 三个点镂空（清 alpha），形成"气泡里说话"的负形
    let dotR = s * 0.075
    let gap = s * 0.185
    let dotY = by + bh * 0.52
    for i in -1...1 {
        let cx = s / 2 + CGFloat(i) * gap
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
        ctx.setBlendMode(.normal)
    }
}

func render(pixels: Int, to path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        exit(1)
    }
    ctx.interpolationQuality = .high
    drawBubble(in: ctx, canvas: CGFloat(pixels))
    guard let img = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: 18, height: 18)   // 菜单栏按 18pt 排版
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: path))
    print("\(path)  \(pixels)x\(pixels)")
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
render(pixels: 18, to: "\(root)/MenuIcon.png")
render(pixels: 36, to: "\(root)/MenuIcon@2x.png")
render(pixels: 144, to: "/tmp/menuicon_preview.png")   // 放大预览用，方便肉眼核对
