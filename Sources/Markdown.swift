import SwiftUI
import AppKit

// MARK: - 块模型

struct MDItem {
    let level: Int
    let marker: String
    let text: String
}

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(lang: String, code: String)
    case bullets([MDItem])
    case ordered([MDItem])
    case quote(String)
    case table(headers: [String], rows: [[String]])
    case rule
    /// 数学公式（KaTeX 渲染）。display = 独立成块、居中
    case math(String, display: Bool)
}

// MARK: - 解析器

enum MarkdownParser {
    /// 把内嵌在正文里的 <svg>…</svg> 片段独立成行（前后加空行），
    /// 这样块解析器就能把它们当成单独的 svg 块渲染，而不是当文字。
    private static func extractInlineSVG(_ text: String) -> String {
        let pattern = "<svg[\\s\\S]*?</svg>"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        guard !matches.isEmpty else { return text }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        for m in matches {
            let loc = m.range.location
            let prefix = ns.substring(to: loc)
            let fenceCount = prefix.components(separatedBy: "```").count - 1
            // 已经在代码围栏里的 SVG 交给正常代码块处理，不重复抽
            if fenceCount % 2 == 1 { continue }
            guard loc >= cursor else { continue }
            result += ns.substring(with: NSRange(location: cursor, length: loc - cursor))
            result += "\n\n" + ns.substring(with: m.range) + "\n\n"
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// 识别一条公式。返回 nil 表示这里不是公式（例如流式输出中 $$ 还没闭合）。
    private static func mathBlock(at index: Int, lines: [String]) -> (latex: String, display: Bool, next: Int)? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

        // $$ 开头：可以跨行，直到遇到结尾的 $$
        if trimmed.hasPrefix("$$") {
            let first = String(trimmed.dropFirst(2))
            if let end = first.range(of: "$$") {
                let latex = String(first[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
                return latex.isEmpty ? nil : (latex, true, index + 1)
            }
            var body: [String] = [first]
            var j = index + 1
            while j < lines.count {
                let l = lines[j]
                if let r = l.range(of: "$$") {
                    body.append(String(l[..<r.lowerBound]))
                    let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return latex.isEmpty ? nil : (latex, true, j + 1)
                }
                body.append(l)
                j += 1
            }
            return nil   // 没闭合（流式输出中途）：先按普通文字显示
        }

        // \[ … \]（可跨行）
        if trimmed.hasPrefix("\\[") {
            let opener = "\\["
            let closer = "\\]"
            let first = String(trimmed.dropFirst(opener.count))
            if let r = first.range(of: closer) {
                let latex = String(first[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return latex.isEmpty ? nil : (latex, true, index + 1)
            }
            var body: [String] = [first]
            var j = index + 1
            while j < lines.count {
                let l = lines[j]
                if let r = l.range(of: closer) {
                    body.append(String(l[..<r.lowerBound]))
                    let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    return latex.isEmpty ? nil : (latex, true, j + 1)
                }
                body.append(l)
                j += 1
            }
            return nil
        }

        // 整行就是一个 $…$：$x^2 + y^2 = z^2$
        if trimmed.hasPrefix("$") && trimmed.hasSuffix("$") && trimmed.count > 2 {
            let inner = String(trimmed.dropFirst().dropLast())
            // 里面还有 $ 说明不是单条公式，交给普通文本
            if !inner.contains("$"), !inner.trimmingCharacters(in: .whitespaces).isEmpty {
                return (inner, false, index + 1)
            }
        }
        return nil
    }

    static func parse(_ source: String) -> [MDBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")

        // 模型常把裸 <svg>…</svg> 直接粘在句子后面（不在行首、也没代码围栏）。
        // 先用正则把这些片段单独抽成行，前后补空行，让下面的块解析能识别它们。
        let extracted = extractInlineSVG(normalized)
        let lines = extracted.components(separatedBy: "\n")

        var blocks: [MDBlock] = []
        var i = 0

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            // 代码围栏（容忍流式输出时尚未闭合）
            if let fence = fenceInfo(trimmed) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if isFenceClose(l, marker: fence.marker) {
                        i += 1
                        break
                    }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: fence.lang, code: body.joined(separator: "\n")))
                continue
            }

            // 裸 SVG：模型常常不加 ```svg 代码围栏，直接吐 <svg>...</svg>。
            // 这里也识别成 svg 代码块，否则只会当普通文字显示成源码。
            if trimmed.lowercased().hasPrefix("<svg") {
                var body: [String] = []
                while i < lines.count {
                    body.append(lines[i])
                    if lines[i].lowercased().contains("</svg>") { i += 1; break }
                    i += 1
                }
                // 流式输出中 SVG 还没写完时也先渲染已到达的部分（WKWebView 容错）
                blocks.append(.code(lang: "svg", code: body.joined(separator: "\n")))
                continue
            }

            // 数学公式。放在代码块之后：围栏里的 $$ 不该被当成公式。
            // $$…$$（可跨行）/ \[…\] 走独立成块；整行只有一个 $…$ 时按行内公式渲染。
            if let math = mathBlock(at: i, lines: lines) {
                blocks.append(.math(math.latex, display: math.display))
                i = math.next
                continue
            }

            // 分割线
            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            // 标题
            if let h = headingInfo(trimmed) {
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var s = String(t.dropFirst())
                    if s.hasPrefix(" ") { s.removeFirst() }
                    body.append(s)
                    i += 1
                }
                blocks.append(.quote(joinParagraph(body)))
                continue
            }

            // 表格
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let headers = splitRow(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(splitRow(t))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // 列表
            if let first = listInfo(raw) {
                var items: [MDItem] = [first]
                let ordered = first.marker.first?.isNumber ?? false
                i += 1
                while i < lines.count {
                    let line = lines[i]
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if let info = listInfo(line) {
                        let isOrdered = info.marker.first?.isNumber ?? false
                        if isOrdered == ordered {
                            items.append(info)
                            i += 1
                            continue
                        }
                        break
                    }
                    // 续行：并入上一项
                    if leadingSpaces(line) >= 2, let last = items.last {
                        items[items.count - 1] = MDItem(level: last.level,
                                                        marker: last.marker,
                                                        text: last.text + joinParagraph([t]))
                        i += 1
                        continue
                    }
                    break
                }
                blocks.append(ordered ? .ordered(items) : .bullets(items))
                continue
            }

            // 段落
            var body: [String] = []
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if fenceInfo(t) != nil || headingInfo(t) != nil || isRule(t) || t.hasPrefix(">") || listInfo(line) != nil {
                    break
                }
                body.append(t)
                i += 1
            }
            if body.isEmpty {
                // 兜底，避免死循环
                body.append(trimmed)
                i += 1
            }
            blocks.append(.paragraph(joinParagraph(body)))
        }

        return blocks
    }

