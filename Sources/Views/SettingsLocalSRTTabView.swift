import SwiftUI

struct SettingsLocalSRTTabView: View {
    @Environment(AppViewModel.self) private var viewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LOCAL SRT")
                        .font(.system(size: 28, weight: .black, design: .rounded))

                    Text("Local Pipeline のモデルと実行パラメータを調整します。変更は自動保存されます。")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    if viewModel.isBusy {
                        Text("実行中は設定を変更できません。")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    SettingsDescriptionRow(
                        title: "ベースモデル",
                        description: "whisper.cpp で使うベースモデルです。"
                    ) {
                        Picker("", selection: baseModelBinding) {
                            Text("Kotoba-Whisper v2.0").tag(LocalBaseModel.kotobaWhisperV2)
                            Text("Kotoba-Whisper Bilingual").tag(LocalBaseModel.kotobaWhisperBilingual)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 460)
                        .accessibilityLabel("ベースモデル")
                    }

                    SettingsDescriptionRow(
                        title: "言語",
                        description: "whisper.cpp 実行時に指定する言語コードです。"
                    ) {
                        TextField("ja", text: localBinding(\.language))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .accessibilityLabel("言語")
                    }

                    SettingsDescriptionRow(
                        title: "Initial Prompt",
                        description: "whisper.cpp の補助語彙です。曲名、固有名詞、よく出る単語、表記の希望に使います。"
                    ) {
                        TextField("任意", text: localBinding(\.initialPrompt))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 340)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .accessibilityLabel("Initial Prompt")
                    }

                    SettingsDescriptionRow(
                        title: "Chunk Length (秒)",
                        description: "音声を分割する1チャンクの長さです。"
                    ) {
                        TextField(
                            "8.0",
                            value: localBinding(\.chunkLengthSeconds),
                            format: .number.precision(.fractionLength(1))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Chunk Length")
                    }

                    SettingsDescriptionRow(
                        title: "Overlap (秒)",
                        description: "チャンク境界の取りこぼしを減らす重なり秒数です。"
                    ) {
                        TextField(
                            "1.0",
                            value: localBinding(\.overlapSeconds),
                            format: .number.precision(.fractionLength(1))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Overlap")
                    }

                    SettingsDescriptionRow(
                        title: "Temperature",
                        description: "ベースASRの温度パラメータです。"
                    ) {
                        TextField(
                            "0.0",
                            value: localBinding(\.temperature),
                            format: .number.precision(.fractionLength(2))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Temperature")
                    }

                    SettingsDescriptionRow(
                        title: "Beam Size",
                        description: "探索幅を決める beam size です。"
                    ) {
                        TextField("5", value: localBinding(\.beamSize), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .accessibilityLabel("Beam Size")
                    }

                    SettingsDescriptionRow(
                        title: "No Speech Threshold",
                        description: "無音判定のしきい値です。"
                    ) {
                        TextField(
                            "0.6",
                            value: localBinding(\.noSpeechThreshold),
                            format: .number.precision(.fractionLength(2))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .accessibilityLabel("No Speech Threshold")
                    }

                    SettingsDescriptionRow(
                        title: "Logprob Threshold",
                        description: "信頼度判定に使う対数確率のしきい値です。"
                    ) {
                        TextField(
                            "-0.8",
                            value: localBinding(\.logprobThreshold),
                            format: .number.precision(.fractionLength(2))
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .accessibilityLabel("Logprob Threshold")
                    }

                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))
                .disabled(viewModel.isBusy)

                VStack(alignment: .leading, spacing: 16) {
                    pathField(
                        title: "Whisper モデルファイル",
                        description: "空なら ~/Library/Application Support/SubtitleStudioPlus/Models/ を自動検出します",
                        keyPath: \.whisperModelPath
                    )
                    pathField(
                        title: "Whisper CoreML モデル",
                        description: "例: /Models/ggml-kotoba-whisper-v2.0-encoder.mlmodelc",
                        keyPath: \.whisperCoreMLModelPath
                    )
                    pathField(
                        title: "aeneas 用 Python",
                        description: "例: python3 または /opt/homebrew/bin/python3",
                        keyPath: \.aeneasPythonPath
                    )
                    pathField(
                        title: "aeneas スクリプト",
                        description: "例: ./Tools/aeneas/align_subtitles.py",
                        keyPath: \.aeneasScriptPath
                    )
                    pathField(
                        title: "補正辞書パス",
                        description: "例: ./Tools/dictionaries/default_ja_corrections.json",
                        keyPath: \.correctionDictionaryPath
                    )
                    pathField(
                        title: "出力ディレクトリ",
                        description: "既定は ~/Library/Application Support/SubtitleStudioPlus/Work です",
                        keyPath: \.outputDirectoryPath
                    )
                }
                .padding(16)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black, lineWidth: 2))
                .disabled(viewModel.isBusy)
            }
            .padding(20)
        }
        .task {
            await viewModel.settings.loadIfNeeded()
        }
    }

    @ViewBuilder
    private func pathField(
        title: String,
        description: String,
        keyPath: WritableKeyPath<LocalPipelineSettings, String>
    ) -> some View {
        SettingsDescriptionRow(title: title, description: description) {
            TextField("", text: localBinding(keyPath))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 360)
                .accessibilityLabel(title)
        }
    }

    private func localBinding<Value>(_ keyPath: WritableKeyPath<LocalPipelineSettings, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.settings.localPipelineSettings[keyPath: keyPath] },
            set: { viewModel.settings.localPipelineSettings[keyPath: keyPath] = $0 }
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
}
