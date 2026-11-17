import SwiftUI

/// 编辑用户消息并重发。保存后会截断这条之后的回答，重新生成。
struct MessageEditSheet: View {
    let messageID: UUID
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var server: ServerController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("编辑消息"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(L("取消")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.subtle)
                Button(L("保存并重发")) {
                    chat.editAndResend(messageID, to: text, server: server)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(L("改完这条会重新提问：它之后的回答都会被删掉重来。"))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.subtle)

            TextEditor(text: $text)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(height: 170)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.background))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
        }
        .padding(16)
        .frame(width: 460, height: 290)
        .onAppear { text = chat.message(messageID)?.text ?? "" }
    }
}