    // MARK: 行级辅助

    private static func fenceInfo(_ trimmed: String) -> (marker: String, lang: String)? {
        for m in ["```", "~~~"] where trimmed.hasPrefix(m) {
            // 关闭围栏不能带语言标记：```text 不是关闭，而是嵌套开启
            let char = m.first!
            // 记下实际开启围栏的长度，关闭围栏不能比它短
            let run = String(trimmed.prefix(while: { $0 == char }))
            let rest = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
            let lang = rest.split(separator: " ").first.map(String.init) ?? ""
            return (run, lang)
        }
        return nil
    }

    /// 只有「同字符、≥3 个、其后仅剩空白」才算关闭围栏
    private static func isFenceClose(_ line: String, marker: String) -> Bool {
        // 允许关闭围栏带尾随空格（模型很爱这么干）
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(marker), let char = marker.first else { return false }
        // 关闭围栏：同字符，且长度不能短于开启围栏
        let count = t.prefix(while: { $0 == char }).count
        return count >= marker.count
    }

    private static func headingInfo(_ trimmed: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex, trimmed[idx] == "#", level < 6 {
            level += 1
            idx = trimmed.index(after: idx)
        }
        guard level > 0, idx <= trimmed.endIndex else { return nil }
        if idx == trimmed.endIndex { return (level, "") }
        guard trimmed[idx] == " " else { return nil }
        var text = String(trimmed[idx...]).trimmingCharacters(in: .whitespaces)
        // 去掉结尾的 ###
        while text.hasSuffix("#") {
            text.removeLast()
        }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        guard let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.contains("|"), compact.contains("-") else { return false }
        return compact.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }

    private static func listInfo(_ line: String) -> MDItem? {
        let spaces = leadingSpaces(line)
        let level = min(spaces / 2, 4)
        let body = line.drop { $0 == " " }
        guard let first = body.first else { return nil }

        if "-*+".contains(first) {
            let after = body.dropFirst()
            guard after.first == " " else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            return MDItem(level: level, marker: "•", text: text)
        }

        if first.isNumber {
            var digits = ""
            var rest = body[...]
            while let c = rest.first, c.isNumber, digits.count < 3 {
                digits.append(c)
                rest = rest.dropFirst()
            }
            guard let sep = rest.first, sep == "." || sep == ")" || sep == "、", rest.count > 1 else { return nil }
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            let text = after.trimmingCharacters(in: .whitespaces)
            return MDItem(level: level, marker: digits + String(sep), text: text)
        }

        return nil
    }

