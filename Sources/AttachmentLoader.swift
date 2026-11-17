import Foundation
import UniformTypeIdentifiers

/// 把本地文件读成纯文本，塞进上下文。
///
/// 只做文本：当前推理服务没挂视觉投影（mmproj），PDF/图片都进不了模型。
/// 能读的是一堆"其实是文本"的扩展名 —— 代码、Markdown、CSV、JSON 之类。
enum AttachmentLoader {

    /// 单个文件上限。再大读进来也是撑爆上下文，不如直接拒绝
    static let maxBytes = 8 * 1024 * 1024

    /// 面板里允许选的扩展名（实际选文件时还开了"其他类型"，靠内容判断兜底）
    static let extensions: [String] = [
        // 纯文本 / 文档
        "txt", "text", "log", "md", "markdown", "mdx", "rst", "adoc", "org", "tex", "bib",
        // 结构化数据 / 配置
        "csv", "tsv", "json", "jsonl", "ndjson", "yaml", "yml", "toml", "ini", "cfg",
        "conf", "env", "properties", "xml", "plist", "sql",
        // 网页 / 样式
        "html", "htm", "css", "scss", "sass", "less", "vue", "svelte",
        // 代码
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "java", "kt", "kts",
        "scala", "go", "rs", "rb", "php", "pl", "lua", "r", "py", "pyi", "ipynb",
        "js", "jsx", "ts", "tsx", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "gradle", "cmake", "mk", "dockerfile", "makefile",
        // 字幕 / 邮件
        "srt", "vtt", "ass", "eml"
    ]

    static var allowedContentTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    enum LoadError: Error {
        case tooLarge(Double)
        case notText(String)
        case empty(String)
        case unreadable(String, String)

        var message: String {
            switch self {
            case .tooLarge(let mb):
                return Lf("文件太大（约 %@ MB），单个文件上限 8 MB", String(format: "%.1f", mb))
            case .notText(let name):
                return Lf("%@ 看起来不是文本文件，读不出文字", name)
            case .empty(let name):
                return Lf("%@ 里没有可用的文字", name)
            case .unreadable(let name, let why):
                return Lf("读不了 %@：%@", name, why)
            }
        }
    }

    /// 读一个文件。charLimit 是这条消息里所有附件共享的字符预算。
    static func load(url: URL, charLimit: Int) -> Result<MessageAttachment, LoadError> {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            return .failure(.tooLarge(Double(size) / 1024 / 1024))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadable(name, L("文件读取失败")))
        }
        guard let raw = decode(data) else {
            return .failure(.notText(name))
        }
        // 去掉行尾多余空白，CRLF 统一成 LF：模型对 \r 没好感，也省 token
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.empty(name))
        }
        let (body, truncated) = truncate(text, limit: charLimit)
        return .success(MessageAttachment(name: name,
                                          text: body,
                                          originalChars: text.count,
                                          truncated: truncated))
    }

    /// 先试 UTF-8，再试 GB18030（中文用户的老文件常见），最后按 Latin-1 兜底但要过一遍乱码检查
    static func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // BOM 指明是 UTF-16 的，先认它
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            return String(data: data, encoding: .utf16BigEndian)
        }
        // 有 NUL 字节的基本都是二进制
        if data.contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)), !s.isEmpty {
            return s
        }
        if let s = String(data: data, encoding: .isoLatin1), !looksBinary(s) { return s }
        return nil
    }

    /// Latin-1 什么字节都能解出来，所以要反过来看：控制字符占比高就是二进制
    static func looksBinary(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var weird = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v < 0x09 || (v > 0x0D && v < 0x20) || v == 0x7F { weird += 1 }
        }
        return Double(weird) / Double(s.unicodeScalars.count) > 0.01
    }

    /// 头 75% + 尾 25%：文档的结论常在末尾，只留开头会漏掉最关键的部分
    static func truncate(_ text: String, limit: Int) -> (String, Bool) {
        guard text.count > limit, limit > 200 else { return (text, false) }
        let headCount = Int(Double(limit) * 0.75)
        let tailCount = limit - headCount
        let omitted = text.count - limit
        let head = String(text.prefix(headCount))
        let tail = String(text.suffix(tailCount))
        return (head + Lf("\n\n…（中间省略 %lld 字）…\n\n", omitted) + tail, true)
    }

    /// 这条消息还能塞多少字：跟着上下文长度走，但不能把上下文全吃了
    static func charLimit(contextSize: Int, existing: Int = 0) -> Int {
        let total = max(2000, min(24000, Int(Double(max(contextSize, 2048)) * 0.55)))
        return max(300, total - existing)
    }
}
