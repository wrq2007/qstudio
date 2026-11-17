import Foundation

/// 一条消息带上来的附件。本地模型吃不了文件，能做的只有"把正文抽成文本塞进上下文"。
/// 文本存进会话文件，重开 app 还能看见当时发了什么。
struct MessageAttachment: Identifiable, Equatable, Codable {
    var id: UUID
    var name: String
    /// 抽取出来的正文（可能已被截断）
    var text: String
    /// 原文总字符数（截断前）
    var originalChars: Int
    /// 因为超预算被截断了
    var truncated: Bool

    init(id: UUID = UUID(), name: String, text: String, originalChars: Int, truncated: Bool) {
        self.id = id
        self.name = name
        self.text = text
        self.originalChars = originalChars
        self.truncated = truncated
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable, Equatable { case user, assistant }

    var id: UUID
    var role: Role
    var text: String
    var reasoning: String
    var tps: Double
    var failed: Bool
    /// 这条是模型抛回来的「候选方向」请求，对话区不显示，只出现在输入栏上方的模块里
    var isChoice: Bool

    /// /compact 生成的摘要气泡：它顶替了前面若干条原文，对话区单独渲染成一张卡片。
    /// 用可选类型：旧数据没有这个字段，解码时不会因为缺 key 失败。
    var isSummary: Bool?
    /// 这张摘要顶替了多少条消息（只用于显示）
    var summaryCount: Int?

    /// 这条消息带的附件（文本/PDF 抽出来的正文）
    var attachments: [MessageAttachment]?

    // 推理指标（每条消息独立，避免串台）
    var promptTokens: Int = 0       // 输入 token 数
    var generatedTokens: Int = 0    // 输出 token 数
    var promptTPS: Double = 0       // prompt 处理速率 tok/s
    var promptMS: Double = 0        // prefill 耗时 ms
    var perTokenMS: Double = 0      // 平均每 token 耗时 ms

    init(id: UUID = UUID(),
         role: Role,
         text: String = "",
         reasoning: String = "",
         tps: Double = 0,
         failed: Bool = false,
         isChoice: Bool = false,
         isSummary: Bool? = nil,
         summaryCount: Int? = nil,
         attachments: [MessageAttachment]? = nil,
         promptTokens: Int = 0,
         generatedTokens: Int = 0,
         promptTPS: Double = 0,
         promptMS: Double = 0,
         perTokenMS: Double = 0) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.tps = tps
        self.failed = failed
        self.isChoice = isChoice
        self.isSummary = isSummary
        self.summaryCount = summaryCount
        self.attachments = attachments
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.promptTPS = promptTPS
        self.promptMS = promptMS
        self.perTokenMS = perTokenMS
    }

    /// 摘要卡片的判定（可选字段的方便写法）
    var isSummaryBubble: Bool { isSummary == true }

    var hasAttachments: Bool { !(attachments ?? []).isEmpty }

    /// 附件正文 + 用户问题（纯文本，不加任何指令）。
    /// 压缩摘要、token 估算、导出都用这个，别在里面塞 prompt。
    var fullContent: String {
        var parts: [String] = []
        for a in attachments ?? [] {
            parts.append("【附件：\(a.name)\(a.truncated ? "（已截断）" : "")】\n" + a.text)
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { parts.append(t) }
        return parts.joined(separator: "\n\n")
    }

    /// 真正发请求时用的正文。有附件才把「只依据资料回答」和资料**物理绑在一起**。
    ///
    /// 为什么不把这句写进 system：实测 4B 读不懂「当用户提供了资料时」这种条件从句，
    /// 会把「资料中没有提到这一点」当成默认回答，连写代码、算加法都被拒。绑在资料块旁边，
    /// 没有资料时这句根本不出现，就不会污染正常问答。
    var promptContent: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAttachments else { return t }

        var blocks: [String] = []
        for a in attachments ?? [] {
            blocks.append("【附件：\(a.name)\(a.truncated ? "（已截断）" : "")】\n" + a.text)
        }
        var out = "<资料>\n" + blocks.joined(separator: "\n\n") + "\n</资料>\n\n"
        out += "以上是用户提供的资料。只依据资料原文回答：资料里没有答案时，"
        out += "只回复「资料中没有提到这一点」，不要补充推测。"
        if !t.isEmpty { out += "\n\n" + t }
        return out
    }
}

/// 一段对话用的采样参数。三档预设是给普通用户的，高级面板留给想细调的人。
struct SamplingParams: Codable, Equatable {
    var temperature: Double = 0.7
    var topP: Double = 0.9
    var topK: Int = 40
    var repeatPenalty: Double = 1.05
    /// -1 = 不限制（一直生成到模型自己停）
    var maxTokens: Int = -1
    /// -1 = 每次随机（llama.cpp 的约定）
    var seed: Int = -1
    /// 最小概率采样：低于 (最高概率 × minP) 的 token 直接丢掉。
    /// 小模型编造专名、数字大多出自长尾 token，这一刀比调 top_p 准。
    var minP: Double = 0.05

