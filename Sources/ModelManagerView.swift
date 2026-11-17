import SwiftUI
import AppKit

/// 模型管理：本机 GGUF 列表 + 推荐模型清单（只给链接，不在 app 内下载）。
/// 用户自行从浏览器下载后，把 .gguf 放到扫描目录即可。
struct ModelManagerView: View {
    let current: String
    let vramGB: Double

    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .local
    @State private var localModels: [URL] = []
    @State private var contextSize = 8192
    /// 估算用的 KV 精度：跟着当前设置走，开了量化就按 q8_0 算，
    /// 否则会把实际跑得动的模型误标成「超出显存」。
    @State private var kvType: GGUFInfo.KVType = .fp16

    enum Tab: String, CaseIterable, Identifiable {
        case local = "本机模型"
        case remote = "获取模型"
        var id: String { rawValue }
        var label: String { L(rawValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch tab {
                case .local: localList
                case .remote: remoteList
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear {
            localModels = ServerController.discoverModels()
            contextSize = ServerController.shared.contextSize
            kvType = ServerController.shared.kvQuant ? .q8_0 : .fp16
            if ProcessInfo.processInfo.environment["MDMODELTEST"] == "2"
                || UserDefaults.standard.string(forKey: "MDModelTab") == "remote" {
                tab = .remote
            }
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack {
            Text("模型管理")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("关闭") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.subtle)
        }
        .padding(16)
    }

    // MARK: - 本机模型

    private var localList: some View {
        Group {
            if localModels.isEmpty {
                emptyHint(L("~/models、~/Downloads 和 App Support 里都没找到 .gguf 文件。\n到「获取模型」查看推荐链接，下载后放进这些目录。"))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(localModels, id: \.self) { url in
                            Button {
                                dismiss()
                                ServerController.shared.setModel(url.path)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: url.path == current ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(url.path == current ? Palette.accent : Palette.subtle.opacity(0.4))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.lastPathComponent)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.text)
                                            .lineLimit(1)
                                        Text(sizeLabel(url))
                                            .font(.system(size: 10))
                                            .foregroundStyle(Palette.subtle)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 获取模型（只给链接，不下载）

    private var remoteList: some View {
        VStack(spacing: 0) {
            // 顶部说明 + HF 搜索页链接
            VStack(alignment: .leading, spacing: 6) {
                Text("Q Studio 不在应用内下载模型。点击下面的链接在浏览器中打开，下载 .gguf 后放进 ~/models、~/Downloads 或 App Support 目录，回到「本机模型」即可使用。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                if let searchURL = URL(string: "\(ModelCatalog.mirrors.first ?? "https://hf-mirror.com")/models?search=gguf") {
                    Button {
                        NSWorkspace.shared.open(searchURL)
                    } label: {
                        HStack(spacing: 4) {
                            Text("浏览全部 GGUF 模型")
                            Image(systemName: "arrow.up.right.square")
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(ModelCatalog.recommended(for: vramGB, context: contextSize)) { spec in
                        remoteRow(spec)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteRow(_ spec: ModelSpec) -> some View {
        let fit = spec.fit(vramGB: vramGB, context: contextSize, kvType: kvType)
        let installed = ModelCatalog.isInstalled(spec)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(spec.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                chip(spec.quant, tint: Palette.accent)
                chip(fit.label, tint: fitTint(fit))
                if installed {
                    chip("已下载", tint: Color(red: 0.18, green: 0.68, blue: 0.35))
                }
                Spacer()
                if let url = spec.pageURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Text("打开网页")
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .help(url.absoluteString)
                }
            }

            Text(L(spec.blurb))
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                meta(String(format: "%.2f GB", spec.sizeGB))
                meta("\(L("估算显存")) \(String(format: "%.1f", spec.estimatedVRAMGB(context: contextSize, kvType: kvType))) GB")
                meta("\(L("KV 缓存")) \(String(format: "%.2f", spec.kvCacheGB(context: contextSize, kvType: kvType))) GB \(kvType.label)")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(L("显存")) \(String(format: "%.0f", vramGB)) GB · \(L("上下文")) \(contextSize)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                Spacer()
                Button(L("打开模型目录")) {
                    try? FileManager.default.createDirectory(at: ModelCatalog.modelsDirectory,
                                                            withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ModelCatalog.modelsDirectory)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.accent)
            }
            Text(Lf("显存估算 = 权重文件 + KV 缓存(%@) + 运行时开销(0.6 GB + 权重×5%)，按 %@ 上下文计算。只是估算，实际占用随上下文长度浮动。",
                    kvType.label, "\(contextSize)"))
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.subtle.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 小工具

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func meta(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Palette.subtle)
    }

    private func fitTint(_ fit: ModelSpec.Fit) -> Color {
        switch fit {
        case .comfortable: return Color(red: 0.18, green: 0.68, blue: 0.35)
        case .tight: return Color(red: 0.95, green: 0.62, blue: 0.13)
        case .over: return Color(red: 0.85, green: 0.25, blue: 0.25)
        }
    }

    private func sizeLabel(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return String(format: "%.2f GB", Double(size) / 1_073_741_824)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.subtle)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
