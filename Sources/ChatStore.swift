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

    // MARK: - 上下文压缩（/compact）

    /// 正在等模型写摘要
    @Published private(set) var isCompacting = false
    /// 一次性提示（压缩失败、对话太短、命令不认识），输入框上方显示几秒后自己消失
    @Published private(set) var commandNote: String?

    private var compactTask: Task<Void, Never>?
    private var noteWorkItem: DispatchWorkItem?

    /// 压缩时保留最近几条消息原文：大约两轮对话。
    /// 留少了模型不知道"刚才说到哪"，留多了腾不出空间。
    private static let compactKeepMessages = 4

    func dismissCommandNote() { commandNote = nil }

    /// 给界面用的公开入口（附件读取失败之类，复用同一条提示位）
    func postNote(_ text: String) { note(text) }

    private func note(_ text: String) {
        commandNote = text
        noteWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.commandNote = nil }
        noteWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    func cancelCompaction() {
        compactTask?.cancel()
        compactTask = nil
        isCompacting = false
        note(L("已取消压缩"))
    }

    /// 切出"要压缩的前缀"和"要保留的尾巴"。
    /// 返回 nil 表示这段对话还不值得压（压缩完反而更长）。
    private func splitForCompact(_ messages: [ChatMessage]) -> (prefix: [ChatMessage], keepIndex: Int)? {
        guard !messages.isEmpty else { return nil }
        var i = messages.count - 1
        var kept = 0
        while i >= 0 && kept < Self.compactKeepMessages {
            let m = messages[i]
            if !m.fullContent.isEmpty && !m.isChoice && !m.failed { kept += 1 }
            i -= 1
        }
        var start = min(i + 1, messages.count - 1)
        // 保留区不能以助手消息开头：历史得从用户开口，某些 chat template 会强校验
        while start > 0 && messages[start].role == .assistant { start -= 1 }
        guard start > 0 else { return nil }
        let prefix = Array(messages[0..<start])
        guard prefix.contains(where: { !$0.fullContent.isEmpty && !$0.isChoice }) else { return nil }
        return (prefix, start)
    }

    /// 压缩当前对话：模型写摘要 → 摘要顶替早前原文，最近几轮保持不变
    func compact(server: ServerController) {
        guard !isCompacting else { return }
        if isStreaming { stop() }
        guard let cur = current else { return }
        guard server.state.isReady else {
            note(Lf("模型还没准备好（%@），等加载完再压缩。", server.state.label))
            return
        }
        guard let split = splitForCompact(cur.messages) else {
            note(L("这段对话还短，不需要压缩"))
            return
        }

        let sessionID = cur.id
        let total = cur.messages.count
        let transcript = ContextCompactor.transcript(
            split.prefix,
            charBudget: ContextCompactor.charBudget(contextSize: server.contextSize))
        pendingChoice = nil
        isCompacting = true

        compactTask = Task { [weak self] in
            guard let self else { return }
            let summary = await ContextCompactor.summarize(transcript: transcript,
                                                           server: server,
                                                           session: self.session)
            if Task.isCancelled { return }
            await MainActor.run {
                self.compactTask = nil
                self.isCompacting = false
                self.applyCompaction(sessionID: sessionID,
                                     keepIndex: split.keepIndex,
                                     totalCount: total,
                                     prefix: split.prefix,
                                     summary: summary,
                                     server: server)
            }
        }
    }

    private func applyCompaction(sessionID: UUID,
                                 keepIndex: Int,
                                 totalCount: Int,
                                 prefix: [ChatMessage],
                                 summary: ContextCompactor.Summary?,
                                 server: ServerController) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // 压缩期间用户可能已经删了消息/换了对话：对不上就不动，别把历史切歪
        guard sessions[idx].messages.count == totalCount,
              keepIndex > 0, keepIndex <= sessions[idx].messages.count else {
            note(L("对话在压缩过程中变了，这次没压缩"))
            return
        }
        let text = summary?.text ?? ContextCompactor.localDigest(prefix)
        let bubble = ChatMessage(role: .assistant,
                                 text: text,
                                 isSummary: true,
                                 summaryCount: prefix.count)
        sessions[idx].messages.removeFirst(keepIndex)
        sessions[idx].messages.insert(bubble, at: 0)
        sessions[idx].updatedAt = Date()
        scheduleSave()

        if currentID == sessionID {
            promptTokens = 0
            generatedTokens = 0
            // 重新数一遍占用，压缩完立刻能看到省了多少
            refreshTokenUsageFallback(server: server)
        }
        if summary == nil { note(L("模型摘要失败，已改用本地摘要")) }
    }

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
    /// 提示词模板（内置 + prompts.json）
    @Published var templates: [PromptTemplate] = PromptLibrary.load()

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
        // 顺手核对公式块解析
        let mathSample = """
        行内公式 $E=mc^2$ 保持原样。

        $$
        a^2 + b^2 = c^2
        $$

        \\[
        \\int_0^1 x\\,dx = \\frac{1}{2}
        \\]

        代码围栏里的不算：
        ```sh
        echo $$ not math $$
        ```
        """
        let kinds = MarkdownParser.parse(mathSample).map { block -> String in
            switch block {
            case .math(let l, let d): return "math(\(d ? "block" : "inline"):\(l.prefix(18)))"
            case .paragraph: return "para"
            case .code(let lang, _): return "code(\(lang))"
            default: return "other"
            }
        }
        lines.append("公式解析：\(kinds.joined(separator: " | "))")

        // 顺手把导出结果落盘，核对格式
        if let cur = current {
            try? SessionExporter.markdown(cur).write(toFile: "/tmp/qstudio_export.md",
                                                     atomically: true, encoding: .utf8)
            if let d = SessionExporter.jsonData(cur, modelName: "test-model") {
                try? d.write(to: URL(fileURLWithPath: "/tmp/qstudio_export.json"))
            }
            lines.append("导出文件名：\(SessionExporter.suggestedName(cur, format: .markdown))")
        }
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
        guard promptTokens == 0, current != nil else { return }
        // 用真正会发出去的 payload 数，压缩摘要/系统提示词都算在里面
        let prompt = buildPayload().map { $0["content"] ?? "" }.joined(separator: "\n")
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

    /// 按消息 id 改消息。流式回调可能晚于用户切走/删掉对话，
    /// 这时"当前会话"已经不是它所属的那个了——按 id 找，找不到就什么都不做。
    private func updateMessage(_ id: UUID, _ body: (inout ChatMessage) -> Void) {
        for si in sessions.indices {
            guard let mi = sessions[si].messages.firstIndex(where: { $0.id == id }) else { continue }
            body(&sessions[si].messages[mi])
            sessions[si].updatedAt = Date()
            scheduleSave()
            return
        }
    }

    /// 按 id 改某个会话（异步回调回来时用户可能已经切走）
    private func mutateSession(_ id: UUID, _ body: (inout ChatSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
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

    /// 用模板新建对话：角色和采样都用模板的，采样没写就沿用默认
    @discardableResult
    func newSession(from template: PromptTemplate, select shouldSelect: Bool = true) -> UUID {
        let id = newSession(select: shouldSelect)
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return id }
        sessions[i].rolePrompt = template.role
        if let sp = template.sampling { sessions[i].sampling = sp }
        scheduleSave()
        return id
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

    func send(_ raw: String, attachments: [MessageAttachment] = [], server: ServerController) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty || !attachments.isEmpty else { return }
        // 斜杠命令不发模型：它改的是本地状态，不该进对话历史
        if let cmd = SlashCommand.parse(input) {
            run(command: cmd, server: server)
            return
        }
        if isCompacting {
            note(L("正在压缩上下文，等它写完再发"))
            return
        }
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
            var user = ChatMessage(role: .user, text: input)
            if !attachments.isEmpty { user.attachments = attachments }
            s.messages.append(user)
            s.messages.append(ChatMessage(id: botID, role: .assistant))
            s.refreshTitle()
            if isFirstMessage {
                s.groupID = showUngroupedOnly ? nil : selectedGroupID
            }
        }
        // 标题等主对话 finishTurn 完成后再生成（那时模型空闲，请求不会被排队饿死）
        // 只贴文件没打字时，用文件名当标题线索，否则会一直叫"新对话"
        lastUserText = input.isEmpty ? (attachments.first?.name ?? "") : input
        isStreaming = true
        generatedTokens = 0

        // 发给模型的历史：身份 + 这段对话的角色提示词，合成一条 system 消息
        let payload = buildPayload(excluding: botID)

        run(payload: payload, forceQuestion: false, botID: botID, server: server,
            sampling: current?.samplingParams ?? SamplingParams.Preset.balanced.params)
    }

    /// 斜杠命令分发
    private func run(command: SlashCommand, server: ServerController) {
        switch command {
        case .compact:
            compact(server: server)
        case .unknown(let name):
            note(Lf("没有这个命令：%@。目前只有 /compact。", name))
        }
    }

    /// 拼这一轮发给模型的完整消息。
    ///
    /// 只有一条 system：身份 + 角色提示词，压缩摘要也并进这条。
    /// 摘要不伪造成一轮对话——历史从 assistant 开口时，有些 chat template 会直接报错。
    private func buildPayload(excluding excludedID: UUID? = nil,
                              extraSystem: String? = nil,
                              includeChoice: Bool = true) -> [[String: String]] {
        var system = Self.composeSystem(identity: Self.identityPrompt, role: current?.rolePrompt)
        var summaryParts: [String] = []
        var history: [[String: String]] = []
        for m in messages where m.id != excludedID && !m.failed {
            if m.isSummaryBubble {
                summaryParts.append(m.text)
                continue
            }
            if m.isChoice && !includeChoice { continue }
            // fullContent：附件正文拼在用户问题前面，附件单独发出的消息也能进历史
            let content = m.fullContent
            guard !content.isEmpty else { continue }
            history.append(["role": m.role == .user ? "user" : "assistant", "content": content])
        }
        for s in summaryParts {
            system += "\n\n（以下是本次对话早前部分的压缩摘要，原文已移除）\n" + s
        }
        if let extraSystem, !extraSystem.isEmpty { system += "\n\n" + extraSystem }
        return [["role": "system", "content": system]] + history
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
        buildPayload(excluding: excludedID)
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

    /// MDATTACHTEST=1：附件读取 + 端到端发送自检。
    /// 造三个临时文件（正常 md / 二进制 / GB18030），核对读取结果，
    /// 再真的带附件问一次模型，确认正文确实进了上下文。
    func selfTestAttach(server: ServerController) {
        guard ProcessInfo.processInfo.environment["MDATTACHTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDATTACHTEST") else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qstudio_attach")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let lines = (1...80).map { "第\($0)行：岩芯编录数据，层位 \($0 * 10) 米。" }
        let md = lines.joined(separator: "\n") + "\n项目代号：玄武-7。\n结论见附录 A。"
        let mdURL = dir.appendingPathComponent("岩芯记录.md")
        try? md.write(to: mdURL, atomically: true, encoding: .utf8)

        let binURL = dir.appendingPathComponent("假二进制.bin")
        var bin = Data([0x00, 0x01, 0x02, 0x03])
        bin.append(contentsOf: [UInt8](repeating: 0x00, count: 200))
        try? bin.write(to: binURL)

        let gbURL = dir.appendingPathComponent("gb.txt")
        let gbEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try? "点位编号：龙门-3。\n岩性：片麻岩。".data(using: gbEnc)?.write(to: gbURL)

        var lines2: [String] = ["--- 读取 ---"]
        func describe(_ label: String, _ r: Result<MessageAttachment, AttachmentLoader.LoadError>) {
            switch r {
            case .success(let a):
                lines2.append("\(label)：成功 name=\(a.name) 原文=\(a.originalChars)字 存下=\(a.text.count)字 截断=\(a.truncated)")
                lines2.append("  含代号=\(a.text.contains("玄武-7")) 含结尾=\(a.text.contains("附录 A")) 含省略标记=\(a.text.contains("中间省略"))")
                lines2.append("  开头：\(a.text.prefix(40).replacingOccurrences(of: "\n", with: "⏎"))")
            case .failure(let e):
                lines2.append("\(label)：失败 —— \(e.message)")
            }
        }
        let small = AttachmentLoader.load(url: mdURL, charLimit: 400)
        describe("md(limit 400)", small)
        describe("二进制", AttachmentLoader.load(url: binURL, charLimit: 4000))
        describe("GB18030", AttachmentLoader.load(url: gbURL, charLimit: 4000))
        lines2.append("上限：字符串长度 \(AttachmentLoader.charLimit(contextSize: 16384))")

        let sid = newSession(select: true)
        let attachment = (try? small.get()) ?? MessageAttachment(name: mdURL.lastPathComponent,
                                                                text: md,
                                                                originalChars: md.count,
                                                                truncated: false)
        send("这个文件的「项目代号」是什么？只回答代号，不要解释。",
             attachments: [attachment], server: server)

        var waited = 0
        var settled = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            waited += 1
            if self.isStreaming && waited <= 150 { return }
            settled += 1
            guard settled >= 2 || waited > 150 else { return }
            t.invalidate()

            let cur = self.sessions.first { $0.id == sid }
            let user = cur?.messages.first { $0.role == .user }
            let reply = cur?.messages.last { $0.role == .assistant && !$0.text.isEmpty }
            lines2.append("--- 端到端 ---")
            lines2.append("用户消息带附件：\(user?.attachments?.count ?? 0) 个；text 为空=\(user?.text.isEmpty ?? true)")
            lines2.append("fullContent 前缀：\((user?.fullContent ?? "").prefix(120).replacingOccurrences(of: "\n", with: "⏎"))")
            lines2.append("payload 条数：\(self.buildPayload().count)")
            if let p = self.buildPayload().first(where: { $0["role"] == "user" }) {
                lines2.append("payload 里 user 段长度：\((p["content"] ?? "").count) 字；含代号=\((p["content"] ?? "").contains("玄武-7"))")
            }
            lines2.append("模型回答：\(reply?.text.replacingOccurrences(of: "\n", with: " ").prefix(200) ?? "（无）")")
            lines2.append("回答里含 玄武-7：\((reply?.text ?? "").contains("玄武-7"))")

            try? lines2.joined(separator: "\n").write(toFile: "/tmp/qstudio_attach.txt",
                                                     atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: dir)
            self.delete(sid)
            UserDefaults.standard.removeObject(forKey: "MDATTACHTEST")
        }
    }

    /// MDCOMPACTTEST=1：在临时会话里跑一遍 /compact，把结果落盘核对，跑完删掉临时会话。
    /// 只用假数据，不碰真实对话。
    func selfTestCompact(server: ServerController) {
        guard ProcessInfo.processInfo.environment["MDCOMPACTTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDCOMPACTTEST") else { return }
        let sid = newSession(select: true)
        let turns: [(String, String)] = [
            ("我们在整理一份野外地质记录，先把点位信息过一遍。", "好的，请把点位和岩性数据发我。"),
            ("点位 A 在北纬 34.2，岩性是灰岩。", "已记下：A 点 N34.2，灰岩。"),
            ("点位 B 在北纬 34.5，岩性是砂岩，倾角 30 度。", "已记下：B 点 N34.5，砂岩，倾角 30 度。"),
            ("帮我算一下两点之间的直线距离。", "粗略估算约 33.4 公里。"),
            ("按这个结果写一段结论。", "结论：A、B 两点相距约 33.4 km，岩性由灰岩过渡为砂岩。")
        ]
        let seeded = turns.flatMap {
            [ChatMessage(role: .user, text: $0.0), ChatMessage(role: .assistant, text: $0.1)]
        }
        mutateCurrent { s in s.messages = seeded }
        let before = messages.count
        compact(server: server)

        var waited = 0
        var settled = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            waited += 1
            if self.isCompacting && waited <= 150 { return }
            settled += 1
            guard settled >= 3 || waited > 150 else { return }
            t.invalidate()
            let cur = self.sessions.first { $0.id == sid }
            var lines: [String] = []
            lines.append("压缩前消息数：\(before)")
            lines.append("压缩后消息数：\(cur?.messages.count ?? -1)")
            lines.append("首条是摘要：\((cur?.messages.first?.isSummaryBubble ?? false) ? "是" : "否")")
            lines.append("顶替条数：\(cur?.messages.first?.summaryCount ?? -1)")
            lines.append("首条角色：\((cur?.messages.first?.role == .user) ? "user" : "assistant")")
            lines.append("其后角色序：\(cur?.messages.dropFirst().map { $0.role == .user ? "u" : "a" }.joined() ?? "")")
            lines.append("摘要文本：\n\((cur?.messages.first?.text ?? "").prefix(700))")
            lines.append("--- payload（应只有一条 system，摘要并进去）---")
            for (i, m) in self.buildPayload().enumerated() {
                let content = m["content"] ?? ""
                lines.append("[\(i)] \(m["role"] ?? "?") \(content.count) 字：\(content.prefix(180))")
            }
            lines.append("commandNote=\(self.commandNote ?? "nil")")
            lines.append("isCompacting=\(self.isCompacting)")
            lines.append("压缩后 token 占用：prompt=\(self.promptTokens) generated=\(self.generatedTokens)")

            // 纯逻辑核对：命令解析 / 预算截断 / 本地兜底
            func cmd(_ s: String) -> String {
                switch SlashCommand.parse(s) {
                case .compact: return "compact"
                case .unknown(let n): return "unknown(\(n))"
                case nil: return "nil"
                }
            }
            lines.append("--- 命令解析 ---")
            lines.append("/compact→\(cmd("/compact"))  /压缩→\(cmd("/压缩"))  /foo→\(cmd("/foo"))  单斜杠→\(cmd("/"))  普通文本→\(cmd("你好"))  含换行→\(cmd("/compact\n多行"))")
            lines.append("--- 预算截断（charBudget=200）---")
            lines.append(ContextCompactor.transcript(seeded, charBudget: 200))
            lines.append("--- 本地兜底摘要 ---")
            lines.append(ContextCompactor.localDigest(Array(seeded.prefix(6))))
            try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_compact.txt",
                                                     atomically: true, encoding: .utf8)
            self.delete(sid)
            UserDefaults.standard.removeObject(forKey: "MDCOMPACTTEST")
        }
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

        let payload = buildPayload(
            excluding: botID,
            extraSystem: "用户还没有明确方向。请你提出一个澄清问题，给出 3 到 5 个具体的选项供用户挑选。"
                + "如果这些选项可以并存、用户可能同时选多个，就把 multi 设为 true（多选）；"
                + "如果是互斥的、只能选一个，就把 multi 设为 false（单选）。",
            includeChoice: false)

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
                    // 按 sessionID 定位：生成标题期间用户可能已经切走，别改到别的对话上
                    self.mutateSession(sessionID) { s in
                        guard let first = s.messages.firstIndex(where: { $0.role == .user }) else { return }
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
            updateMessage(id) { m in
                m.text = question
                m.isChoice = true
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
            updateMessage(id) { m in
                m.text = q
                m.isChoice = true
            }
            return
        }

        // 3) 普通回复：只有「短问句」才当成在问用户。
        //    长答案即使最后一行是问号（比如带标题和代码块的技术答复），
        //    也应该留在对话区正常渲染 markdown，不能被当成问题挪走。
        guard text.hasSuffix("？") || text.hasSuffix("?") else { return }
        guard text.count <= 120, text.split(separator: "\n").count <= 3 else { return }
        pendingChoice = ChoiceRequest(question: text, options: [])
        updateMessage(id) { m in m.isChoice = true }
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

        // 按消息 id 找所属会话，而不是拿"当前会话"当目标：
        // 流式收尾的那一帧可能晚于用户切走/删掉对话，落在当前会话上就会
        // 给别的对话白刷一次 updatedAt（实测能把它顶到列表最前面）。
        func locate(_ id: UUID) -> (Int, Int)? {
            for (si, s) in sessions.enumerated() {
                if let mi = s.messages.firstIndex(where: { $0.id == id }) { return (si, mi) }
            }
            return nil
        }

        var touched = false
        var touchedSessions = Set<Int>()
        for (id, chunk) in pendingText {
            if let (si, mi) = locate(id) {
                sessions[si].messages[mi].text += chunk
                touchedSessions.insert(si)
                touched = true
            }
        }
        for (id, chunk) in pendingReasoning {
            if let (si, mi) = locate(id) {
                sessions[si].messages[mi].reasoning += chunk
                touchedSessions.insert(si)
                touched = true
            }
        }
        for (id, m) in pendingMetrics {
            if let (si, mi) = locate(id) {
                sessions[si].messages[mi].tps = m.tps
                sessions[si].messages[mi].promptTokens = m.promptTokens
                sessions[si].messages[mi].generatedTokens = m.generatedTokens
                sessions[si].messages[mi].promptTPS = m.promptTPS
                sessions[si].messages[mi].promptMS = m.promptMS
                sessions[si].messages[mi].perTokenMS = m.perTokenMS
                touchedSessions.insert(si)
                touched = true
            }
            if m.tps > 0 { lastTPS = m.tps }
        }
        if touched {
            for i in touchedSessions { sessions[i].updatedAt = Date() }
            scheduleSave()
        }
        pendingText.removeAll()
        pendingReasoning.removeAll()
        pendingMetrics.removeAll()
    }

    private func fail(_ id: UUID, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let si = self.sessions.firstIndex(where: { $0.messages.contains { $0.id == id } }),
                  let mi = self.sessions[si].messages.firstIndex(where: { $0.id == id }) else { return }
            self.sessions[si].messages[mi].failed = true
            self.sessions[si].messages[mi].text = self.sessions[si].messages[mi].text.isEmpty
                ? Lf("出错了：%@", message)
                : self.sessions[si].messages[mi].text + "\n\n" + Lf("（中断：%@）", message)
            self.sessions[si].updatedAt = Date()
            self.scheduleSave()
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
