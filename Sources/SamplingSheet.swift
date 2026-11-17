import SwiftUI

/// 采样参数的高级面板。三档预设已经覆盖大多数场景，这里给想细调的人。
struct SamplingSheet: View {
    let sessionID: UUID?
    @EnvironmentObject private var chat: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var p = SamplingParams.Preset.balanced.params

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("采样参数"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Spacer()
                Button(L("恢复默认")) {
                    p = SamplingParams.Preset.balanced.params
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                Button(L("取消")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.subtle)
                Button(L("应用")) {
                    chat.setSampling(p, for: sessionID)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.accent)
            }

            Text(L("只影响这段对话下一轮开始的生成。温度低更稳、更容易重复；温度高更发散、更容易跑题。"))
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.subtle)
                .fixedSize(horizontal: false, vertical: true)

            slider(L("温度"), value: $p.temperature, range: 0...2, format: "%.2f")
            slider(L("Top-P"), value: $p.topP, range: 0.1...1, format: "%.2f")
            slider(L("重复惩罚"), value: $p.repeatPenalty, range: 0.8...1.5, format: "%.2f")

            HStack(spacing: 10) {
                Text(L("Top-K"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.subtle)
                    .frame(width: 76, alignment: .leading)
                Stepper(value: $p.topK, in: 1...200, step: 5) {
                    Text("\(p.topK)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.text)
                }
            }

            HStack(spacing: 10) {
                Text(L("最大长度"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.subtle)
                    .frame(width: 76, alignment: .leading)
                Stepper(value: $p.maxTokens, in: -1...8192, step: 256) {
                    Text(p.maxTokens < 0 ? L("不限") : "\(p.maxTokens)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.text)
                }
            }

            HStack(spacing: 10) {
                Text(L("固定种子"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.subtle)
                    .frame(width: 76, alignment: .leading)
                Stepper(value: $p.seed, in: -1...99999, step: 1) {
                    Text(p.seed < 0 ? L("随机") : "\(p.seed)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.text)
                }
                Spacer()
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 440, height: 340)
        .onAppear { p = chat.sampling(for: sessionID) }
    }

    private func slider(_ label: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.subtle)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
                .frame(maxWidth: 220)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.text)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
