# 詳細設計書

## 1. 目的
本書は基本設計を実装可能な粒度まで詳細化し、Swift 側と Python 側の責務、ジョブの状態遷移、エラー処理、再試行、保存ルールを固定する。

## 2. ジョブ状態設計

### 2.1 共通状態
- `idle`
- `validating`
- `preparing`
- `chunking`
- `baseTranscribing`
- `detectingSuspicious`
- `refining`
- `aligning`
- `correcting`
- `assembling`
- `writingOutputs`
- `completed`
- `failed`

### 2.2 画面表示
- 状態ごとに固定文言を出す。
- チャンク処理中は `currentChunk / totalChunks` を表示する。
- `failed` では失敗段階、原因概要、ログ保存先を出す。

## 3. Local Pipeline の詳細フロー

### 3.1 準備
1. 設定をロードする。
2. tool path を検証する。
3. モデルファイル存在を検証する。
4. 出力先 run directory を生成する。
5. 実行用 manifest JSON を保存する。

### 3.2 正規化
1. 入力音声を mono / 16kHz wav に変換する。
2. 出力は `Work/<run-id>/input/normalized.wav` に保存する。
3. 元音声情報と変換結果を manifest に記録する。

### 3.3 チャンク分割
1. `chunkLengthSeconds` と `overlapSeconds` で区間を作る。
2. 各チャンクを `chunks/chunk-00001.wav` 形式で保存する。
3. チャンクメタデータを `chunks/index.json` に保存する。

### 3.4 ベースASR
1. 各チャンクに対して whisper.cpp を実行する。
2. 出力は JSON 形式を標準とする。
3. 結果は `base_json/chunk-00001.json` に保存する。
4. 失敗時は 1 回だけ再試行する。
5. 再試行後も失敗ならジョブ全体を失敗とする。

### 3.5 疑わしい区間抽出
1. ベース結果を segment 単位で評価する。
2. 判定基準:
   - 空文字または 1 文字
   - 同一文字反復
   - ひらがな偏重
   - 信頼スコア下回り
   - 前後チャンク接続不自然
3. suspicious 判定結果を `base_json/suspicious_index.json` に保存する。

### 3.6 Qwen3-ASR 再判定
1. suspicious な区間のみ再判定対象にする。
2. 対象区間を phrase 単位で切り出して Python へ渡す。
3. 出力は `qwen_json/chunk-00001.json` に保存する。
4. 統合時は `refined transcript` を残す。

### 3.7 結果統合
1. ベース結果と再判定結果を segment 単位で統合する。
2. 置換条件:
   - Qwen 側が空でない
   - Qwen 側の品質評価がベースより高い
   - 前後セグメントとの結合で破綻しない
3. 統合結果を `aligned_json/pre_alignment.json` に保存する。

### 3.8 Forced Alignment
1. 統合後 transcript を phrase 単位で Qwen3-ForcedAligner へ渡す。
2. 入力長が 5 分を超える場合は phrase group に分割する。
3. 出力を `aligned_json/phrase_alignment.json` に保存する。
4. word timing も保存する。

### 3.9 補正
1. 辞書置換
2. 正規表現補正
3. 既知歌詞照合
4. 表記統一
5. 結果を `final/final.json` に保存する。

### 3.10 出力
1. 共通字幕モデルへ変換する。
2. `final.txt` `final.json` `final.lrc` `final.srt` を生成する。
3. ログを `logs/run.jsonl` に保存する。

## 4. 品質評価ロジック

### 4.1 suspicious 判定スコア
- `lengthScore`
- `repeatScore`
- `hiraganaBiasScore`
- `confidenceScore`
- `contextScore`

### 4.2 統合判定
- `replace` / `keepBase` / `hold`
- `hold` は本番では採用しない。`hold` になった場合は `keepBase` に倒してログを残す。

## 5. エラー処理詳細

### 5.1 停止条件
- 入力読込失敗
- 正規化失敗
- whisper.cpp 実行不能
- モデル未検出
- Python 実行不能
- align 出力 JSON 不正
- final assembly 不正

### 5.2 再試行条件
- whisper.cpp の一時失敗
- Python 子プロセスの一時失敗
- ファイル読み取り競合

### 5.3 再試行回数
- ベースASR: 1 回
- Qwen3-ASR: 1 回
- ForcedAligner: 1 回
- 出力書き込み: 1 回

### 5.4 タイムアウト
- whisper.cpp: 1 チャンクあたり 180 秒
- Qwen3-ASR: 1 チャンクあたり 300 秒
- ForcedAligner: 1 phrase group あたり 300 秒

## 6. ログ設計

### 6.1 共通フィールド
- `timestamp`
- `runId`
- `stage`
- `level`
- `message`
- `engineType`
- `chunkId`
- `command`
- `exitCode`
- `stderrPath`

### 6.2 レベル
- `INFO`
- `WARN`
- `ERROR`

## 7. セキュリティ詳細
- Keychain 管理対象は Gemini API Key のみとする。
- ローカル設定は秘密情報を含まない前提で UserDefaults に保存する。
- `Work/` 内へ API Key を書かない。
- ログに全文 transcript を書かない。
- transcript は成果物 JSON にのみ保存し、ログには path と件数だけ記録する。

## 8. パフォーマンス詳細
- 正規化は 1 回のみ行う。
- チャンク音声は再利用する。
- 中間 JSON は後続段階が読むため必ず保存する。
- 同時並列数は本番既定で 1 とする。
- 並列化は将来拡張とし、本設計では採用しない。

## 9. 復旧設計
- run directory に `manifest.json` を保存する。
- `manifest.json` には stage 完了フラグを持たせる。
- 再実行時に `resumeFrom` を指定できる構造にする。
- 本番 v1 では UI からの再開機能は付けず、内部実装だけ用意する。

## 10. 非採用詳細
- チャンク単位の部分字幕をそのまま編集画面へ出す運用はしない。
- UTO-ALIGN をローカルパイプラインの必須段にしない。
- Gemini と Local Pipeline の混成自動フォールバックはしない。
