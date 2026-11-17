import Foundation

/// 从 GGUF 文件头里读出来的架构信息，用来精确算 KV 缓存。
struct GGUFInfo {
    var architecture: String = ""
    var blockCount: Int = 0
    var headCount: Int = 0
    var headCountKV: Int = 0
    var keyLength: Int = 0
    var embeddingLength: Int = 0
    var trainedContext: Int = 0
    var fileSize: Int64 = 0

    /// 每个 token 的 head 维度
    var headDim: Int {
        if keyLength > 0 { return keyLength }
        if headCount > 0 && embeddingLength > 0 { return embeddingLength / headCount }
        return 0
    }

    /// KV 缓存精度：q8_0 每个元素 1 字节再加 1/32 的 fp16 缩放系数，实测约 1.0625 字节；
    /// fp16 是 2 字节。量化后同样的显存能装下接近两倍的上下文。
    enum KVType {
        case fp16
        case q8_0

        var bytesPerElement: Double {
            switch self {
            case .fp16: return 2
            case .q8_0: return 1.0625
            }
        }

        var label: String { self == .q8_0 ? "q8_0" : "fp16" }
    }

    /// 每 token 的 KV 缓存字节数（K + V 两份）
    func kvBytesPerToken(_ type: KVType = .fp16) -> Int {
        Int((Double(2 * blockCount * headCountKV * headDim) * type.bytesPerElement).rounded())
    }

    /// 兼容旧调用：默认 fp16
    var kvBytesPerToken: Int { kvBytesPerToken(.fp16) }

    var summary: String {
        var parts: [String] = []
        if blockCount > 0 { parts.append(Lf("%lld 层", blockCount)) }
        if headCountKV > 0 { parts.append(Lf("%lld 个 KV 头", headCountKV)) }
        if headDim > 0 { parts.append("head_dim \(headDim)") }
        return parts.joined(separator: " · ")
    }
}

/// GGUF 文件头解析器。
///
/// 只读文件开头的元数据区（通常不到 1 MB），不碰权重数据。
/// 格式：magic "GGUF" | version u32 | tensor_count u64 | kv_count u64 | kv 对
enum GGUFInspector {

    /// 只验文件头 4 字节 magic 是否为 "GGUF"。
    /// 下载收尾时用，防止一个大小对但内容损坏的文件被当成模型装进去。
    static func hasValidMagic(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return String(decoding: head, as: UTF8.self) == "GGUF"
    }

    /// 上一次解析失败的原因（排查用）
    static var lastFailure: String?

    static func read(at url: URL) -> GGUFInfo? {
        lastFailure = nil
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            lastFailure = "打不开文件"
            return nil
        }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        var info = GGUFInfo()
        info.fileSize = size

        // 元数据一般在文件头，先读 8 MB，不够再补
        let data = handle.readData(ofLength: 8 * 1024 * 1024)
        var cursor = Cursor(data: data)
        guard cursor.magic() else {
            lastFailure = "magic 不对"
            return nil
        }
        _ = cursor.u32()          // version
        _ = cursor.u64()          // tensor_count
        guard let kvCount = cursor.u64() else {
            lastFailure = "读不到 kv 数量"
            return nil
        }

        var arch = ""
        var values: [String: Int] = [:]

        for i in 0..<kvCount {
            guard let key = cursor.string() else {
                lastFailure = "第 \(i) 个键读不出来"
                break
            }
            guard let type = cursor.u32() else {
                lastFailure = "第 \(i) 个键 \(key) 的类型读不出来"
                break
            }
            if key == "general.architecture" {
                arch = cursor.string() ?? ""
                continue
            }
            // 只关心这几个键，其余跳过
            let interesting = key.hasSuffix(".block_count")
                || key.hasSuffix(".attention.head_count")
                || key.hasSuffix(".attention.head_count_kv")
                || key.hasSuffix(".attention.key_length")
                || key.hasSuffix(".embedding_length")
                || key.hasSuffix(".context_length")
            if interesting {
                guard let v = cursor.value(type: type) else {
                    lastFailure = "读 \(key) 的值失败（type \(type)）"
                    break
                }
                values[key] = v
            } else if !cursor.skipValue(type: type) {
                // tokenizer 那种超长数组读不完就到此为止，
                // 需要的架构参数都在它前面，已经拿到了
                lastFailure = "跳过 \(key)（type \(type)）时读完了文件头，已取到的信息仍然可用"
                break
            }
        }