    init(temperature: Double = 0.7, topP: Double = 0.9, topK: Int = 40,
         repeatPenalty: Double = 1.05, maxTokens: Int = -1, seed: Int = -1,
         minP: Double = 0.05) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.repeatPenalty = repeatPenalty
        self.maxTokens = maxTokens
        self.seed = seed
        self.minP = minP
    }

    /// 自定义解码只为一件事：1.1.2 之前的会话文件里没有 minP 这个 key，
    /// 合成解码器遇到缺 key 会整份抛错，用户的对话就没了。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SamplingParams()
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? d.temperature
        topP = try c.decodeIfPresent(Double.self, forKey: .topP) ?? d.topP
        topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK
        repeatPenalty = try c.decodeIfPresent(Double.self, forKey: .repeatPenalty) ?? d.repeatPenalty
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens) ?? d.maxTokens
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? d.seed
        minP = try c.decodeIfPresent(Double.self, forKey: .minP) ?? d.minP
    }

    enum Preset: String, CaseIterable, Identifiable {
        case precise, balanced, creative

        var id: String { rawValue }
        var label: String {
            switch self {
            case .precise: return L("精确")
            case .balanced: return L("平衡")
            case .creative: return L("发散")
            }
        }

        var params: SamplingParams {
            // 三档的 minP 都是 0.05：阈值取的是「相对最高概率的 5%」，很温和，
            // 正常创作不受影响，但能把小模型编专名、编数字时最爱走的极端长尾掐掉。
            // 旧会话文件里没有 minP，解码时补的也是 0.05，预设高亮不会因此错位。
            switch self {
            case .precise:
                return SamplingParams(temperature: 0.3, topP: 0.85, topK: 20, repeatPenalty: 1.08,
                                      maxTokens: -1, seed: -1, minP: 0.05)
            case .balanced:
                return SamplingParams(temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.05,
                                      maxTokens: -1, seed: -1, minP: 0.05)
            case .creative:
                return SamplingParams(temperature: 1.0, topP: 0.95, topK: 60, repeatPenalty: 1.0,
                                      maxTokens: -1, seed: -1, minP: 0.05)
            }
        }
    }

    /// 和哪一档完全一致（用于高亮）；都不一致时按最接近的算
    var preset: Preset? {
        for p in Preset.allCases where p.params == self { return p }
        return nil
    }

    /// 一句话描述，显示在工具条上
    var summary: String {
        if let p = preset { return p.label }
        return String(format: "T%.2f", temperature)
    }
}

/// 工作组（对话分组/文件夹）。一个对话只属于一个组。
struct WorkGroup: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date
    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// 一段对话。归档只是加个标记，消息本体照常保存。
struct ChatSession: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool
    var messages: [ChatMessage]
    /// 所属工作组；nil = 未分组。旧数据没有这个字段，解码时为 nil。
    var groupID: UUID?

    /// 这段对话的采样参数。旧数据没有这个字段，解码为 nil，按模板默认值处理。
    var sampling: SamplingParams?

    /// 这段对话自己的角色提示词（怎么答）。
    /// 旧数据没有这个字段，解码为 nil，加载时用当时的全局指令快照补齐——
    /// 不能留空，否则老对话的行为会突然变。
    var rolePrompt: String?

    init(id: UUID = UUID(),
         title: String = "新对话",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         archived: Bool = false,
         messages: [ChatMessage] = [],
         groupID: UUID? = nil,
         rolePrompt: String? = nil,
         sampling: SamplingParams? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.messages = messages
        self.groupID = groupID
        self.rolePrompt = rolePrompt
        self.sampling = sampling
    }

    /// 取生效的采样参数：没设过就用平衡档
    var samplingParams: SamplingParams { sampling ?? SamplingParams.Preset.balanced.params }

    /// 标题的显示形态：默认占位标题「新对话」跟随界面语言，其余是用户/模型生成的原文。
    /// 存储里始终保留中文占位值，标题生成的判断逻辑（title == "新对话"）才不会被语言影响。
    var displayTitle: String { title == "新对话" ? L("新对话") : title }

    /// 用第一条用户消息当标题
    mutating func refreshTitle() {
        guard let first = messages.first(where: { $0.role == .user && !$0.text.isEmpty }) else { return }
        let trimmed = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        title = trimmed.count > 20 ? String(trimmed.prefix(20)) + "…" : trimmed
    }

    var lastMessagePreview: String {
        for m in messages.reversed() where !m.text.isEmpty {
            let t = m.text.replacingOccurrences(of: "\n", with: " ")
            return t.count > 40 ? String(t.prefix(40)) + "…" : t
        }
        return "还没有内容"
    }
}
