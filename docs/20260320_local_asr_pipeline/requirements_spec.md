# 要件定義書

## 1. システム名称
Subtitle Studio Plus 向け
`whisper.cpp + aeneas` ローカル字幕生成パイプライン

## 2. 背景
既存の Gemini 経路は残す。
一方で、歌詞向けにローカル完結で字幕を作る経路も必要である。
これまで試した `Qwen3-ASR` と `Qwen3-ForcedAligner` の多段構成は、歌詞の崩れ、時刻 0 秒固定、処理時間の長さが問題になった。
そのため、ローカル経路は `whisper.cpp + Kotoba-Whisper` を主軸にし、時間合わせはまず `aeneas` を使う構成へ切り替える。

## 3. 目的
本システムの目的は、Subtitle Studio Plus 上で、ボーカル抽出済み音声から字幕用の `SRT` を安定して作れるようにすることである。
あわせて以下を満たす。

1. 既存の `Gemini` 経路を壊さない
2. `Local Pipeline` を UI から選べる
3. Apple Silicon 上で現実的な速度で動く
4. 字幕が 0 秒位置に固まらない
5. クリップ長が全部同じ短さにならない
6. 最終成果物は `SRT` だけに絞る
7. `whisper.cpp` の prompt はローカル専用の短い歌詞向け補助文を使う

## 4. 適用範囲

### 4.1 対象
- 音声入力受付
- 生成方式選択
- 音声正規化
- `whisper.cpp` による下書き生成
- 下書きの字幕行整形
- 字幕ブロック分割
- `aeneas` による時間合わせ
- 辞書補正
- `SRT` 出力
- ログ記録
- エラー表示
- Swift からの外部プロセス制御
- 設定画面でのローカル実行設定

### 4.2 対象外
- ボーカル分離そのもの
- 公式歌詞貼り付け専用 UI
- `WhisperX` 実装
- クラウド実行
- `TXT / JSON / LRC` の最終成果物出力

## 5. 想定利用者
- macOS と Apple Silicon を使う利用者
- ローカルで歌詞字幕を作りたい利用者
- Gemini とローカルを用途で使い分けたい利用者

## 6. システム概要
本システムは Subtitle Studio Plus の中に、次の 2 経路を並立させる。

- `Gemini`
- `Local Pipeline`

`Local Pipeline` の基本フローは次で固定する。

1. 音声を `mono / 16kHz wav` に整える
2. `whisper.cpp + Kotoba-Whisper` で下書きを作る
3. 下書きを字幕向けの短い行へ整える
4. 約 `8〜12秒`、最大 `2行` ごとの小さいまとまりに分ける
5. 小さいまとまりごとに `aeneas` で時間を合わせる
6. `aeneas` が失敗した所だけ `whisper.cpp` の時間を使う
7. 最後に `SRT` を出力する

## 7. 構成要素

### 7.1 Swift 本体
SwiftUI アプリが全体の制御を行う。

- 生成方式切り替え
- 設定読込
- 音声前処理
- 外部プロセス呼び出し
- ログ保存
- `SubtitleItem[]` 組み立て
- `SRT` 出力

### 7.2 ベース文字起こし
`whisper.cpp` を使う。
Apple Silicon では Core ML を有効にできる構成を維持する。
モデルは以下を切り替え可能にする。

- `Kotoba-Whisper v2.x`
- `Kotoba-Whisper Bilingual`

### 7.3 時間合わせ
時間合わせの第一候補は `aeneas` とする。
`WhisperX` は将来候補として docs にだけ残す。
今回の実装対象には含めない。

### 7.4 補正
辞書補正と既知歌詞照合を行う。
ただし、Qwen の再生成のような重い再判定は行わない。

### 7.5 出力
最終成果物は `SRT` のみとする。

## 8. 機能要件

### 8.1 入力
- 受け付ける形式:
  - WAV
  - M4A
  - FLAC
  - MP3
