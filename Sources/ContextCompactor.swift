import Foundation

/// 斜杠命令。输入框里发出去的第一件事就是解析它——
/// 命令不是"发给模型的一段文字"，不该进对话历史。
enum SlashCommand: Equatable {
    case compact
    case unknown(String)

    /// 命令面板里列出来的条目（详情文案走本地化字典）
    static let catalog: [(usage: String, detail: String)] = [
        ("/compact", "把早前的对话压成摘要，腾出上下文")
    ]

    /// 只认开头是 / 的整条输入；`/` 单独一个字符不算命令（用户可能就想打个斜杠）
    static func parse(_ raw: String) -> SlashCommand? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), !t.contains("\n") else { return nil }
        let name = t.dropFirst().split(separator: " ").first.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }
        switch name.lowercased() {
        case "compact", "压缩": return .compact
        default: return .unknown("/" + name)
        }
    }
}

/// 上下文压缩：把早前的对话交给模型压成一份摘要，再用摘要替换原文。
///
/// 三个约束决定了实现方式：
/// 1. 摘要请求本身也吃上下文 —— 历史太长时必须先截断，否则压缩请求自己就超限；
/// 2. 尾巴要留 —— 最近几轮原文不动，否则模型会忘掉用户刚说的话；
/// 3. 压缩不能失败到卡死对话 —— 模型不在或报错时退到本地抽取式摘要。
enum ContextCompactor {

    /// 摘要指令只发给模型，不进本地化字典（不给用户看）
    static let instruction = """
    你的任务是把下面这段对话压缩成一份可以继续对话的摘要。
    要求：
    1. 保留用户的目标、已确认的事实与数据、做过的决定、尚未完成的事项；
    2. 专有名词、文件名、函数或接口名、数字与单位原样保留，不要改写；
    3. 丢掉寒暄、重复解释、被否决的方案；
    4. 分条陈述，按时间顺序，不要编造原文没有的信息；
    5. 只输出摘要正文，不要写"以下是摘要"这类开场话。
    """

    /// 单条消息在摘要请求里的长度上限，超了保留头尾（结论常在最后）
    private static let perMessageLimit = 1600

    /// 摘要请求能塞多少字符历史。中文约 1 字 ≈ 1 token，留一半给指令和输出。
    static func charBudget(contextSize: Int) -> Int {
        max(1200, min(12000, Int(Double(max(contextSize, 2048)) * 0.55)))
    }

    /// 拼成交给模型的对话记录。超预算时从最早的消息开始丢，
    /// 并把这个事实写进记录——模型才知道"前面还有内容，只是看不到了"。
    static func transcript(_ messages: [ChatMessage], charBudget: Int) -> String {
        var lines: [String] = []
        for m in messages where !m.text.isEmpty && !m.isChoice {
            var body = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > perMessageLimit {
                let head = String(body.prefix(perMessageLimit * 2 / 3))
                let tail = String(body.suffix(perMessageLimit / 3))
                body = head + "\n…（中间省略）…\n" + tail
            }
            let speaker = m.isSummaryBubble ? "早前的摘要："
                                             : (m.role == .user ? "用户：" : "助手：")
            lines.append(speaker + body)
        }

        // 从后往前装，保证离现在最近的内容一定在
        var picked: [String] = []
        var used = 0
        for line in lines.reversed() {
            if used + line.count > charBudget && !picked.isEmpty { break }
            picked.append(line)
            used += line.count + 1
        }
        if picked.count < lines.count {
            picked.append("（更早的 \(lines.count - picked.count) 段内容因长度限制已省略）")
        }
        return picked.reversed().joined(separator: "\n\n")
    }

    struct Summary {
        var text: String
        /// true = 模型写的；false = 本地摘要
        var byModel: Bool
    }

    /// 让模型写摘要。失败/超时/返回空 → nil，交给调用方兜底。
    static func summarize(transcript: String,
                          server: ServerController,
                          session: URLSession) async -> Summary? {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let body: [String: Any] = [
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": transcript]
            ],
            "stream": false,
            "temperature": 0.2,
            "top_p": 0.9,
            "max_tokens": 900
        ]
        do {
            var req = URLRequest(url: server.baseURL.appendingPathComponent("v1/chat/completions"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // 压缩请求是纯 CPU/GPU 计算，慢一点也别超时放弃
            req.timeoutInterval = 240
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { return nil }
            let cleaned = clean(content)
            guard !cleaned.isEmpty else { return nil }
            return Summary(text: cleaned, byModel: true)
        } catch {
            return nil
        }
    }

    /// 去掉模型爱加的开场话和代码围栏
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // ```markdown\n...\n```
            var lines = s.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.removeLast()
            }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefixes = ["摘要：", "摘要:", "对话摘要：", "对话摘要:", "**摘要**", "Summary:", "summary:"]
        for p in prefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// 本地兜底摘要：模型不可用时的抽取式摘要。
    /// 信息密度低，但保证 /compact 一定有个结果，不会把用户卡在"上下文快满了"上。
    static func localDigest(_ messages: [ChatMessage], limit: Int = 1400) -> String {
        var out: [String] = ["（本地摘要：模型摘要失败，以下为各轮要点摘录）"]
        var used = out[0].count
        for m in messages where !m.text.isEmpty && !m.isChoice {
            let firstLine = m.text.split(separator: "\n").first.map(String.init) ?? m.text
            var s = firstLine.trimmingCharacters(in: .whitespaces)
            if s.count > 120 { s = String(s.prefix(120)) + "…" }
            let line = (m.role == .user ? "· 用户：" : "· 助手：") + s
            if used + line.count > limit {
                out.append("· …（其余省略）")
                break
            }
            out.append(line)
            used += line.count + 1
        }
        return out.joined(separator: "\n")
    }
}
