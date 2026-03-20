# JSON スキーマ定義

## 1. 方針
- 本番では JSON を段階ごとに保存する。
- 文字コードは UTF-8。
- 時刻は秒単位の `number`。
- パスは JSON に保存しない。必要な path は manifest 側で持つ。

## 2. chunks/index.json
```json
{
  "runId": "run-20260320-120000-ab12cd34",
  "sourceDuration": 215.42,
  "chunkLengthSeconds": 8.0,
  "overlapSeconds": 1.0,
  "chunks": [
    {
      "chunkId": "chunk-00001",
      "start": 0.0,
      "end": 8.0
    }
  ]
}
```

## 3. base_json/chunk-xxxxx.json
```json
{
  "chunkId": "chunk-00001",
  "engineType": "localPipeline",
  "baseModel": "kotobaWhisperV2",
  "language": "ja",
  "segments": [
    {
      "segmentId": "chunk-00001-seg-0001",
      "start": 0.35,
      "end": 2.42,
      "text": "あいしてる",
      "confidence": 0.74,
      "suspicious": true,
      "suspiciousReasons": [
        "hiragana_bias",
        "low_confidence"
      ]
    }
  ]
}
```

## 4. qwen_json/chunk-xxxxx.json
```json
{
  "chunkId": "chunk-00001",
  "engineType": "localPipeline",
  "modelName": "Qwen/Qwen3-ASR",
  "segments": [
    {
      "segmentId": "chunk-00001-seg-0001",
      "start": 0.35,
      "end": 2.42,
      "text": "愛してる",
      "confidence": 0.91
    }
  ]
}
```

## 5. aligned_json/pre_alignment.json
```json
{
  "runId": "run-20260320-120000-ab12cd34",
  "segments": [
    {
      "chunkId": "chunk-00001",
      "segmentId": "chunk-00001-seg-0001",
      "baseTranscript": "あいしてる",
      "refinedTranscript": "愛してる",
      "finalTranscript": "愛してる",
      "modelUsed": "Qwen/Qwen3-ASR",
      "suspicious": true
    }
  ]
}
```

## 6. aligned_json/phrase_alignment.json
```json
{
  "runId": "run-20260320-120000-ab12cd34",
  "modelName": "Qwen/Qwen3-ForcedAligner",
  "phrases": [
    {
      "phraseId": "phrase-0001",
      "text": "愛してる",
      "start": 10.42,
      "end": 12.63,
      "words": [
        {
          "word": "愛してる",
          "start": 10.42,
          "end": 12.63
        }
      ]
    }
  ]
}
```

## 7. final/final.json
```json
{
  "runId": "run-20260320-120000-ab12cd34",
  "engineType": "localPipeline",
  "sourceFileName": "song01.wav",
  "baseModel": "kotobaWhisperV2",
  "refinementModel": "Qwen/Qwen3-ASR",
  "alignmentModel": "Qwen/Qwen3-ForcedAligner",
  "segments": [
    {
      "id": "A2B3C4D5-E6F7-48A1-9B2C-1234567890AB",
      "chunkId": "chunk-00001",
      "phraseId": "phrase-0001",
      "startTime": 10.42,
      "endTime": 12.63,
      "baseTranscript": "あいしてる",
      "refinedTranscript": "愛してる",
      "finalTranscript": "愛してる",
      "suspicious": true,
      "corrections": [
        {
          "type": "dictionary",
          "before": "あいしてる",
          "after": "愛してる"
        }
      ]
    }
  ]
}
```

## 8. logs/run.jsonl
```json
{"timestamp":"2026-03-20T12:00:00+09:00","runId":"run-20260320-120000-ab12cd34","stage":"preparing","level":"INFO","message":"run directory created","engineType":"localPipeline"}
{"timestamp":"2026-03-20T12:00:08+09:00","runId":"run-20260320-120000-ab12cd34","stage":"baseTranscribing","level":"INFO","message":"chunk completed","engineType":"localPipeline","chunkId":"chunk-00001"}
```

## 9. manifest.json
```json
{
  "runId": "run-20260320-120000-ab12cd34",
  "engineType": "localPipeline",
  "sourceFileName": "song01.wav",
  "sourceDuration": 215.42,
  "settingsSnapshot": {
    "baseModel": "kotobaWhisperV2",
    "language": "ja",
    "chunkLengthSeconds": 8.0,
    "overlapSeconds": 1.0
  },
  "stages": {
    "normalized": true,
    "chunked": true,
    "baseTranscribed": true,
    "refined": false,
    "aligned": false,
    "corrected": false,
    "outputsWritten": false
  }
}
```
