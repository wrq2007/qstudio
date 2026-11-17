import AppKit
import UniformTypeIdentifiers

/// 对话导出。两种格式：
/// - Markdown：给人看的，带角色提示词与每轮指标
/// - JSON：给程序读的，含角色提示词、采样参数，不含身份提示词（那是产品设定，不属于对话内容）
enum SessionExporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown, json
        var id: String { rawValue }
        var label: String { self == .markdown ? "Markdown (.md)" : "JSON (.json)" }
        var ext: String { self == .markdown ? "md" : "json" }
    }

    // MARK: - 生成内容

    static func markdown(_ s: ChatSession) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# \(s.displayTitle)\n\n"
        out += "- 创建时间：\(df.string(from: s.createdAt))\n"
        out += "- 最后更新：\(df.string(from: s.updatedAt))\n"
        out += "- 消息数：\(s.messages.count)\n"
        let role = (s.rolePrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty {
            out += "- 角色提示词：\n\n  > " + role.replacingOccurrences(of: "\n", with: "\n  > ") + "\n"
        }
        out += "\n---\n\n"
        for m in s.messages where !m.isChoice {
            if m.isSummaryBubble {
                out += "## 上下文摘要"
                if let n = m.summaryCount, n > 0 { out += "（顶替 \(n) 条消息）" }
                out += "\n\n> 以下为此前对话的压缩摘要，原文已移除。\n\n"
                out += m.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
                continue
            }
            let who = m.role == .user ? "用户" : "助手"
            out += "## \(who)\n\n"
            if !m.reasoning.isEmpty {
                out += "<details><summary>思考过程</summary>\n\n"
                    + m.reasoning + "\n\n</details>\n\n"
            }
            out += m.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            if m.role == .assistant, m.tps > 0 || m.promptTokens > 0 {
                var parts: [String] = []
                if m.tps > 0 { parts.append(String(format: "%.1f tok/s", m.tps)) }
                if m.promptTokens > 0 || m.generatedTokens > 0 {
                    parts.append("\(m.promptTokens)→\(m.generatedTokens) tok")
                }
                out += "<!-- " + parts.joined(separator: " · ") + " -->\n\n"
            }
        }
        return out
    }

    /// 程序可读的导出：含采样参数与角色提示词，不含身份提示词
    static func jsonData(_ s: ChatSession, modelName: String) -> Data? {
        var root: [String: Any] = [
            "title": s.title,
            "createdAt": ISO8601DateFormatter().string(from: s.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: s.updatedAt),
            "model": modelName,
            "rolePrompt": s.rolePrompt ?? "",
            "sampling": [
                "temperature": s.samplingParams.temperature,
                "topP": s.samplingParams.topP,
                "topK": s.samplingParams.topK,
                "repeatPenalty": s.samplingParams.repeatPenalty,
                "maxTokens": s.samplingParams.maxTokens,
                "seed": s.samplingParams.seed
            ],
            "messages": s.messages.filter { !$0.isChoice }.map { m -> [String: Any] in
                var d: [String: Any] = [
                    "role": m.role == .user ? "user" : "assistant",
                    "text": m.text
                ]
                if !m.reasoning.isEmpty { d["reasoning"] = m.reasoning }
                if m.isSummaryBubble {
                    d["isSummary"] = true
                    d["summaryCount"] = m.summaryCount ?? 0
                }
                if m.promptTokens > 0 { d["promptTokens"] = m.promptTokens }
                if m.generatedTokens > 0 { d["generatedTokens"] = m.generatedTokens }
                if m.tps > 0 { d["tps"] = m.tps }
                return d
            }
        ]
        root["app"] = "Q Studio"
        return try? JSONSerialization.data(withJSONObject: root,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - 存盘

    /// 建议文件名：标题-YYYYMMDD-HHMM.md，去掉路径/冒号等非法字符
    static func suggestedName(_ s: ChatSession, format: Format) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var base = s.displayTitle.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "对话" }
        if base.count > 40 { base = String(base.prefix(40)) }
        return "\(base)-\(df.string(from: s.updatedAt)).\(format.ext)"
    }

    /// 同名不覆盖：追加 -2、-3…
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while true {
            url = dir.appendingPathComponent("\(base)-\(i).\(ext)")
            if !fm.fileExists(atPath: url.path) { return url }
            i += 1
        }
    }

    /// 弹保存面板并写盘。导出成功返回写入的地址。
    @MainActor
    static func save(_ s: ChatSession, format: Format, modelName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName(s, format: format)
        panel.canCreateDirectories = true
        if format == .markdown { panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText] }
        else { panel.allowedContentTypes = [.json] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data: Data?
        switch format {
        case .markdown: data = markdown(s).data(using: .utf8)
        case .json:     data = jsonData(s, modelName: modelName)
        }
        guard let data else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}
