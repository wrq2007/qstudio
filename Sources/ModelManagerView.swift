import SwiftUI
import AppKit

/// 模型管理：一边看本机已有的 GGUF，一边从镜像站在线下载。
///
/// 下载只在本页点「下载」时才会发生，app 不会自己拉任何东西。
struct ModelManagerView: View {
    let current: String
    let vramGB: Double

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dl = ModelDownloader.shared

    @State private var tab: Tab = .local
    @State private var localModels: [URL] = []
    @State private var contextSize = 8192
    @State private var pendingRedownload: ModelSpec?

    enum Tab: String, CaseIterable, Identifiable {
        case local = "本机模型"
        case remote = "在线下载"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
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
        .confirmationDialog(
            "重新下载这个模型？",
            isPresented: Binding(
                get: { pendingRedownload != nil },
                set: { if !$0 { pendingRedownload = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("重新下载", role: .destructive) {
                if let s = pendingRedownload { dl.reset(s); dl.start(s) }
                pendingRedownload = nil
            }
            Button("取消", role: .cancel) { pendingRedownload = nil }
        } message: {
            Text("已有的同名文件会被移到废纸篓后再下载。如果它正在使用中，下载会被拒绝——请先切换到别的模型。")
        }
        .onAppear {
            localModels = ServerController.discoverModels()
            contextSize = ServerController.shared.contextSize
            if ProcessInfo.processInfo.environment["MDMODELTEST"] == "2" {
                tab = .remote
            }
        }
        .onChange(of: dl.states) { _, _ in
            localModels = ServerController.discoverModels()
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
                emptyHint("~/models、~/Downloads 和 App Support 里都没找到 .gguf 文件。\n切到「在线下载」可以直接拉一个。")
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

    // MARK: - 在线下载

    private var remoteList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ModelCatalog.recommended(for: vramGB, context: contextSize)) { spec in
                    remoteRow(spec)
                    Divider().opacity(0.4)
                }
            }
        }
    }

    @ViewBuilder
    private func remoteRow(_ spec: ModelSpec) -> some View {
        let fit = spec.fit(vramGB: vramGB, context: contextSize)
        let installed = ModelCatalog.isInstalled(spec)
        let state = dl.state(for: spec)

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
            }

            Text(spec.blurb)
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                meta(String(format: "%.2f GB", spec.sizeGB))
                meta("估算显存 \(String(format: "%.1f", spec.estimatedVRAMGB(context: contextSize))) GB")
                meta("KV 缓存 \(String(format: "%.2f", spec.kvCacheGB(context: contextSize))) GB")
                Spacer()
                action(spec, state: state, fit: fit, installed: installed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func action(_ spec: ModelSpec,
                        state: DownloadPhase?,
                        fit: ModelSpec.Fit,
                        installed: Bool) -> some View {
        switch state {
        case .running(let received, let total):
            VStack(alignment: .trailing, spacing: 3) {
                ProgressView(value: Double(received), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 170)
                HStack(spacing: 6) {
                    Text(progressText(received, total, spec: spec))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.subtle)
                    Button("取消") { dl.cancel(spec) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accent)
                }
            }
        case .completed(let url):
            HStack(spacing: 6) {
                if url.path == current {
                    Text("使用中")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.18, green: 0.68, blue: 0.35))
                } else {
                    Button("使用") {
                        dismiss()
                        ServerController.shared.setModel(url.path)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.accent)
                }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                    .lineLimit(1)
                Button("重试") { dl.start(spec) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.accent)
            }
        case .cancelled:
            Button("继续下载") { dl.start(spec) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.accent)
        default:
            if installed {
                Button("重新下载") { pendingRedownload = spec }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                    .help("删除本地副本并重新下载（会先移到废纸篓）")
            } else {
                Button {
                    dl.start(spec)
                } label: {
                    Text(fit == .over ? "仍要下载" : "下载")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(fit == .over ? Palette.subtle : .white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(fit == .over ? Palette.subtle.opacity(0.25) : Palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("显存 \(String(format: "%.0f", vramGB)) GB · 上下文 \(String(contextSize))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                Spacer()
                Button("打开模型目录") {
                    try? FileManager.default.createDirectory(at: ModelCatalog.modelsDirectory,
                                                            withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ModelCatalog.modelsDirectory)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.accent)
            }
            Text("显存估算 = 权重文件 + KV 缓存(fp16, ctx \(contextSize)) + 运行时开销(0.6 GB + 权重×5%)。只是估算，实际占用随上下文长度浮动。")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.subtle.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Text("下载源：\(ModelCatalog.mirrors.joined(separator: " → "))")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.subtle.opacity(0.85))
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

    private func progressText(_ received: Int64, _ total: Int64, spec: ModelSpec) -> String {
        let pct = total > 0 ? Double(received) / Double(total) * 100 : 0
        let speed = dl.speeds[spec.id] ?? 0
        return String(format: "%.0f%% · %.2f/%.2f GB", pct,
                      Double(received) / 1_073_741_824,
                      Double(total) / 1_073_741_824)
            + (speed > 0 ? String(format: " · %.1f MB/s", speed / 1_048_576) : "")
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Palette.subtle)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
