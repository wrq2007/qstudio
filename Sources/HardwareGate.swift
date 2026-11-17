import Foundation
import Metal
import IOKit

/// 一块被 Metal / IOKit 识别到的 GPU。
struct GPUInfo: Identifiable {
    let id: UInt64            // IORegistryEntryID，与 MTLDevice.registryID 一致
    let name: String
    let ioClass: String
    let vramGB: Double
    let metalFamily: String
    let removable: Bool

    var isAMD: Bool {
        let c = ioClass.lowercased(), n = name.lowercased()
        return c.contains("amd") || n.contains("radeon") || c.contains("atic")
    }

    /// NVIDIA 独显。NullMoth 1401 / nvidia-macos-driver 装好后，Metal 会报告 NVIDIA 设备。
    var isNVIDIA: Bool {
        let c = ioClass.lowercased(), n = name.lowercased()
        return c.contains("nvidia") || n.contains("nvidia") || n.contains("geforce")
            || n.contains("rtx") || n.contains("quadro") || n.contains("titan")
    }

    var isIntelIntegrated: Bool {
        let c = ioClass.lowercased(), n = name.lowercased()
        return c.contains("intel") || n.contains("intel")
    }

    var isAppleSilicon: Bool {
        ioClass.lowercased().contains("agx")
    }

    /// 是独立显卡（非核显、非 Apple 集成 GPU）
    var isDiscrete: Bool { !isIntelIntegrated && !isAppleSilicon }

    var vendorLabel: String {
        if isAMD { return "AMD" }
        if isNVIDIA { return "NVIDIA" }
        if isAppleSilicon { return "Apple" }
        if isIntelIntegrated { return "Intel" }
        return "未知"
    }
}

enum Verdict {
    /// warning 非空时界面显示一条性能提示横幅，但不阻塞使用
    case supported(GPUInfo, warning: String? = nil)
    case refused(title: String, reason: String)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }
}

struct MachineProfile {
    let cpu: String
    let isAppleSilicon: Bool
    let macos: String
    let gpus: [GPUInfo]
}

/// 硬件判定：放行所有 Intel x86 机器 + 任意 Metal GPU，但对非理想组合给出性能警告。
/// 设计原则：能跑就让用户跑，把性能预期讲清楚，而不是一刀切拒绝。
enum HardwareGate {

    // MARK: - 系统信息

    static var cpuBrand: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "未知处理器"
        }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 {
            return value == 1
        }
        return false
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    // MARK: - GPU 探测

    static func probe() -> MachineProfile {
        MachineProfile(cpu: cpuBrand,
                       isAppleSilicon: isAppleSilicon,
                       macos: macOSVersion,
                       gpus: probeGPUs())
    }

    static func probeGPUs() -> [GPUInfo] {
        var devices: [MTLDevice] = MTLCopyAllDevices()
        if devices.isEmpty, let fallback = MTLCreateSystemDefaultDevice() {
            devices = [fallback]
        }
        return devices.map { dev in
            GPUInfo(id: dev.registryID,
                    name: dev.name,
                    ioClass: ioClass(for: dev.registryID),
                    vramGB: Double(dev.recommendedMaxWorkingSetSize) / 1_073_741_824.0,
                    metalFamily: familyLabel(dev),
                    removable: dev.isRemovable)
        }
    }

    private static func ioClass(for entryID: UInt64) -> String {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var eid: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &eid)
            if eid == entryID {
                let prop = IORegistryEntryCreateCFProperty(service,
                                                           "IOClass" as CFString,
                                                           kCFAllocatorDefault, 0)
                IOObjectRelease(service)
                return (prop?.takeRetainedValue() as? String) ?? ""
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return ""
    }

    private static func familyLabel(_ device: MTLDevice) -> String {
        if device.supportsFamily(.mac2) { return "Metal 3 (Mac2)" }
        if device.supportsFamily(.common3) { return "Metal 2 (Common3)" }
        if device.supportsFamily(.common2) { return "Metal (Common2)" }
        return "Metal 1"
    }

    // MARK: - 判定

    static func evaluate(_ profile: MachineProfile) -> Verdict {
        if profile.isAppleSilicon {
            return .refused(
                title: L("这是 Apple Silicon 机器"),
                reason: L("苹果芯片走的是统一内存 + 原生 Metal 后端，llama.cpp、Ollama、LM Studio 都能直接吃满 GPU，不需要也不应该经 MoltenVK 转发。装这个反而更慢。")
            )
        }

        // 没有任何 Metal 加速器：Vulkan 路径无从谈起，真的跑不了
        guard let gpu = profile.gpus.first else {
            return .refused(
                title: L("没有可用的 GPU"),
                reason: L("系统没有报告任何 Metal 加速器，无法运行推理。请确认显卡驱动已正确安装。")
            )
        }

        // 优先挑独显（AMD / NVIDIA / 其它），没有独显才退回核显
        let discrete = profile.gpus.first { $0.isDiscrete }
        let chosen = discrete ?? gpu

        // 显存过小不拒绝，只警告——小模型（0.6B/1.5B Q4）仍有机会跑
        var warnings: [String] = []

        if chosen.isIntelIntegrated {
            warnings.append(Lf("当前是 Intel 核显（%@）：与系统内存共享带宽，推理速度会明显偏慢，建议选 1.5B 以下的小模型并把上下文调到 2K–4K。", chosen.name))
        } else if chosen.isNVIDIA {
            warnings.append(Lf("检测到 NVIDIA 显卡（%@）。请确认已安装 NullMoth 1401 / nvidia-macos-driver 且 Metal 状态为 supported——没有 Metal 驱动时 MoltenVK 看不到这张卡，推理会退回 CPU 或失败。", chosen.name))
        } else if !chosen.isAMD {
            warnings.append(Lf("未识别的显卡型号（%@），性能表现未知，建议先用小模型试跑。", chosen.name))
        }

        if chosen.vramGB < 2.0 {
            warnings.append(Lf("显存约 %.1f GB，偏小：只能跑 1.5B 以下的量化模型，长上下文会溢出到内存导致变慢。", chosen.vramGB))
        }

        return .supported(chosen, warning: warnings.isEmpty ? nil : warnings.joined(separator: "\n\n"))
    }
}
