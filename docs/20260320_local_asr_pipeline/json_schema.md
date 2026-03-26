# JSON スキーマ定義

## 1. chunks/index.json
```json
{
  "runId": "run-20260321-000001-abcd1234",
  "sourceFileName": "song.wav",
  "chunks": [
    {
      "chunkId": "chunk-00001",
      "startTime": 0.0,
      "endTime": 8.0,
      "fileName": "chunk-00001.wav"
    }
  ]
}
```

## 2. base_json/chunk-xxxxx.json
```json
{
  "chunkId": "chunk-00001",
  "engineType": "localPipeline",
  "modelName": "whisper.cpp",
  "segments": [
    {
      "segmentId": "chunk-00001-seg-0001",
      "start": 0.0,
      "end": 1.6,
      "text": "愛してる",
      "confidence": 0.92
    }
  ]
}
```

## 3. draft_json/draft_segments.json
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
      "text": "愛してる\n君のこと",
      "sourceChunkIds": ["chunk-00001"]
    }
  ]
}
```

## 4. aligned_json/segment_alignment.json
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

## 5. final/final.json
中間確認用に残す場合の形。
最終成果物ではない。

```json
{
  "runId": "run-20260321-000001-abcd1234",
  "engineType": "localPipeline",
  "modelName": "aeneas",
  "subtitles": [
    {
      "start": 0.1,
      "end": 8.2,
      "text": "愛してる\n君のこと"
    }
  ]
}
```

## 6. logs/run.jsonl
```json
{"timestamp":"2026-03-21T00:00:01+09:00","level":"INFO","stage":"normalized","message":"normalized audio written"}
{"timestamp":"2026-03-21T00:00:02+09:00","level":"INFO","stage":"chunked","message":"chunk plan written"}
{"timestamp":"2026-03-21T00:00:10+09:00","level":"INFO","stage":"baseTranscribed","message":"base transcription completed"}
{"timestamp":"2026-03-21T00:00:20+09:00","level":"INFO","stage":"aligned","message":"aeneas alignment completed"}
{"timestamp":"2026-03-21T00:00:22+09:00","level":"INFO","stage":"corrected","message":"correction completed"}
{"timestamp":"2026-03-21T00:00:23+09:00","level":"INFO","stage":"outputsWritten","message":"final srt written"}
```
