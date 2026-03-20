# 実装計画と詳細タスク

## 結論
- 実装は 9 フェーズに分ける。
- 先に `型 / 設定 / UI 導線` を固定し、その後に `外部プロセス層`、`Local Pipeline 本体`、`Python 補助スクリプト`、`出力 / テスト / 検証` を積む。
- `Gemini` は残し、`Local Pipeline` を並立追加する。

## フェーズ 1: 共通型と設定の土台

### 完了条件
- `Gemini / Local Pipeline` をコード上で切り替えられる。
- ローカル設定を永続化できる。

### タスク
- [ ] `SRTGenerationEngine` を追加する
- [ ] `LocalBaseModel` を追加する
- [ ] `LocalPipelineSettings` を追加する
- [ ] `LocalPipelinePhase` を追加する
- [ ] `LocalPipelineProgress` を追加する
- [ ] `LocalPipelineError` を追加する
- [ ] `SettingsStore` に `selectedSRTGenerationEngine` を追加する
- [ ] `SettingsStore` に `localPipelineSettings` を追加する
- [ ] `geminiAPIKey` は Keychain、その他は UserDefaults に分離保存する
- [ ] ローカル設定の既定値を設計書どおり固定する
- [ ] `SettingsStoreTests` に永続化テストを追加する

### 主対象
- [AppModels.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Models/AppModels.swift)
- [SettingsStore.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Persistence/SettingsStore.swift)
- [SettingsStoreTests.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Tests/SettingsStoreTests.swift)

## フェーズ 2: UI 導線の追加

### 完了条件
- `AUTO GENERATE` 前に生成方式を選べる。
- 設定画面に `LOCAL SRT` タブが出る。

### タスク
- [ ] `SettingsTab` に `localSRT` を追加する
- [ ] `SettingsLocalSRTTabView.swift` を新規追加する
- [ ] `SettingsView` に `LOCAL SRT` タブを追加する
- [ ] `LivePreviewPanel` に `Gemini / Local Pipeline` セレクタを追加する
- [ ] 実行中は生成方式セレクタを無効化する
- [ ] Local 設定 UI にモデル、chunk、overlap、temperature、beam size、threshold 類、tool path、dictionary path を追加する
- [ ] 起動時に最後に使った生成方式を既定表示する

### 主対象
- [SettingsTab.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Views/SettingsTab.swift)
- [SettingsView.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Views/SettingsView.swift)
- [LivePreviewPanel.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Views/LivePreviewPanel.swift)

## フェーズ 3: ViewModel 分岐と共通進捗

### 完了条件
- `analyzeAudio()` が engine 選択で Gemini / Local を分岐できる。
- どちらでも進捗とエラーが表示できる。

### タスク
- [ ] `AppViewModel` に現在の生成方式参照を追加する
- [ ] `analyzeAudio()` を `gemini` と `localPipeline` の分岐に変更する
- [ ] Gemini 経路は既存 `AudioAnalysisService` をそのまま呼ぶ
- [ ] Local 経路は `LocalPipelineService` を呼ぶ
- [ ] `isBusy` 判定に Local 実行中を含める
- [ ] 進捗表示用の共通反映処理を追加する
- [ ] Local 実行の `runDirectoryURL` と成果物 URL を保持する
- [ ] 失敗時に stage / message / log path をダイアログへ出せるようにする
- [ ] `AppViewModel` の分岐テストを追加する

### 主対象
- [AppViewModel.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/ViewModels/AppViewModel.swift)
- [AudioAnalysisService.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Services/AudioAnalysisService.swift)

## フェーズ 4: 外部プロセス実行層

### 完了条件
- Swift から `whisper.cpp` と Python スクリプトを timeout 付きで安全に呼べる。
- stdout / stderr / exitCode を回収できる。

### タスク
- [ ] `ExternalProcessRequest` を追加する
- [ ] `ExternalProcessResult` を追加する
- [ ] `ExternalProcessRunner.swift` を新規追加する
- [ ] 実行ファイル存在確認を実装する
- [ ] 環境変数受け渡しを実装する
- [ ] timeout 制御を実装する
- [ ] stdout / stderr を Data で回収する
- [ ] 異常終了時に `LocalPipelineError` へ変換する
- [ ] `ExternalProcessRunner` の timeout / exitCode / stderr テストを追加する

### 主対象
- `Sources/Services/ExternalProcessRunner.swift`
- `Tests/ExternalProcessRunnerTests.swift`

## フェーズ 5: run directory と manifest

### 完了条件
- 実行ごとに `Work/run-.../` が作られる。
- `manifest.json` と `logs/run.jsonl` の初期化ができる。

### タスク
- [ ] `RunDirectoryBuilder.swift` を新規追加する
- [ ] run id を `run-YYYYMMDD-HHMMSS-<uuid8>` 形式で生成する
- [ ] `input/` `chunks/` `base_json/` `qwen_json/` `aligned_json/` `final/` `logs/` を作成する
- [ ] `manifest.json` 初期内容を書き出す
- [ ] stage 完了フラグ更新メソッドを実装する
- [ ] `run.jsonl` ロガーを実装する
- [ ] API Key を `Work/` やログへ書かないことをテストで確認する

### 主対象
- `Sources/Services/RunDirectoryBuilder.swift`
- `Sources/Services/RunLogger.swift`
- `Tests/RunDirectoryBuilderTests.swift`

## フェーズ 6: Local Pipeline 本体

### 完了条件
- Local Pipeline で `final.json / txt / lrc / srt` まで出る。
- `Qwen3-ASR` と `Qwen3-ForcedAligner` が必須段として実行される。

