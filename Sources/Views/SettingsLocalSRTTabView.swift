import AppKit
import SwiftUI

struct SettingsLocalSRTTabView: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var isAdvancedExpanded = false
    @State private var activeGuide: LocalSetupGuide?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                setupStatusCard
                basicSettingsCard
                advancedSettingsCard
            }
            .padding(20)
        }
        .task {
            await viewModel.settings.loadIfNeeded()
            await viewModel.refreshLocalPipelineSetupStatus()
        }
        .sheet(item: $activeGuide) { guide in
            setupGuideSheet(for: guide)
        }
    }

    private var setupStatusCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 18) {
                sectionHeader(
                    title: "セットアップ状況",
                    message: "必須のものと任意のものを分けて表示します。"
                )

                setupRow(
                    title: "全体",
                    description: "ローカル字幕に必要な準備がそろっているかをまとめて表示します。",
                    state: viewModel.localPipelineSetupStatus.overall,
                    action: nil
                )

                sectionHeader(
                    title: "必須",
                    message: "ここがそろうとローカル字幕を使えます。"
                )

                setupRow(
                    title: "Whisper モデル",
                    description: "音声から歌詞を読む本体モデルです。認識モードに合わせて取得します。",
                    state: viewModel.localPipelineSetupStatus.whisperModel.state,
                    action: viewModel.localPipelineSetupStatus.whisperModel.action
                )

                setupRow(
                    title: "Python",
                    description: "aeneas を動かす土台です。",
                    state: viewModel.localPipelineSetupStatus.python.state,
                    action: viewModel.localPipelineSetupStatus.python.action
                )

                setupRow(
                    title: "FFmpeg",
                    description: "TXT 参照の音声区間検出で使います。ローカル字幕では必須です。",
                    state: viewModel.localPipelineSetupStatus.ffmpeg.state,
                    action: viewModel.localPipelineSetupStatus.ffmpeg.action
                )

                setupRow(
                    title: "aeneas",
                    description: "歌詞ブロックの時間合わせに使います。",
                    state: viewModel.localPipelineSetupStatus.aeneas.state,
                    action: viewModel.localPipelineSetupStatus.aeneas.action
                )

                setupRow(
                    title: "同梱ファイル",
                    description: "補助スクリプトと補正辞書です。通常はアプリ内に入っています。",
                    state: viewModel.localPipelineSetupStatus.supportFiles.state,
                    action: viewModel.localPipelineSetupStatus.supportFiles.action
                )

                sectionHeader(
                    title: "任意",
                    message: "なくても動きますが、あると快適になる項目です。"
                )

                setupRow(
                    title: "Core ML モデル",
                    description: "Whisper の高速化に使います。今は手動設定のみです。",
                    helperText: viewModel.localPipelineSetupStatus.note,
                    state: viewModel.localPipelineSetupStatus.coreML.state,
                    action: viewModel.localPipelineSetupStatus.coreML.action
                )

                sectionHeader(
                    title: "参考情報",
                    message: "現在のアプリでは必須にしていないコマンドです。"
                )

                HStack(spacing: 12) {
                    dependencyChip(title: "ffprobe", status: viewModel.localPipelineSetupStatus.ffprobe)
                    dependencyChip(title: "eSpeak", status: viewModel.localPipelineSetupStatus.espeak)
                }

                HStack(spacing: 12) {
                    Button {
                        Task {
                            await viewModel.refreshLocalPipelineSetupStatus()
                        }
                    } label: {
                        Label("再確認", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    if viewModel.isLocalPipelineSetupBusy {
                        ProgressView()
                            .controlSize(.small)
                        Text("準備中...")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(viewModel.isBusy || viewModel.isLocalPipelineSetupBusy)
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
                Task {
                    await viewModel.refreshLocalPipelineSetupStatus()
                }
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

    @ViewBuilder
    private func setupRow(
        title: String,
        description: String,
        helperText: String? = nil,
        state: LocalPipelineSetupState,
        action: LocalPipelineSetupAction?
    ) -> some View {
        SettingsDescriptionRow(
            title: title,
            description: description,
            badgeText: badgeText(for: state),
            helperText: helperText
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.message)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(statusColor(for: state))
                    .fixedSize(horizontal: false, vertical: true)

                if let action {
                    Button {
                        performSetupAction(action)
                    } label: {
                        Label(actionTitle(for: action), systemImage: actionSystemImage(for: action))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func badgeText(for state: LocalPipelineSetupState) -> String {
        switch state {
        case .checking:
            return "確認中"
        case .ready:
            return "OK"
        case .missing:
            return "未設定"
        case .inProgress:
            return "準備中"
        case .failed:
            return "要確認"
        }
    }

    private func statusColor(for state: LocalPipelineSetupState) -> Color {
        switch state {
        case .checking:
            return .secondary
        case .ready:
            return .brandGreen
        case .missing:
            return .brandOrange
        case .inProgress:
            return .brandBlue
        case .failed:
            return .brandPink
        }
    }

    private func actionTitle(for action: LocalPipelineSetupAction) -> String {
        switch action {
        case .downloadWhisperModel:
            return "ダウンロード"
        case .downloadCoreMLModel:
            return "ダウンロード"
        case .installAlignmentTools:
            return "セットアップ"
        case .openPythonGuide:
            return "案内を開く"
        case .openFFmpegGuide:
            return "FFmpeg の案内"
        }
    }

    private func actionSystemImage(for action: LocalPipelineSetupAction) -> String {
        switch action {
        case .downloadWhisperModel:
            return "arrow.down.circle.fill"
        case .downloadCoreMLModel:
            return "arrow.down.circle.fill"
        case .installAlignmentTools:
            return "shippingbox.fill"
        case .openPythonGuide:
            return "safari.fill"
        case .openFFmpegGuide:
            return "book.fill"
        }
    }

    private func dependencyChip(title: String, status: LocalPipelineSetupRowStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundStyle(.primary)
            Text(shortStatusText(for: status))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(statusColor(for: status.state))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.backgroundYellow.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.black.opacity(0.15), lineWidth: 1)
        )
    }

    private func shortStatusText(for status: LocalPipelineSetupRowStatus) -> String {
        if case .ready(let message) = status.state, message.contains("必須ではありません") {
            return "任意"
        }

        let state = status.state
        switch state {
        case .checking:
            return "確認中"
        case .ready:
            return "見つかりました"
        case .missing:
            return "不足"
        case .inProgress:
            return "準備中"
        case .failed:
            return "失敗"
        }
    }

    private func performSetupAction(_ action: LocalPipelineSetupAction) {
        switch action {
        case .openPythonGuide:
            activeGuide = .python
        case .openFFmpegGuide:
            activeGuide = .ffmpeg
        case .downloadWhisperModel, .installAlignmentTools, .downloadCoreMLModel:
            Task {
                await viewModel.handleLocalPipelineSetupAction(action)
            }
        }
    }

    @ViewBuilder
    private func setupGuideSheet(for guide: LocalSetupGuide) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(guide.title)
                .font(.system(size: 22, weight: .black, design: .rounded))

            Text(guide.summary)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(step)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let command = guide.command {
                VStack(alignment: .leading, spacing: 8) {
                    Text("参考コマンド")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                    Text(command)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.backgroundYellow.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            HStack(spacing: 12) {
                Button {
                    openGuideURL(guide.url)
                } label: {
                    Label(guide.linkLabel, systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)

                Button("閉じる") {
                    activeGuide = nil
                }
                .buttonStyle(.bordered)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420)
    }

    private func openGuideURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

private enum LocalSetupGuide: String, Identifiable {
    case python
    case ffmpeg

    var id: String { rawValue }

    var title: String {
        switch self {
        case .python:
            return "Python 3 の入れ方"
        case .ffmpeg:
            return "FFmpeg の入れ方"
        }
    }

    var summary: String {
        switch self {
        case .python:
            return "aeneas を動かすために Python 3 が必要です。インストール後、この画面で『再確認』を押してください。"
        case .ffmpeg:
            return "このアプリでは FFmpeg を必須として扱います。インストール後、この画面で『再確認』を押してください。"
        }
    }

    var steps: [String] {
        switch self {
        case .python:
            return [
                "下のボタンから Python 公式サイトを開きます。",
                "macOS 向けの Python 3 をインストールします。",
                "インストールが終わったら、この設定画面で『再確認』を押します。"
            ]
        case .ffmpeg:
            return [
                "Homebrew をお使いなら、下の参考コマンドで FFmpeg を入れます。",
                "Homebrew が未導入なら、先に公式ページの手順で Homebrew を入れます。",
                "インストール後、この設定画面で『再確認』を押します。"
            ]
        }
    }

    var command: String? {
        switch self {
        case .python:
            return nil
        case .ffmpeg:
            return "brew install ffmpeg"
        }
    }

    var url: URL {
        switch self {
        case .python:
            return URL(string: "https://www.python.org/downloads/macos/")!
        case .ffmpeg:
            return URL(string: "https://brew.sh/")!
        }
    }

    var linkLabel: String {
        switch self {
        case .python:
            return "Python の配布ページを開く"
        case .ffmpeg:
            return "Homebrew の手順を見る"
        }
    }
}