    /// 合并软换行：中文之间直接相连，英文之间补空格
    static func joinParagraph(_ lines: [String]) -> String {
        var out = ""
        for (n, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if n == 0 {
                out = line
                continue
            }
            if let a = out.last, let b = line.first, isCJK(a), isCJK(b) {
                out += line
            } else if out.hasSuffix("  ") {
                out += "\n" + line
            } else {
                out += " " + line
            }
        }
        return out
    }

    private static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x3000...0x303F).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

// MARK: - 行内样式

private struct InlineStyle {
    var size: CGFloat
    var color: Color
    var bold: Bool = false
    var italic: Bool = false
}

private enum Inline {
    static func render(_ text: String, _ style: InlineStyle, codeColor: Color, codeFill: Color) -> AttributedString {
        parse(text, style, codeColor: codeColor, codeFill: codeFill)
    }

    private static func attrs(_ style: InlineStyle, code: Bool, codeColor: Color, codeFill: Color) -> AttributeContainer {
        var c = AttributeContainer()
        var font = Font.system(size: style.size,
                               weight: style.bold ? .semibold : .regular,
                               design: code ? .monospaced : .default)
        if style.italic { font = font.italic() }
        c.font = font
        c.foregroundColor = code ? codeColor : style.color
        if code {
            c.backgroundColor = codeFill
        }
        return c
    }

    private static func parse(_ text: String, _ style: InlineStyle, codeColor: Color, codeFill: Color) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var i = text.startIndex

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(AttributedString(buffer, attributes: attrs(style, code: false, codeColor: codeColor, codeFill: codeFill)))
            buffer = ""
        }

        while i < text.endIndex {
            let rest = text[i...]

            // 行内代码
            if rest.hasPrefix("`") {
                let start = text.index(after: i)
                if let close = text.range(of: "`", range: start..<text.endIndex) {
                    flush()
                    let inner = String(text[start..<close.lowerBound])
                    out.append(AttributedString(inner, attributes: attrs(style, code: true, codeColor: codeColor, codeFill: codeFill)))
                    i = close.upperBound
                    continue
                }
            }

            // 粗体
            if rest.hasPrefix("**") || rest.hasPrefix("__") {
                let delim = rest.hasPrefix("**") ? "**" : "__"
                let start = text.index(i, offsetBy: 2)
                if let close = findClose(text, from: start, delim: delim) {
                    flush()
                    var s = style
                    s.bold = true
                    out.append(parse(String(text[start..<close]), s, codeColor: codeColor, codeFill: codeFill))
                    i = text.index(close, offsetBy: 2)
                    continue
                }
            }

            // 删除线
            if rest.hasPrefix("~~") {
                let start = text.index(i, offsetBy: 2)
                if let close = findClose(text, from: start, delim: "~~") {
                    flush()
                    var c = attrs(style, code: false, codeColor: codeColor, codeFill: codeFill)
                    c.strikethroughStyle = .single
                    out.append(AttributedString(String(text[start..<close]), attributes: c))
                    i = text.index(close, offsetBy: 2)
                    continue
                }
            }

            // 斜体
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                let ch = rest.first!
                let start = text.index(after: i)
                if let close = findClose(text, from: start, delim: String(ch), allowSpaceAfterOpen: false) {
                    flush()
                    var s = style
                    s.italic = true
                    out.append(parse(String(text[start..<close]), s, codeColor: codeColor, codeFill: codeFill))
                    i = text.index(after: close)
                    continue
                }
            }

            // 链接 / 图片
            if rest.hasPrefix("["), let labelEnd = text.range(of: "]", range: text.index(after: i)..<text.endIndex),
               labelEnd.upperBound < text.endIndex, text[labelEnd.upperBound] == "(",
               let urlEnd = text.range(of: ")", range: text.index(after: labelEnd.upperBound)..<text.endIndex) {
                flush()
                let label = String(text[text.index(after: i)..<labelEnd.lowerBound])
                let urlText = String(text[text.index(after: labelEnd.upperBound)..<urlEnd.lowerBound])
                var c = attrs(style, code: false, codeColor: codeColor, codeFill: codeFill)
                c.underlineStyle = .single
                if let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) {
                    c.link = url
                }
                let shown = label.isEmpty ? urlText : label
                out.append(AttributedString(shown, attributes: c))
                i = urlEnd.upperBound
                continue
            }

            buffer.append(text[i])
            i = text.index(after: i)
        }

        flush()
        return out
    }

    private static func findClose(_ text: String,
                                  from start: String.Index,
                                  delim: String,
                                  allowSpaceAfterOpen: Bool = true) -> String.Index? {
        guard start < text.endIndex else { return nil }
        if !allowSpaceAfterOpen, text[start] == " " { return nil }
        var searchRange = start..<text.endIndex
        while let r = text.range(of: delim, range: searchRange) {
            // 闭标记前不能是空白
            let before = text.index(before: r.lowerBound)
            if before >= start, text[before] != " " {
                return r.lowerBound
            }
            searchRange = r.upperBound..<text.endIndex
            if searchRange.isEmpty { break }
        }
        return nil
    }
}

