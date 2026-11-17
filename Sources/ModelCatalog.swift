import Foundation

/// 一个可下载的 GGUF 模型。
///
/// repo / file / sizeBytes 三个字段都用 HF 仓库的 HEAD 响应核对过
/// （`x-linked-size` 与 tree 接口的 size 字段），体积写死是为了
/// 离线也能给出可信的显存估算，不用联网。
struct ModelSpec: Identifiable, Hashable {
    let repo: String
    let file: String
    let displayName: String
    let family: String
    let paramsB: Double
    let quant: String
    let sizeBytes: Int64
    let blurb: String
    let tags: [String]

    /// 用于估算 KV 缓存的架构参数
    let kvLayers: Int
    let kvHeads: Int
    let headDim: Int

    var id: String { "\(repo)/\(file)" }
    var localName: String { "\(displayName)-\(quant).gguf" }
    var sizeGB: Double { Double(sizeBytes) / 1_073_741_824 }

    /// 浏览器打开的模型文件页（默认走 hf-mirror，与镜像策略一致）
    var pageURL: URL? {
        let base = ModelCatalog.mirrors.first ?? "https://hf-mirror.com"
        return URL(string: "\(base)/\(repo)/blob/main/\(file)")
    }

    /// KV 缓存体积（K + V 两份）。q8_0 约是 fp16 的 53%，同样显存能开两倍上下文。
    func kvCacheGB(context: Int, kvType: GGUFInfo.KVType = .fp16) -> Double {
        let elements = Double(2 * kvLayers * context * kvHeads * headDim)
        return elements * kvType.bytesPerElement / 1_073_741_824
    }

    /// 估算显存占用：权重 + KV 缓存 + 运行时开销
    func estimatedVRAMGB(context: Int = 8192, kvType: GGUFInfo.KVType = .fp16) -> Double {
        let overhead = 0.6 + sizeGB * 0.05
        return sizeGB + kvCacheGB(context: context, kvType: kvType) + overhead
    }

    enum Fit {
        case comfortable   // 装得下且留有余量
        case tight        // 勉强装下，跑长上下文会溢出到内存
        case over         // 装不下

        var label: String {
            switch self {
            case .comfortable: return L("推荐")
            case .tight: return L("偏紧")
            case .over: return L("超出显存")
            }
        }
    }

    func fit(vramGB: Double, context: Int = 8192, kvType: GGUFInfo.KVType = .fp16) -> Fit {
        let need = estimatedVRAMGB(context: context, kvType: kvType)
        if need <= vramGB * 0.75 { return .comfortable }
        if need <= vramGB * 0.95 { return .tight }
        return .over
    }
}

enum ModelCatalog {

    /// 镜像源：国内直连 huggingface.co 基本不通，默认走 hf-mirror
    static var mirrors = ["https://hf-mirror.com", "https://huggingface.co"]

    /// 下载落地目录（与 ServerController.discoverModels 的扫描路径一致）
    static var modelsDirectoryOverride: URL?

