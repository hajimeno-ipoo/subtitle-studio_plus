# Python 補助スクリプト設計

## 1. 対象
- `Tools/qwen/transcribe.py`
- `Tools/qwen/align.py`

本書では、Swift から呼び出す Python 補助スクリプトの入力、出力、終了コード、標準出力、標準エラーの仕様を固定する。

## 2. 共通方針
- 標準出力は JSON のみとする。
- ログは標準エラーへ出す。
- 正常終了は exit code `0` とする。
- 異常終了は exit code `1` 以上とする。
- 例外スタックトレースは標準エラーへ出す。
- 入力不足や設定不正は即時終了する。

## 3. transcribe.py

### 3.1 目的
- suspicious 区間または phrase 音声に対して Qwen3-ASR を実行し、再判定結果を返す。

### 3.2 呼び出し形式
```bash
python3 Tools/qwen/transcribe.py \
  --input-audio /abs/path/chunk.wav \
  --chunk-id chunk-00012 \
  --model-name Qwen/Qwen3-ASR \
  --language ja \
  --output-json /abs/path/qwen_json/chunk-00012.json
```

### 3.3 入力引数
- `--input-audio`
- `--chunk-id`
- `--model-name`
- `--language`
- `--output-json`

### 3.4 標準出力 JSON
```json
{
  "chunkId": "chunk-00012",
  "modelName": "Qwen/Qwen3-ASR",
  "language": "ja",
  "segments": [
    {
      "segmentId": "chunk-00012-seg-0001",
      "start": 0.42,
      "end": 2.31,
      "text": "愛してる",
      "confidence": 0.91
    }
  ]
}
```

### 3.5 保存ファイル
- `--output-json` が指定された場合、標準出力と同じ JSON を保存する。

## 4. align.py

### 4.1 目的
- transcript と音声から Qwen3-ForcedAligner を実行し、phrase / word timing を返す。

### 4.2 呼び出し形式
```bash
python3 Tools/qwen/align.py \
  --input-audio /abs/path/normalized.wav \
  --transcript-json /abs/path/aligned_json/pre_alignment.json \
  --model-name Qwen/Qwen3-ForcedAligner \
  --output-json /abs/path/aligned_json/phrase_alignment.json
```

### 4.3 入力引数
- `--input-audio`
- `--transcript-json`
- `--model-name`
- `--output-json`

### 4.4 標準出力 JSON
```json
{
  "modelName": "Qwen/Qwen3-ForcedAligner",
  "phrases": [
    {
      "phraseId": "phrase-0001",
      "start": 12.45,
      "end": 15.02,
      "text": "愛してる君を",
      "words": [
        {
          "word": "愛してる",
          "start": 12.45,
          "end": 13.68
        },
        {
          "word": "君を",
          "start": 13.69,
          "end": 15.02
        }
      ]
    }
  ]
}
```

## 5. 実装ルール
- スクリプトの先頭で引数を検証する。
- ファイル存在確認を行う。
- JSON 読み書き時は UTF-8 固定とする。
- 浮動小数点秒は `float` で出す。
- 内部ログは `stderr` に 1 行ずつ出す。
- GPU 依存や CUDA 前提にはしない。
- Apple Silicon の Python 環境で動作することを前提にする。

## 6. 終了コード
- `0`: 成功
- `2`: 引数不正
- `3`: 入力ファイル不正
- `4`: モデルロード失敗
- `5`: 推論失敗
- `6`: JSON 出力失敗

## 7. 本番での禁止事項
- 標準出力へ説明文を混ぜること
- Markdown を出すこと
- 途中結果を未定義フォーマットで出すこと
- 絶対パス以外を前提にすること

## 8. 依存管理
- Python は `python3` で起動する。
- 依存パッケージは `requirements-local-pipeline.txt` に固定する。
- 本番環境ではバージョン固定を行う。