### タスク
- [ ] `LocalPipelineService.swift` を新規追加する
- [ ] 準備段で tool path と model path を検証する
- [ ] 音声正規化段を実装する
- [ ] チャンク分割段を実装する
- [ ] `chunks/index.json` 書き出しを実装する
- [ ] `whisper.cpp + Kotoba` ベース転写段を実装する
- [ ] `base_json/chunk-xxxxx.json` 保存を実装する
- [ ] suspicious 判定ロジックを実装する
- [ ] `suspicious_index.json` 保存を実装する
- [ ] `Qwen3-ASR` 再判定段を実装する
- [ ] `qwen_json/chunk-xxxxx.json` 保存を実装する
- [ ] ベース結果と再判定結果の統合ロジックを実装する
- [ ] `aligned_json/pre_alignment.json` 保存を実装する
- [ ] `Qwen3-ForcedAligner` 実行段を実装する
- [ ] `aligned_json/phrase_alignment.json` 保存を実装する
- [ ] 辞書置換、正規表現補正、既知歌詞照合、表記統一を実装する
- [ ] `final/final.json` 生成を実装する
- [ ] `final.txt / final.lrc / final.srt` 生成を実装する
- [ ] `final.json` から共通字幕モデルへ変換する

### 主対象
- `Sources/Services/LocalPipelineService.swift`
- `Sources/Services/LocalPipelineAssembler.swift`
- `Sources/Services/LocalPipelineCorrectionService.swift`
- [WaveformService.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Services/WaveformService.swift)

## フェーズ 7: Python 補助スクリプトと補助ファイル

### 完了条件
- `transcribe.py` と `align.py` が設計どおりの JSON を返す。
- 本番向けの依存固定ファイルがある。

### タスク
- [ ] `Tools/qwen/transcribe.py` を追加する
- [ ] `Tools/qwen/align.py` を追加する
- [ ] `Tools/qwen/requirements-local-pipeline.txt` を追加する
- [ ] `Tools/dictionaries/default_ja_corrections.json` を追加する
- [ ] `Tools/dictionaries/sample_known_lyrics.txt` を追加する
- [ ] 標準出力は JSON のみ、標準エラーはログのみ、exit code は固定値で実装する
- [ ] `transcribe.py` の引数検証を実装する
- [ ] `align.py` の引数検証を実装する
- [ ] JSON fixture ベースの Python テストを追加する

### 主対象
- `Tools/qwen/transcribe.py`
- `Tools/qwen/align.py`
- `Tools/qwen/requirements-local-pipeline.txt`

## フェーズ 8: 既存機能との結合

### 完了条件
- Local の結果も既存の編集、UTO-ALIGN、SRT 出力、Resolve 連携へ流れる。
- Gemini 経路の挙動が変わらない。

### タスク
- [ ] Local 生成後に `subtitles` へ共通反映する
- [ ] Undo / Redo に乗るようにする
- [ ] 編集画面の表示と選択状態が壊れないことを確認する
- [ ] UTO-ALIGN の後段利用ができることを確認する
- [ ] 既存の `EXPORT .SRT` が Local 結果でも使えることを確認する
- [ ] Resolve 連携で Local 結果も送れることを確認する
- [ ] Gemini 経路の回帰テストを追加する

### 主対象
- [AppViewModel.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/ViewModels/AppViewModel.swift)
- [SubtitleAlignmentService.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/Services/SubtitleAlignmentService.swift)
- [ResolveLaunchIntent.swift](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/Sources/App/ResolveLaunchIntent.swift)

## フェーズ 9: 本番検証

### 完了条件
- 受け入れ基準 9 項目を満たす。
- 失敗時の運用情報が利用者に返る。

### タスク
- [ ] `Gemini` で従来どおり字幕生成できることを確認する
- [ ] `Local Pipeline` で `final.txt / json / lrc / srt` が出ることを確認する
- [ ] モデル切替が UI と設定保存へ反映されることを確認する
- [ ] tool path 不正時に開始前で止まることを確認する
- [ ] model path 不正時に開始前で止まることを確認する
- [ ] `Qwen3-ASR` 失敗時に stage と stderr が分かることを確認する
- [ ] `Qwen3-ForcedAligner` 失敗時に stage と stderr が分かることを確認する
- [ ] `run.jsonl` と `manifest.json` が期待どおり出ることを確認する
- [ ] 編集、UTO-ALIGN、Resolve 連携が壊れていないことを確認する
- [ ] `xcodebuild build` を通す
- [ ] `xcodebuild test` を通す
- [ ] `git diff --check` を通す

## 依存関係
- フェーズ 1 完了前にフェーズ 2 と 3 は確定しない。
- フェーズ 4 と 5 がないとフェーズ 6 は着手しても結合できない。
- フェーズ 6 と 7 は並行可能。
- フェーズ 8 はフェーズ 6 と 7 の後。
- フェーズ 9 は最後。

## 差し戻し条件
- `Gemini` が使えなくなる
- `Local Pipeline` で `Qwen3-ASR` または `Qwen3-ForcedAligner` を飛ばしている
- `final.json / txt / lrc / srt` が揃わない
- `Work/` に API Key や機密情報が出る
- 失敗時に stage / stderr / run directory が分からない
- UTO-ALIGN、編集、Resolve 連携のどれかが壊れる

## 戻し方
- docs だけ戻す時は `docs/20260320_local_asr_pipeline/implementation_tasks.md` と [FOR[hazimeno_ipoo].md](/Users/apple/Desktop/Dev_App/subtitle-studio_plus/FOR%5Bhazimeno_ipoo%5D.md) の差分を戻す
