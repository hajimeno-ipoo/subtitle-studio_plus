# 詳細設計

## 1. 実行順
1. 入力検証
2. 音声正規化
3. チャンク分割
4. `whisper.cpp` 実行
5. Whisper 出力統合
6. 字幕ブロック整形
7. `aeneas` 実行
8. timing fallback
9. 補正
10. `SubtitleItem[]` 組み立て
11. `final.srt` 出力

## 2. 入力検証
開始前に次を確認する。

- `whisper-cli` の path
- whisper model の path
- `aeneas` 実行用 Python の path
- `Tools/aeneas/align_subtitles.py` の path
- 出力先ディレクトリ

## 3. 音声正規化
- 入力音声を `mono / 16kHz wav` に変換する
- 保存先: `input/normalized.wav`

## 4. チャンク分割
- `chunkLengthSeconds` と `overlapSeconds` に従ってチャンク計画を作る
- 保存先:
  - `chunks/index.json`
  - `chunks/chunk-xxxxx.wav`

## 5. whisper.cpp 実行
- 各チャンクに対して `whisper.cpp` を実行する
- prompt は次で固定する
  - `日本語の歌詞です。`
  - `自然な区切りの日本語の歌詞として認識してください。`
  - `歌詞らしい語順と自然な表記を優先してください。`
  - 必要なら改行して `initialPrompt`
- 保存先:
  - `base_json/chunk-xxxxx.json`

## 6. Whisper 出力統合
- チャンク間の重なりを見て重複を減らす
- Whisper の raw segment を `LocalPipelineBaseSegment` へ変換する

## 7. 字幕ブロック整形
- Whisper segment をそのまま最終字幕にしない
- 次のルールで block を作る
  - 最大 2 行
  - 1 block の目安は `8〜12秒`
  - 長すぎる行は分割する
  - 句読点や無音境界を優先する
- 保存先:
  - `draft_json/draft_segments.json`
  - `alignment_input/segments.json`

## 8. aeneas 実行
- block ごとに `aeneas` を使って時間を付ける
- Swift から直接ではなく Python スクリプトを呼ぶ
- script は stderr に
  - `Aligning block 3/12: seg-0003`
  のように進捗を書く
- 保存先:
  - `aligned_json/segment_alignment.json`

## 9. timing fallback
次の条件は無効 timing とみなす。

- `start == end`
- `end <= start`
- timing 欠落

無効 timing の block は Whisper timing を使う。
これで `0秒固定` と `0.1秒固定` を防ぐ。

## 10. 補正
- 辞書置換
- 既知歌詞照合
- 表記統一
- timing は block 単位の `start / end` を使う

## 11. 組み立て
- 補正済み block を `SubtitleItem[]` に変換する
- 並びは曲の最初から最後へ向かって自然な順に並べる

## 12. 出力
- 最終成果物は `final/final.srt` のみ
- 中間 JSON はデバッグ用に残してよい
- 字幕 0 件なら成功扱いにせず、エラーにする

## 13. 進捗表示
画面では Gemini に近い段階名を使う。

- 音声読込中
- 音声準備中
- 分割中
- 解析中
- 整形中
- まとめ中
- 完了

## 14. エラー表示
画面には次を出す。

- 失敗段階
- 一言の原因
- 必要なら run directory

## 15. 失敗時の扱い
- `whisper.cpp` が失敗したらジョブ全体を止める
- `aeneas` が block 単位で失敗しても、その block は Whisper timing で続行する
- `final.srt` 生成まで到達できることを優先する
