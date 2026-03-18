import SwiftUI

struct SettingsUTOAlignTabView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("UTO-ALIGN")
                        .font(.system(size: 28, weight: .black, design: .rounded))

                    Text("字幕の自動調整に使う数値です。わからない時は、まず今のまま使って大丈夫です。")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    SettingsDescriptionRow(
                        title: "RMS 窓幅 (秒)",
                        description: "音量を平均して見る時間です。短いほど細かく、長いほどなめらかに見ます。"
                    ) {
                        TextField(
                            "",
                            value: $bindableViewModel.settings.autoAlignRMSWindowSize,
                            format: .number.precision(.fractionLength(3))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }

                    SettingsDescriptionRow(
                        title: "しきい値比率",
                        description: "最大音量に対して、有音とみなす割合です。上げると厳しく、下げると拾いやすくなります。"
                    ) {
                        TextField(
                            "",
                            value: $bindableViewModel.settings.autoAlignThresholdRatio,
                            format: .number.precision(.fractionLength(3))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }

                    SettingsDescriptionRow(
                        title: "最小すき間埋め (秒)",
                        description: "短い無音のすき間を埋める長さです。細かく分かれた区間をつなげやすくなります。"
                    ) {
                        TextField(
                            "",
                            value: $bindableViewModel.settings.autoAlignMinGapFill,
                            format: .number.precision(.fractionLength(3))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                    }

                    SettingsDescriptionRow(
                        title: "自動しきい値を使う",
                        description: "周りの音量に合わせて、しきい値を少し自動調整します。静かな区間でも拾いやすくなります。"
                    ) {
                        Toggle("", isOn: $bindableViewModel.settings.autoAlignUseAdaptiveThreshold)
                            .labelsHidden()
                    }
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))
            }
            .padding(20)
        }
        .task {
            await viewModel.settings.loadIfNeeded()
        }
    }
}
