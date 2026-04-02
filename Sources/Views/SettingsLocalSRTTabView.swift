import SwiftUI

struct SettingsLocalSRTTabView: View {
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
            Text("LOCAL SRT")
                .font(.system(size: 28, weight: .black, design: .rounded))

            Text("音声から字幕を作るときの設定です。通常は『おすすめ』のままで大丈夫です。")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            if viewModel.isBusy {
                Text("実行中は設定を変更できません。")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var basicSettingsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(
                    title: "基本設定",
                    message: "通常はここだけで大丈夫です。迷ったら『おすすめ』をお使いくださいませ。"
                )

                SettingsDescriptionRow(
                    title: "品質プリセット",
                    description: "字幕の作り方を、迷わず選べるまとめ設定です。",
                    badgeText: currentLocalPresetBadgeText,
                    helperText: localPresetHelperText
                ) {
                    Picker("品質プリセット", selection: localPresetBinding) {
                        Text("おすすめ").tag(LocalSRTPreset.recommended)
                        Text("高精度").tag(LocalSRTPreset.highAccuracy)
                        Text("高速").tag(LocalSRTPreset.fast)
                        Text("カスタム").tag(LocalSRTPreset.custom)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 460)
                    .labelsHidden()
                    .accessibilityLabel("品質プリセット")
                }

                SettingsDescriptionRow(
                    title: "認識モード",
                    description: "日本語の曲なら『日本語中心』で十分です。英語が混ざる曲だけ『日英まじり』を選びます。",
                    badgeText: "おすすめ"
                ) {
                    Picker("認識モード", selection: baseModelBinding) {
                        Text("日本語中心").tag(LocalBaseModel.kotobaWhisperV2)
                        Text("日英まじり").tag(LocalBaseModel.kotobaWhisperBilingual)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 460)
                    .labelsHidden()
                    .accessibilityLabel("認識モード")
                }

                SettingsDescriptionRow(
                    title: "認識のヒント",
                    description: "曲名、歌手名、固有名詞、よく出る言葉を書くと認識が安定しやすくなります。",
                    helperText: "空でも使えます。分かる言葉だけ入れれば十分です。"
                ) {
                    TextField(
                        "例: 夜明け、Dreamer、Hazimeno",
                        text: localBinding(\.initialPrompt)
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .frame(minWidth: 360)
                    .accessibilityLabel("認識のヒント")
                }
            }
        }
        .disabled(viewModel.isBusy)
    }

    private var advancedSettingsCard: some View {
        settingsCard {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsDescriptionRow(
                        title: "字幕の言語",
                        description: "通常は `ja` のままで大丈夫です。",
                        helperText: "迷ったら変更不要です。"
                    ) {
                        TextField("ja", text: localBinding(\.language))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .accessibilityLabel("字幕の言語")
                    }

                    numericField(
                        title: "1回の処理時間",
                        description: "長いほど処理回数は減りますが、失敗時の影響が大きくなります。",
                        placeholder: "8.0",
                        value: localBinding(\.chunkLengthSeconds),
                        format: .number.precision(.fractionLength(1)),
                        accessibilityLabel: "1回の処理時間"
                    )

                    numericField(
                        title: "つなぎの重なり",
                        description: "音声を分けた境目を取りこぼしにくくします。",
                        placeholder: "1.0",
                        value: localBinding(\.overlapSeconds),
                        format: .number.precision(.fractionLength(1)),
                        accessibilityLabel: "つなぎの重なり"
                    )

                    numericField(
                        title: "認識のゆらぎ",
                        description: "大きくすると、認識結果のゆれが増えます。",
                        placeholder: "0.0",
                        value: localBinding(\.temperature),
                        format: .number.precision(.fractionLength(2)),
                        accessibilityLabel: "認識のゆらぎ"
                    )

                    numericField(
                        title: "候補の広さ",
                        description: "大きいほど、より多くの候補を比べます。",
                        placeholder: "5",
                        value: localBinding(\.beamSize),
                        format: .number,
                        accessibilityLabel: "候補の広さ"
                    )

                    numericField(
                        title: "無音の判定",
                        description: "大きくすると、音がないと判断しやすくなります。",
                        placeholder: "0.6",
                        value: localBinding(\.noSpeechThreshold),
                        format: .number.precision(.fractionLength(2)),
                        accessibilityLabel: "無音の判定"
                    )

                    numericField(
                        title: "信頼度の下限",
                        description: "低すぎる認識結果を抑えたい時の目安です。",
                        placeholder: "-1.0",
                        value: localBinding(\.logprobThreshold),
                        format: .number.precision(.fractionLength(2)),
                        accessibilityLabel: "信頼度の下限"
                    )

                    pathField(
                        title: "Whisper モデルファイル",
                        description: "空なら自動で探します。",
                        keyPath: \.whisperModelPath
                    )

                    pathField(
                        title: "Whisper CoreML モデル",
                        description: "高速化用の追加モデルです。",
                        keyPath: \.whisperCoreMLModelPath
                    )

                    pathField(
                        title: "aeneas 用 Python",
                        description: "時間合わせで使う Python です。",
                        keyPath: \.aeneasPythonPath
                    )

                    pathField(
                        title: "aeneas スクリプト",
                        description: "時間合わせで使う補助スクリプトです。",
                        keyPath: \.aeneasScriptPath
                    )

                    pathField(
                        title: "補正辞書ファイル",
                        description: "よく間違う言葉を直す辞書です。",
                        keyPath: \.correctionDictionaryPath
                    )

                    pathField(
                        title: "出力フォルダ",
                        description: "作成した字幕やログの保存先です。",
                        keyPath: \.outputDirectoryPath
                    )
                }
                .padding(.top, 16)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("詳細設定")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("細かい数値やファイル場所を変えたい時だけ開いてください。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        }
        .disabled(viewModel.isBusy)
    }

    private var currentLocalPresetBadgeText: String? {
        switch viewModel.settings.localSRTPreset {
        case .recommended:
            return "おすすめ"
        case .highAccuracy:
            return "高精度"
        case .fast:
            return "高速"
        case .custom:
            return "カスタム"
        }
    }

    private var localPresetHelperText: String {
        switch viewModel.settings.localSRTPreset {
        case .recommended:
            return "迷ったらこのままで大丈夫です。"
        case .highAccuracy:
            return "精度を優先したい時に向いています。"
        case .fast:
            return "まず早く結果を見たい時に向いています。"
        case .custom:
            return "詳細設定を手動で変えているため、今はカスタム扱いです。"
        }
    }

    private var localPresetBinding: Binding<LocalSRTPreset> {
        Binding(
            get: { viewModel.settings.localSRTPreset },
            set: { viewModel.settings.applyLocalSRTPreset($0) }
        )
    }

    private var baseModelBinding: Binding<LocalBaseModel> {
        Binding(
            get: { viewModel.settings.localPipelineSettings.baseModel },
            set: {
                viewModel.settings.markLocalPipelineBaseModelCustomized()
                viewModel.settings.localPipelineSettings.baseModel = $0
            }
        )
    }

    private func localBinding<Value>(_ keyPath: WritableKeyPath<LocalPipelineSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settings.localPipelineSettings[keyPath: keyPath] },
            set: { viewModel.settings.localPipelineSettings[keyPath: keyPath] = $0 }
        )
    }

    @ViewBuilder
    private func numericField<Value, Format>(
        title: String,
        description: String,
        placeholder: String,
        value: Binding<Value>,
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
    private func pathField(
        title: String,
        description: String,
        keyPath: WritableKeyPath<LocalPipelineSettings, String>
    ) -> some View {
        SettingsDescriptionRow(
            title: title,
            description: description,
            helperText: "迷ったら変更不要です。"
        ) {
            TextField("", text: localBinding(keyPath))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 360)
                .accessibilityLabel(title)
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
