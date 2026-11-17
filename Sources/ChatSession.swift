import Foundation

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
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.promptTPS = promptTPS
        self.promptMS = promptMS
        self.perTokenMS = perTokenMS
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
            switch self {
            case .precise:
                return SamplingParams(temperature: 0.3, topP: 0.85, topK: 20, repeatPenalty: 1.08,
                                      maxTokens: -1, seed: -1)
            case .balanced:
                return SamplingParams(temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.05,
                                      maxTokens: -1, seed: -1)
            case .creative:
                return SamplingParams(temperature: 1.0, topP: 0.95, topK: 60, repeatPenalty: 1.0,
                                      maxTokens: -1, seed: -1)
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
