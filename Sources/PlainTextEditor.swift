import SwiftUI
import AppKit

/// 自己包一层的输入框。
///
/// SwiftUI 自带的 `TextEditor` 有一层系统内边距，而占位提示是另画的，两者的起点对不上，
/// 表现为光标和提示文字不在一条竖线上。这里改用裸 `NSTextView`：
/// inset 全部自己控制，**占位文字用同一个文本系统画在同一个原点上**，所以光标、提示、
/// 实际输入三者严格对齐。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var focused: Bool

    var font: NSFont
    var textColor: NSColor
    var placeholder: String
    var onSubmit: () -> Void
    var onHeightChange: (CGFloat) -> Void

    /// 文本容器上边距，占位文字和真实输入共用这个起点
    static let topInset: CGFloat = 6
    static let minHeight: CGFloat = 28
    static let maxHeight: CGFloat = 120

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.textContainerInset = NSSize(width: 0, height: Self.topInset)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 20)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = context.coordinator
        tv.string = text

        let ph = PlaceholderView(frame: NSRect(x: 0, y: Self.topInset, width: 400, height: 18))
        ph.text = placeholder
        ph.font = font
        ph.color = textColor.withAlphaComponent(0.35)
        ph.isHidden = !text.isEmpty
        tv.addSubview(ph)
        context.coordinator.placeholder = ph

        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.parent = self
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }

        // 输入法组合期（markedText 未上屏）绝不覆盖 tv.string：
        // 此时 tv.string 是正在拼的拼音（如 "ni"），而绑定的 text 还是旧值。
        // 流式输出时本视图每 55ms 刷新一次，一旦覆盖就会把拼音冲掉，导致中文打不进去。
        if tv.string != text, tv.markedRange().length == 0 {
            let caret = tv.selectedRange().location
            tv.string = text
            let loc = min(caret, (text as NSString).length)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
        }
        if tv.font != font { tv.font = font }
        if tv.textColor != textColor {
            tv.textColor = textColor
            tv.insertionPointColor = textColor
        }
        context.coordinator.placeholder?.text = placeholder
        context.coordinator.placeholder?.font = font
        // 占位符显隐只由 textDidChange 统一判断（含输入法组合期 markedRange），
        // 这里若再写一遍 !text.isEmpty，会在 SwiftUI 刷新时把组合中的占位符错误地显示回来
        if let tv = context.coordinator.textView {
            context.coordinator.placeholder?.isHidden = !tv.string.isEmpty || tv.markedRange().length > 0
        }

        // 只在焦点状态从 false 变 true 的那一刻抢焦点，
        // 否则用户点别处（比如左栏）会被立刻拽回输入框
        if focused, !context.coordinator.wasFocused,
           tv.window?.firstResponder !== tv, let w = tv.window {
            w.makeFirstResponder(tv)
        }
        context.coordinator.wasFocused = focused
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        weak var textView: NSTextView?
        weak var placeholder: PlaceholderView?
        var wasFocused = false

        init(_ parent: PlainTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
            // 输入法组合期间 markedText 还没上屏，tv.string 可能仍为空，
            // 但占位符必须立刻消失——只要有正在编辑的内容（含 markedRange）就隐藏
            let hasContent = !tv.string.isEmpty || tv.markedRange().length > 0
            placeholder?.isHidden = hasContent
            reportHeight(tv)
        }

        /// markedText 变化时 AppKit 走的是这个 delegate，不是 textDidChange。
        /// 组合期必须在这里也隐藏占位符，否则灰色提示字会压在拼音下面。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            let hasContent = !tv.string.isEmpty || tv.markedRange().length > 0
            placeholder?.isHidden = hasContent
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewline(nil)       // Shift+回车 = 换行
                } else {
                    parent.onSubmit()                 // 回车 = 发送
                }
                return true
            }
            return false
        }

        private func reportHeight(_ tv: NSTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let h = used.height + PlainTextEditor.topInset * 2
            parent.onHeightChange(min(max(h, PlainTextEditor.minHeight), PlainTextEditor.maxHeight))
        }
    }
}

/// 占位提示。用和正文完全相同的字体、绘制原点，所以和光标、输入文字严格对齐。
final class PlaceholderView: NSView {
    var text: String = "" {
        didSet { needsDisplay = true }
    }
    var font: NSFont = .systemFont(ofSize: 13) {
        didSet { needsDisplay = true }
    }
    var color: NSColor = .secondaryLabelColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
    }

    /// 不参与鼠标命中，点了也能落到文本框上
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
