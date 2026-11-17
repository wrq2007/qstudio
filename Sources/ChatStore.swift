import Foundation
import Combine

/// 模型抛回来的交互问题（WorkBuddy 风格的选项卡片）
struct ChoiceRequest: Equatable {
    var question: String
    var options: [String]
    /// true = 复选框可多选；false = 单选（点了就发）
    var multiSelect: Bool = false

    /// 用户提交时把选中的选项拼成一条消息
    static func answerText(_ selected: [String]) -> String {
        selected.joined(separator: "\n")
    }
}

/// 一条回复的推理指标，流式帧里逐次覆盖，flush 时一次性写进消息
struct PendingMetrics {
    var tps: Double = 0
    var promptTokens: Int = 0
    var generatedTokens: Int = 0
    var promptTPS: Double = 0
    var promptMS: Double = 0
    var perTokenMS: Double = 0
    var hasData: Bool { tps > 0 || promptTokens > 0 || generatedTokens > 0 || promptTPS > 0 }
}

final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var sessions: [ChatSession] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var lastTPS: Double = 0
    @Published private(set) var promptTPS: Double = 0

    /// 最近一次请求的上下文占用情况
    @Published private(set) var promptTokens: Int = 0
    @Published private(set) var generatedTokens: Int = 0

    /// 新对话的默认角色提示词（设置页可改）。只影响之后新建的对话，
    /// 已有对话各自带着自己的 rolePrompt，改这里不会把它改掉。
    @Published var instruction: String

    /// 身份提示词：写死、用户改不了。它说明"你是谁、在什么环境里说话"，
    /// 属于产品设定；而"怎么答"（角色/语气/领域）交给每个对话自己的 rolePrompt。
    static let identityPrompt = """
    你是 Q Studio 里的本地助手，运行在用户自己的电脑上，模型离线推理，无法联网、无法打开链接、无法访问用户的文件系统。
    回答用简体中文（用户用其他语言提问时跟随用户）。不确定的地方直接说明不确定，不要编造事实、链接或数据。
    """

    /// 把身份和角色拼成一条 system 消息。角色为空时只发身份。
    static func composeSystem(identity: String, role: String?) -> String {
        let r = (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? identity : identity + "\n\n" + r
    }

    /// 角色提示词编辑器的目标会话（nil = 没打开）
    @Published var roleEditorSessionID: UUID?

    func openRoleEditor(_ id: UUID?) { roleEditorSessionID = id }

    /// 模型给的候选方向，显示在输入栏上方
    @Published var pendingChoice: ChoiceRequest?

    /// 数据层告警（如会话文件损坏已另存），显示在界面上让用户知情
    @Published private(set) var dataWarning: String?

    func dismissDataWarning() { dataWarning = nil }

    private var task: Task<Void, Never>?
    /// 生成标题用的独立任务（不参与 generation，避免被 stop 误取消主流程）
    private var titleTask: Task<Void, Never>?
    /// 已经自动生成过标题的会话，避免每轮都生成
    private var titledSessions: Set<UUID> = []
    /// 本轮的用户输入，供 finishTurn 后生成标题用
    private var lastUserText: String = ""
    /// 代次计数：每次开始新一轮或 stop 就 +1。
    /// 被取代/被取消的旧任务在收尾时比对，发现代次已变就不再碰共享状态，
    /// 否则旧任务的收尾会把新任务正在写的东西清掉。
    private var generation: Int = 0
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    private var saveWorkItem: DispatchWorkItem?

    /// 工作组（对话分组）。单独存 groups.json，不混进 sessions.json 以免破坏旧数据兼容。
    @Published var groups: [WorkGroup] = []
    /// 侧栏当前选中的组；nil = 全部对话。放在这里让新建对话能自动归入选中的组。
    @Published var selectedGroupID: UUID?
    /// true = 侧栏只看未分组对话
    @Published var showUngroupedOnly = false

    /// 强制模型提问用的工具定义
    private static let askUserTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "ask_user",
            "description": "向用户提问，以获取继续回答所必需的信息",
            "parameters": [
                "type": "object",
                "properties": [
                    "question": ["type": "string", "description": "要问用户的问题"]
                ],
                "required": ["question"]
            ]
        ]
    ]

    private init() {
        instruction = UserDefaults.standard.string(forKey: "systemInstruction") ?? ""
        load()
        // 启动后当前对话必须是一个未归档的活跃对话：
        // 侧栏只列未归档项，若 currentID 指向归档会话，就会出现「对话区有内容、侧栏却空」的错乱。
        let currentIsActive = current.flatMap { !$0.archived } ?? false
        if !currentIsActive {
            if let active = sessions.filter({ !$0.archived })
                                .sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                currentID = active.id          // 落到最近活跃的对话
            } else {
                newSession(select: true)       // 一个活跃对话都没有 → 新建
            }
        }
    }

    func saveInstruction() {
        UserDefaults.standard.set(instruction, forKey: "systemInstruction")
    }

    /// 写某段对话自己的角色提示词（从角色编辑器保存时调用）
    func setRolePrompt(_ text: String, for id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].rolePrompt = text
        scheduleSave()
    }

    /// MDRPTEST=1：把身份/角色拆分的结果落盘，核对迁移与合成后的 system 文案
    func dumpRoleTestIfNeeded() {
        guard ProcessInfo.processInfo.environment["MDRPTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDRPTEST") else { return }
        var lines: [String] = []
        lines.append("默认角色（新对话用）：\(instruction.isEmpty ? "<空>" : instruction)")
        for s in sessions {
            let role = s.rolePrompt.map { $0.isEmpty ? "<空>" : $0 } ?? "<nil 未迁移>"
            lines.append("会话：\(s.title) | 角色：\(role)")
        }
        lines.append("--- 合成后的 system（当前会话）---")
        lines.append(Self.composeSystem(identity: Self.identityPrompt, role: current?.rolePrompt))
        // 顺手验证 GGUF 里的采样推荐值解析（配合 /tmp/fake_sampling.gguf）
        if let info = GGUFInspector.read(at: URL(fileURLWithPath: "/tmp/fake_sampling.gguf")) {
            let sp = info.sampling
            lines.append("fake gguf: arch=\(info.architecture) layers=\(info.blockCount) kvHeads=\(info.headCountKV) "
                         + "ctx=\(info.trainedContext) sampling=\(sp.map { "T\($0.temperature)/K\($0.topK)/P\($0.topP)/R\($0.repeatPenalty)" } ?? "nil")")
        } else {
            lines.append("fake gguf: 解析失败")
        }
        try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_role.txt",
                                                 atomically: true, encoding: .utf8)
    }

    /// 改某段对话的采样参数
    func setSampling(_ p: SamplingParams, for id: UUID?) {
        guard let id, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].sampling = p
        scheduleSave()
    }

    func sampling(for id: UUID?) -> SamplingParams {
        guard let id, let s = sessions.first(where: { $0.id == id }) else {
            return SamplingParams.Preset.balanced.params
        }
        return s.samplingParams
    }

    func rolePrompt(for id: UUID) -> String {
        sessions.first(where: { $0.id == id })?.rolePrompt ?? ""
    }

    // MARK: - 当前会话

    var current: ChatSession? {
        guard let id = currentID else { return nil }
        return sessions.first { $0.id == id }
    }

    var messages: [ChatMessage] {
        current?.messages ?? []
    }

    /// 当前会话占掉的上下文 token 数（提示 + 本轮生成）
    var contextUsed: Int {
        promptTokens + generatedTokens
    }

    /// 服务端没回 usage 时的兜底：把这一轮真正发出去的提示拼起来，走 /tokenize 数一遍。
    /// 只在这轮结束时调用，不阻塞流式过程。
    func refreshTokenUsageFallback(server: ServerController) {
        guard promptTokens == 0, let cur = current else { return }
        let prompt = ([Self.composeSystem(identity: Self.identityPrompt, role: cur.rolePrompt)]
                      + cur.messages.filter { !$0.text.isEmpty }.map { $0.text })
            .joined(separator: "\n")
        guard !prompt.isEmpty else { return }
        var req = URLRequest(url: server.baseURL.appendingPathComponent("tokenize"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": prompt])
        session.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let toks = obj["tokens"] as? [Any], !toks.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.promptTokens == 0 else { return }
                self.promptTokens = toks.count
            }
        }.resume()
    }

    private func indexOfCurrent() -> Int? {
        guard let id = currentID else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    /// 改当前会话的内容
    private func mutateCurrent(_ body: (inout ChatSession) -> Void) {
        guard let idx = indexOfCurrent() else { return }
        body(&sessions[idx])
        sessions[idx].updatedAt = Date()
        scheduleSave()
    }

    // MARK: - 会话操作

    /// 当前已经在一条空的新对话上时，不再允许再新建
    /// （不然会攒出一串空会话，还分不清哪条是哪条）
    var canCreateNewSession: Bool {
        guard let cur = current else { return true }
        return !cur.messages.isEmpty
    }

    @discardableResult
    func newSession(select: Bool = true) -> UUID {
        stop()
        // 侧栏选中了某个组时，新对话直接归进去——这样用户先选组再提问，回答完就在该组里
        let group = showUngroupedOnly ? nil : selectedGroupID
        let s = ChatSession(groupID: group,
                           rolePrompt: instruction,
                           sampling: ServerController.shared.modelInfo?.sampling
                                     ?? SamplingParams.Preset.balanced.params)
        sessions.insert(s, at: 0)
        if select {
            currentID = s.id
        }
        promptTokens = 0
        generatedTokens = 0
        lastTPS = 0
        promptTPS = 0
        scheduleSave()
        return s.id
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        if isStreaming { stop() }
        currentID = id
        promptTokens = 0
        generatedTokens = 0
    }

    // MARK: - 工作组

    @discardableResult
    func createGroup(name: String) -> UUID {
        let g = WorkGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        groups.append(g)
        scheduleSave()
        return g.id
    }

    func renameGroup(_ id: UUID, name: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        groups[idx].name = n
        scheduleSave()
    }

    /// 删除工作组，组内的对话变成未分组（不删对话）
    func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in sessions.indices where sessions[i].groupID == id {
            sessions[i].groupID = nil
        }
        scheduleSave()
    }

    /// 把对话加入某组；groupID 传 nil = 移出工作组
    func assign(_ sessionID: UUID, to groupID: UUID?) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].groupID = groupID
        scheduleSave()
    }

    func groupName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return groups.first { $0.id == id }?.name
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].archived = archived
        sessions[idx].updatedAt = Date()

        // 归档当前正在用的对话后，它就处于不活跃状态——自动新建一条空对话接手，
        // 避免继续在归档区里发言。新建的对话自然是未归档的。
        if archived && currentID == id {
            newSession(select: true)
        }
        scheduleSave()
    }

    func toggleArchive(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        setArchived(id, !sessions[idx].archived)
    }

    func delete(_ id: UUID) {
        if isStreaming, currentID == id { stop() }
        sessions.removeAll { $0.id == id }
        if currentID == id {
            currentID = sessions.first?.id
        }
        scheduleSave()
    }

    func deleteAllArchived() {
        if isStreaming, let cur = current, cur.archived { stop() }
        sessions.removeAll { $0.archived }
        if let cur = current, cur.archived {
            currentID = sessions.first?.id
        }
        scheduleSave()
    }

    /// 兼容旧调用
    func clear() {
        newSession()
    }

    /// 往当前会话追加一条消息（自检和外部导入用）
    func appendMessage(_ message: ChatMessage) {
        mutateCurrent { s in
            s.messages.append(message)
            s.refreshTitle()
        }
    }

    /// 自检用：造几条历史记录，看看左栏排版
    func seedDemoSessions() {
        let demos: [(String, String, TimeInterval)] = [
            ("玄武岩和花岗岩的成因差异", "玄武岩是喷出岩，花岗岩是深成岩。", 300),
            ("写一个 Python 快速排序", "def qsort(a): ...", 7200),
            ("板块构造理论简述", "岩石圈被分割成若干刚性板块。", 86400),
            ("分析一份野外地质报告", "报告里给出的年龄数据需要重新校准。", 172800)
        ]
        for (title, reply, ago) in demos {
            var s = ChatSession(title: title)
            s.messages = [ChatMessage(role: .user, text: title),
                          ChatMessage(role: .assistant, text: reply)]
            s.createdAt = Date().addingTimeInterval(-ago)
            s.updatedAt = Date().addingTimeInterval(-ago)
            s.archived = title.hasPrefix("分析")
            sessions.append(s)
        }
        scheduleSave()
    }

    // MARK: - 持久化

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalModel/sessions.json")
    }

    private var groupsURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("groups.json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL) else {
            dataWarning = "读不到对话文件，已另存原件。本次是空对话。"
            quarantineCorruptStore(data: nil)
            return
        }
        // 工作组单独读，读不到就当空组，不影响会话加载
        if let gdata = try? Data(contentsOf: groupsURL),
           let glist = try? JSONDecoder().decode([WorkGroup].self, from: gdata) {
            groups = glist
        }
        do {
            var list = try JSONDecoder().decode([ChatSession].self, from: data)
            // 旧数据没有 rolePrompt：用当时的全局指令补一份快照，行为保持不变；
            // 补过之后再新建的对话都自带 rolePrompt（哪怕是空串），不会被误判成旧数据。
            var migrated = 0
            for i in list.indices where list[i].rolePrompt == nil {
                list[i].rolePrompt = instruction
                migrated += 1
            }
            sessions = list
            currentID = list.first?.id
            if migrated > 0 { scheduleSave() }
        } catch {
            // 防呆：解码失败不静默清空——先把损坏原件隔离保存，用户有机会找回来
            quarantineCorruptStore(data: data)
            dataWarning = "对话文件损坏，原件已另存为 sessions.corrupt.json，本次从空对话开始。"
        }
    }

    /// 把读不懂/读不到的原件另存，避免下次启动又被覆盖掉
    private func quarantineCorruptStore(data: Data?) {
        let corrupt = storeURL.deletingLastPathComponent()
            .appendingPathComponent("sessions.corrupt.json")
        let fm = FileManager.default
        if let data, !fm.fileExists(atPath: corrupt.path) {
            try? data.write(to: corrupt, options: .atomic)
        } else if fm.fileExists(atPath: storeURL.path), !fm.fileExists(atPath: corrupt.path) {
            try? fm.copyItem(at: storeURL, to: corrupt)
        }
        // 挪走坏文件，让新的空会话能正常写盘
        try? fm.removeItem(at: storeURL)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            // 工作组单独存
            if let gdata = try? JSONEncoder().encode(self.groups) {
                try? gdata.write(to: self.groupsURL, options: .atomic)
            }
            let data = (try? JSONEncoder().encode(self.sessions)) ?? Data()
            guard !data.isEmpty else { return }   // 编码失败就别写空文件把原件冲掉
            try? fm.createDirectory(
                at: self.storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // 防呆：覆盖前留一份上一版滚动备份，写坏了能退回去
            if fm.fileExists(atPath: self.storeURL.path) {
                let bak = self.storeURL.deletingPathExtension().appendingPathExtension("bak.json")
                try? fm.removeItem(at: bak)
                try? fm.copyItem(at: self.storeURL, to: bak)
            }
            try? data.write(to: self.storeURL, options: .atomic)
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    // MARK: - 对话

    func send(_ raw: String, server: ServerController) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        // 生成过程中也能发：先停下当前生成（已生成的部分保留），再把新消息发出去
        if isStreaming { stop() }
        pendingChoice = nil

        guard server.state.isReady else {
            mutateCurrent { s in
                s.messages.append(ChatMessage(role: .assistant,
                                              text: Lf("模型还没准备好（%@），等加载完再发。", server.state.label),
                                              failed: true))
            }
            return
        }

        let botID = UUID()
        mutateCurrent { s in
            // 空对话发出第一条消息时，归入侧栏当前选中的组。
            // 覆盖「打开app→点组→直接打字发送」这条路径——此时不会走 newSession，
            // 用户的对话若不归组，组里就看不到。
            let isFirstMessage = s.messages.isEmpty
            s.messages.append(ChatMessage(role: .user, text: input))
            s.messages.append(ChatMessage(id: botID, role: .assistant))
            s.refreshTitle()
            if isFirstMessage {
                s.groupID = showUngroupedOnly ? nil : selectedGroupID
            }
        }
        // 标题等主对话 finishTurn 完成后再生成（那时模型空闲，请求不会被排队饿死）
        lastUserText = input
        isStreaming = true
        generatedTokens = 0

        // 发给模型的历史：身份 + 这段对话的角色提示词，合成一条 system 消息
        var payload: [[String: String]] = []
        payload.append(["role": "system",
                        "content": Self.composeSystem(identity: Self.identityPrompt,
                                                      role: current?.rolePrompt)])
        for m in messages where m.id != botID && !m.failed && !m.text.isEmpty {
            payload.append(["role": m.role == .user ? "user" : "assistant", "content": m.text])
        }

        run(payload: payload, forceQuestion: false, botID: botID, server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// 挑了一个候选方向
    func answerChoice(_ text: String, server: ServerController) {
        send(text, server: server)
    }

    // MARK: - 消息级操作

    /// 正在编辑重发的消息（nil = 没打开编辑器）
    @Published var editingMessageID: UUID?
    /// 待删除确认的消息
    @Published var pendingDeleteMessageID: UUID?

    /// 拼这一轮要发出去的完整历史（identity + 角色 + 除指定消息外的全部消息）
    private func payloadExcluding(_ excludedID: UUID?) -> [[String: String]] {
        var payload: [[String: String]] = []
        payload.append(["role": "system",
                        "content": Self.composeSystem(identity: Self.identityPrompt,
                                                      role: current?.rolePrompt)])
        for m in messages where m.id != excludedID && !m.failed && !m.text.isEmpty {
            payload.append(["role": m.role == .user ? "user" : "assistant", "content": m.text])
        }
        return payload
    }

    /// 重新生成：删掉这条及之后的消息，用剩下的前缀重发。
    /// 前缀没变，服务端命中 prompt cache，比整段重发快得多。
    func regenerate(_ id: UUID, server: ServerController) {
        guard server.state.isReady else { return }
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .assistant else { return }
        if isStreaming { stop() }
        let botID = UUID()
        mutateCurrent { s in
            s.messages.removeSubrange(idx...)
            s.messages.append(ChatMessage(id: botID, role: .assistant))
        }
        isStreaming = true
        generatedTokens = 0
        run(payload: payloadExcluding(botID), forceQuestion: false, botID: botID, server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// 继续生成：把已有回答留在上下文里，接着往下写（新的气泡，不覆盖原文）
    func continueGeneration(server: ServerController) {
        guard server.state.isReady, !isStreaming else { return }
        guard let last = messages.last, last.role == .assistant, !last.text.isEmpty else { return }
        let botID = UUID()
        mutateCurrent { s in s.messages.append(ChatMessage(id: botID, role: .assistant)) }
        isStreaming = true
        generatedTokens = 0
        run(payload: payloadExcluding(botID), forceQuestion: false, botID: botID, server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// 删掉一条消息（确认框由界面负责）
    func deleteMessage(_ id: UUID) {
        mutateCurrent { s in s.messages.removeAll { $0.id == id } }
        scheduleSave()
    }

    /// 编辑用户消息并重发：改完把它之后的回答全部作废，从这条重新问
    func editAndResend(_ id: UUID, to newText: String, server: ServerController) {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, server.state.isReady else { return }
        guard let idx = messages.firstIndex(where: { $0.id == id }),
              messages[idx].role == .user else { return }
        if isStreaming { stop() }
        let botID = UUID()
        mutateCurrent { s in
            s.messages[idx].text = text
            s.messages.removeSubrange((idx + 1)...)
            s.messages.append(ChatMessage(id: botID, role: .assistant))
        }
        isStreaming = true
        generatedTokens = 0
        run(payload: payloadExcluding(botID), forceQuestion: false, botID: botID, server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// MDMSGTEST=1：在临时会话里跑一遍「重新生成」，核对截断与重新生成的结果。
    /// 跑完把临时会话删掉，不污染真实数据。
    func selfTestMessages(server: ServerController) {
        guard ProcessInfo.processInfo.environment["MDMSGTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDMSGTEST") else { return }
        let sid = newSession(select: true)
        let targetID = UUID()
        mutateCurrent { s in
            s.messages = [
                ChatMessage(role: .user, text: "用一句话说明砂岩和页岩的区别。"),
                ChatMessage(id: targetID, role: .assistant, text: "砂岩颗粒粗，页岩颗粒细。"),
                ChatMessage(role: .user, text: "那它们的孔隙度呢？"),
                ChatMessage(role: .assistant, text: "砂岩孔隙度通常更高。")
            ]
        }
        regenerate(targetID, server: server)   // 应截断到第 1 条之后

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let cur = self.sessions.first(where: { $0.id == sid }) else { return }
            var lines = ["截断后消息数：\(cur.messages.count)（期望 2：1 条 user + 1 条新回答）"]
            for m in cur.messages {
                lines.append("\(m.role == .user ? "user" : "bot ")：\(m.text.prefix(24))")
            }
            lines.append("isStreaming=\(self.isStreaming)")
            try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_msg.txt",
                                                     atomically: true, encoding: .utf8)
            self.delete(sid)
        }
    }

    func message(_ id: UUID) -> ChatMessage? {
        messages.first { $0.id == id }
    }

    /// 让模型给出几个候选方向。
    ///
    /// 用 JSON schema 约束输出（llama.cpp 会转成语法强约束生成），格式一定合法；
    /// 模型只负责写内容和列选项，不负责「该不该问、问什么」这种判断。
    func askOptions(server: ServerController) {
        guard server.state.isReady else {
            mutateCurrent { s in
                s.messages.append(ChatMessage(role: .assistant,
                                              text: Lf("模型还没准备好（%@），等加载完再问。", server.state.label),
                                              failed: true))
            }
            return
        }
        // 先暂停正在进行的生成
        if isStreaming { stop() }

        let botID = UUID()
        mutateCurrent { s in
            s.messages.append(ChatMessage(id: botID, role: .assistant, isChoice: true))
        }
        isStreaming = true
        generatedTokens = 0

        var payload: [[String: String]] = []
        payload.append(["role": "system",
                        "content": Self.composeSystem(identity: Self.identityPrompt,
                                                      role: current?.rolePrompt)])
        payload.append(["role": "system",
                        "content": "用户还没有明确方向。请你提出一个澄清问题，给出 3 到 5 个具体的选项供用户挑选。"
                        + "如果这些选项可以并存、用户可能同时选多个，就把 multi 设为 true（多选）；"
                        + "如果是互斥的、只能选一个，就把 multi 设为 false（单选）。"])
        for m in messages where m.id != botID && !m.failed && !m.text.isEmpty && !m.isChoice {
            payload.append(["role": m.role == .user ? "user" : "assistant", "content": m.text])
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "question": ["type": "string"],
                "options": ["type": "array", "items": ["type": "string"]],
                "multi": ["type": "boolean"]
            ],
            "required": ["question", "options", "multi"]
        ]

        run(payload: payload,
            forceQuestion: false,
            responseFormat: ["type": "json_object", "schema": schema],
            botID: botID,
            server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// 首轮对话后让模型给这段对话起个短标题（≤14 字）。
    /// 独立请求、短超时，失败就静默保留兜底标题，绝不影响主对话。
    private func generateTitle(for sessionID: UUID, userText: String, server: ServerController) {
        titleTask?.cancel()
        titleTask = Task { [weak self] in
            guard let self else { return }
            // 4B 模型不会听话地"只输出标题"——强制 JSON schema，让它除了 title 字段没别的地方可写
            let schema: [String: Any] = [
                "type": "object",
                "properties": ["title": ["type": "string"]],
                "required": ["title"]
            ]
            let body: [String: Any] = [
                "messages": [
                    ["role": "system", "content": "你的唯一任务：给这段用户提问起一个简短标题（不超过12个汉字），作为会话名称。"
                        + "标题要概括用户想做什么，例如提问关于板块构造就写「板块构造理论」。"
                        + "严禁回答这个问题，严禁复述整句提问，只给出标题短语。"],
                    ["role": "user", "content": String(userText.prefix(600))]
                ],
                "stream": false,
                "max_tokens": 64,
                "temperature": 0.2,
                "response_format": ["type": "json_object", "schema": schema]
            ]
            do {
                var req = URLRequest(url: server.baseURL.appendingPathComponent("v1/chat/completions"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 30
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, resp) = try await self.session.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let msg = choices.first?["message"] as? [String: Any],
                      let content = msg["content"] as? String else { return }
                // 小模型有时被 max_tokens 截断，JSON 不完整——先严格解析，失败就正则抠字段
                var title: String?
                if let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] {
                    title = inner["title"] as? String
                }
                if title == nil,
                   let re = try? NSRegularExpression(pattern: "\"title\"\\s*:\\s*\"([^\"]+)\""),
                   let m = re.firstMatch(in: content, options: [],
                                         range: NSRange(location: 0, length: content.utf16.count)),
                   m.numberOfRanges >= 2 {
                    title = (content as NSString).substring(with: m.range(at: 2))
                }
                guard var extracted = title else { return }
                // 清洗：去引号/空白/换行，限长
                extracted = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'「」《》:："))
                extracted = extracted.replacingOccurrences(of: "\n", with: " ")
                guard !extracted.isEmpty else { return }
                let finalTitle = extracted.count > 14 ? String(extracted.prefix(14)) : extracted
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    self.mutateCurrent { s in
                        guard s.id == sessionID, let first = s.messages.firstIndex(where: { $0.role == .user }) else { return }
                        // 只在标题还是"新对话"或首条消息截断值时覆盖
                        let fallback = s.messages[first].text
                        if s.title == "新对话" || s.title == fallback || s.title.hasSuffix("…") {
                            s.title = finalTitle
                        }
                    }
                }
            } catch {
                // 起标题失败不影响主对话：啥也不做，保留兜底标题
            }
        }
    }

    private func run(payload: [[String: String]],
                     forceQuestion: Bool,
                     responseFormat: [String: Any]? = nil,
                     botID: UUID,
                     server: ServerController,
                     sampling: SamplingParams = SamplingParams.Preset.balanced.params) {
        var body: [String: Any] = [
            "messages": payload,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        body["temperature"] = sampling.temperature
        body["top_p"] = sampling.topP
        body["top_k"] = sampling.topK
        body["repeat_penalty"] = sampling.repeatPenalty
        body["max_tokens"] = sampling.maxTokens
        if sampling.seed >= 0 { body["seed"] = sampling.seed }
        if let responseFormat {
            body["response_format"] = responseFormat
        }
        if forceQuestion {
            body["tools"] = [ChatStore.askUserTool]
            body["tool_choice"] = ["type": "function", "function": ["name": "ask_user"]]
        }

        generation += 1
        let myGen = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var req = URLRequest(url: server.baseURL.appendingPathComponent("v1/chat/completions"))
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                var (bytes, response) = try await self.session.bytes(for: req)
                // 采样字段可能不被这个版本的服务端接受（400）：退回只带温度的最小请求再试一次，
                // 宁可少调参，也不能让用户发不出消息
                if let http = response as? HTTPURLResponse, http.statusCode == 400 {
                    var minimal: [String: Any] = [
                        "messages": payload,
                        "stream": true,
                        "temperature": 0.7,
                        "max_tokens": -1,
                        "stream_options": ["include_usage": true]
                    ]
                    if let responseFormat { minimal["response_format"] = responseFormat }
                    if forceQuestion {
                        minimal["tools"] = [ChatStore.askUserTool]
                        minimal["tool_choice"] = ["type": "function", "function": ["name": "ask_user"]]
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: minimal)
                    (bytes, response) = try await self.session.bytes(for: req)
                }
                guard let http = response as? HTTPURLResponse else {
                    throw ChatFailure.message(L("服务器没有返回有效响应"))
                }
                guard http.statusCode == 200 else {
                    throw ChatFailure.message(Lf("服务器返回 HTTP %@", "\(http.statusCode)"))
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payloadText.isEmpty || payloadText == "[DONE]" { continue }
                    self.consume(payloadText, id: botID)
                }
            } catch is CancellationError {
                // 用户主动停止，保留已生成的部分
            } catch {
                if !Task.isCancelled && self.generation == myGen {
                    self.fail(botID, error.localizedDescription)
                }
            }
            await MainActor.run {
                // 这一轮可能已经被 stop() 或新一轮取代：旧任务不许再动共享状态，
                // 否则会把新消息正在写的内容清掉（曾导致「发不出去」）
                guard self.generation == myGen else { return }
                self.flushPending()
                self.isStreaming = false
                self.refreshTokenUsageFallback(server: server)
                self.finishTurn(id: botID, server: server)
                self.scheduleSave()
            }
        }
    }

    func stop() {
        generation += 1          // 让在飞的旧任务收尾失效
        task?.cancel()
        task = nil
        flushPending()
        isStreaming = false
    }

    private func consume(_ json: String, id: UUID) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var content: String?
        var reasoning: String?
        var toolArgs = ""

        if let choices = obj["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            content = delta["content"] as? String
            reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String
            // 强制提问时，模型输出的是工具调用，参数分片到达
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    if let fn = tc["function"] as? [String: Any],
                       let args = fn["arguments"] as? String {
                        toolArgs += args
                    }
                }
            }
        }

        var m = PendingMetrics()
        if let timings = obj["timings"] as? [String: Any] {
            if let v = timings["predicted_per_second"] as? Double { m.tps = v }
            if let v = timings["prompt_per_second"] as? Double { m.promptTPS = v }
            if let v = timings["prompt_n"] as? Int { m.promptTokens = v }
            if let v = timings["predicted_n"] as? Int { m.generatedTokens = v }
            if let v = timings["prompt_ms"] as? Double { m.promptMS = v }
            if let v = timings["predicted_per_token_ms"] as? Double { m.perTokenMS = v }
        }
        // 最后一帧会带 usage，必须放在 timings 之后覆盖：
        // 命中 prompt cache 时 timings.prompt_n 只是「本次新算的」增量（实测 16 个 token 的
        // 提示在前一轮缓存后只报 4），而 usage.prompt_tokens 始终是完整提示。
        // 上下文占用要用完整值，否则每轮都显得很空。
        if let usage = obj["usage"] as? [String: Any] {
            if let v = usage["prompt_tokens"] as? Int, v > 0 { m.promptTokens = v }
            if let v = usage["completion_tokens"] as? Int, v > 0 { m.generatedTokens = v }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let c = content, !c.isEmpty { self.pendingText[id, default: ""] += c }
            if let r = reasoning, !r.isEmpty { self.pendingReasoning[id, default: ""] += r }
            if !toolArgs.isEmpty { self.pendingToolArgs += toolArgs }
            // 逐帧覆盖：新的非空值盖掉旧值，缺失字段保留上一帧的
            var merged = self.pendingMetrics[id] ?? PendingMetrics()
            if m.tps > 0 { merged.tps = m.tps }
            if m.promptTPS > 0 { merged.promptTPS = m.promptTPS }
            if m.promptTokens > 0 { merged.promptTokens = m.promptTokens }
            if m.generatedTokens > 0 { merged.generatedTokens = m.generatedTokens }
            if m.promptMS > 0 { merged.promptMS = m.promptMS }
            if m.perTokenMS > 0 { merged.perTokenMS = m.perTokenMS }
            if merged.hasData { self.pendingMetrics[id] = merged }
            if m.promptTPS > 0 { self.promptTPS = m.promptTPS }
            if m.promptTokens > 0 { self.promptTokens = m.promptTokens }
            if m.generatedTokens > 0 { self.generatedTokens = m.generatedTokens }
            self.scheduleFlush()
        }
    }

    /// 这一轮结束后，判断模型是不是在让用户选方向
    private func finishTurn(id: UUID, server: ServerController) {
        let raw = pendingToolArgs
        pendingToolArgs = ""

        // 首轮完成后生成标题：此时模型已空闲，不会被主对话排队饿死
        if let sid = currentID, !titledSessions.contains(sid), !lastUserText.isEmpty {
            titledSessions.insert(sid)
            generateTitle(for: sid, userText: lastUserText, server: server)
        }

        let text = currentText(id: id).trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 工具调用（大模型自己调 ask_user 时）
        if !raw.isEmpty {
            var question = raw
            var options: [String] = []
            var multi = false
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let q = obj["question"] as? String, !q.isEmpty { question = q }
                if let arr = obj["options"] as? [String] { options = arr }
                multi = obj["multi"] as? Bool ?? false
            }
            pendingChoice = ChoiceRequest(question: question, options: options, multiSelect: multi)
            mutateCurrent { s in
                guard let idx = s.messages.firstIndex(where: { $0.id == id }) else { return }
                s.messages[idx].text = question
                s.messages[idx].isChoice = true
            }
            return
        }

        // 2) 结构化输出（我们强制 JSON schema 时）
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let q = obj["question"] as? String, !q.isEmpty {
            let options = obj["options"] as? [String] ?? []
            let multi = obj["multi"] as? Bool ?? false
            pendingChoice = ChoiceRequest(question: q, options: options, multiSelect: multi)
            mutateCurrent { s in
                guard let idx = s.messages.firstIndex(where: { $0.id == id }) else { return }
                s.messages[idx].text = q
                s.messages[idx].isChoice = true
            }
            return
        }

        // 3) 普通回复：只有「短问句」才当成在问用户。
        //    长答案即使最后一行是问号（比如带标题和代码块的技术答复），
        //    也应该留在对话区正常渲染 markdown，不能被当成问题挪走。
        guard text.hasSuffix("？") || text.hasSuffix("?") else { return }
        guard text.count <= 120, text.split(separator: "\n").count <= 3 else { return }
        pendingChoice = ChoiceRequest(question: text, options: [])
        mutateCurrent { s in
            guard let idx = s.messages.firstIndex(where: { $0.id == id }) else { return }
            s.messages[idx].isChoice = true
        }
    }

    private func currentText(id: UUID) -> String {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return "" }
        return messages[idx].text
    }

    // MARK: 帧合并

    private var pendingText: [UUID: String] = [:]
    private var pendingReasoning: [UUID: String] = [:]
    private var pendingMetrics: [UUID: PendingMetrics] = [:]
    private var pendingToolArgs: String = ""
    private var flushScheduled = false

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
            self?.flushPending()
        }
    }

    func flushPending() {
        flushScheduled = false
        guard !pendingText.isEmpty || !pendingReasoning.isEmpty || !pendingMetrics.isEmpty else { return }

        mutateCurrent { s in
            for (id, chunk) in pendingText {
                if let idx = s.messages.firstIndex(where: { $0.id == id }) {
                    s.messages[idx].text += chunk
                }
            }
            for (id, chunk) in pendingReasoning {
                if let idx = s.messages.firstIndex(where: { $0.id == id }) {
                    s.messages[idx].reasoning += chunk
                }
            }
            for (id, m) in pendingMetrics {
                if let idx = s.messages.firstIndex(where: { $0.id == id }) {
                    s.messages[idx].tps = m.tps
                    s.messages[idx].promptTokens = m.promptTokens
                    s.messages[idx].generatedTokens = m.generatedTokens
                    s.messages[idx].promptTPS = m.promptTPS
                    s.messages[idx].promptMS = m.promptMS
                    s.messages[idx].perTokenMS = m.perTokenMS
                }
                if m.tps > 0 { lastTPS = m.tps }
            }
        }
        pendingText.removeAll()
        pendingReasoning.removeAll()
        pendingMetrics.removeAll()
    }

    private func fail(_ id: UUID, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutateCurrent { s in
                guard let idx = s.messages.firstIndex(where: { $0.id == id }) else { return }
                s.messages[idx].failed = true
                s.messages[idx].text = s.messages[idx].text.isEmpty
                    ? Lf("出错了：%@", message)
                    : s.messages[idx].text + "\n\n" + Lf("（中断：%@）", message)
            }
        }
    }
}

enum ChatFailure: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
