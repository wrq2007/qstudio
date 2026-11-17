import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 配色

enum Palette {
    static let background = Color(red: 0.965, green: 0.965, blue: 0.955)
    static let card = Color.white
    static let border = Color.black.opacity(0.075)
    static let accent = Color(red: 0.22, green: 0.42, blue: 0.92)
    static let userBubble = Color(red: 0.22, green: 0.42, blue: 0.92)
    static let text = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let subtle = Color(red: 0.45, green: 0.45, blue: 0.48)
}

// MARK: - 根视图

struct ContentView: View {
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var chat: ChatStore

    @State private var verdict: Verdict?
    @State private var profile: MachineProfile?
    @State private var input: String = ""
    @FocusState private var inputFocused: Bool

    /// 取实际用于推理的显卡显存（优先独显，与 HardwareGate 的判定一致）
    private func gpuVRAM(_ p: MachineProfile) -> Double {
        (p.gpus.first { $0.isDiscrete })?.vramGB ?? p.gpus.first?.vramGB ?? 0
    }

    static let mdSample = """
    我们将使用 Python 编写一个简单的命令行计算器。它将支持基本的加减乘除运算。
    ### 功能特点：
    - 支持 `+`, `-`, `*`, `/` 四则运算。
    - 输入格式：例如 `5 + 3` 或 `10 / 2`。
    - 自动处理空格和运算符两侧的空白。
    - 如果输入错误（如非数字或格式错误），会给出提示。
    ### 代码实现：
    ```python
    def calculate():
    print("=== 简易命令行计算器 ===")
    while True:
    # 获取用户输入
    user_input = input("请输入表达式 (例如: 5 + 3): ").strip()
    if not user_input:
    break
    import re
    pattern = r'^(\\d+)\\s*([+\\-*/])\\s*(\\d+)$'
    match = re.match(pattern, user_input)
    if match:
    num1 = float(match.group(1))
    print(f"结果: {num1}")
    ```
    ### 使用方法：
    1. 将代码保存为 `calculator.py`（或其他 `.py` 文件名）。
    2. 在终端中运行：`python calculator.py`
    ### 注意事项：
    - 目前仅支持整数和浮点数（例如 `3.14`）。
    - 如果您需要支持更复杂的表达式（如括号、负数等），可以告诉我，我会进一步优化代码。

    """

    /// 用户实际模型输出的自检样例（MDSVGUSERTEST=1）
    static let svgUserSample = """
    这是碰撞示意图：
    <svg width="300" height="200" xmlns="http://www.w3.org/2000/svg">
    <rect width="100%" height="100%" fill="#87CEEB" />
    <rect x="0" y="100" width="150" height="100" fill="#8B4513" />
    <text x="75" y="175" font-family="Arial" font-size="16" fill="white" text-anchor="middle">大陆板块</text>
    <rect x="150" y="100" width="150" height="100" fill="#4682B4" />
    <text x="225" y="175" font-family="Arial" font-size="16" fill="white" text-anchor="middle">海洋板块</text>
    <path d="M 75 100 L 75 0 L 125 0 L 125 100" fill="none" stroke="#228B22" stroke-width="5" stroke-linecap="round" />
    <circle cx="90" cy="30" r="15" fill="white" />
    <text x="100" y="40" font-family="Arial" font-size="14" fill="black" text-anchor="middle" font-weight="bold">喜马拉雅山脉</text>
    <line x1="60" y1="150" x2="40" y2="150" stroke="black" stroke-width="2" stroke-dasharray="4,2" />
    <text x="20" y="155" font-family="Arial" font-size="12" fill="black">← 碰撞</text>
    <line x1="140" y1="150" x2="160" y2="150" stroke="black" stroke-width="2" stroke-dasharray="4,2" />
    <text x="180" y="155" font-family="Arial" font-size="12" fill="black">→ 碰撞</text>
    </svg>
    """

    /// SVG 渲染自检样例（MDSVGTEST=1）
    /// 沙箱自检用：故意塞满能外联/能执行的东西
    static let svgSecSample = """
    图里带了一堆不该生效的东西：
    <svg width="320" height="200" viewBox="0 0 320 200" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" onload="alert('onload')">
      <script>document.body.innerHTML='SCRIPT RAN'</script>
      <style>@import url(https://evil.example/a.css); .x{background:url(https://evil.example/b.png)}</style>
      <rect width="320" height="200" fill="#eef2ff"/>
      <rect class="x" x="20" y="20" width="280" height="120" rx="10" fill="#c7d2fe"/>
      <defs><linearGradient id="g"><stop offset="0" stop-color="#4f46e5"/><stop offset="1" stop-color="#a855f7"/></linearGradient></defs>
      <circle cx="70" cy="80" r="26" fill="url(#g)"/>
      <image x="140" y="50" width="60" height="60" href="https://evil.example/leak.png"/>
      <image x="220" y="50" width="60" height="60" xlink:href="https://evil.example/leak2.png"/>
      <text x="160" y="175" font-family="Helvetica" font-size="14" fill="#1e1b4b" text-anchor="middle">若脚本生效，这张图会消失</text>
    </svg>
    """

