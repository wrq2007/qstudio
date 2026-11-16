import Foundation
import Combine

enum DownloadPhase: Equatable {
    case running(received: Int64, total: Int64)
    case completed(URL)
    case failed(String)
    case cancelled
}

/// 在线下载 GGUF。断点续传、镜像自动切换、进度与速度实时上报。
///
/// 没有任何自动下载行为——只有用户在界面上点「下载」才会开始。
///
/// 并发规则：同一个模型同一时刻只允许一个下载任务。所有状态变更都串行发生在
/// 内部的 queue 上（URLSession 的 delegate 也挂在同一个队列），避免取消/换镜像
/// 时出现两个任务同时写同一个 .part 文件。
final class ModelDownloader: NSObject, ObservableObject {
    static let shared = ModelDownloader()

    @Published private(set) var states: [String: DownloadPhase] = [:]
    @Published private(set) var speeds: [String: Double] = [:]

    private final class Attempt {
        let spec: ModelSpec
        var mirrorIndex = 0
        var task: URLSessionDataTask?
        var handle: FileHandle?
        var resumeOffset: Int64 = 0
        var userCancelled = false
        var finished = false
        var retriedFromZero = false

        init(spec: ModelSpec) { self.spec = spec }
    }

    private let queue = DispatchQueue(label: "localmodel.download")
    private var attempts: [String: Attempt] = [:]
    private var completed: Set<String> = []
    private var lastSample: [String: (at: Date, bytes: Int64)] = [:]

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        let opq = OperationQueue()
        opq.maxConcurrentOperationCount = 1
        opq.underlyingQueue = queue
        return URLSession(configuration: cfg, delegate: self, delegateQueue: opq)
    }()

    // MARK: - 对外接口

    func state(for spec: ModelSpec) -> DownloadPhase? {
        states[spec.id]
    }

    func isRunning(_ spec: ModelSpec) -> Bool {
        if case .running = states[spec.id] { return true }
        return false
    }

    /// 之前显示「已下载」，但文件后来被删了
    func isStale(_ spec: ModelSpec) -> Bool {
        if case .completed(let url) = states[spec.id] {
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return false
    }

    func start(_ spec: ModelSpec) {
        queue.async { self.startLocked(spec) }
    }

    func cancel(_ spec: ModelSpec) {
        queue.async {
            guard let attempt = self.attempts[spec.id] else {
                self.publish(spec.id, .cancelled)
                return
            }
            attempt.userCancelled = true
            attempt.task?.cancel()
        }
    }

    func reset(_ spec: ModelSpec) {
        queue.async {
            self.completed.remove(spec.id)
            DispatchQueue.main.async {
                self.states[spec.id] = nil
                self.speeds[spec.id] = nil
            }
        }
    }

    /// 清掉半截文件
    func discardPartial(_ spec: ModelSpec) {
        let part = partURL(spec)
        try? FileManager.default.removeItem(at: part)
    }

    // MARK: - 内部（只在 queue 上跑）

    private func startLocked(_ spec: ModelSpec) {
        if attempts[spec.id] != nil { return }                     // 已经在跑
        if completed.contains(spec.id), !isStale(spec) { return } // 已下完

        try? FileManager.default.createDirectory(at: ModelCatalog.modelsDirectory,
                                                 withIntermediateDirectories: true)
        let attempt = Attempt(spec: spec)
        attempts[spec.id] = attempt
        begin(attempt)
    }

    private func begin(_ attempt: Attempt) {
        let mirrors = ModelCatalog.mirrors
        guard attempt.mirrorIndex < mirrors.count else {
            finish(attempt, .failed("所有镜像源都没能提供这个文件"))
            return
        }
        let mirror = mirrors[attempt.mirrorIndex]
        guard let url = URL(string: "\(mirror)/\(attempt.spec.repo)/resolve/main/\(attempt.spec.file)") else {
            finish(attempt, .failed("下载地址不合法"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        var existing: Int64 = 0
        let part = partURL(attempt.spec)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: part.path),
           let size = attrs[.size] as? NSNumber {
            existing = size.int64Value
        }

        // 上次下到一半被取消，但缓冲区已经把文件写满了 —— 直接收尾，不用重下
        if existing == attempt.spec.sizeBytes {
            finalize(attempt)
            return
        }
        if existing > attempt.spec.sizeBytes {
            try? FileManager.default.removeItem(at: part)   // 半截文件比源还大，只能是坏的
            existing = 0
        }

        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        attempt.resumeOffset = existing

        let task = session.dataTask(with: request)
        task.taskDescription = attempt.spec.id
        attempt.task = task
        task.resume()
    }

    private func partURL(_ spec: ModelSpec) -> URL {
        ModelCatalog.destinationURL(for: spec).appendingPathExtension("part")
    }

    private func openHandle(_ attempt: Attempt, offset: Int64) -> FileHandle? {
        let part = partURL(attempt.spec)
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        guard let fh = try? FileHandle(forWritingTo: part) else { return nil }
        do {
            try fh.truncate(atOffset: UInt64(offset))
            try fh.seek(toOffset: UInt64(offset))
        } catch {
            try? fh.close()
            return nil
        }
        return fh
    }

    private func closeHandle(_ attempt: Attempt) {
        try? attempt.handle?.close()
        attempt.handle = nil
    }

    private func finish(_ attempt: Attempt, _ phase: DownloadPhase) {
        guard !attempt.finished else { return }
        attempt.finished = true
        closeHandle(attempt)
        attempt.task = nil

        let id = attempt.spec.id
        if attempts[id] === attempt { attempts[id] = nil }
        if case .completed = phase { completed.insert(id) }

        DispatchQueue.main.async {
            self.states[id] = phase
            if case .failed = phase { self.speeds[id] = nil }
        }
    }

    private func publish(_ id: String, _ phase: DownloadPhase) {
        DispatchQueue.main.async { self.states[id] = phase }
    }

    /// .part 改名成正式文件
    private func finalize(_ attempt: Attempt) {
        let spec = attempt.spec
        let part = partURL(spec)
        let dest = ModelCatalog.destinationURL(for: spec)
        let fm = FileManager.default

        // 防呆 1：落盘前先验 GGUF 头。大小对不代表内容对——
        // 一个损坏/截断的 .part 若直接覆盖正式模型，损失不可逆。
        guard GGUFInspector.hasValidMagic(at: part) else {
            finish(attempt, .failed("下载文件损坏（不是有效的 GGUF），已丢弃，请重试"))
            try? fm.removeItem(at: part)
            return
        }

        // 防呆 2：绝不覆盖当前正在使用的模型——推理进程还开着这个文件，
        // 覆盖会让下次重启加载到一个意外版本。
        let inUse = ServerController.shared.modelPath
        if fm.fileExists(atPath: dest.path), dest.path == inUse {
            finish(attempt, .failed("目标文件正在使用中，不能覆盖。请先切换到别的模型再重试"))
            return
        }

        do {
            if fm.fileExists(atPath: dest.path) {
                // 防呆 3：已存在的文件移到废纸篓而不是直接删，误覆盖也能找回来
                var trashURL: NSURL?
                if (try? fm.trashItem(at: dest, resultingItemURL: &trashURL)) == nil {
                    // 废纸篓不可用（权限/卷不支持）时退而求其次：改名为 .bak-时间戳
                    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
                        .replacingOccurrences(of: ":", with: "-")
                    let backup = dest.deletingPathExtension().appendingPathExtension("bak-\(stamp).gguf")
                    try fm.moveItem(at: dest, to: backup)
                }
            }
            try fm.moveItem(at: part, to: dest)
            DispatchQueue.main.async { self.speeds[spec.id] = nil }
            finish(attempt, .completed(dest))
        } catch {
            finish(attempt, .failed("保存文件失败：\(error.localizedDescription)"))
        }
    }
}

// MARK: - URLSessionDelegate

extension ModelDownloader: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskDescription ?? ""
        guard let attempt = attempts[id] else {
            completionHandler(.cancel)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(attempt, .failed("服务器返回了无法识别的响应"))
            return
        }

        if http.statusCode == 200 || http.statusCode == 206 {
            var offset = attempt.resumeOffset
            if http.statusCode == 200 { offset = 0 }   // 服务器没接受 Range，从头开始
            attempt.resumeOffset = offset

            closeHandle(attempt)
            guard let fh = openHandle(attempt, offset: offset) else {
                completionHandler(.cancel)
                finish(attempt, .failed("无法写入下载文件"))
                return
            }
            attempt.handle = fh
            lastSample[id] = (Date(), offset)
            publish(id, .running(received: offset, total: attempt.spec.sizeBytes))
            completionHandler(.allow)
            return
        }

        completionHandler(.cancel)
        closeHandle(attempt)

        // 416：请求的 Range 超出了文件长度。多半是半截文件已经完整或损坏
        if http.statusCode == 416 {
            let partSize = (try? FileManager.default.attributesOfItem(atPath: partURL(attempt.spec).path)[.size] as? NSNumber)??.int64Value ?? 0
            if partSize == attempt.spec.sizeBytes {
                finalize(attempt)
                return
            }
            if !attempt.retriedFromZero {
                attempt.retriedFromZero = true
                try? FileManager.default.removeItem(at: partURL(attempt.spec))
                attempt.resumeOffset = 0
                begin(attempt)
                return
            }
        }

        // 429 / 5xx 换下一个镜像；404 说明文件不存在，换镜像也没用
        if http.statusCode == 429 || http.statusCode >= 500 {
            attempt.mirrorIndex += 1
            if attempt.mirrorIndex < ModelCatalog.mirrors.count {
                begin(attempt)
                return
            }
        }
        finish(attempt, .failed("下载失败：HTTP \(http.statusCode)"))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskDescription ?? ""
        guard let attempt = attempts[id], let fh = attempt.handle else { return }
        do {
            try fh.write(contentsOf: data)
            let received = Int64((try? fh.offset()) ?? 0)
            let now = Date()
            var speed: Double = 0
            if let prev = lastSample[id] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.2 {
                    speed = Double(received - prev.bytes) / dt
                    lastSample[id] = (now, received)
                }
            } else {
                lastSample[id] = (now, received)
            }
            DispatchQueue.main.async {
                self.states[id] = .running(received: received, total: attempt.spec.sizeBytes)
                if speed > 0 { self.speeds[id] = speed }
            }
        } catch {
            finish(attempt, .failed("写入文件失败：\(error.localizedDescription)"))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription ?? ""
        guard let attempt = attempts[id] else { return }
        // 已经被换掉的旧尝试（比如换镜像时 cancel 掉的），它的结束回调不管
        guard attempt.task === task else { return }

        if attempt.userCancelled {
            finish(attempt, .cancelled)
            return
        }

        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                return   // 换镜像时主动 cancel 的，交给换镜像的分支
            }
            attempt.mirrorIndex += 1
            if attempt.mirrorIndex < ModelCatalog.mirrors.count {
                begin(attempt)
                return
            }
            finish(attempt, .failed("下载中断：\(error.localizedDescription)"))
            return
        }

        // 正常结束：.part 改名成正式文件
        finalize(attempt)
    }
}
