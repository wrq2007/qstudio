import Foundation

/// MDSAFETYTEST=1：不碰网络、不碰真实会话，只核对两件事——
/// 1) 老会话文件里没有 minP 这个 key，解码不能整份失败；
/// 2) 只有带附件的用户消息才带「只依据资料」那句约束，普通问答一个字都不加。
/// 结果落盘 /tmp/qstudio_safety.txt。
enum SafetySelfTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MDSAFETYTEST"] == "1"
            || UserDefaults.standard.bool(forKey: "MDSAFETYTEST")
    }

    static func schedule() {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { run() }
    }

    static func run() {
        var lines: [String] = ["--- 采样参数兼容 ---"]

        // 1.1.1 写下的会话文件：没有 minP
        let old = #"{"temperature":0.3,"topP":0.85,"topK":20,"repeatPenalty":1.08,"maxTokens":-1,"seed":-1}"#
        if let d = old.data(using: .utf8),
           let p = try? JSONDecoder().decode(SamplingParams.self, from: d) {
            lines.append("旧 JSON：解码成功 温度=\(p.temperature) minP=\(p.minP) 预设=\(p.preset?.rawValue ?? "无匹配")")
        } else {
            lines.append("旧 JSON：解码失败 ← 不能接受")
        }

        // 三档预设本身
        for preset in SamplingParams.Preset.allCases {
            let p = preset.params
            lines.append("预设 \(preset.rawValue)：T\(p.temperature) K\(p.topK) P\(p.topP) minP\(p.minP) 自匹配=\(p.preset == preset)")
        }

        // 新 JSON 往返
        let np = SamplingParams(temperature: 0.7, topP: 0.9, topK: 40, repeatPenalty: 1.05,
                                maxTokens: -1, seed: -1, minP: 0.08)
        if let d = try? JSONEncoder().encode(np),
           let back = try? JSONDecoder().decode(SamplingParams.self, from: d) {
            lines.append("新 JSON 往返：minP=\(back.minP) 完全一致=\(back == np)")
        }

        lines.append("")
        lines.append("--- 资料约束 ---")
        let plain = ChatMessage(role: .user, text: "1 到 100 的整数和是多少？")
        lines.append("无附件：promptContent 与原文相同=\(plain.promptContent == plain.text) 含约束=\(plain.promptContent.contains("资料中没有提到这一点"))")

        let a = MessageAttachment(name: "岩芯记录.md", text: "项目代号：玄武-7。", originalChars: 9, truncated: false)
        let withAtt = ChatMessage(role: .user, text: "这个文件的代号是什么？", attachments: [a])
        let pc = withAtt.promptContent
        lines.append("带附件：含 <资料>=\(pc.contains("<资料>")) 有闭合=\(pc.contains("</资料>"))")
        lines.append("带附件：含约束句=\(pc.contains("资料中没有提到这一点"))")
        lines.append("带附件：问题在最后=\(pc.hasSuffix("这个文件的代号是什么？"))")
        lines.append("带附件：fullContent 未受污染=\(withAtt.fullContent.hasPrefix("【附件："))")

        lines.append("")
        lines.append("--- 实际发出的正文 ---")
        lines.append(pc)

        try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_safety.txt",
                                                 atomically: true, encoding: .utf8)
    }
}