    static let svgSample = """
    这是一张地层剖面示意图：
    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" width="420" height="200" viewBox="0 0 420 200">
      <rect width="420" height="200" fill="#faf6ee"/>
      <rect x="30" y="20" width="360" height="34" rx="3" fill="#c8a165"/>
      <text x="42" y="43" font-size="13" fill="#fff">表土层 · 第四系</text>
      <rect x="30" y="54" width="360" height="42" fill="#9b7653"/>
      <text x="42" y="80" font-size="13" fill="#fff">砂岩 · 白垩系</text>
      <rect x="30" y="96" width="360" height="46" fill="#6e7b6f"/>
      <text x="42" y="124" font-size="13" fill="#fff">泥岩 · 侏罗系</text>
      <rect x="30" y="142" width="360" height="38" rx="3" fill="#4a5a6a"/>
      <text x="42" y="167" font-size="13" fill="#fff">灰岩 · 三叠系</text>
    </svg>
    ```
    每层厚度按实际野外记录等比例绘制。
    """

    var body: some View {
        Group {
            if let verdict {
                switch verdict {
                case .supported(let gpu, let warning):
                    ChatView(gpu: gpu, warning: warning, input: $input, inputFocused: $inputFocused)
                case .refused(let title, let reason):
                    RefusedView(title: title, reason: reason, profile: profile)
                }
            } else {
                ProgressView("检测硬件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background)
            }
        }
        .onAppear {
            let p = HardwareGate.probe()
            profile = p
            let v = HardwareGate.evaluate(p)
            verdict = v
            if v.isSupported {
                server.setGPU(vramGB: gpuVRAM(p))
                let env = ProcessInfo.processInfo.environment
                if env["MDMODELTEST"] == nil {
                    server.start()
                }
                inputFocused = true
            }
            if ProcessInfo.processInfo.environment["MDSELFTEST"] == "1" {
                chat.appendMessage(ChatMessage(role: .user, text: "帮我整理这份野外记录"))
                chat.appendMessage(ChatMessage(role: .assistant, text: Self.mdSample, tps: 20.4))
            }
            if ProcessInfo.processInfo.environment["MDSVGTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDSVGTEST") {
                chat.appendMessage(ChatMessage(role: .user, text: "画个示意图"))
                chat.appendMessage(ChatMessage(role: .assistant, text: Self.svgSample, tps: 18.2))
            }
            if ProcessInfo.processInfo.environment["MDSVGUSERTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDSVGUSERTEST") {
                chat.appendMessage(ChatMessage(role: .user, text: "画板块碰撞图"))
                chat.appendMessage(ChatMessage(role: .assistant, text: Self.svgUserSample, tps: 18.2))
            }
            if ProcessInfo.processInfo.environment["MDSVGSECTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDSVGSECTEST") {
                // 恶意 SVG：脚本、事件属性、外链图片、CSS 外链全给上，验证都不生效
                chat.appendMessage(ChatMessage(role: .user, text: "画个示意图"))
                chat.appendMessage(ChatMessage(role: .assistant, text: Self.svgSecSample, tps: 18.2))
                SVGView.selfTestDump(Self.svgSecSample)
            }
            if ProcessInfo.processInfo.environment["MDSIDEBARTEST"] == "1" {
                chat.seedDemoSessions()
            }
            if ProcessInfo.processInfo.environment["MDGROUPTEST"] == "1" {
                chat.seedDemoSessions()
                let g1 = chat.createGroup(name: "地质作业")
                let g2 = chat.createGroup(name: "论文资料")
                let ids = chat.sessions.filter { !$0.archived }.prefix(4).map { $0.id }
                if ids.count >= 1 { chat.assign(ids[0], to: g1) }
                if ids.count >= 2 { chat.assign(ids[1], to: g1) }
                if ids.count >= 3 { chat.assign(ids[2], to: g2) }
            }
            if ProcessInfo.processInfo.environment["MDTEXTTEST"] == "1" {
                input = "光标应该和这行提示词左边缘对齐"
            }
            if ProcessInfo.processInfo.environment["MDCHATTEST"] == "1" {
                // 等服务就绪后自动发一条，用来核对上下文占用条
                var tries = 0
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                    tries += 1
                    if server.state.isReady {
                        t.invalidate()
                        chat.send("用两句话说明板块构造理论", server: server)
                    } else if tries > 180 {
                        t.invalidate()
                    }
                }
            }
        }
    }
}

