# Swift 側インターフェース設計

## 1. 目的
本書は、Swift 本体で追加・変更する型、サービス境界、ViewModel インターフェース、設定保持項目を固定する。

## 2. 追加する公開型

### 2.1 生成方式
```swift
enum SRTGenerationEngine: String, Codable, CaseIterable {
    case gemini
    case localPipeline
}
```

### 2.2 ローカルモデル
```swift
enum LocalBaseModel: String, Codable, CaseIterable {
    case kotobaWhisperV2
    case kotobaWhisperBilingual
}
```

### 2.3 ローカル設定
```swift
struct LocalPipelineSettings: Codable, Equatable {
    var baseModel: LocalBaseModel
    var language: String
    var chunkLengthSeconds: Double
    var overlapSeconds: Double
    var temperature: Double
    var beamSize: Int
    var noSpeechThreshold: Double
    var logprobThreshold: Double
    var suspiciousThreshold: Double
    var whisperCLIPath: String
    var whisperModelPath: String
    var whisperCoreMLModelPath: String
    var qwenTranscribeScriptPath: String
    var qwenAlignScriptPath: String
    var qwenModelName: String
    var forcedAlignerModelName: String
    var correctionDictionaryPath: String
    var knownLyricsPath: String
    var outputDirectoryPath: String
}
```

### 2.4 実行進捗
```swift
enum LocalPipelinePhase: String, Codable {
    case validating
    case preparing
    case chunking
    case baseTranscribing
    case detectingSuspicious
    case refining
    case aligning
    case correcting
    case assembling
    case writingOutputs
}

struct LocalPipelineProgress: Codable, Equatable {
    var phase: LocalPipelinePhase
    var message: String
    var currentChunk: Int
    var totalChunks: Int
    var displayPercent: Double
}
```

## 3. SettingsStore 変更方針
- 既存 `geminiAPIKey` は維持する。
- 次を追加する。
  - `selectedSRTGenerationEngine`
  - `localPipelineSettings`
- 保存先:
  - `geminiAPIKey` は Keychain
  - それ以外は UserDefaults
- `loadIfNeeded()` は Gemini 設定とローカル設定を同時にロードする。
- `persist()` は Gemini API Key 保存とローカル設定保存を分離する。

## 4. Service 設計

### 4.1 Gemini
- 既存 `AudioAnalysisService` を維持する。
- 引数は基本そのまま使う。

### 4.2 Local Pipeline
```swift
protocol LocalPipelineAnalyzing {
    func analyze(
        fileURL: URL,
        settings: LocalPipelineSettings,
        progress: @escaping @Sendable (LocalPipelineProgress) async -> Void
    ) async throws -> LocalPipelineResult
}
```

### 4.3 子プロセス実行
```swift
protocol ExternalProcessRunning {
    func run(_ request: ExternalProcessRequest) async throws -> ExternalProcessResult
}

struct ExternalProcessRequest {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: URL?
    var environment: [String: String]
    var timeout: TimeInterval
}

struct ExternalProcessResult {
    var stdout: Data
    var stderr: Data
    var exitCode: Int32
}
```

## 5. Result 設計
```swift
struct LocalPipelineResult {
    var subtitles: [SubtitleItem]
    var runDirectoryURL: URL
    var finalJSONURL: URL
    var finalSRTURL: URL
    var finalLRCURL: URL
    var finalTXTURL: URL
}
```

## 6. AppViewModel 変更方針
- `analyzeAudio()` は生成方式によって分岐する。
- `gemini` 選択時:
  - 既存の Gemini 経路を呼ぶ。
- `localPipeline` 選択時:
  - `LocalPipelineService` を呼ぶ。
- 進捗状態は既存 `analysisProgress` と別に持たず、表示側で Gemini 用と Local 用を吸収するか、共通進捗型へ統合する。
- `isBusy` は Gemini / Local / Align の全処理で true になる。

## 7. View 変更方針

### 7.1 LivePreviewPanel
- `AUTO GENERATE` の近くに生成方式セレクタを置く。
- `Gemini` / `Local Pipeline` を明示する。
- 実行中はセレクタを無効化する。

### 7.2 SettingsView
- 新タブ `LOCAL SRT` を追加する。
- `API` は Gemini 用として維持する。
- `UTO-ALIGN` は既存どおり維持する。

## 8. エラー型
```swift
enum LocalPipelineError: LocalizedError, Equatable {
    case missingExecutable(String)
    case missingModelFile(String)
    case invalidConfiguration(String)
    case normalizationFailed(String)
    case chunkingFailed(String)
    case baseTranscriptionFailed(String)
    case qwenRefinementFailed(String)
    case alignmentFailed(String)
    case correctionFailed(String)
    case invalidJSON(String)
    case outputWriteFailed(String)
}
```

## 9. 本番での既定値
- `selectedSRTGenerationEngine = .gemini`
- `baseModel = .kotobaWhisperV2`
- `language = "ja"`
- `chunkLengthSeconds = 8.0`
- `overlapSeconds = 1.0`
- `temperature = 0.0`
- `beamSize = 5`
- `noSpeechThreshold = 0.6`
- `logprobThreshold = -1.0`
- `suspiciousThreshold = 0.5`

## 10. 既存コードとの接続点
- `SettingsStore`
- `AppViewModel.analyzeAudio()`
- `LivePreviewPanel`
- `SettingsView`
- `SettingsTab`
