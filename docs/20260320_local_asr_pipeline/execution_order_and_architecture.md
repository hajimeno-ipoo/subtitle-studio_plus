# 実行順と構成

## 結論
Subtitle Studio Plus のローカル字幕生成は、`whisper.cpp + Kotoba-Whisper` で下書きを作り、`aeneas` で短い字幕ブロックごとに時間を合わせる。
`Qwen3-ASR` と `Qwen3-ForcedAligner` は使わない。

## 実行順
1. 音声を `mono / 16kHz wav` に変換する
2. `whisper.cpp` で下書きを作る
3. 下書きを字幕向け block にまとめる
4. block ごとに `aeneas` で時間を合わせる
5. 失敗 block は Whisper timing を使う
6. `final.srt` を出力する

## Swift からの現実的な構成
Swift 本体が司令塔になる。
重い処理は外部プロセスとして呼ぶ。

- `whisper.cpp`
- `python3 Tools/aeneas/align_subtitles.py`

Swift 側は次を担当する。

- 設定読込
- 音声正規化
- 進捗表示
- 失敗時のエラー表示
- 字幕モデル統合
- `SRT` 書き出し

## なぜこの構成にするか
- `whisper.cpp` は Apple Silicon と相性がよい
- `Qwen3-ASR` の再生成で歌詞が崩れる問題を避けられる
- `aeneas` は行単位や短い block 単位の `SRT` 生成と相性がよい
- 目的が `SRT` なので、重い多段構成より単純な方が合う

## おすすめディレクトリ構成
```text
Tools/
  aeneas/
    align_subtitles.py
  dictionaries/
    default_ja_corrections.json

Work/
  run-YYYYMMDD-HHMMSS-xxxxxxxx/
    input/
      normalized.wav
    chunks/
      chunk-00001.wav
      index.json
    base_json/
      chunk-00001.json
    draft_json/
      draft_segments.json
    alignment_input/
      segments.json
    aligned_json/
      segment_alignment.json
    final/
      final.srt
    logs/
      run.jsonl
      aeneas.stderr.log
```

## モデル選択
- 日本語中心:
  - `Kotoba-Whisper v2.x`
- 英語混在が多い:
  - `Kotoba-Whisper Bilingual`

## chunk 長
- `6〜10秒` を基本にする
- オーバーラップは `0.5〜1.5秒`
- alignment 用の字幕 block は `8〜12秒`、最大 `2行`

## 優先順位
1. `SRT` を最後まで出せること
2. 字幕が 0 秒に重ならないこと
3. クリップ長が不自然にそろわないこと
4. UI を Gemini に近い流れにすること
5. 実装を複雑にしないこと

## 最終提案
今の Local Pipeline は、`whisper.cpp + aeneas` に一本化する。
`Qwen3-ASR` と `Qwen3-ForcedAligner` は削除する。
最終成果物は `SRT` のみとする。
