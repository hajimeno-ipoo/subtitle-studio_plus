import SwiftUI

struct SettingsUTOAlignTabView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isAdvancedExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                basicSettingsCard
                advancedSettingsCard
            }
            .padding(20)
        }
        .task {
            await viewModel.settings.loadIfNeeded()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UTO-ALIGN")
                .font(.system(size: 28, weight: .black, design: .rounded))

            Text("すでに作った字幕のタイミングを、自動で前後に合わせる設定です。字幕生成そのものには使いません。")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var basicSettingsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(
                    title: "基本設定",
                    message: "まずはここだけで十分です。字幕のタイミング調整専用の設定です。"
                )

                SettingsDescriptionRow(
                    title: "調整プリセット",
                    description: "タイミング合わせの強さを、用途ごとにまとめて選べます。",
                    badgeText: currentUTOAlignPresetBadgeText,
                    helperText: utoAlignPresetHelperText
                ) {
                    Picker("調整プリセット", selection: utoAlignPresetBinding) {
                        Text("おすすめ").tag(UTOAlignPreset.recommended)
                        Text("静かな声も拾う").tag(UTOAlignPreset.sensitive)
                        Text("誤反応を減らす").tag(UTOAlignPreset.strict)
                        Text("カスタム").tag(UTOAlignPreset.custom)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    .labelsHidden()
                    .accessibilityLabel("調整プリセット")
                }

                SettingsDescriptionRow(
                    title: "静かな声も拾いやすくする",
                    description: "小さい声や静かな部分も合わせやすくします。",
                    badgeText: viewModel.settings.autoAlignUseAdaptiveThreshold ? "オン" : "オフ",
                    helperText: "通常はオンのままで大丈夫です。"
                ) {
                    Toggle("静かな声も拾いやすくする", isOn: adaptiveThresholdBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityLabel("静かな声も拾いやすくする")
                }
            }
        }
    }

    private var advancedSettingsCard: some View {
        settingsCard {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    numericField(
                        title: "音量を見る細かさ",
                        description: "短いほど細かく見ます。長いほどなめらかに見ます。",
                        value: rmsWindowBinding,
                        placeholder: "0.005",
                        format: .number.precision(.fractionLength(3)),
                        accessibilityLabel: "音量を見る細かさ"
                    )

                    numericField(
                        title: "声ありとみなす強さ",
                        description: "大きいほど厳しく、小さいほど拾いやすくなります。",
                        value: thresholdRatioBinding,
                        placeholder: "0.120",
                        format: .number.precision(.fractionLength(3)),
                        accessibilityLabel: "声ありとみなす強さ"
                    )

                    numericField(
                        title: "短い無音をつなぐ長さ",
                        description: "短い無音を、同じフレーズとしてまとめやすくします。",
                        value: minGapFillBinding,
                        placeholder: "0.300",
                        format: .number.precision(.fractionLength(3)),
                        accessibilityLabel: "短い無音をつなぐ長さ"
                    )
                }
                .padding(.top, 16)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("詳細設定")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("細かく調整したい時だけ開いてください。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
    }

    private var currentUTOAlignPresetBadgeText: String? {
        switch viewModel.settings.utoAlignPreset {
        case .recommended:
            return "おすすめ"
        case .sensitive:
            return "静かな声向け"
        case .strict:
            return "誤反応を減らす"
        case .custom:
            return "カスタム"
        }
    }

    private var utoAlignPresetHelperText: String {
        switch viewModel.settings.utoAlignPreset {
        case .recommended:
            return "迷ったらこのままで大丈夫です。"
        case .sensitive:
            return "静かな歌声や弱い音も拾いたい時に向いています。"
        case .strict:
            return "BGMやノイズで余計に動くのを減らしたい時に向いています。"
        case .custom:
            return "詳細設定を手動で変えているため、今はカスタム扱いです。"
        }
    }

    private var utoAlignPresetBinding: Binding<UTOAlignPreset> {
        Binding(
            get: { viewModel.settings.utoAlignPreset },
            set: { viewModel.settings.applyUTOAlignPreset($0) }
        )
    }

    private var adaptiveThresholdBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.autoAlignUseAdaptiveThreshold },
            set: { viewModel.settings.autoAlignUseAdaptiveThreshold = $0 }
        )
    }

    private var rmsWindowBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.autoAlignRMSWindowSize },
            set: { viewModel.settings.autoAlignRMSWindowSize = $0 }
        )
    }

    private var thresholdRatioBinding: Binding<Float> {
        Binding(
            get: { viewModel.settings.autoAlignThresholdRatio },
            set: { viewModel.settings.autoAlignThresholdRatio = $0 }
        )
    }

    private var minGapFillBinding: Binding<Double> {
        Binding(
            get: { viewModel.settings.autoAlignMinGapFill },
            set: { viewModel.settings.autoAlignMinGapFill = $0 }
        )
    }

    @ViewBuilder
    private func numericField<Value, Format>(
        title: String,
        description: String,
        value: Binding<Value>,
        placeholder: String,
        format: Format,
        accessibilityLabel: String
    ) -> some View where Format: ParseableFormatStyle, Format.FormatInput == Value, Format.FormatOutput == String {
        SettingsDescriptionRow(
            title: title,
            description: description,
            helperText: "迷ったら変更不要です。"
        ) {
            TextField(placeholder, value: value, format: format)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .accessibilityLabel(accessibilityLabel)
        }
    }

    @ViewBuilder
    private func sectionHeader(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .black, design: .rounded))
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))
    }
}
