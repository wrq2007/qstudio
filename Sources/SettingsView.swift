import SwiftUI

/// 软件设置。系统提示词（引导模型）住在这里，不占输入框的位置。
struct SettingsView: View {
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var server: ServerController
    @EnvironmentObject private var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearArchived = false
    @State private var pendingDelete: ChatSession?
    @State private var selectedTab: SettingsTab = UserDefaults.standard.string(forKey: "MDSettingTab") == "archives"
        ? .archives : UserDefaults.standard.string(forKey: "MDSettingTab") == "about" ? .about : .general
    @State private var archiveSearch = ""

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case general, archives, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: return "通用"
            case .archives: return "归档对话"
            case .about: return "关于"
            }
        }
    }

    private var archivedSessions: [ChatSession] {
        chat.sessions.filter { $0.archived }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filteredArchives: [ChatSession] {
        let q = archiveSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return archivedSessions }
        return archivedSessions.filter { s in
            s.title.lowercased().contains(q)
                || s.messages.contains { $0.text.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(L(tab.label)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .general:
                        languageSection
                        systemPrompt
                        contextSection
                        kvSection
                    case .archives:
                        archivedSection
                    case .about:
                        aboutSection
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .confirmationDialog(L("清空所有归档？"), isPresented: $confirmClearArchived, titleVisibility: .visible) {
            Button(Lf("清空 %lld 段对话", archivedSessions.count), role: .destructive) {
                chat.deleteAllArchived()
            }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(Lf("这 %lld 段归档对话及其全部消息会被永久删除，删了就找不回来了。", archivedSessions.count))
        }
        .confirmationDialog(L("删除归档？"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button(L("删除"), role: .destructive) {
                if let s = pendingDelete { chat.delete(s.id) }
                pendingDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { Lf("「%@」将被永久删除。", $0.title) } ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: 系统提示词

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("界面语言")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)
            Picker("", selection: Binding(
                get: { lang.language },
                set: { lang.language = $0 }
            )) {
                ForEach(AppLanguage.allCases) { l in
                    Text(l.label).tag(l)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            Text("切换后立即生效，无需重启。")
                .font(.system(size: 10))
                .foregroundStyle(Palette.subtle)
        }
    }

    private var systemPrompt: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("新对话默认角色提示词")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)

            Text("只给之后新建的对话用：告诉模型该怎么回答（领域、语气、格式）。已有对话各自带着自己的角色提示词，改这里不会影响它们；要改某一段，去输入框上方那条提示点编辑。")
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: Binding(
                get: { chat.instruction },
                set: { chat.instruction = $0; chat.saveInstruction() }
            ))
            .font(.system(size: 12))
            .foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.background))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))

            HStack(spacing: 8) {
                Text("例如：你是一个地质学导师，回答时先给结论再给依据。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle.opacity(0.8))
                Spacer()
                Button("清空") {
                    chat.instruction = ""
                    chat.saveInstruction()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.subtle)
                .disabled(chat.instruction.isEmpty)
            }
        }
    }

    // MARK: 上下文

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("默认上下文长度")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)

            HStack(spacing: 8) {
                ForEach(ServerController.contextOptions, id: \.self) { size in
                    Button {
                        server.setContextSize(size)
                    } label: {
                        Text("\(size / 1024)K")
                            .font(.system(size: 11.5, weight: size == server.contextSize ? .semibold : .regular))
                            .foregroundStyle(size == server.contextSize ? .white : Palette.text.opacity(0.85))
                            .frame(width: 44, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(size == server.contextSize ? Palette.accent : Palette.subtle.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            if let a = server.contextAdvice {
                Text(Lf("按 %@ GB 显存和当前模型（权重 %@ GB，KV 缓存 %@ GB）建议用 %lldK。",
                        String(format: "%.0f", a.vramGB),
                        String(format: "%.1f", a.weightsGB),
                        String(format: "%.2f", a.kvGB),
                        a.recommended / 1024))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: KV 缓存精度

    private var kvSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("KV 缓存精度")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)

            HStack(spacing: 8) {
                ForEach([GGUFInfo.KVType.q8_0, GGUFInfo.KVType.fp16], id: \.self) { t in
                    let on = server.kvQuant == (t == .q8_0)
                    Button {
                        server.setKVQuant(t == .q8_0)
                    } label: {
                        Text(t.label)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? .white : Palette.text.opacity(0.85))
                            .frame(width: 58, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(on ? Palette.accent : Palette.subtle.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            Text("KV 缓存会随上下文长度线性增长，压到 8 位大约省一半显存，同样的显存能开两倍上下文。切换后模型会重新加载。")
                .font(.system(size: 10))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)

            if let note = server.kvQuantNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.80, green: 0.50, blue: 0.10))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 归档管理

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("归档的对话")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                if !archivedSessions.isEmpty {
                    Button("清空全部") { confirmClearArchived = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.85, green: 0.25, blue: 0.25))
                }
            }
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.subtle)
                TextField(L("搜索归档对话"), text: $archiveSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.background))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border))

            if archivedSessions.isEmpty {
                Text("还没有归档的对话。在对话列表右键可以归档。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
            } else if filteredArchives.isEmpty {
                Text("没有匹配的归档对话")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredArchives) { s in
                        HStack(spacing: 7) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.displayTitle).font(.system(size: 11.5)).foregroundStyle(Palette.text).lineLimit(1)
                                Text("\(s.messages.count) \(L("条消息"))").font(.system(size: 9.5)).foregroundStyle(Palette.subtle)
                            }
                            Spacer(minLength: 4)
                            Button("恢复") { chat.setArchived(s.id, false) }
                                .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Palette.accent)
                            Button {
                                pendingDelete = s
                            } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.red.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.background))
                        if s.id != filteredArchives.last?.id { Divider().opacity(0.4) }
                    }
                }
            }
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("关于")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Palette.text)

            row("当前模型", server.modelPath.isEmpty ? "未选择" : (server.modelPath as NSString).lastPathComponent)
            row("模型目录", ModelCatalog.modelsDirectory.path)
            row("对话记录", (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LocalModel/sessions.json")).path)
            if let info = server.modelInfo {
                row("架构", "\(info.architecture) · \(info.summary)")
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(L(key))
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                .lineLimit(1)
                .frame(width: 98, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