        info.architecture = arch
        for (key, v) in values {
            guard arch.isEmpty || key.hasPrefix(arch + ".") else { continue }
            switch String(key.dropFirst(arch.count + 1)) {
            case "block_count": info.blockCount = v
            case "attention.head_count": info.headCount = v
            case "attention.head_count_kv": info.headCountKV = v
            case "attention.key_length": info.keyLength = v
            case "embedding_length": info.embeddingLength = v
            case "context_length": info.trainedContext = v
            default: break
            }
        }
        // 老文件不写 head_count_kv，默认等于 head_count（即 MHA）
        if info.headCountKV == 0 { info.headCountKV = info.headCount }
        guard info.blockCount > 0, info.kvBytesPerToken > 0 else {
            lastFailure = lastFailure ?? "没读到架构参数"
            return nil
        }
        return info
    }

    // MARK: - 游标

    private struct Cursor {
        let data: Data
        var offset: Int = 0

        mutating func magic() -> Bool {
            guard data.count >= 4 else { return false }
            let m = data.prefix(4)
            let ok = m[0] == 0x47 && m[1] == 0x47 && m[2] == 0x55 && m[3] == 0x46   // "GGUF"
            offset = 4
            return ok
        }

        mutating func u32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
            offset += 4
            return v
        }

        mutating func u64() -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
            offset += 8
            return v
        }

        mutating func string() -> String? {
            guard let len = u64(), len < 1 << 24 else { return nil }
            let n = Int(len)
            guard offset + n <= data.count else { return nil }
            let s = String(decoding: data[offset..<(offset + n)], as: UTF8.self)
            offset += n
            return s
        }

        /// 取出一个标量值；字符串/数组返回 0
        mutating func value(type: UInt32) -> Int? {
            switch type {
            case 0, 1, 2, 3, 4, 5, 7, 10, 11:
                guard let raw = scalar(type: type) else { return nil }
                return Int(raw)
            case 6:   // float32
                guard offset + 4 <= data.count else { return nil }
                offset += 4
                return 0
            case 12:  // float64
                guard offset + 8 <= data.count else { return nil }
                offset += 8
                return 0
            case 8:   // string
                _ = string()
                return 0
            case 9:   // array
                guard let elemType = u32(), let count = u64() else { return nil }
                for _ in 0..<count {
                    guard skipValue(type: elemType) else { return nil }
                }
                return 0
            default:
                return nil
            }
        }

        mutating func skipValue(type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:  offset += 1
            case 2, 3:     offset += 2
            case 4, 5, 6:  offset += 4
            case 10, 11, 12: offset += 8
            case 8:        guard string() != nil else { return false }
            case 9:
                guard let elemType = u32(), let count = u64() else { return false }
                for _ in 0..<count {
                    guard skipValue(type: elemType) else { return false }
                }
            default: return false
            }
            return offset <= data.count
        }

        private mutating func scalar(type: UInt32) -> UInt64? {
            switch type {
            case 0, 1, 7:
                guard offset + 1 <= data.count else { return nil }
                let v = UInt64(data[offset]); offset += 1; return v
            case 2, 3:
                guard offset + 2 <= data.count else { return nil }
                var v: UInt64 = 0
                for i in 0..<2 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
                offset += 2; return v
            case 4, 5:
                guard offset + 4 <= data.count else { return nil }
                var v: UInt64 = 0
                for i in 0..<4 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
                offset += 4; return v
            case 10, 11:
                return u64()
            default:
                return nil
            }
        }
    }
}

/// 根据「显存 + 模型」推荐合适的上下文长度。
enum ContextAdvisor {

    struct Advice {
        let recommended: Int
        let weightsGB: Double
        let kvGB: Double
        let overheadGB: Double
        let freeGB: Double
        let vramGB: Double
        let maxContext: Int
        let info: GGUFInfo
        let kvType: GGUFInfo.KVType

        /// 推荐值是不是已经到顶了（再往上显存就不够了）
        var atLimit: Bool { maxContext < recommended * 2 }
    }

    /// 留 15% 显存给计算缓冲、显存碎片和驱动开销
    static let headroomRatio = 0.85

    static func advise(vramGB: Double,
                       modelPath: String,
                       info: GGUFInfo?,
                       options: [Int],
                       kvType: GGUFInfo.KVType = .fp16) -> Advice? {
        guard vramGB > 0, !modelPath.isEmpty,
              let info, info.kvBytesPerToken(kvType) > 0 else { return nil }

        let weightsGB = Double(info.fileSize) / 1_073_741_824
        let overheadGB = 0.6 + weightsGB * 0.05
        let freeGB = vramGB * headroomRatio - weightsGB - overheadGB
        let perToken = info.kvBytesPerToken(kvType)
        let maxContext = freeGB > 0 ? Int(freeGB * 1_073_741_824 / Double(perToken)) : 0

        let sorted = options.sorted()
        let recommended = sorted.last { Double($0) <= Double(maxContext) } ?? sorted.first ?? 8192
        let kvGB = Double(perToken * recommended) / 1_073_741_824

        return Advice(recommended: recommended,
                      weightsGB: weightsGB,
                      kvGB: kvGB,
                      overheadGB: overheadGB,
                      freeGB: freeGB,
                      vramGB: vramGB,
                      maxContext: maxContext,
                      info: info,
                      kvType: kvType)
    }
}
