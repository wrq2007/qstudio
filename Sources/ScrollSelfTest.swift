import AppKit
import SwiftUI

/// 对话区滚动几何自检：`defaults write com.lens.localmodel MDSCROLLTEST -bool true` 后启动，
/// 3 秒后把内容滚到 15% / 50% / 85% 三处，每次记下落盘：
///
/// 关键看 `docH` 三次是否一致。之前对话区用 `LazyVStack`，只按已渲染的几行估总高度，
/// 滚动过程中估算值会被改写（实测 5357 → 3693），滚动条按错误的总高度算滑块位置，
/// 鼠标一动就跳一下。换成 `VStack` 后 docH 恒定，`float` 才会精确等于目标比例。
@MainActor
enum ScrollSelfTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MDSCROLLTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDSCROLLTEST")
    }

    static func schedule() {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { run() }
    }

    private static func run() {
        var lines: [String] = []
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let root = window.contentView else {
            write(["没有可见窗口"]); return
        }
        // 内容高于一屏的才是对话区（输入框那个滚动视图内容通常不超屏）
        let scrolls = collect(root).sorted {
            ($0.documentView?.frame.height ?? 0) > ($1.documentView?.frame.height ?? 0)
        }
        guard let chat = scrolls.first, let clip = chat.contentView as NSClipView?,
              let docH = chat.documentView?.frame.height else { write(["没找到对话区滚动视图"]); return }

        let clipH = Int(clip.bounds.height)
        let docHi = Int(docH)
        let startY = Int(clip.bounds.origin.y)
        let startFloat = fmt(chat.verticalScroller?.floatValue)
        let startKnob = fmt3(chat.verticalScroller?.knobProportion)
        lines.append("clipH=\(clipH) docH=\(docHi) 初始 y=\(startY) float=\(startFloat) knob=\(startKnob)")

        var ratios = [0.15, 0.50, 0.85]
        var results: [String] = []
        func step() {
            guard !ratios.isEmpty else {
                lines.append(contentsOf: results)
                write(lines)
                return
            }
            let r = ratios.removeFirst()
            let y = max(0, (docH - clip.bounds.height) * r)
            clip.scroll(to: NSPoint(x: 0, y: y))
            chat.reflectScrolledClipView(clip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let nowDoc = chat.documentView?.frame.height ?? 0
                let sc = chat.verticalScroller
                let y = Int(clip.bounds.origin.y)
                let doc = Int(nowDoc)
                let f = fmt(sc?.floatValue)
                let k = fmt3(sc?.knobProportion)
                results.append("目标 \(Int(r * 100))% → y=\(y) docH=\(doc) float=\(f) knob=\(k)")
                step()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { step() }
    }

    private static func collect(_ v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let sv = v as? NSScrollView,
           let doc = sv.documentView, doc.frame.height > sv.contentView.bounds.height * 1.2 {
            out.append(sv)
        }
        for sub in v.subviews { out += collect(sub) }
        return out
    }

    private static func fmt(_ v: Float?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "-"
    }

    private static func fmt3(_ v: CGFloat?) -> String {
        v.map { String(format: "%.3f", $0) } ?? "-"
    }

    private static func write(_ lines: [String]) {
        try? lines.joined(separator: "\n")
            .write(toFile: "/tmp/qstudio_scroll.txt", atomically: true, encoding: .utf8)
        UserDefaults.standard.removeObject(forKey: "MDSCROLLTEST")
    }
}