// MARK: - 渲染

struct MarkdownView: View {
    let source: String
    var baseSize: CGFloat = 13.5
    var textColor: Color = .primary
    var accentText: Bool = false
    /// true = 铺满可用宽度；false = 贴合内容宽度（气泡短消息用）
    var fillsWidth: Bool = true

    private var blockSpacing: CGFloat { baseSize * 0.62 }

    var body: some View {
        let blocks = MarkdownParser.parse(source)
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
    }

    // MARK: 配色

    private var codeFill: Color {
        accentText ? Color.white.opacity(0.18) : Color.black.opacity(0.055)
    }

    private var codeText: Color {
        accentText ? Color.white.opacity(0.95) : textColor
    }

    private var blockFill: Color {
        accentText ? Color.white.opacity(0.12) : Color.black.opacity(0.04)
    }

    private var borderColor: Color {
        accentText ? Color.white.opacity(0.22) : Color.black.opacity(0.09)
    }

    private var mutedText: Color {
        accentText ? Color.white.opacity(0.75) : textColor.opacity(0.62)
    }

    private func style(size: CGFloat, bold: Bool = false, italic: Bool = false) -> InlineStyle {
        InlineStyle(size: size, color: textColor, bold: bold, italic: italic)
    }

    private func inline(_ text: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> AttributedString {
        Inline.render(text, style(size: size, bold: bold, italic: italic), codeColor: codeText, codeFill: codeFill)
    }

    // MARK: 块视图

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let scale: CGFloat = [1.5, 1.32, 1.18, 1.08, 1.02, 1.0][min(level - 1, 5)]
            Text(inline(text, size: baseSize * scale, bold: true))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 3 : 1)

        case .paragraph(let text):
            Text(inline(text, size: baseSize))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .code(let lang, let code):
            if lang.lowercased() == "svg", code.lowercased().contains("<svg") {
                SVGView(source: code)
            } else {
                codeBlock(lang: lang, code: code)
            }

        case .bullets(let items):
            VStack(alignment: .leading, spacing: baseSize * 0.34) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.level == 0 ? "•" : "◦")
                            .font(.system(size: baseSize * 0.95, weight: .bold))
                            .foregroundStyle(textColor.opacity(0.55))
                        Text(inline(item.text, size: baseSize))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 15)
                }
            }

        case .ordered(let items):
            VStack(alignment: .leading, spacing: baseSize * 0.34) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: baseSize, weight: .medium, design: .rounded))
                            .foregroundStyle(textColor.opacity(0.55))
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inline(item.text, size: baseSize))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(item.level) * 15)
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(textColor.opacity(0.22))
                    .frame(width: 2.5)
                Text(inline(text, size: baseSize))
                    .lineSpacing(4)
                    .foregroundStyle(mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let headers, let rows):
            table(headers: headers, rows: rows)

        case .math(let latex, let display):
            MathBlock(latex: latex, display: display)
                .frame(maxWidth: .infinity, alignment: display ? .center : .leading)

        case .rule:
            Rectangle()
                .fill(textColor.opacity(0.13))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func codeBlock(lang: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(lang.isEmpty ? "代码" : lang.lowercased())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(mutedText)
                Spacer(minLength: 4)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5))
                        .foregroundStyle(mutedText)
                }
                .buttonStyle(.plain)
                .help("复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.top, 7)
            .padding(.bottom, 5)

            Text(code.isEmpty ? " " : code)
                .font(.system(size: baseSize * 0.86, design: .monospaced))
                .foregroundStyle(codeText)
                .textSelection(.enabled)
                .lineSpacing(2)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(blockFill))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 0.8))
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<cols, id: \.self) { c in
                    cell(c < headers.count ? headers[c] : "", header: true)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<cols, id: \.self) { c in
                        cell(c < row.count ? row[c] : "", header: false)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 7).fill(blockFill))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(borderColor, lineWidth: 0.8))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func cell(_ text: String, header: Bool) -> some View {
        Text(inline(text, size: baseSize * 0.92, bold: header))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(header ? textColor.opacity(0.05) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(borderColor).frame(height: 0.5)
            }
    }
}
