# Python 補助スクリプト設計

## 1. 方針
`Qwen` 用スクリプトは使わない。
`Local Pipeline` から呼ぶ Python スクリプトは `aeneas` 用の 1 本だけにする。

## 2. 対象スクリプト
- 追加:
  - `Tools/aeneas/align_subtitles.py`
- 削除:
  - `Tools/qwen/transcribe.py`
  - `Tools/qwen/align.py`
  - `Tools/qwen/requirements-local-pipeline.txt`

## 3. 役目
`align_subtitles.py` は、字幕ブロックごとに `aeneas` を呼び、開始時間と終了時間を JSON で返す。

## 4. 入力
```bash
/path/to/python3 Tools/aeneas/align_subtitles.py \
  --input-audio /abs/path/input/normalized.wav \
  --segments-json /abs/path/alignment_input/segments.json \
  --language ja \
  --output-json /abs/path/aligned_json/segment_alignment.json
```

## 5. 入力 JSON の想定
`segments.json` には block 単位の情報を入れる。

```json
{
  "runId": "run-20260321-000001-abcd1234",
  "sourceFileName": "song.wav",
  "language": "ja",
  "segments": [
    {
      "segmentId": "seg-0001",
      "startTime": 0.0,
      "endTime": 8.4,
      "text": "愛してる\n君のこと"
    }
  ]
}
```

## 6. 出力 JSON
```json
{
  "runId": "run-20260321-000001-abcd1234",
  "engineType": "localPipeline",
  "modelName": "aeneas",
  "segments": [
    {
      "segmentId": "seg-0001",
      "start": 0.1,
      "end": 8.2,
      "text": "愛してる\n君のこと"
    }
  ]
}
```

## 7. 進捗出力
stderr に block 単位の進捗を出す。

例:
```text
Aligning block 3/12: seg-0003
```

Swift 側はこれを拾って進捗表示に使う。

## 8. 失敗時の扱い
- block 単位の失敗でジョブ全体を即終了させない
- 失敗 block は Swift 側で Whisper timing fallback を使う
- 入力 JSON 読込失敗や出力 JSON 書込失敗だけは script 全体を失敗にしてよい
