import Foundation

/// 一个提示词模板：标题 + 角色提示词（可选带采样参数）。
/// 只写「怎么答」，不碰身份提示词——身份由 ChatStore.identityPrompt 统一负责。
struct PromptTemplate: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var role: String
    var sampling: SamplingParams?
}

/// 模板库。内置 5 个，首次运行写一份 prompts.json 到 Application Support，
/// 之后用户改文件就能改模板（不提供界面编辑，避免和「每对话角色」混淆）。
enum PromptLibrary {
    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalModel/prompts.json")
    }

    static let builtins: [PromptTemplate] = [
        PromptTemplate(id: "translate", title: "翻译",
                       role: "你是翻译。把用户给你的内容翻译成目标语言（用户没指定时中英互译）。"
                           + "只输出译文，不要解释、不要加前言。保留原文的段落、列表和代码块，术语以领域习惯为准。",
                       sampling: SamplingParams(temperature: 0.3, topP: 0.9, topK: 20,
                                                repeatPenalty: 1.05, maxTokens: -1, seed: -1)),
        PromptTemplate(id: "summary", title: "摘要",
                       role: "你是编辑。把用户给的材料压成要点：先用一句话说结论，再列 3 到 7 条要点，"
                           + "每条不超过一行。只写材料里有的东西，不要补充推测。",
                       sampling: SamplingParams(temperature: 0.4, topP: 0.9, topK: 30,
                                                repeatPenalty: 1.05, maxTokens: -1, seed: -1)),
        PromptTemplate(id: "codereview", title: "代码审阅",
                       role: "你是资深工程师，负责代码审阅。按「正确性 → 边界条件 → 性能 → 可读性」的顺序找问题，"
                           + "每条都要指出具体位置（函数名或代码片段）、说明为什么是问题、给出改法。"
                           + "没把握的地方直说没把握，不要为了凑数编问题。",
                       sampling: nil),
        PromptTemplate(id: "polish", title: "润色",
                       role: "你是中文编辑。在不改变原意和事实的前提下润色用户的文字：删冗余、调语序、统一术语。"
                           + "先给润色后的完整文本，再用一小段说明主要改了什么。",
                       sampling: SamplingParams(temperature: 0.6, topP: 0.9, topK: 40,
                                                repeatPenalty: 1.05, maxTokens: -1, seed: -1)),
        PromptTemplate(id: "weekly", title: "周报",
                       role: "你是助理，把用户这一周的零散记录整理成周报，按「本周完成 / 进行中 / 风险与阻塞 / 下周计划」四段写。"
                           + "用短句，不编造没提到的事项；信息不足的地方写成「待补充」。",
                       sampling: SamplingParams(temperature: 0.5, topP: 0.9, topK: 40,
                                                repeatPenalty: 1.05, maxTokens: -1, seed: -1))
    ]

    /// 读模板：文件存在就用文件（用户可能自己加了模板），否则用内置并落盘一份
    static func load() -> [PromptTemplate] {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([PromptTemplate].self, from: data),
           !list.isEmpty {
            return list
        }
        try? fm.createDirectory(at: storeURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(builtins) {
            try? data.write(to: storeURL, options: .atomic)
        }
        return builtins
    }
}