- 内部処理では `WAV / 16kHz / mono` に正規化する
- 入力音声は原則としてボーカル抽出済みを前提とする

### 8.2 生成方式切り替え
UI で以下を選択できること。

- `Gemini`
- `Local Pipeline`

### 8.3 ベース文字起こし
- `whisper.cpp` を用いてローカル推論する
- モデルは以下を切り替え可能とする
  - `Kotoba-Whisper v2.x`
  - `Kotoba-Whisper Bilingual`
- 設定可能項目:
  - `language`
  - `temperature`
  - `beamSize`
  - `initialPrompt`
  - `chunkLengthSeconds`
  - `overlapSeconds`
  - `noSpeechThreshold`
  - `logprobThreshold`

### 8.4 Whisper prompt
- `whisper.cpp` に渡す prompt は次で固定する
  - 先頭: ローカル専用の歌詞向けベース prompt
  - 後ろ: ユーザー入力の `initialPrompt`
- ベース prompt は次とする
  - `日本語の歌詞です。`
  - `自然な区切りの日本語の歌詞として認識してください。`
  - `歌詞らしい語順と自然な表記を優先してください。`
- `initialPrompt` は曲名、固有名詞、よく出る単語、表記の希望を足すために使う

### 8.5 字幕行整形
- Whisper の生出力をそのまま 1 行にせず、字幕向けに整形する
- 1 ブロックは最大 2 行
- 1 ブロックの長さはおよそ `8〜12秒`
- 長すぎるブロックはさらに分ける

### 8.6 時間合わせ
- `aeneas` は小さい字幕ブロックごとに実行する
- 長い全体音声を一発で合わせない
- `aeneas` が時刻を返したブロックはその結果を採用する
- `aeneas` が失敗したブロックは `whisper.cpp` の時刻に戻す

### 8.7 時刻 fallback
以下は無効時刻とみなす。

- `start == end`
- `end <= start`
- 時刻欠落

無効時刻になったブロックは、必ず Whisper 側の時刻へ戻す。

### 8.8 出力
- 最終成果物は `final.srt`
- `TXT / JSON / LRC` は最終成果物としては出さない
- 中間 JSON はデバッグ用に保存してよい
- 字幕 0 件なら成功扱いにせず、エラーとして扱う

### 8.9 UI 表示
- 進捗表示は Gemini に近い考え方にそろえる
  - 音声読込中
  - 音声準備中
  - 分割中
  - 解析中
  - 整形中
  - まとめ中
  - 完了
- エラー表示は
  - 失敗段階
  - 一言の原因
  - 必要ならログ保存先
  を出す

### 8.10 設定画面
`LOCAL SRT` で次を設定できること。

- ベースモデル
- 言語
- `initialPrompt`
- `chunkLengthSeconds`
- `overlapSeconds`
- `beamSize`
- `temperature`
- `whisperModelPath`
- `whisperCoreMLModelPath`
- `aeneasPythonPath`
- `aeneasScriptPath`
- `correctionDictionaryPath`
- `outputDirectoryPath`

以下は削除対象とする。

- `Qwen3-ASR` スクリプト設定
- `ForcedAligner` スクリプト設定
- `Qwen3-ASR` モデル設定
- `Qwen3-ForcedAligner` モデル設定
- `suspiciousThreshold`
- `whisperCLIPath`
- `knownLyricsPath`

## 9. 非機能要件
- Apple Silicon で動くこと
- `.app` のカレントディレクトリに依存しないこと
- `Work/run-.../` にログと中間成果物を分けて保存すること
- 失敗時に段階とログが追えること
- 既存 `Gemini` 経路を壊さないこと

## 10. 完了条件
- `Local Pipeline` で `final.srt` が出る
- 作られた字幕が全部 0 秒位置に重ならない
- 作られた字幕の長さが全部同じ極端な短さにならない
- タイムライン全体で字幕が波形の流れに沿って並ぶ
- `Gemini` と `Local Pipeline` を UI で切り替えられる