// MARK: - 拒绝安装页
private struct RefusedView: View {
    let title: String
    let reason: String
    let profile: MachineProfile?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.subtle)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let p = profile {
                VStack(alignment: .leading, spacing: 6) {
                    row("处理器", p.cpu)
                    row("系统", "macOS " + p.macos)
                    ForEach(p.gpus) { g in
                        row("显卡", "\(g.name) · \(g.vendorLabel) · \(g.metalFamily) · \(String(format: "%.1f", g.vramGB)) GB")
                    }
                    if p.gpus.isEmpty {
                        row("显卡", "未检测到 Metal 加速器")
                    }
                }
                .padding(14)
                .frame(maxWidth: 440, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border))
            }

            Text("适用范围：Intel x86_64 处理器 + AMD 独立显卡（Polaris / Vega / Navi），macOS 14 及以上。")
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(L(key))
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.subtle)
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 主聊天界面

private struct ChatView: View {
    let gpu: GPUInfo
    let warning: String?
    @State private var warningDismissed = false

    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var chat: ChatStore

    @Binding var input: String
    @FocusState.Binding var inputFocused: Bool

    @State private var showLog = false
    @State private var showModelPicker = false
    @State private var showContextPicker = false
    @State private var showSettings = false
    @State private var pendingContextSize: Int?
    @State private var selectedOptions: Set<Int> = []
    @State private var otherText: String = ""
    @State private var showOtherInput = false

    /// "其他/补充/other"这类选项不直接提交，而是展开输入框让用户自己填
    private func isOtherOption(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("其他") || l.contains("其它") || l.contains("补充") || l.contains("other")
    }

