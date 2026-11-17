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

    init(id: UUID = UUID(),
         title: String = "新对话",
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         archived: Bool = false,
         messages: [ChatMessage] = [],
         groupID: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.messages = messages
        self.groupID = groupID
    }

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
