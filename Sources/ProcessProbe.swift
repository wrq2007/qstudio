import Foundation

/// 用 lsof 探测端口占用和进程的可执行文件路径。
///
/// 用途只有一个：app 被强杀（SIGKILL）之后，llama-server 会变成孤儿继续占着显存，
/// 启动时要把这种残留认出来并清掉。只认 app 包内那个 llama-server，
/// 用户自己在终端跑的推理服务不动。
enum ProcessProbe {

    /// 正在监听指定端口的进程 PID
    static func listenerPIDs(port: Int) -> [Int32] {
        let out = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return out.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 进程的主可执行文件路径（lsof 的 txt 映射项）
    static func executablePath(pid: Int32) -> String? {
        let out = run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"])
        var wantTxt = false
        for line in out.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("f") {
                wantTxt = s.contains("txt")
                continue
            }
            if wantTxt && s.hasPrefix("n") {
                return unescape(String(s.dropFirst()))
            }
        }
        return nil
    }

    /// 两个路径是不是同一个文件（比字符串可靠：不受 /private 前缀、符号链接影响）
    static func sameFile(_ pathA: String, _ pathB: String) -> Bool {
        var a = stat(), b = stat()
        guard stat(pathA, &a) == 0, stat(pathB, &b) == 0 else {
            return pathA == pathB
        }
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// lsof 在非 UTF-8 locale 下会把路径里的非 ASCII 字节转义成 \xNN，这里还原
    static func unescape(_ s: String) -> String {
        guard s.contains("\\x") else { return s }
        let src = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < src.count {
            if i + 3 < src.count, src[i] == 0x5C, src[i + 1] == 0x78,
               let hi = hexValue(src[i + 2]), let lo = hexValue(src[i + 3]) {
                out.append(hi << 4 | lo)
                i += 4
            } else {
                out.append(src[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }

    /// 进程是否还活着
    static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// 进程的父进程 PID
    ///
    /// 用内核的 KERN_PROC_PID 直接读，不依赖 `ps`——这台机器上 ps 被系统策略拦了。
    static func parentPID(pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            sysctl(buf.baseAddress!, u_int(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// 这个进程是不是没人管的孤儿：父进程已经没了（被 launchd 收养，ppid=1）
    static func isOrphan(pid: Int32) -> Bool {
        guard let ppid = parentPID(pid: pid) else { return true }
        if ppid <= 1 { return true }
        return !isAlive(pid: ppid)
    }

    /// 终止进程：先 SIGTERM，宽限期后 SIGKILL
    @discardableResult
    static func terminate(pid: Int32, grace: TimeInterval = 2.0) -> Bool {
        guard isAlive(pid: pid) else { return true }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if !isAlive(pid: pid) { return true }
            usleep(100_000)
        }
        kill(pid, SIGKILL)
        usleep(200_000)
        return !isAlive(pid: pid)
    }

    // MARK: - 内部

    private static func run(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // lsof 在非 UTF-8 locale 下会把非 ASCII 路径转义成 \xNN，指定 locale 拿到原字节
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