    /// 提交问题卡片里选中的选项 + 用户自填的内容
    private func submitChoice(_ choice: ChoiceRequest) {
        var picked = choice.options.enumerated()
            .filter { selectedOptions.contains($0.offset) && !isOtherOption($0.element) }
            .map { $0.element }
        let extra = otherText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { picked.append(extra) }
        selectedOptions = []
        otherText = ""
        showOtherInput = false
        chat.pendingChoice = nil
        guard !picked.isEmpty else { return }
        chat.answerChoice(ChoiceRequest.answerText(picked), server: server)
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()

            // 侧栏与对话区之间的竖分割线
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 1)

            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)
                if let warning, !warningDismissed {
                    performanceWarning(warning)
                }
                conversation
                if case .failed(let msg) = server.state {
                    failureBar(msg)
                }
                if let warning = chat.dataWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text(warning)
                            .font(.system(size: 10.5))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            chat.dismissDataWarning()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color(red: 0.6, green: 0.35, blue: 0.05))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(red: 0.98, green: 0.9, blue: 0.75))
                }
                composer
            }
        }
        .background(Palette.background)
        // 界面是按浅色设计的。系统若是深色模式，系统绘制的菜单/浮层会变成深色，
        // 跟界面打架，所以整个 app 强制浅色（跟 WorkBuddy 一致）。
        .preferredColorScheme(.light)
        .onExitCommand {
            showContextPicker = false
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(server)
                .environmentObject(chat)
                .localized()
        }
        .confirmationDialog(
            L("显存可能不够"),
            isPresented: Binding(
                get: { pendingContextSize != nil },
                set: { if !$0 { pendingContextSize = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(Lf("仍然改用 %@", pendingContextSize.map { "\($0 / 1024)K" } ?? "")) {
                if let size = pendingContextSize { server.setContextSize(size) }
                pendingContextSize = nil
                showContextPicker = false
            }
            Button(L("取消"), role: .cancel) { pendingContextSize = nil }
        } message: {
            if let a = server.contextAdvice, let size = pendingContextSize {
                let kv = Double(a.info.kvBytesPerToken * size) / 1_073_741_824
                Text(Lf("显存 %@ GB 装不下 %@K 的 KV 缓存（约 %@ GB）。模型可能加载失败或回退到内存，速度大降。建议不超过 %@K。",
                        String(format: "%.0f", a.vramGB),
                        "\(size / 1024)",
                        String(format: "%.1f", kv),
                        "\(a.maxContext / 1024)"))
            }
        }
        .onAppear {
            // 自检开关：直接弹出模型管理页，方便截图核对界面
            if ProcessInfo.processInfo.environment["MDMODELTEST"] != nil
                || UserDefaults.standard.bool(forKey: "MDModelPicker") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showModelPicker = true }
            }
            if ProcessInfo.processInfo.environment["MDCTXTEST"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showContextPicker = true }
            }
            if ProcessInfo.processInfo.environment["MDCHOICETEST"] == "1" {
                chat.pendingChoice = ChoiceRequest(
                    question: "你想从哪几个方面深入？",
                    options: ["效率提升与系统搭建", "应对拖延与专注力管理", "优先级排序与目标拆解", "工作与生活的平衡", "其他补充…"],
                    multiSelect: true)
            }
            let instTest = ProcessInfo.processInfo.environment["MDINSTTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDINSTTEST")
            if instTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showSettings = true }
            }
            if ProcessInfo.processInfo.environment["MDASKTEST"] == "1" {
                // 等服务就绪后让模型反问一次，验证问题卡片
                var tries = 0
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                    tries += 1
                    if server.state.isReady {
                        t.invalidate()
                        chat.appendMessage(ChatMessage(role: .user, text: "帮我整理这份野外记录"))
                        chat.askOptions(server: server)
                    } else if tries > 180 {
                        t.invalidate()
                    }
                }
            }
        }
    }

    // MARK: 顶栏

    /// 硬件性能提示横幅：不阻塞使用，可关闭
    private func performanceWarning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.92, green: 0.62, blue: 0.13))
            VStack(alignment: .leading, spacing: 3) {
                Text("硬件性能提示")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button { warningDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(red: 0.92, green: 0.62, blue: 0.13).opacity(0.10))
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.current?.displayTitle ?? L("新对话"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.subtle)
                        .lineLimit(1)
                }
                .help("\(server.state.label) · \(gpu.name)")
            }

            Spacer()

            Menu {
                Button(L("压缩上下文")) { chat.compact(server: server) }
                    .disabled(chat.isCompacting)
                Divider()
                Button("重新加载模型") { server.restart() }
                Button("查看运行日志") { showLog.toggle() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
            .help("更多")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.background)
        .sheet(isPresented: $showModelPicker) {
            ModelManagerView(current: server.modelPath, vramGB: gpu.vramGB)
                .localized()
        }
        .sheet(isPresented: $showLog) {
            LogView(log: server.log)
                .localized()
        }
        .sheet(item: Binding(
            get: { chat.roleEditorSessionID.map { RoleEditTarget(id: $0) } },
            set: { if $0 == nil { chat.roleEditorSessionID = nil } }
        )) { target in
            RolePromptSheet(sessionID: target.id)
                .environmentObject(chat)
                .localized()
        }
        .sheet(isPresented: $showSampling) {
            SamplingSheet(sessionID: chat.currentID)
                .environmentObject(chat)
                .localized()
        }
        .sheet(item: Binding(
            get: { chat.editingMessageID.map { RoleEditTarget(id: $0) } },
            set: { if $0 == nil { chat.editingMessageID = nil } }
        )) { target in
            MessageEditSheet(messageID: target.id)
                .environmentObject(chat)
                .environmentObject(server)
                .localized()
        }
        .confirmationDialog(L("删除这条消息？"), isPresented: Binding(
            get: { chat.pendingDeleteMessageID != nil },
            set: { if !$0 { chat.pendingDeleteMessageID = nil } }
        ), titleVisibility: .visible) {
            Button(L("删除"), role: .destructive) {
                if let id = chat.pendingDeleteMessageID { chat.deleteMessage(id) }
                chat.pendingDeleteMessageID = nil
            }
            Button(L("取消"), role: .cancel) { chat.pendingDeleteMessageID = nil }
        } message: {
            Text(L("只删这一条，其他消息不受影响。对话历史里少一段上下文，之后的回答可能不如原来连贯。"))
        }
    }

    /// 模型文件名往往很长，顶栏只显示掐头去尾的缩写
    private var shortModelName: String {
        let n = server.modelName
        if n.count <= 30 { return n }
        return String(n.prefix(18)) + "…" + String(n.suffix(10))
    }

    private var statusLine: String {
        // 速度只在输出气泡里显示（消息下方的 x tok/s），顶栏不再重复
        [shortModelName, server.state.label].joined(separator: " · ")
    }

    private var statusColor: Color {
        switch server.state {
        case .ready:    return Color(red: 0.18, green: 0.68, blue: 0.35)
        case .starting: return Color(red: 0.95, green: 0.62, blue: 0.13)
        case .failed:   return Color(red: 0.85, green: 0.25, blue: 0.25)
        case .stopped:  return Palette.subtle.opacity(0.5)
        }
    }

    // MARK: 对话区

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages.filter { !$0.isChoice }) { msg in
                        MessageRow(
                            message: msg,
                            streaming: chat.isStreaming && msg.id == chat.messages.last?.id,
                            isLast: msg.id == chat.messages.last(where: { !$0.isChoice })?.id
                        )
                    }
                    // 底部哨兵：用它在 scroll 坐标系里的位置判断用户是否还贴着底部
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomOffsetKey.self,
                                value: g.frame(in: .named("chatScroll")).minY)
                        })
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .coordinateSpace(name: "chatScroll")
            .background(GeometryReader { g in
                Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(ViewportHeightKey.self) { scrollViewportHeight = $0 }
            .onPreferenceChange(BottomOffsetKey.self) { offset in
                // 哨兵 minY <= 可视区高度 + 60 视为「贴底」，留 60pt 容差
                autoScroll = offset <= scrollViewportHeight + 60
            }
            .onChange(of: chat.messages.last?.text) {
                if autoScroll {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: chat.messages.count) {
                if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// 用户往上滚动后暂停自动跟随；回到底部会自动恢复（由 onPreferenceChange 判定）
    @State private var autoScroll = true
    @State private var scrollViewportHeight: CGFloat = 600

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(Palette.accent)
                Text("所有计算都在本机完成，不联网")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.subtle)
            }
            Text("试着问点什么")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        input = L(s)
                        send()
                    } label: {
                        Text(L(s))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var suggestions: [String] {
        ["用三句话解释板块运动", "写一个 Python 的快速排序", "玄武岩和花岗岩成因上有什么区别？"]
    }

    private func failureBar(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("重试") { server.restart() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            DisclosureGroup("运行日志") {
                ScrollView {
                    Text(server.tailLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
            .font(.system(size: 11))
        }
        .padding(12)
        .background(Color(red: 1.0, green: 0.96, blue: 0.94))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.border), alignment: .top)
    }

    // MARK: 上下文

    /// token 数用「几K」显示
    private func kFormat(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k >= 10 ? "\(Int(k.rounded()))K" : String(format: "%.1fK", k)
    }

    /// 上下文长度（2K / 4K / 8K …）
    private var ctxLabel: String {
        let n = server.contextSize
        if n >= 1024, n % 1024 == 0 { return "\(n / 1024)K" }
        return "\(n)"
    }

    /// 当前上下文占用：圆环 + 已用/上限
    private var contextUsage: some View {
        let used = chat.contextUsed
        let total = server.contextSize
        let ratio = total > 0 ? min(1.0, Double(used) / Double(total)) : 0

        let warn = ratio > 0.7 ? (ratio > 0.9 ? Color(red: 0.85, green: 0.25, blue: 0.25)
                                              : Color(red: 0.85, green: 0.58, blue: 0.10))
                               : Palette.accent

        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Palette.subtle.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(warn, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)

            Text("\(kFormat(used)) / \(ctxLabel)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ratio > 0.7 ? warn : Palette.subtle)
                .fixedSize()

            // 快到上限时给一句人话，光看数字很多人不会换算
            if ratio > 0.9 {
                Button {
                    chat.compact(server: server)
                } label: {
                    Text("压缩一下")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(warn)
                        .underline()
                }
                .buttonStyle(.plain)
                .help(L("把早前的对话压成摘要，腾出上下文"))
            } else if ratio > 0.7 {
                Text("\(Int(ratio * 100))%")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(warn)
                    .fixedSize()
            }
        }
        .help(ratio > 0.9
              ? Lf("已占用 %@ / %@ tokens（%@%%）。接近上限，回答开始被截断，建议开新对话或输入 /compact 压缩。",
                   "\(used)", "\(total)", "\(Int(ratio * 100))")
              : Lf("已占用 %@ / %@ tokens", "\(used)", "\(total)"))
    }

    private var contextPickerList: some View {
        let advice = server.contextAdvice

        return VStack(alignment: .leading, spacing: 0) {
            if let a = advice {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.13))
                        Text("\(L("建议")) \(a.recommended / 1024)K")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Palette.text)
                    }
                    Text("\(L("显存")) \(String(format: "%.0f", a.vramGB)) GB，\(L("权重")) \(String(format: "%.1f", a.weightsGB)) GB，"
                         + "\(L("KV 缓存")) \(String(format: "%.2f", a.kvGB)) GB")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                    if a.recommended != server.contextSize {
                        Button {
                            chooseContext(a.recommended)
                        } label: {
                            Text("\(L("改用推荐的")) \(a.recommended / 1024)K")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 6)

                Divider().padding(.horizontal, 9).padding(.bottom, 3)
            }

            ForEach(ServerController.contextOptions, id: \.self) { size in
                Button {
                    chooseContext(size)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: size == server.contextSize ? "checkmark" : "")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 13)
                        Text("\(size / 1024)K")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.text)
                        if let a = advice, a.recommended == size {
                            Text("推荐")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(Color(red: 0.95, green: 0.62, blue: 0.13))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color(red: 0.95, green: 0.62, blue: 0.13).opacity(0.15)))
                        }
                        Spacer(minLength: 4)
                        if size == server.contextSize {
                            Text("当前")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Palette.subtle)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 4).padding(.horizontal, 9)
            Text("KV 缓存随长度线性增长，改完会重新加载模型")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.subtle)
                .padding(.horizontal, 9)
                .padding(.bottom, 5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: 候选方向模块

    /// WorkBuddy 风格的交互问题卡片：标题 + 页码/关闭 + 复选框选项 + 提交按钮
    /// 单选点一行就发；多选勾选后点右下角箭头一起发。
    private var choiceModule: some View {
        Group {
            if let choice = chat.pendingChoice {
                VStack(alignment: .leading, spacing: 0) {
                    // 标题行 + 右上角页码与关闭
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        MarkdownView(source: choice.question,
                                     baseSize: 13,
                                     textColor: Palette.text,
                                     fillsWidth: false)
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 10))
                                .foregroundStyle(Palette.subtle.opacity(0.5))
                            Text("1/1").font(.system(size: 10.5))
                                .foregroundStyle(Palette.subtle)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                                .foregroundStyle(Palette.subtle.opacity(0.5))
                            Button {
                                selectedOptions = []
                                chat.pendingChoice = nil
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 11))
                                    .foregroundStyle(Palette.subtle)
                            }
                            .buttonStyle(.plain)
                            .help("关掉，继续正常对话")
                        }
                    }
                    .padding(.bottom, 10)

                    // 选项列表：方形复选框 + 文字，行间细分隔线
                    if !choice.options.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(choice.options.enumerated()), id: \.offset) { idx, opt in
                                let isOn = selectedOptions.contains(idx)
                                Button {
                                    if isOtherOption(opt) {
                                        // 其他/补充 → 展开输入框，不直接发
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            showOtherInput.toggle()
                                            if choice.multiSelect {
                                                if isOn { selectedOptions.remove(idx) }
                                                else { selectedOptions.insert(idx) }
                                            } else {
                                                selectedOptions = [idx]
                                            }
                                        }
                                    } else if choice.multiSelect {
                                        if isOn { selectedOptions.remove(idx) }
                                        else { selectedOptions.insert(idx) }
                                    } else {
                                        selectedOptions = []
                                        chat.pendingChoice = nil
                                        chat.answerChoice(opt, server: server)
                                    }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: isOn ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 15))
                                            .foregroundStyle(isOn ? Palette.accent : Palette.subtle.opacity(0.6))
                                        Text(opt)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Palette.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                    }
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if idx < choice.options.count - 1 {
                                    Divider().opacity(0.5)
                                }
                            }
                        }

                        // 选了「其他/补充」时展开输入框，让用户自己填
                        if showOtherInput {
                            HStack(spacing: 6) {
                                TextField("补充说明…", text: $otherText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.background))
                            }
                            .padding(.top, 8)
                        }

                        // 底部：提示 + 圆形提交按钮
                        let hasInput = !otherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let canSubmit = !selectedOptions.isEmpty || hasInput
                        HStack {
                            Text(choice.multiSelect ? "可多选，选完点右下角发送" : "选一项，也可以直接在下面输入引导")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.subtle)
                            Spacer()
                            if choice.multiSelect || showOtherInput {
                                Button {
                                    submitChoice(choice)
                                } label: {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 27, height: 27)
                                        .background(Circle().fill(canSubmit ? Palette.accent : Palette.subtle.opacity(0.3)))
                                }
                                .buttonStyle(.plain)
                                .disabled(!canSubmit)
                            }
                        }
                        .padding(.top, 9)
                    } else {
                        Text("直接在下面输入来引导模型")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.subtle)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border.opacity(0.6)))
                .shadow(color: Color.black.opacity(0.06), radius: 10, y: 3)
                .onChange(of: chat.pendingChoice?.question) { _, _ in
                    selectedOptions = []
                    otherText = ""
                    showOtherInput = false
                }
            }
        }
    }

    // MARK: 输入区

    @State private var inputHeight: CGFloat = PlainTextEditor.minHeight
    @State private var showSampling = false

    private var composer: some View {
        VStack(spacing: 8) {
            // 候选方向模块：在输入栏上方
            choiceModule

            // 命令反馈（压缩失败、对话太短……）只停几秒，不占对话区
            commandNoteBar

            // 压缩进行中：给个进度，别让用户以为卡住了
            compactionBar

            // 这段对话有角色提示词时挂一条，能看到它生效了（点开是本对话的编辑器）
            if let role = chat.current?.rolePrompt,
               !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 9.5))
                    Text(role)
                        .lineLimit(1)
                    Button {
                        chat.openRoleEditor(chat.currentID)
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .help(L("编辑这段对话的角色提示词"))
                }
                .font(.system(size: 10))
                .foregroundStyle(Palette.subtle)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.accent.opacity(0.07))
                )
            }

            // 输入 "/" 时列出可用命令
            slashPanel

            VStack(alignment: .leading, spacing: 8) {
                PlainTextEditor(
                    text: $input,
                    focused: $inputFocused,
                    font: .systemFont(ofSize: 13),
                    textColor: NSColor(Palette.text),
                    placeholder: L("说点什么…"),
                    onSubmit: send,
                    onHeightChange: { h in
                        if abs(h - inputHeight) > 0.5 { inputHeight = h }
                    }
                )
                .frame(height: inputHeight)

                // 工具条：跟 WorkBuddy 一个思路，上下文调节就放这儿，不藏菜单
                HStack(spacing: 10) {
                    Button {
                        showModelPicker = true
                    } label: {
                        Image(systemName: "cube.box")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(ToolButtonStyle())
                    .help("模型管理")

                    Button {
                        showContextPicker.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 10.5))
                            Text("\(L("上下文")) \(ctxLabel)")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Palette.text.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.subtle.opacity(showContextPicker ? 0.16 : 0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("调整上下文长度")

                    // 采样参数：三档预设放在菜单里，细调开高级面板
                    Menu {
                        ForEach(SamplingParams.Preset.allCases) { preset in
                            Button {
                                chat.setSampling(preset.params, for: chat.currentID)
                            } label: {
                                let cur = chat.sampling(for: chat.currentID)
                                Text(cur.preset == preset ? "✓ \(preset.label)" : preset.label)
                            }
                        }
                        Divider()
                        Button(L("高级…")) { showSampling = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 10.5))
                            Text("\(L("采样")) \(chat.sampling(for: chat.currentID).summary)")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Palette.text.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Palette.subtle.opacity(0.08))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("调整采样参数：温度、Top-K、重复惩罚等"))

                    Spacer(minLength: 6)

                    contextUsage

                    // 深度思考开关：控制模型是否输出思维链（切换会重载模型）
                    Button {
                        server.setThinking(!server.thinkEnabled)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.system(size: 11))
                            Text("深度思考")
                                .font(.system(size: 10.5))
                        }
                        .foregroundStyle(server.thinkEnabled ? Palette.accent : Palette.subtle)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(server.thinkEnabled
                                      ? Palette.accent.opacity(0.14)
                                      : Palette.subtle.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(server.thinkEnabled ? L("关闭深度思考（会重载模型）") : L("开启深度思考，显示推理过程（会重载模型）"))

                    Button {
                        if chat.isStreaming { chat.stop() } else { send() }
                    } label: {
                        Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(canSend || chat.isStreaming
                                              ? Palette.accent
                                              : Palette.subtle.opacity(0.25))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend && !chat.isStreaming)
                    .help(chat.isStreaming ? L("停止生成（也可以直接在下面输入来引导）") : L("发送（Enter）"))
                }
                // 浮层用 overlay，不参与布局——否则面板会把输入框撑长
                .overlay(alignment: .bottomLeading) {
                    if showContextPicker {
                        contextPickerList
                            .frame(width: 228, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.card))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.border))
                            .shadow(color: Color.black.opacity(0.16), radius: 12, y: 3)
                            .offset(x: 30, y: -30)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))

            HStack(spacing: 6) {
                Text("全部计算在本机完成，不联网")
                Text("·")
                Text("输入 / 查看命令")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Palette.subtle.opacity(0.75))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var commandNoteBar: some View {
        if let note = chat.commandNote {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(note)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { chat.dismissCommandNote() } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.subtle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.subtle.opacity(0.08)))
        }
    }

    @ViewBuilder
    private var compactionBar: some View {
        if chat.isCompacting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                    .frame(width: 14, height: 14)
                Text("正在压缩上下文…")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                Spacer(minLength: 6)
                Button(L("取消")) { chat.cancelCompaction() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent.opacity(0.07)))
        }
    }

    /// 输入框里以 / 开头时，列出匹配的命令
    private var slashQuery: String? {
        guard !input.contains("\n") else { return nil }
        let t = input.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("/") else { return nil }
        return t.lowercased()
    }

    private var slashMatches: [(usage: String, detail: String)] {
        guard let q = slashQuery else { return [] }
        return SlashCommand.catalog.filter { $0.usage.hasPrefix(q) }
    }

    @ViewBuilder
    private var slashPanel: some View {
        let items = slashMatches
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    Button {
                        input = ""
                        chat.send(item.usage, server: server)
                        inputFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(item.usage)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Palette.text)
                            Text(L(item.detail))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.subtle)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("⏎")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Palette.subtle.opacity(0.6))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < items.count - 1 { Divider().opacity(0.5) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.border))
        }
    }

    /// 选上下文档位：超过显存能承载的上限时先弹确认，避免直接加载失败
    private func chooseContext(_ size: Int) {
        if let a = server.contextAdvice, size > a.maxContext, a.maxContext > 0 {
            pendingContextSize = size
        } else {
            server.setContextSize(size)
            showContextPicker = false
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input = ""
        chat.send(text, server: server)
        // 发送后把焦点交还输入框：点发送按钮会让它失焦，而 @FocusState 没绑到具体视图
        // 不会自己变，导致之后打字打不进去。false→true 才能触发 updateNSView 重新抢焦点。
        inputFocused = false
        DispatchQueue.main.async { inputFocused = true }
    }}

