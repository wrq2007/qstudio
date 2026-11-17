import AppKit

/// 生成 DMG 安装窗口的背景图：底色 + 中间一个箭头 + 底部一行提示。
/// 输出 Resources/dmg-background.png（1x）和 @2x。
///
/// 用法：swift Tools/DmgBackground.swift Resources
/// 改完重跑，再执行 Tools/make_dmg.sh。
let W: CGFloat = 640
// 高度要和 dmg_settings.py 里的 window_rect / 图标坐标一致：
// 420 时窗口内容高度只有约 392，底部那行小字会被裁掉，改 400 刚好装下。
let H: CGFloat = 400

func draw(_ scale: CGFloat, to path: String) -> Bool {
    // 用显式位图上下文：lockFocus 会跟随屏幕的 Retina 缩放，
    // 1x 那张会被悄悄放大成 2 倍（实测输出 1280x840）。
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(W * scale),
                                     pixelsHigh: Int(H * scale),
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return false }
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let ctx = graphics.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // 背景：极浅的竖向渐变，避免纯白显得像个空文件夹
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(srgbRed: 0.980, green: 0.984, blue: 0.992, alpha: 1).cgColor,
        NSColor(srgbRed: 0.929, green: 0.937, blue: 0.949, alpha: 1).cgColor,
    ] as CFArray
    if let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: 0, y: H),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }

    // 箭头：从左侧 app 指向右侧 Applications
    let yMid: CGFloat = H - 176        // 与图标垂直居中对齐（坐标原点在左下）
    let x0: CGFloat = 252
    let x1: CGFloat = 396
    let accent = NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 0.55)

    ctx.setStrokeColor(accent.cgColor)
    ctx.setLineWidth(9)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x0, y: yMid))
    ctx.addLine(to: CGPoint(x: x1 - 16, y: yMid))
    ctx.strokePath()

    // 箭头头部
    ctx.setFillColor(accent.cgColor)
    ctx.move(to: CGPoint(x: x1 + 6, y: yMid))
    ctx.addLine(to: CGPoint(x: x1 - 22, y: yMid + 19))
    ctx.addLine(to: CGPoint(x: x1 - 22, y: yMid - 19))
    ctx.closePath()
    ctx.fillPath()

    // 提示文字：中文主标题 + 英文副标题
    let center = NSMutableParagraphStyle()
    center.alignment = .center

    let title = NSAttributedString(string: "把 Q Studio 拖到「应用程序」文件夹",
                                   attributes: [
                                       .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                                       .foregroundColor: NSColor(srgbRed: 0.176, green: 0.192, blue: 0.216, alpha: 1),
                                       .paragraphStyle: center,
                                   ])
    let subtitle = NSAttributedString(string: "Drag Q Studio into the Applications folder",
                                      attributes: [
                                          .font: NSFont.systemFont(ofSize: 12.5),
                                          .foregroundColor: NSColor(srgbRed: 0.49, green: 0.51, blue: 0.55, alpha: 1),
                                          .paragraphStyle: center,
                                      ])

    let box = NSRect(x: 0, y: 0, width: W, height: 24)
    title.draw(in: box.offsetBy(dx: 0, dy: H - 300))
    subtitle.draw(in: box.offsetBy(dx: 0, dy: H - 326))

    // 底部再补一句：首次打开需要右键打开（未签名公证）
    let hint = NSAttributedString(string: "首次打开若提示「无法验证开发者」，请右键 →「打开」",
                                  attributes: [
                                      .font: NSFont.systemFont(ofSize: 10.5),
                                      .foregroundColor: NSColor(srgbRed: 0.56, green: 0.58, blue: 0.62, alpha: 1),
                                      .paragraphStyle: center,
                                  ])
    hint.draw(in: box.offsetBy(dx: 0, dy: 16))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    try? png.write(to: URL(fileURLWithPath: path))
    return true
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
_ = draw(1, to: "\(outDir)/dmg-background.png")
_ = draw(2, to: "\(outDir)/dmg-background@2x.png")
print("wrote \(outDir)/dmg-background.png")
