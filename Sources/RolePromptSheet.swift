import SwiftUI

/// 单段对话的角色提示词编辑器。
/// 这里只改「怎么答」；「你是谁、在什么环境里跑」是写死的身份提示词，只读展示。
struct RolePromptSheet: View {
    let sessionID: UUID

    @EnvironmentObject private var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var showIdentity = false

    private var title: String {
        chat.sessions.first(where: { $0.id == sessionID })?.displayTitle ?? L("这段对话")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("角色提示词"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(L("取消")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.subtle)
                Button(L("保存")) {
                    chat.setRolePrompt(text, for: sessionID)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
            }

            Text(Lf("只影响「%@」这段对话：告诉模型该怎么回答（领域、语气、格式）。留空就只用固定的身份提示词。", title))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.background))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))

            DisclosureGroup(isExpanded: $showIdentity) {
                Text(ChatStore.identityPrompt)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Text(L("身份提示词（固定，不能改）"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.subtle)
            }
            .accentColor(Palette.subtle)
        }
        .padding(16)
        .frame(width: 470, height: 330)
        .onAppear { text = chat.rolePrompt(for: sessionID) }
    }
}
