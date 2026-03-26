# Swift 側インターフェース設計

## 1. 公開する生成方式
```swift
enum SRTGenerationEngine: String, CaseIterable, Codable, Sendable {
    case gemini
    case localPipeline
}
```

## 2. LocalPipelineSettings
`Local Pipeline` 用の設定は次で固定する。

```swift
struct LocalPipelineSettings: Codable, Equatable, Sendable {
    var baseModel: LocalBaseModel
    var language: String
    var initialPrompt: String
    var chunkLengthSeconds: Double
    var overlapSeconds: Double
    var beamSize: Int
    var temperature: Double
    var noSpeechThreshold: Double
    var logprobThreshold: Double
    var whisperCLIPath: String
    var whisperModelPath: String
    var whisperCoreMLModelPath: String
    var aeneasPythonPath: String
    var aeneasScriptPath: String
    var correctionDictionaryPath: String
    var knownLyricsPath: String
    var outputDirectoryPath: String
}
```

削除する項目:
- `qwenTranscribeScriptPath`
- `qwenAlignScriptPath`
- `qwenModelName`
- `forcedAlignerModelName`
- `suspiciousThreshold`

## 3. LocalPipelinePhase
内部段階は次に整理する。

```swift
enum LocalPipelinePhase: String, Codable, Sendable {
    case validating
    case preparing
    case chunking
    case baseTranscribing
    case aligning
    case correcting
    case assembling
    case writingOutputs
    case completed
    case failed
}
```

削除する段階:
- `detectingSuspicious`
- `refining`

## 4. 進捗
画面表示は Gemini に寄せる。
内部では `LocalPipelineProgress` を使ってもよいが、見せ方は次にそろえる。

- 音声読込中
- 音声準備中
- 分割中
- 解析中
- 整形中
- まとめ中
- 完了

## 5. 結果
```swift
struct LocalPipelineResult: Sendable {
    var subtitles: [SubtitleItem]
    var runDirectoryURL: URL
    var finalSRTURL: URL
}
```

## 6. 字幕ブロックモデル
phrase 単位ではなく、字幕 block 単位で扱う。

```swift
struct LocalPipelineDraftSegment: Codable, Equatable, Sendable {
    var segmentId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var sourceChunkIds: [String]
}

struct LocalPipelineAlignedSegment: Codable, Equatable, Sendable {
    var segmentId: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}
```

## 7. エラー
Qwen 固有エラーは消す。
必要なのは次だけでよい。

```swift
enum LocalPipelineError: Error, Sendable {
    case invalidConfiguration(String)
    case whisperExecutionFailed(String)
    case alignmentFailed(String)
    case outputWriteFailed(String)
}
```

## 8. prompt 契約
Whisper に渡す prompt は次で固定する。

```swift
let finalPrompt: String
if settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    finalPrompt = """
    日本語の歌詞です。
    自然な区切りの日本語の歌詞として認識してください。
    歌詞らしい語順と自然な表記を優先してください。
    """
} else {
    finalPrompt = """
    日本語の歌詞です。
    自然な区切りの日本語の歌詞として認識してください。
    歌詞らしい語順と自然な表記を優先してください。
    """
        + "\n"
        + settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

## 9. 補正サービス
補正サービスは phrase 前提をやめ、字幕 block の `start / end` を使う。

```swift
func correct(
    runId: String,
    draftSegments: [LocalPipelineDraftSegment],
    alignedSegments: [LocalPipelineAlignedSegment],
    settings: LocalPipelineSettings
) throws -> [LocalPipelineCorrectedSegment]
```
