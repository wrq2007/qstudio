import AppKit
import CoreGraphics

// 生成 1024x1024 图标：渐变圆角方块 + 白色对话气泡
let size: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil,
                          width: Int(size), height: Int(size),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}

// 背景圆角矩形（留出 macOS 图标安全边距）
let inset: CGFloat = 60
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = (size - inset * 2) * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(path)
ctx.clip()

let colors = [
    CGColor(red: 0.17, green: 0.30, blue: 0.92, alpha: 1),
    CGColor(red: 0.46, green: 0.24, blue: 0.86, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY),
                       options: [])
ctx.restoreGState()

// 顶部高光
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
ctx.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))
ctx.restoreGState()

// 对话气泡
let bubbleW: CGFloat = size * 0.50
let bubbleH: CGFloat = size * 0.38
let bubbleRect = CGRect(x: (size - bubbleW) / 2,
                        y: (size - bubbleH) / 2 + size * 0.03,
                        width: bubbleW, height: bubbleH)
let bubbleRadius = bubbleH * 0.34

let bubble = CGMutablePath()
bubble.addRoundedRect(in: bubbleRect, cornerWidth: bubbleRadius, cornerHeight: bubbleRadius)

// 气泡尾巴
let tailX = bubbleRect.minX + bubbleW * 0.28
let tail = CGMutablePath()
tail.move(to: CGPoint(x: tailX, y: bubbleRect.minY + 6))
tail.addLine(to: CGPoint(x: tailX - size * 0.055, y: bubbleRect.minY - size * 0.085))
tail.addLine(to: CGPoint(x: tailX + size * 0.085, y: bubbleRect.minY + 6))
tail.closeSubpath()

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(bubble)
ctx.addPath(tail)
ctx.fillPath()

// 气泡里的三个点
let dotY = bubbleRect.midY
let dotR: CGFloat = size * 0.028
let gap: CGFloat = size * 0.082
for i in -1...1 {
    let cx = bubbleRect.midX + CGFloat(i) * gap
    let dotRect = CGRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
    ctx.setFillColor(CGColor(red: 0.30, green: 0.34, blue: 0.86, alpha: 1))
    ctx.fillEllipse(in: dotRect)
}

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: "/tmp/icon_1024.png"))
print("已生成 /tmp/icon_1024.png")
