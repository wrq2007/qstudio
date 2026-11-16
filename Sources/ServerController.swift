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
        case .stopped:  return "已停止"
        case .starting: return "加载模型…"
        case .ready:    return "就绪"
        case .failed:   return "启动失败"
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
    @Published private(set) var gpuName: String = ""
    @Published private(set) var contextSize: Int = 8192

    /// 当前显卡显存（界面注入），用来推算合适的上下文长度
    @Published private(set) var vramGB: Double = 0

    /// 当前模型的架构信息（从 GGUF 文件头读的），KV 缓存按真实参数算
    @Published private(set) var modelInfo: GGUFInfo?

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
                              options: ServerController.contextOptions)
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
            state = .failed("应用包不完整：找不到内置推理引擎")
            return
        }
        guard !modelPath.isEmpty, FileManager.default.fileExists(atPath: modelPath) else {
            state = .failed("还没有可用的 GGUF 模型文件")
            return
        }

        reapOrphanServer()

        checkHealth { [weak self] alive in
            guard let self else { return }
            if alive {
                self.state = .ready
                self.appendLog("检测到已在运行的推理服务，直接连接。\n", reset: true)
            } else {
                self.launch()
            }
        }
    }

    func restart() {
        stopSync()
        state = .stopped
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.launch()
        }
    }

    func setModel(_ path: String) {
        guard path != modelPath else { return }
        modelPath = path
        UserDefaults.standard.set(path, forKey: "modelPath")
        refreshModelInfo()
        restart()
    }

    func setThinking(_ on: Bool) {
        guard on != thinkEnabled else { return }
        thinkEnabled = on
        UserDefaults.standard.set(on, forKey: "thinkEnabled")
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

    private func launch() {
        guard let icdPath = prepareICD() else {
            state = .failed("无法写入 Vulkan 配置")
            return
        }

        appendLog((pendingNotice ?? "") + "正在加载 \(modelName)…\n", reset: true)
        pendingNotice = nil
        state = .starting
        startedAt = Date()

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
                if case .starting = self.state {
                    self.state = .failed("推理进程退出（状态码 \(proc.terminationStatus)）")
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
            state = .failed("无法启动推理进程：\(error.localizedDescription)")
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
            let orphan = ProcessProbe.isOrphan(pid: pid)
            let same = ProcessProbe.sameFile(path, ours)
            trace("PID \(pid) 路径=\(path) 同一个文件=\(same) 孤儿=\(orphan)")
            guard same else { continue }

            // 父进程还活着 → 是某个正在运行的实例拉起来的，连过去就行
            if !orphan {
                trace("父进程还活着，连过去")
                pendingNotice = "检测到另一个实例的推理服务在运行，直接连接。\n"
                writeReaperLog(lines)
                return
            }

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
            state = .failed("加载超时（超过 5 分钟）")
            stopPolling()
            return
        }

        checkHealth { [weak self] alive in
            guard let self else { return }
            if alive, self.state.isBusy {
                self.state = .ready
                self.stopPolling()
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
                state = .failed("Vulkan 后端没有找到可用显卡。请确认 AMD 显卡驱动正常、未被其他进程独占。")
                stopPolling()
            }
        }
    }

    private func appendLog(_ text: String, reset: Bool) {
        log = reset ? text : log + text
    }

    var tailLog: String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(20).joined(separator: "\n")
    }
}
