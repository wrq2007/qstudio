import AppKit
import CoreGraphics

// 生成菜单栏模板图：直接从应用图标里取那个 Q 的形状，做成"深色即不透明"的剪影。
//
// 模板图（isTemplate = true）只用 alpha 通道，颜色由系统按菜单栏深浅色决定，
// 所以这里只关心"哪里不透明"。效果就是用户看到的：和应用图标同一个 Q，
// 只是颜色反相——图标是深色 Q 配白底，菜单栏里是镂空 Q 配透明底。
//
// 用法：swift Tools/MenuIconGen.swift [输出目录] [源图标]
// 源图标默认取 Assets/QStudio.iconset/icon_1024x1024.png。

/// 把图标转成"越深越不透明"的黑色剪影，同时返回字形外框（左下角原点的坐标）
func maskFrom(_ img: CGImage) -> (CGImage, CGRect)? {
    let w = img.width, h = img.height
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let buf = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return nil }

    // 先画原件，再原地改写成剪影：白底 → alpha 0，深色 Q → alpha 1
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

    var minX = w, maxX = -1, minY = h, maxY = -1   // minY/maxY 先按"内存行号"记，行 0 是图像顶部
    for row in 0..<h {
        for x in 0..<w {
            let i = (row * w + x) * 4
            let r = Double(buf[i]) / 255
            let g = Double(buf[i + 1]) / 255
            let b = Double(buf[i + 2]) / 255
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // 图标是白底 + 近黑字形：0.88 以下才算笔画，0.43 是抗锯齿过渡带
            let a = min(1, max(0, (0.88 - lum) / 0.45))
            let v = UInt8(a * 255)
            buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0; buf[i + 3] = v
            if v > 16 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
    }
    guard maxX >= minX, maxY >= minY, let masked = ctx.makeImage() else { return nil }

    // 内存行号 → 左下角原点：行 0 是顶部，所以底边 y = h - 1 - maxY
    let box = CGRect(x: CGFloat(minX),
                     y: CGFloat(h - 1 - maxY),
                     width: CGFloat(maxX - minX + 1),
                     height: CGFloat(maxY - minY + 1))
    return (masked, box)
}

/// 把字形按比例放进正方形画布，四周留一点边，保证 18pt 下不糊
func render(pixels: Int, masked: CGImage, box: CGRect, to path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        exit(1)
    }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

    let s0 = CGFloat(pixels)
    // 4% 留白：外框把右下角那条尾巴也算进去了，给多了环显得又细又小，
    // 一点不留又会顶到画布边缘（18pt 下贴着菜单栏上下沿）
    let pad = s0 * 0.04
    let avail = s0 - pad * 2
    let scale = min(avail / box.width, avail / box.height)
    let dw = box.width * scale, dh = box.height * scale
    let dx = (s0 - dw) / 2, dy = (s0 - dh) / 2

    // 画整张剪影，但平移+缩放使字形外框正好落在目标矩形里；
    // 剪影其余部分 alpha 为 0，画上去也不会盖住东西
    let W = CGFloat(masked.width), H = CGFloat(masked.height)
    let rect = CGRect(x: dx - box.origin.x * scale,
                      y: dy - box.origin.y * scale,
                      width: W * scale, height: H * scale)
    ctx.draw(masked, in: rect)

    guard let img = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: img)
    rep.size = NSSize(width: 18, height: 18)   // 菜单栏按 18pt 排版
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: path))
    print("\(path)  \(pixels)x\(pixels)  字形 \(Int(box.width))x\(Int(box.height))")
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let srcPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "Assets/QStudio.iconset/icon_1024x1024.png"

guard let data = try? Data(contentsOf: URL(fileURLWithPath: srcPath)),
      let srcRep = NSBitmapImageRep(data: data),
      let src = srcRep.cgImage else {
    FileHandle.standardError.write("读不到源图标：\(srcPath)\n".data(using: .utf8)!)
    exit(1)
}
guard let (masked, box) = maskFrom(src) else { exit(1) }

render(pixels: 18, masked: masked, box: box, to: "\(root)/MenuIcon.png")
render(pixels: 36, masked: masked, box: box, to: "\(root)/MenuIcon@2x.png")
render(pixels: 144, masked: masked, box: box, to: "/tmp/menuicon_preview.png")   // 放大预览用