// MARK: - 滚动位置偏好键

/// .sheet(item:) 需要一个 Identifiable 的载体，这里把会话 id 包一层
private struct RoleEditTarget: Identifiable { let id: UUID }

private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 600
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - 消息气泡

private struct MessageRow: View {
    let message: ChatMessage
    let streaming: Bool
    /// 这条是不是最后一条（「继续生成」只在最后一条上有意义）
    let isLast: Bool

    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var server: ServerController

    /// 单行短消息要让气泡贴合文字；多行/含代码表格的交给 560 上限换行
    private var isShortBubble: Bool {
        let t = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains("\n") && !t.contains("```") && !t.contains("|") && !t.contains("<svg") && t.count < 80
    }

    var body: some View {
        if message.isSummaryBubble {
            summaryCard
        } else {
            bubble
        }
    }

    /// 普通消息气泡
    private var bubble: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 70) }

            VStack(alignment: .leading, spacing: 7) {
                if !message.reasoning.isEmpty {
                    DisclosureGroup("思考过程") {
                        Text(message.reasoning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.subtle)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 5)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.subtle)
                }

                if message.text.isEmpty && streaming {
                    TypingDots()
                } else {
                    MarkdownView(
                        source: message.text + (streaming ? " ▍" : ""),
                        baseSize: 13.5,
                        textColor: message.role == .user ? .white : Palette.text,
                        accentText: message.role == .user,
                        fillsWidth: false
                    )
                }

                if !streaming { metricsBar(message) }
            }
            // 短消息（无换行/代码/表格）：先 fixedSize 让视图贴合文字，frame 不设上限，
            // 背景就画在内容宽度上，不再撑满整行。
            // 长消息：才用 560 封顶并允许换行，否则会溢出屏幕。
            .fixedSize(horizontal: isShortBubble, vertical: !isShortBubble)
            .frame(maxWidth: isShortBubble ? nil : 560, alignment: .leading)
            // 助手气泡留足内边距：文字贴着气泡顶边/侧边会显得很挤
            .padding(.horizontal, message.role == .assistant ? 18 : 13)
            .padding(.top, message.role == .assistant ? 16 : 10)
            .padding(.bottom, message.role == .assistant ? 15 : 10)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(message.role == .user ? Palette.userBubble : Palette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(message.role == .user ? Color.clear : (message.failed ? Color.red.opacity(0.35) : Palette.border))
            )

            if message.role == .assistant { Spacer(minLength: 70) }
        }
        .contextMenu { messageMenu }
    }

    /// 压缩摘要卡片：跟普通回答区分开——它是"前情提要"，不是模型这一轮说的话
    @State private var expandedSummary = false

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("上下文已压缩")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                if let n = message.summaryCount, n > 0 {
                    Text(Lf("%lld 条消息 → 摘要", n))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.subtle)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { expandedSummary.toggle() }
                } label: {
                    Text(expandedSummary ? L("收起") : L("展开"))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
            }

            if expandedSummary {
                MarkdownView(source: message.text,
                             baseSize: 12.5,
                             textColor: Palette.text,
                             fillsWidth: true)
            } else {
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.subtle)
                    .lineSpacing(2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent.opacity(0.22)))
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Label("复制摘要", systemImage: "doc.on.doc")
            }
        }
    }

    @ViewBuilder
    private var messageMenu: some View {
        if message.role == .assistant {
            Button {
                chat.regenerate(message.id, server: server)
            } label: {
                Label("重新生成", systemImage: "arrow.clockwise")
            }
            if isLast && !chat.isStreaming {
                Button {
                    chat.continueGeneration(server: server)
                } label: {
                    Label("继续生成", systemImage: "arrow.down.to.line")
                }
            }
        } else {
            Button {
                chat.editingMessageID = message.id
            } label: {
                Label("编辑并重发…", systemImage: "square.and.pencil")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
        } label: {
            Label("复制", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) {
            chat.pendingDeleteMessageID = message.id
        } label: {
            Label("删除这条", systemImage: "trash")
        }
    }

    /// 气泡下方的推理指标条：decode / prefill 速率、token 进出、prefill 耗时、单 token 延迟
    private func metricsText(_ m: ChatMessage) -> String {
        var parts: [String] = []
        if m.tps > 0 { parts.append(String(format: "DECODE %.1f t/s", m.tps)) }
        if m.promptTPS > 0 { parts.append(String(format: "PREFILL %.1f t/s", m.promptTPS)) }
        if m.promptTokens > 0 || m.generatedTokens > 0 {
            parts.append("\(m.promptTokens)→\(m.generatedTokens) tok")
        }
        if m.promptMS > 0 { parts.append(String(format: "TTFT %.0f ms", m.promptMS)) }
        if m.perTokenMS > 0 { parts.append(String(format: "%.1f ms/tok", m.perTokenMS)) }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder
    private func metricsBar(_ m: ChatMessage) -> some View {
        let text = metricsText(m)
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(m.role == .user ? Color.white.opacity(0.6) : Palette.subtle.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TypingDots: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Palette.subtle.opacity(phase == i ? 0.85 : 0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.vertical, 3)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - 日志窗口

private struct LogView: View {
    let log: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("运行日志").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(.plain).foregroundStyle(Palette.subtle)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(log.isEmpty ? "（暂无输出）" : log)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.subtle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 640, height: 420)
    }
}

// MARK: - 小组件

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundStyle(configuration.isPressed ? Palette.accent : Palette.subtle)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }
}

/// 输入框工具条上的小图标按钮
private struct ToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Palette.accent : Palette.subtle)
            .frame(width: 22, height: 20)
            .contentShape(Rectangle())
    }
}

// MARK: - 结束