    static var modelsDirectory: URL {
        if let modelsDirectoryOverride { return modelsDirectoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalModel/models", isDirectory: true)
    }

    static func destinationURL(for spec: ModelSpec) -> URL {
        modelsDirectory.appendingPathComponent(spec.localName)
    }

    static func isInstalled(_ spec: ModelSpec) -> Bool {
        let dest = destinationURL(for: spec)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }

    // MARK: - 清单

    static let specs: [ModelSpec] = [
        ModelSpec(repo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", file: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
                  displayName: "Qwen2.5 1.5B Instruct", family: "Qwen2.5", paramsB: 1.54, quant: "Q4_K_M",
                  sizeBytes: 1_117_320_736,
                  blurb: "最小可用档位。显存占用低、生成快，适合先跑通链路。",
                  tags: ["轻量", "中文"], kvLayers: 28, kvHeads: 2, headDim: 128),
        ModelSpec(repo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", file: "qwen2.5-1.5b-instruct-q8_0.gguf",
                  displayName: "Qwen2.5 1.5B Instruct", family: "Qwen2.5", paramsB: 1.54, quant: "Q8_0",
                  sizeBytes: 1_894_532_128,
                  blurb: "同款模型的无损档位，1.8 GB 也能塞进 8 GB 显存。",
                  tags: ["轻量", "高质量"], kvLayers: 28, kvHeads: 2, headDim: 128),

        ModelSpec(repo: "Qwen/Qwen2.5-3B-Instruct-GGUF", file: "qwen2.5-3b-instruct-q4_k_m.gguf",
                  displayName: "Qwen2.5 3B Instruct", family: "Qwen2.5", paramsB: 3.09, quant: "Q4_K_M",
                  sizeBytes: 2_104_932_768,
                  blurb: "综合性价比最高的一档。中文和日常问答都够用，显存占用不到 3 GB。",
                  tags: ["通用", "中文"], kvLayers: 36, kvHeads: 2, headDim: 128),
        ModelSpec(repo: "Qwen/Qwen2.5-3B-Instruct-GGUF", file: "qwen2.5-3b-instruct-q5_k_m.gguf",
                  displayName: "Qwen2.5 3B Instruct", family: "Qwen2.5", paramsB: 3.09, quant: "Q5_K_M",
                  sizeBytes: 2_438_740_384,
                  blurb: "3B 的高精度档，量化损失更小，速度略降。",
                  tags: ["通用"], kvLayers: 36, kvHeads: 2, headDim: 128),
        ModelSpec(repo: "Qwen/Qwen2.5-3B-Instruct-GGUF", file: "qwen2.5-3b-instruct-q8_0.gguf",
                  displayName: "Qwen2.5 3B Instruct", family: "Qwen2.5", paramsB: 3.09, quant: "Q8_0",
                  sizeBytes: 3_616_088_480,
                  blurb: "3B 的无损档，体积换精度，8 GB 显存跑起来仍然宽裕。",
                  tags: ["通用", "高质量"], kvLayers: 36, kvHeads: 2, headDim: 128),

        ModelSpec(repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", file: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
                  displayName: "Qwen2.5 7B Instruct", family: "Qwen2.5", paramsB: 7.62, quant: "Q4_K_M",
                  sizeBytes: 4_683_074_240,
                  blurb: "7B 的推荐档。推理与代码明显强于 3B，本机实测约 20 tok/s。",
                  tags: ["通用", "代码"], kvLayers: 28, kvHeads: 4, headDim: 128),
        ModelSpec(repo: "bartowski/Qwen2.5-7B-Instruct-GGUF", file: "Qwen2.5-7B-Instruct-Q5_K_M.gguf",
                  displayName: "Qwen2.5 7B Instruct", family: "Qwen2.5", paramsB: 7.62, quant: "Q5_K_M",
                  sizeBytes: 5_444_831_936,
                  blurb: "7B 的高精度档，8 GB 显存跑它会偏紧，长上下文容易溢出。",
                  tags: ["通用", "高质量"], kvLayers: 28, kvHeads: 4, headDim: 128),

        ModelSpec(repo: "Qwen/Qwen3-0.6B-GGUF", file: "Qwen3-0.6B-Q8_0.gguf",
                  displayName: "Qwen3 0.6B", family: "Qwen3", paramsB: 0.60, quant: "Q8_0",
                  sizeBytes: 639_446_688,
                  blurb: "610 MB 的小模型。测链路、调参、验证部署都够用。",
                  tags: ["测试", "轻量"], kvLayers: 28, kvHeads: 8, headDim: 128),
        ModelSpec(repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF", file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                  displayName: "Qwen3 4B Instruct 2507", family: "Qwen3", paramsB: 4.02, quant: "Q4_K_M",
                  sizeBytes: 2_497_281_120,
                  blurb: "新一代 4B，中文语感与指令遵循都比 2.5 代好一截，显存同样只占 3 GB 出头。",
                  tags: ["通用", "中文"], kvLayers: 36, kvHeads: 8, headDim: 128),
        ModelSpec(repo: "Qwen/Qwen3-8B-GGUF", file: "Qwen3-8B-Q4_K_M.gguf",
                  displayName: "Qwen3 8B", family: "Qwen3", paramsB: 8.19, quant: "Q4_K_M",
                  sizeBytes: 5_027_783_488,
                  blurb: "8B 档位。权重 4.7 GB 加 1.1 GB KV 缓存，8 GB 显存属于偏紧。",
                  tags: ["通用"], kvLayers: 36, kvHeads: 8, headDim: 128),
        ModelSpec(repo: "Qwen/Qwen3-14B-GGUF", file: "Qwen3-14B-Q4_K_M.gguf",
                  displayName: "Qwen3 14B", family: "Qwen3", paramsB: 14.8, quant: "Q4_K_M",
                  sizeBytes: 9_001_752_960,
                  blurb: "8 GB 显存装不下。想跑它需要 16 GB 卡，或把上下文砍到 2K 硬挤。",
                  tags: ["超显存"], kvLayers: 40, kvHeads: 8, headDim: 128),

        ModelSpec(repo: "unsloth/Llama-3.2-3B-Instruct-GGUF", file: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
                  displayName: "Llama 3.2 3B Instruct", family: "Llama", paramsB: 3.21, quant: "Q4_K_M",
                  sizeBytes: 2_019_377_600,
                  blurb: "Meta 的 3B，多语言和英文更顺，中文一般。",
                  tags: ["英文", "多语言"], kvLayers: 28, kvHeads: 8, headDim: 128),
        ModelSpec(repo: "ggml-org/gemma-3-4b-it-GGUF", file: "gemma-3-4b-it-Q4_K_M.gguf",
                  displayName: "Gemma 3 4B IT", family: "Gemma", paramsB: 4.30, quant: "Q4_K_M",
                  sizeBytes: 2_489_757_856,
                  blurb: "谷歌 4B，长上下文表现好。注意它的 KV 缓存有 1 GB 以上。",
                  tags: ["长文本"], kvLayers: 34, kvHeads: 4, headDim: 256),
        ModelSpec(repo: "bartowski/Phi-3.5-mini-instruct-GGUF", file: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
                  displayName: "Phi-3.5 mini Instruct", family: "Phi", paramsB: 3.82, quant: "Q4_K_M",
                  sizeBytes: 2_393_232_672,
                  blurb: "微软 3.8B，数学和代码不错。它是 MHA，KV 缓存特别大，估算占用会明显偏高。",
                  tags: ["代码", "数学"], kvLayers: 32, kvHeads: 32, headDim: 96),
        ModelSpec(repo: "bartowski/Phi-3.5-mini-instruct-GGUF", file: "Phi-3.5-mini-instruct-Q5_K_M.gguf",
                  displayName: "Phi-3.5 mini Instruct", family: "Phi", paramsB: 3.82, quant: "Q5_K_M",
                  sizeBytes: 2_815_276_320,
                  blurb: "Phi-3.5 的高精度档，KV 缓存依旧占 3 GB。",
                  tags: ["代码", "数学"], kvLayers: 32, kvHeads: 32, headDim: 96),
        ModelSpec(repo: "bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF", file: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
                  displayName: "DeepSeek-R1 Distill Qwen 7B", family: "DeepSeek", paramsB: 7.62, quant: "Q4_K_M",
                  sizeBytes: 4_683_073_504,
                  blurb: "带思维链的推理模型。会先输出一大段思考再给正文，需要把输入框右下角的「深度思考」打开。",
                  tags: ["推理"], kvLayers: 28, kvHeads: 4, headDim: 128),
        ModelSpec(repo: "bartowski/Mistral-7B-Instruct-v0.3-GGUF", file: "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf",
                  displayName: "Mistral 7B Instruct v0.3", family: "Mistral", paramsB: 7.25, quant: "Q4_K_M",
                  sizeBytes: 4_372_812_000,
                  blurb: "经典 7B，英文指令跟随稳，中文偏弱。",
                  tags: ["英文"], kvLayers: 32, kvHeads: 8, headDim: 128),
        ModelSpec(repo: "bartowski/Qwen2.5-14B-Instruct-GGUF", file: "Qwen2.5-14B-Instruct-Q4_K_M.gguf",
                  displayName: "Qwen2.5 14B Instruct", family: "Qwen2.5", paramsB: 14.8, quant: "Q4_K_M",
                  sizeBytes: 8_988_110_976,
                  blurb: "权重本身就 8.4 GB，8 GB 显存的卡放不下。",
                  tags: ["超显存"], kvLayers: 48, kvHeads: 8, headDim: 128)
    ]

    /// 按显存给出推荐顺序：装得下的排前面，同档里参数更大、量化更高的质量更好。
    static func recommended(for vramGB: Double, context: Int = 8192) -> [ModelSpec] {
        specs.sorted { a, b in
            let fa = a.fit(vramGB: vramGB, context: context)
            let fb = b.fit(vramGB: vramGB, context: context)
            let rank: (ModelSpec.Fit) -> Int = {
                switch $0 {
                case .comfortable: return 0
                case .tight: return 1
                case .over: return 2
                }
            }
            if rank(fa) != rank(fb) { return rank(fa) < rank(fb) }
            if a.paramsB != b.paramsB { return a.paramsB > b.paramsB }
            return a.sizeBytes > b.sizeBytes
        }
    }
}
