import SwiftUI

/// 左栏对话历史：切换、归档、删除。
///
/// 布局参照 WorkBuddy：顶部是「标题 + 图标行」，下面是会话列表（标题 + 右侧时间），
/// 当前会话浅色圆角高亮。侧栏和主区之间有一条明确的竖分割线。
struct SidebarView: View {
    @EnvironmentObject private var chat: ChatStore

    @State private var pendingDelete: ChatSession?
    @State private var hoveredID: UUID?
    @State private var showSettings = false
    @State private var renamingGroup: WorkGroup?
    @State private var renameText = ""
    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var pendingGroupDelete: WorkGroup?
    @State private var chatSearch = ""

    /// 按当前选中的组筛选；nil = 全部；再按搜索词过滤
    private var activeSessions: [ChatSession] {
        let q = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return chat.sessions.filter { s in
            guard !s.archived else { return false }
            if chat.showUngroupedOnly { return s.groupID == nil }
            if let gid = chat.selectedGroupID { return s.groupID == gid }
            return true
        }.filter { s in
            guard !q.isEmpty else { return true }
            return s.title.lowercased().contains(q)
                || s.messages.contains { $0.text.lowercased().contains(q) }
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func groupCount(_ id: UUID?) -> Int {
        chat.sessions.filter { !$0.archived && $0.groupID == id }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            // 上下各占一半：上半工作组，下半对话
            GeometryReader { geo in
                let half = geo.size.height * 0.5
                VStack(alignment: .leading, spacing: 0) {
                    groupSection
                        .frame(height: half)
                    Divider().opacity(0.4)
                    list
                        .frame(height: geo.size.height - half)
                }
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 214)
        .background(Palette.background)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(chat)
                .localized()
        }
        .sheet(isPresented: $showNewGroup) {
            groupNameSheet(isNew: true)
                .localized()
        }
        .sheet(item: $renamingGroup) { g in
            groupNameSheet(isNew: false, group: g)
                .localized()
        }
        .confirmationDialog(L("删除工作组？"), isPresented: Binding(
            get: { pendingGroupDelete != nil },
            set: { if !$0 { pendingGroupDelete = nil } }
        ), titleVisibility: .visible) {
            Button(L("删除"), role: .destructive) {
                if let g = pendingGroupDelete {
                    chat.deleteGroup(g.id)
                    if chat.selectedGroupID == g.id { chat.selectedGroupID = nil }
                }
                pendingGroupDelete = nil
            }
            Button(L("取消"), role: .cancel) { pendingGroupDelete = nil }
        } message: {
            Text(pendingGroupDelete.map { Lf("「%@」会被删除，组里的对话会变成未分组（对话本身不删）。", $0.name) } ?? "")
        }
        .confirmationDialog(
            L("删除这段对话？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("删除"), role: .destructive) {
                if let s = pendingDelete { chat.delete(s.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete.map { Lf("「%@」及其消息会一起删掉，删了就找不回来了。", $0.title) } ?? "")
        }
    }

    // MARK: - 顶部图标行

    private var header: some View {
        HStack(spacing: 4) {
            Text("对话历史")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.subtle)
            Spacer()

            Button {
                chat.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chat.canCreateNewSession ? Palette.subtle : Palette.subtle.opacity(0.3))
            .disabled(!chat.canCreateNewSession)
            .help(chat.canCreateNewSession ? L("新对话 ⌘N") : L("当前已经是新对话了"))

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - 工作组区（上半）

    private var groupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("工作组")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.subtle)
                Spacer()
                Button {
                    newGroupName = ""
                    showNewGroup = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.subtle)
                .help("新建工作组")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    // 「全部对话」伪组
                    groupRow(id: nil, name: "全部对话", icon: "tray.full", count: groupCount(nil)
                             + chat.groups.reduce(0) { $0 + groupCount($1.id) })
                    ForEach(chat.groups) { g in
                        groupRow(id: g.id, name: g.name, icon: "folder", count: groupCount(g.id))
                    }
                    // 未分组
                    if chat.groups.contains(where: { groupCount($0.id) > 0 }) {
                        groupRow(id: nil, name: "未分组", icon: "questionmark.folder", count: groupCount(nil), isUngrouped: true)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    private func groupRow(id: UUID?, name: String, icon: String, count: Int, isUngrouped: Bool = false) -> some View {
        let isAll = !isUngrouped && id == nil
        let isSelected = isUngrouped ? chat.showUngroupedOnly
                        : isAll ? (!chat.showUngroupedOnly && chat.selectedGroupID == nil)
                        : (chat.selectedGroupID == id && !chat.showUngroupedOnly)

        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(isSelected ? Palette.accent : Palette.subtle.opacity(0.8))
            Text(isAll ? L("全部对话") : isUngrouped ? L("未分组") : name)
                .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Palette.text : Palette.text.opacity(0.82))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.subtle.opacity(0.6))
                .fixedSize()
            if let id, !isUngrouped {
                Menu {
                    Button {
                        if let g = chat.groups.first(where: { $0.id == id }) {
                            renameText = g.name
                            renamingGroup = g
                        }
                    } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) {
                        pendingGroupDelete = chat.groups.first { $0.id == id }
                    } label: { Label("删除组", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 10))
                        .foregroundStyle(Palette.subtle.opacity(hoveredID == id ? 0.95 : 0.35))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(isSelected ? Palette.accent.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.12)) {
                if isUngrouped {
                    chat.showUngroupedOnly = !chat.showUngroupedOnly
                    chat.selectedGroupID = nil
                } else if isAll {
                    chat.showUngroupedOnly = false
                    chat.selectedGroupID = nil
                } else {
                    chat.showUngroupedOnly = false
                    chat.selectedGroupID = (chat.selectedGroupID == id) ? nil : id
                }
            }
        }
        .onHover { hovering in
            if let id { hoveredID = hovering ? id : (hoveredID == id ? nil : hoveredID) }
        }
    }

    // MARK: - 列表

    @ViewBuilder
    private var list: some View {
        if chat.sessions.isEmpty {
            VStack(spacing: 6) {
                Text("还没有对话")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.subtle)
                Text("聊一句就会自动出现在这里")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.subtle)
                    TextField(L("搜索对话"), text: $chatSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.text)
                    if !chatSearch.isEmpty {
                        Button {
                            chatSearch = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.subtle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .padding(.top, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(activeSessions) { s in
                            row(s)
                        }
                        if activeSessions.isEmpty && !chatSearch.isEmpty {
                            Text("没有匹配的对话")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.subtle)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 20)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Palette.subtle.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    /// 「加到工作组」子菜单，右键菜单和省略号菜单共用
    @ViewBuilder
    private func assignGroupMenu(for s: ChatSession) -> some View {
        Menu {
            Button {
                chat.assign(s.id, to: nil)
            } label: {
                Label("未分组", systemImage: s.groupID == nil ? "checkmark" : "questionmark.folder")
            }
            if !chat.groups.isEmpty { Divider() }
            ForEach(chat.groups) { g in
                Button {
                    chat.assign(s.id, to: g.id)
                } label: {
                    Label(g.name, systemImage: s.groupID == g.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Label("加到工作组", systemImage: "folder.badge.plus")
        }
    }

    private func row(_ s: ChatSession) -> some View {
        let isCurrent = s.id == chat.currentID
        let isHovered = hoveredID == s.id

        return HStack(spacing: 2) {
            Button {
                chat.select(s.id)
            } label: {
                HStack(spacing: 5) {
                    if s.archived {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.subtle)
                    }
                    Text(s.displayTitle)
                        .font(.system(size: 11.5, weight: isCurrent ? .medium : .regular))
                        .foregroundStyle(isCurrent ? Palette.text : Palette.text.opacity(0.82))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timeLabel(s.updatedAt))
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.subtle.opacity(isCurrent ? 0.9 : 0.6))
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isCurrent ? Palette.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                assignGroupMenu(for: s)
                Divider()
                Button {
                    chat.toggleArchive(s.id)
                } label: {
                    Label(s.archived ? "取消归档" : "归档",
                          systemImage: s.archived ? "tray.and.arrow.up" : "archivebox")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDelete = s
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle.opacity(isHovered || isCurrent ? 0.95 : 0.35))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.trailing, 4)
        .onHover { hovering in
            hoveredID = hovering ? s.id : (hoveredID == s.id ? nil : hoveredID)
        }
        .contextMenu {
            assignGroupMenu(for: s)
            Divider()
            Button {
                chat.toggleArchive(s.id)
            } label: {
                Label(s.archived ? "取消归档" : "归档",
                      systemImage: s.archived ? "tray.and.arrow.up" : "archivebox")
            }
            Button(role: .destructive) {
                pendingDelete = s
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 工作组命名弹窗

    @ViewBuilder
    private func groupNameSheet(isNew: Bool, group: WorkGroup? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "新建工作组" : "重命名工作组")
                .font(.system(size: 14, weight: .semibold))
            TextField("工作组名称", text: isNew ? $newGroupName : $renameText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onAppear { if !isNew { /* 已有值 */ } }
            HStack {
                Spacer()
                Button("取消") {
                    showNewGroup = false
                    renamingGroup = nil
                }
                .buttonStyle(.plain)
                Button(isNew ? "创建" : "保存") {
                    if isNew {
                        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            let gid = chat.createGroup(name: name)
                            chat.selectedGroupID = gid
                            chat.showUngroupedOnly = false
                        }
                        showNewGroup = false
                    } else if let g = group {
                        chat.renameGroup(g.id, name: renameText)
                        renamingGroup = nil
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // MARK: - 底栏

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 左下角：设置入口（系统提示词、归档管理等）
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10.5))
                    Text("设置")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(Palette.subtle)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("设置：系统提示词、上下文默认值")

            Text("对话保存在本机\n~/Library/Application Support/LocalModel")
                .font(.system(size: 9))
                .foregroundStyle(Palette.subtle.opacity(0.7))
                .lineSpacing(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func timeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()

        if cal.isDateInToday(date) {
            let mins = Int(now.timeIntervalSince(date) / 60)
            if mins < 1 { return L("刚刚") }
            if mins < 60 { return Lf("%lld分钟前", mins) }
            return Lf("%lld小时前", Int(now.timeIntervalSince(date) / 3600))
        }

        // 天数必须按自然日算：dateComponents([.day]) 会把不足一天的部分截掉，
        // 两天前 20:00 的会话在今天 18:00 会被算成 1 天
        let dayDiff = cal.dateComponents([.day],
                                        from: cal.startOfDay(for: date),
                                        to: cal.startOfDay(for: now)).day ?? 0
        if dayDiff == 1 { return L("昨天") }
        if dayDiff < 7 { return Lf("%lld天前", dayDiff) }
        return SidebarView.shortDate.string(from: date)
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
}
