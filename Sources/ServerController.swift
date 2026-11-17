import Foundation
import Combine
import AppKit

enum ServerState: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .stopped:  return L("已停止")
        case .starting: return L("加载模型…")
        case .ready:    return L("就绪")
        case .failed:   return L("启动失败")
        }
    }

    var isBusy: Bool {
        if case .starting = self { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

final class ServerController: ObservableObject {
    static let shared = ServerController()

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var log: String = ""
    @Published var modelPath: String
    @Published var thinkEnabled: Bool

    /// 开关已经改过、但还没落到进程上（生成结束后才重载）。
    /// 界面据此提示「下一轮生效」，避免用户以为点一下当场就变了。
    @Published private(set) var thinkPendingApply = false

    /// 当前进程启动时用的开关值：用户来回点两次能靠它判断"其实不用重启"
    private var activeThink = false
    @Published private(set) var gpuName: String = ""
    @Published private(set) var contextSize: Int = 8192

    /// 当前显卡显存（界面注入），用来推算合适的上下文长度
    @Published private(set) var vramGB: Double = 0

    /// 当前模型的架构信息（从 GGUF 文件头读的），KV 缓存按真实参数算
    @Published private(set) var modelInfo: GGUFInfo?

    /// KV 缓存量化开关：q8_0 省一半 KV 显存，8 GB 机器上上下文能开大一倍
    @Published private(set) var kvQuant: Bool

    /// 这次启动 KV 量化是否真的生效（架构不支持或用户关掉时为 false）
    @Published private(set) var kvQuantActive: Bool = false

    /// 量化导致启动失败后自动回退了一次，界面据此提示用户
    @Published private(set) var kvQuantFellBack: Bool = false

    /// 量化失败过一次：本次启动先不用量化重试（用户手动重启后清空）
    private var suppressQuant = false

    /// 最近一次真正传给推理进程的参数（自检用）
    private(set) var lastArguments: [String] = []
    private var kvFallbackTried = false

    /// 上下文长度可选档位。KV 缓存随上下文线性增长，显存吃紧时别往上调。
    static let contextOptions = [2048, 4096, 8192, 16384, 32768]

    let port = 8080

    private var process: Process?
    private var pipe: Pipe?
    private var pollTimer: Timer?
    private var startedAt: Date?
    private var pendingNotice: String?

    let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 900
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "modelPath") ?? ""
        if !saved.isEmpty, FileManager.default.fileExists(atPath: saved) {
            modelPath = saved
        } else {
            modelPath = ServerController.discoverModels().first?.path ?? ""
        }
        if defaults.object(forKey: "thinkEnabled") == nil {
            defaults.set(false, forKey: "thinkEnabled")
        }
        thinkEnabled = defaults.bool(forKey: "thinkEnabled")
        if defaults.object(forKey: "kvQuant") == nil {
            defaults.set(true, forKey: "kvQuant")   // 默认开：省显存，质量损失可忽略
        }
        kvQuant = defaults.bool(forKey: "kvQuant")

        let savedCtx = defaults.integer(forKey: "contextSize")
        if savedCtx > 0, ServerController.contextOptions.contains(savedCtx) {
            contextSize = savedCtx
        }
        refreshModelInfo()
    }

    /// 显卡信息由界面探测后注入
    func setGPU(vramGB: Double) {
        guard abs(self.vramGB - vramGB) > 0.01 else { return }
        self.vramGB = vramGB
    }

    /// 实际生效的 KV 精度：只有用户开着、且架构支持时才是 q8_0
    var activeKVType: GGUFInfo.KVType {
        // 回退过、或被抑制时实际生效的是 fp16——估算要跟着实际走，否则会低估显存
        (kvQuant && !kvQuantFellBack && !suppressQuant
            && Self.kvQuantSupported(architecture: modelInfo?.architecture, name: modelName))
            ? .q8_0 : .fp16
    }

    /// 当前模型是否支持 KV 量化。
    /// 线性注意力 / 状态空间模型（Mamba、RWKV、Jamba、Falcon-H1）没有常规 KV 缓存，
    /// 量化参数对它们没有意义；MoE 架构上 llama.cpp 的 -fa 行为还没验证过，一并跳过。
    static func kvQuantSupported(architecture: String?, name: String) -> Bool {
        let a = (architecture ?? "").lowercased()
        if a.isEmpty { return true }   // 读不到架构时按支持处理，失败会自动回退
        let linear = ["mamba", "rwkv", "jamba", "zamba", "falcon-h1", "granitehybrid", "plamo2"]
        if linear.contains(where: { a.contains($0) }) { return false }
        let moe = ["moe", "mixtral"]
        if moe.contains(where: { a.contains($0) }) { return false }
        return true
    }

    /// 给界面用的一句话说明（为什么不生效）
    var kvQuantNote: String? {
        if !kvQuant { return nil }
        if kvQuantFellBack { return L("KV 量化启动失败，已自动回退 fp16") }
        if !Self.kvQuantSupported(architecture: modelInfo?.architecture, name: modelName) {
            return L("该架构不支持 KV 量化，保持 fp16")
        }
        return nil
    }

    /// 切换 KV 精度：存盘并重启服务
    func setKVQuant(_ on: Bool) {
        guard on != kvQuant else { return }
        kvQuant = on
        UserDefaults.standard.set(on, forKey: "kvQuant")
        kvQuantFellBack = false
        restart()
    }

    /// 读当前模型 GGUF 头的架构信息（只读文件头，不碰权重）
    private func refreshModelInfo() {
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            modelInfo = nil
            return
        }
        modelInfo = GGUFInspector.read(at: URL(fileURLWithPath: modelPath))
    }

    /// 按「显存 + 当前模型」推荐的上下文长度
    var contextAdvice: ContextAdvisor.Advice? {
        ContextAdvisor.advise(vramGB: vramGB,
                              modelPath: modelPath,
                              info: modelInfo,
                              options: ServerController.contextOptions,
                              kvType: activeKVType)
    }

    // MARK: - 路径

    private var frameworksDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
    }

    var executableURL: URL {
        frameworksDir.appendingPathComponent("llama-server")
    }

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalModel", isDirectory: true)
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var modelName: String {
        guard !modelPath.isEmpty else { return "未选择模型" }
        return (modelPath as NSString).lastPathComponent.replacingOccurrences(of: ".gguf", with: "")
    }

    // MARK: - 模型发现

    static func discoverModels() -> [URL] {
        let fm = FileManager.default
        let dirs = [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("models"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LocalModel/models")
        ]

        var found: [URL] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.fileSizeKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items where item.pathExtension.lowercased() == "gguf" {
                found.append(item)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - 生命周期

    func start() {
        guard !state.isBusy else { return }
        if let p = process, p.isRunning { return }

        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            state = .failed(L("应用包不完整：找不到内置推理引擎"))
            return
        }
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            state = .failed(L("还没有可用的 GGUF 模型文件"))
            return
        }

        reapOrphanServer()

        // 刚清掉的残留进程不会立刻释放端口，马上 launch 会 bind 失败
        waitForPortFree { [weak self] in
            guard let self else { return }
            self.checkHealth { [weak self] alive in
                guard let self else { return }
                if alive {
                    self.state = .ready
                    self.appendLog("检测到已在运行的推理服务，直接连接。\n", reset: true)
                } else {
                    self.launch()
                }
            }
        }
    }

    /// 轮询等端口空出来（最多 3 秒），再决定是连过去还是自己拉一个
    private func waitForPortFree(attempt: Int = 0, done: @escaping () -> Void) {
        if ProcessProbe.listenerPIDs(port: port).isEmpty || attempt >= 15 {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForPortFree(attempt: attempt + 1, done: done)
        }
    }

    func restart() {
        stopSync()
        suppressQuant = false          // 用户主动重启：重新给量化一次机会
        kvFallbackTried = false
        state = .stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            // 走 start() 而不是直接 launch()：重启前要先清掉可能占着 8080 的残留推理进程，
            // 并等端口真的释放。之前直接 launch()，只要有一个旧进程霸着端口，
            // 新进程就 bind 失败，界面报「推理进程退出（状态码 1）」。
            self?.start()
        }
    }

    func setModel(_ path: String) {
        guard path != modelPath else { return }
        modelPath = path
        UserDefaults.standard.set(path, forKey: "modelPath")
        refreshModelInfo()
        suppressQuant = false
        kvFallbackTried = false
        kvQuantFellBack = false
        restart()
    }

    func setThinking(_ on: Bool) {
        guard on != thinkEnabled else { return }
        thinkEnabled = on
        UserDefaults.standard.set(on, forKey: "thinkEnabled")
        // 生成过程中改这个开关会重载模型，等于把正在输出的内容打断。
        // 记下来，等这一轮结束再重启——开关对下一轮生效。
        if ChatStore.shared.isStreaming {
            thinkPendingApply = (on != activeThink)
            return
        }
        thinkPendingApply = false
        restart()
    }

    /// 一轮生成收尾时调用：把生成期间攒下的开关改动落到进程上
    func applyPendingThinkIfNeeded() {
        guard thinkPendingApply, !ChatStore.shared.isStreaming else { return }
        thinkPendingApply = false
        restart()
    }

    /// 上下文长度改了必须重启进程（-c 是启动参数）。
    /// 调大之前先想清楚显存够不够：KV 缓存是随上下文线性涨的。
    func setContextSize(_ size: Int) {
        guard size != contextSize, ServerController.contextOptions.contains(size) else { return }
        contextSize = size
        UserDefaults.standard.set(size, forKey: "contextSize")
        restart()
    }

    /// app 内置的 Vulkan 运行时不需要系统装 SDK，ICD 描述文件在启动时生成。
    private func prepareICD() -> String? {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let icd = supportDir.appendingPathComponent("MoltenVK_icd.json")
        let lib = frameworksDir.appendingPathComponent("libMoltenVK.dylib").path
        let json = """
        {
            "file_format_version": "1.0.0",
            "ICD": {
                "library_path": "\(lib)",
                "api_version": "1.4.0",
                "is_portability_driver": true
            }
        }
        """
        do {
            try json.write(to: icd, atomically: true, encoding: .utf8)
            return icd.path
        } catch {
            return nil
        }
    }

    /// 启动失败统一走这里：如果失败发生在开着 KV 量化的启动里，先自动关量化重试一次，
    /// 避免"模型不支持 -ctk/-ctv 就永远起不来"。
    private func startFailed(_ message: String) {
        if kvQuantActive && !kvFallbackTried {
            kvFallbackTried = true
            suppressQuant = true
            kvQuantFellBack = true
            appendLog(Lf("KV 量化启动失败，改用 fp16 重试：%@", message) + "\n", reset: false)
            state = .starting
            launch()
            return
        }
        state = .failed(message)
        stopPolling()
    }

    private func launch() {
        guard let icdPath = prepareICD() else {
            state = .failed(L("无法写入 Vulkan 配置"))
            return
        }

        appendLog((pendingNotice ?? "") + "正在加载 \(modelName)…\n", reset: true)
        pendingNotice = nil
        state = .starting
        startedAt = Date()
        activeThink = thinkEnabled        // 这一进程真正带上的开关值

        let p = Process()
        p.executableURL = executableURL
        p.arguments = [
            "-m", modelPath,
            "-ngl", "99",
            "-c", String(contextSize),
            "-np", "1",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--jinja",
            "--no-webui",
            "--no-warmup",
            "--chat-template-kwargs", thinkEnabled ? #"{"enable_thinking":true}"# : #"{"enable_thinking":false}"#
        ]

        // KV 量化：-ctk/-ctv 把 K/V 缓存压到 8 位，-fa on 是它的前置条件
        let useQuant = kvQuant && !suppressQuant
            && ServerController.kvQuantSupported(architecture: modelInfo?.architecture, name: modelName)
        kvQuantActive = useQuant
        if useQuant {
            // MDKVFAIL=1：故意传一个非法 KV 类型，用来验证"量化启动失败→自动回退 fp16"这条路径
            let kvFailTest = ProcessInfo.processInfo.environment["MDKVFAIL"] == "1"
                || UserDefaults.standard.bool(forKey: "MDKVFAIL")
            let ctk = kvFailTest ? "esoteric_bogus" : "q8_0"
            p.arguments! += ["-ctk", ctk, "-ctv", "q8_0", "-fa", "on"]
        }

        lastArguments = p.arguments ?? []

        var env = ProcessInfo.processInfo.environment
        env["VK_ICD_FILENAMES"] = icdPath
        env["VK_DRIVER_FILES"] = icdPath
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.currentDirectoryURL = frameworksDir

        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.ingest(text) }
        }

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                // 只处理"当前这个进程"的退出：KV 量化失败自动回退时，旧进程的终止回调
                // 不能把刚拉起的新进程状态一起清掉
                guard self.process === proc else { return }
                if case .starting = self.state {
                    var msg = Lf("推理进程退出（状态码 %lld）", proc.terminationStatus)
                    // 端口被别的进程（多半是上一次启动留下的推理服务）占着时，
                    // 光给状态码看不出原因，直接把话说清楚
                    if !ProcessProbe.listenerPIDs(port: self.port).isEmpty {
                        msg += " " + Lf("端口 %@ 已被占用，可能是上次异常退出留下的推理进程。",
                                        "\(self.port)")
                    }
                    self.startFailed(msg)
                    // startFailed 已经拉起新进程：轮询和 process 都归它，这里不能动
                    guard self.process === proc else { return }
                } else if case .ready = self.state {
                    self.state = .stopped
                }
                self.stopPolling()
                self.process = nil
            }
        }

        do {
            try p.run()
        } catch {
            state = .failed(Lf("无法启动推理进程：%@", error.localizedDescription))
            return
        }

        process = p
        pipe = outPipe
        startPolling()
    }

    // MARK: - 孤儿进程清理

    /// app 被强杀（SIGKILL）时 llama-server 会活下来继续占着显存。
    /// 启动时如果发现占用端口的正是本 app 包里那个 llama-server，
    /// 且它已经没了爹（父进程被 init 收养），就把它清掉再重新拉起。
    private func reapOrphanServer() {
        let ours = executableURL.path
        let pids = ProcessProbe.listenerPIDs(port: port)
        var lines: [String] = []
        func trace(_ s: String) {
            lines.append(s)
            print("[reaper] \(s)")
        }
        trace("ours=\(ours)")
        trace("端口 \(port) 上的 PID: \(pids)")
        for pid in pids {
            guard let path = ProcessProbe.executablePath(pid: pid) else {
                trace("PID \(pid) 取不到可执行路径")
                continue
            }
            let name = (path as NSString).lastPathComponent
            let orphan = ProcessProbe.isOrphan(pid: pid)
            let same = ProcessProbe.sameFile(path, ours)
            trace("PID \(pid) 路径=\(path) 同一个文件=\(same) 孤儿=\(orphan)")
            // 只处理推理服务本身，别的进程霸着端口不归我们管
            guard name == "llama-server" else { continue }

            // 父进程还活着 → 是某个正在运行的实例拉起来的，连过去就行
            if !orphan {
                trace("父进程还活着，连过去")
                pendingNotice = "检测到另一个实例的推理服务在运行，直接连接。\n"
                writeReaperLog(lines)
                return
            }

            // 孤儿一律清掉，不再要求"和我们的可执行文件是同一个文件"：
            // 重新打包会把旧 app 挪进废纸篓，旧进程的文件路径就变了，
            // 但它仍然是 llama-server，仍然占着 8080，新进程 bind 必失败。
            let killed = ProcessProbe.terminate(pid: pid)
            trace("终止结果=\(killed)")
            if killed {
                pendingNotice = "清理了残留的推理进程（PID \(pid)）。\n"
            }
        }
        writeReaperLog(lines)
    }

    /// 诊断日志：写到 Application Support，方便事后翻查
    private func writeReaperLog(_ lines: [String]) {
        let url = supportDir.appendingPathComponent("reaper.log")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        let body = (["[\(stamp)]"] + lines).joined(separator: " | ") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(body.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 健康检查

    private func checkHealth(_ completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 1.5
        session.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func tick() {
        if case .ready = state { stopPolling(); return }
        if case .failed = state { stopPolling(); return }

        if let started = startedAt, Date().timeIntervalSince(started) > 300 {
            startFailed(L("加载超时（超过 5 分钟）"))
            return
        }

        checkHealth { [weak self] alive in
            guard let self else { return }
            if alive, self.state.isBusy {
                self.state = .ready
                self.kvFallbackTried = false
                self.stopPolling()
                self.dumpKVTestIfNeeded()
            }
        }
    }

    // MARK: - 停止

    func stopSync() {
        stopPolling()
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while p.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if p.isRunning {
                kill(p.processIdentifier, SIGKILL)
            }
        }
        process = nil
        if state.isReady { state = .stopped }
    }

    // MARK: - 日志

    private func ingest(_ text: String) {
        log += text
        if log.count > 60_000 {
            log = String(log.suffix(40_000))
        }

        // Vulkan 没能初始化时要明确失败，而不是默默退化成 CPU
        if state.isBusy {
            if log.contains("No devices found") || log.contains("failed to initialize Vulkan") {
                startFailed(L("Vulkan 后端没有找到可用显卡。请确认 AMD 显卡驱动正常、未被其他进程独占。"))
            }
        }
    }

    private func appendLog(_ text: String, reset: Bool) {
        log = reset ? text : log + text
    }

    /// MDKVTEST=1：就绪后把启动参数和 KV 相关日志落盘，用来核对 -ctk/-ctv 真的传下去、真的生效。
    private func dumpKVTestIfNeeded() {
        guard ProcessInfo.processInfo.environment["MDKVTEST"] == "1"
                || UserDefaults.standard.bool(forKey: "MDKVTEST") else { return }
        var lines: [String] = []
        lines.append("kvQuant=YES\(kvQuant ? "" : "NO")  active=\(kvQuantActive)  fellBack=\(kvQuantFellBack)")
        lines.append("activeKVType=\(activeKVType.label)  arch=\(modelInfo?.architecture ?? "nil")")
        lines.append("args: " + lastArguments.joined(separator: " "))
        lines.append("--- log (KV/flash 相关) ---")
        for l in log.split(separator: "\n") where l.lowercased().contains("kv")
            || l.lowercased().contains("flash") || l.lowercased().contains("quant") {
            lines.append(String(l))
        }
        try? lines.joined(separator: "\n").write(toFile: "/tmp/qstudio_kv.txt",
                                                 atomically: true, encoding: .utf8)
    }

    var tailLog: String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(20).joined(separator: "\n")
    }
}
