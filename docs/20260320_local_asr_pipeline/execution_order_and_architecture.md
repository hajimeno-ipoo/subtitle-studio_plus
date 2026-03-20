# M3 Pro 向けの実行順と、Swift から呼ぶための現実的な構成図

はい。では、このプロジェクト向けに、実行順と Swift からのつなぎ方をそのまま使える形で整理します。  
結論から言うと、Subtitle Studio Plus では SRT 生成エンジンを UI で切り替えて同居させる前提で、Local Pipeline の最終形はこれがいちばん扱いやすいです。

第1段: whisper.cpp + Core ML + Kotoba-Whisper v2.x / Bilingual  
第2段: 怪しい区間だけ Qwen3-ASR で再判定  
第3段: Forced Aligner で時刻合わせ  
第4段: 辞書補正・かな漢字補正・既知歌詞照合

この構成が良い理由は、whisper.cpp は Apple Silicon で Core ML を使ってエンコーダを ANE で動かせるため高速で、Kotoba v2.0 は日本語ASR向けの蒸留Whisperとして公開され、Bilingual は whisper.cpp 互換のGGML重みが配布されています。さらに Qwen3-ASR は日本語対応を含む多言語ASRと別系統の ForcedAligner を公開しています。  
見方としてはこうです。

- whisper.cpp は「実行エンジン」
- Kotoba は「載せるモデル」
- Qwen3-ASR は「再判定用の上位救済」
- ForcedAligner は「タイミング修正担当」

つまり、Kotoba と Qwen を全部直列に流すより、まず軽く広く拾って、怪しい場所だけ重いモデルに回すほうが自然です。  
このプロジェクトでは、これと並行して既存の Gemini SRT 生成経路も維持し、利用者が UI で `Gemini` と `Local Pipeline` を切り替えます。

## 実行順
1段目はベース転写です。  
純日本語の曲なら、まず Kotoba-Whisper v2.x を先に試すのが素直です。v2.0 は日本語ASR向けの蒸留Whisperとして公開されていて、whisper.cpp 重みも faster-whisper 用変換もあります。Bilingual は日英ASRと双方向音声翻訳が主目的なので、英語フレーズが混ざる曲で優先度が上がります。

実際の優先順は、こうすると分かりやすいです。

純日本語曲  
Kotoba v2.x → Bilingual → Qwen3-ASR

日英混在曲  
Bilingual → Kotoba v2.x → Qwen3-ASR

2段目は再判定です。  
ベース結果のうち、明らかに崩れている区間だけを Qwen3-ASR に投げます。Qwen3-ASR は長音声対応、複雑な音響環境での頑健性、多言語対応を打ち出しています。全部を Qwen にすると重いので、ここは「救急搬送」だと思うのがいちばん分かりやすいです。

3段目はアライメントです。  
Qwen3-ForcedAligner は最大5分までの任意単位の時刻予測をサポートする前提で扱います。歌詞字幕やLRCを作るなら、この段で時刻を詰めるのが自然です。

4段目は補正です。  
ここはモデルというより、文字列処理です。  
たとえば、

「あいしてる」→「愛してる」  
「きみ」→「君」  
「まぼろし」→「幻」

のような、歌ではありがちな表記揺れをそろえます。  
この段は地味ですが、体感精度をかなり上げます。

## Swiftからの現実的な構成
いちばんおすすめは、Subtitle Studio Plus の Swift 本体は司令塔にして、重い認識処理は CLI で呼ぶ構成です。

構成図にするとこうです。

`Subtitle Studio Plus`  
↓  
`SRT Engine Selector (Gemini / Local Pipeline)`  
↓  
`Gemini SRT Engine` または `Audio chunking`  
↓  
`whisper.cpp CLI (Kotoba v2.x or Bilingual)`  
↓  
`疑わしい区間を抽出`  
↓  
`Python CLI for Qwen3-ASR`  
↓  
`Python CLI for ForcedAligner`  
↓  
`Swiftで統合・補正・LRC/SRT/JSON/TXT生成`

この形が強いのは、Swift から直接 PyTorch や Transformers を抱え込まなくて済むからです。  
macOS アプリの中に全部詰め込むより、外部プロセスとして呼ぶほうが壊れにくいです。

## おすすめディレクトリ構成
このプロジェクトでは、こう切るのが自然です。

```text
SubtitleStudioPlus.xcodeproj
Sources/
  App/
  Models/
  Persistence/
  Services/
    AudioAnalysisService.swift        # 既存 Gemini 経路
    LocalPipelineService.swift        # 新規 Local Pipeline 経路
    ASRProcessRunner.swift            # whisper.cpp / Python 呼び出し
    SubtitleAlignmentService.swift    # 既存波形補正 or 併用
  ViewModels/
  Views/
Tools/
  whisper/
    whisper-cli
    models/
      ggml-kotoba-v2.bin
      ggml-kotoba-bilingual.bin
      ggml-base.en-encoder.mlmodelc
  qwen/
    transcribe.py
    align.py
Work/
  input/
  chunks/
  base_json/
  qwen_json/
  aligned_json/
  final/
docs/
  20260320_local_asr_pipeline/
```

## Swift側の責務
Swift は次の役割に絞ると安定します。

1. UI で `Gemini` と `Local Pipeline` を切り替える
2. 設定画面でローカルモデルとパラメータを選ばせる
3. 音声を 5〜12 秒程度に切る
4. whisper.cpp を呼ぶ
5. スコアが低い区間や怪しい区間だけ Qwen に回す
6. 最後に結果を統合して LRC / SRT / JSON / TXT にする

この役割分担だと、Swift は「配車係」、ASR モデルは「運転手」みたいな関係になります。

## 怪しい区間の判定基準
ここは重要です。  
再判定を賢くするには、「どこが怪しいか」を決める必要があります。

実務上は、こんな条件で十分です。

- 空文字に近い
- 同じ文字の引き伸ばしが多い
- ひらがなばかりで不自然
- 句読点や空白の入り方が崩れている
- 信頼スコアが低い
- 前後の文脈に比べて極端に短い

たとえば、

あ あ あ  
うー うー  
見えない の の の

みたいな区間だけ Qwen に再送します。

## Swiftの実装イメージ
まず whisper.cpp を叩く部分です。

```swift
import Foundation

struct WhisperSegment: Decodable {
    let t0: Int?
    let t1: Int?
    let text: String?
}

final class ASRRunner {
    func runWhisper(
        audioPath: String,
        modelPath: String,
        language: String = "ja"
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "bash", "-lc",
            """
            ./Tools/whisper/whisper-cli \
              -m \(modelPath) \
              -f \(audioPath) \
              -l \(language) \
              -oj -otxt
            """
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
```

次に、怪しい区間を選ぶ例です。

```swift
func looksSuspicious(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 1 { return true }

    let hiraOnly = trimmed.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "ぁあぃいぅうぇえぉおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんー ").contains($0)
    }

    if hiraOnly && trimmed.count <= 4 { return true }

    let repeated = ["あああ", "ーー", "のの", "うう"]
    if repeated.contains(where: trimmed.contains) { return true }

    return false
}
```

Qwen3-ASR は Swift から直接より、Python スクリプト呼び出しが安全です。

```swift
func runQwen(audioPath: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        "./Tools/qwen/transcribe.py",
        audioPath
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self)
}
```

ForcedAligner も同じ考え方で、Swift から Python スクリプトを呼び出して JSON を受け取り、Subtitle Studio Plus の字幕モデルへ統合します。

運用フローは、こんな感じです。

```swift
for chunk in chunks {
    let baseText = try runWhisper(
        audioPath: chunk.path,
        modelPath: selectedKotobaModelPath
    )

    if looksSuspicious(baseText) {
        let repaired = try runQwen(audioPath: chunk.path)
        mergedResults.append(repaired)
    } else {
        mergedResults.append(baseText)
    }
}
```

## モデル選択ルール
ここを固定すると、使いやすくなります。  
曲メタデータや最初の数チャンクから判定して、

英語率が低い  
→ Kotoba v2.x

英語率が高い、または英単語が頻出  
→ Kotoba Bilingual

崩れが多い  
→ Qwen 救済を増やす

という3段階で十分です。  
このプロジェクトでは、これに加えて設定画面から利用者がモデル選択を上書きできるようにします。

## おすすめチャンク長
歌では長すぎるチャンクが不利になりやすいので、こう勧めます。

ベース転写  
6〜10秒

Qwen再判定  
4〜8秒

Forced Alignment  
1フレーズ単位、または最大5分以内

最後の条件は、Qwen3-ForcedAligner を最大5分までの任意単位の時刻予測として扱う前提に沿っています。

## M3 Pro向けの優先順位
この環境なら、まずここから始めるのがいちばんきれいです。

1. Subtitle Studio Plus に `Gemini / Local Pipeline` 切替を置く
2. whisper.cpp + Core ML を通す
3. Kotoba v2.x を主力にする
4. 英語混在曲だけ Bilingual に切り替える
5. 怪しい区間だけ Qwen3-ASR
6. 最後に ForcedAligner

理由は単純で、whisper.cpp は Apple Silicon で Core ML によりエンコーダを ANE 実行できる一方、Kotoba v2.0 は日本語ASR向けで、Bilingual は日英対応に向いているからです。

最初の検証セット
まず3曲だけで比較すると、方向が見えやすいです。

- 純日本語バラード
- 早口気味のJ-POP
- 英語混じりの曲

この3つに対して、

- Kotoba v2.x 単独
- Bilingual 単独
- Kotoba v2.x + Qwen 救済

を見比べると、どこに差が出るかかなりはっきりします。

## 最終提案
このプロジェクト向けの「まず外しにくい構成」はこれです。

標準ルート  
whisper.cpp(Core ML) + Kotoba v2.x  
→ 怪しい区間だけ Qwen3-ASR  
→ Qwen3-ForcedAligner  
→ 辞書補正

日英混在ルート  
whisper.cpp(Core ML) + Kotoba Bilingual  
→ 怪しい区間だけ Qwen3-ASR  
→ Qwen3-ForcedAligner  
→ 辞書補正

並立ルート  
Gemini SRT Engine  
→ Subtitle Studio Plus 既存 SRT 生成  
→ 同じ字幕モデルと出力系に合流

この3本立てで十分実戦的です。  
次は、これをそのまま動かせるように、macOS 向けの

- セットアップ手順
- Swift Package 構成
- whisper.cpp 呼び出しラッパ
- Python 補助スクリプト I/O 仕様

まで一気に書けます。
