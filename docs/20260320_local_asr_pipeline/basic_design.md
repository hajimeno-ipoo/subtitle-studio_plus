# 基本設計

## 1. 方針
ローカル字幕生成は `whisper.cpp + Kotoba-Whisper` を主軸にし、時間合わせは `aeneas` を使う。
`Qwen3-ASR` と `Qwen3-ForcedAligner` は使わない。
最終成果物は `SRT` のみとする。

## 2. 全体構成
- `Gemini`
  - 既存のクラウド経路
- `Local Pipeline`
  - 新しいローカル経路

`Local Pipeline` の流れ:

1. 音声正規化
2. `whisper.cpp` 下書き生成
3. 字幕向け行整形
4. 小さいブロック分割
5. `aeneas` で block ごとに時間合わせ
6. 失敗 block は Whisper timing へ戻す
7. `SubtitleItem[]` 組み立て
8. `final.srt` 出力

## 3. 役割分担

### 3.1 Swift 本体
- UI 切り替え
- 設定の保存
- 音声正規化
- 外部プロセス実行
- ログ保存
- 字幕モデルへの変換

### 3.2 whisper.cpp
- 歌詞の下書きを作る
- ローカル専用の短い歌詞向けベース prompt を使う
- ユーザー入力 `initialPrompt` はその後ろに足す

### 3.3 aeneas
- 下書きを小さい字幕ブロックごとに時間合わせする
- うまく合わせられた block だけを採用する

### 3.4 補正
- 辞書補正
- 既知歌詞照合
- 表記統一

## 4. UI 設計方針
- 生成方式の切り替え UI はそのまま使う
- `Local Pipeline` の進捗表示は Gemini と近い形にする
- 細かすぎる内部段階は画面に出しすぎない
- 失敗時は
  - どの段階で止まったか
  - 一言の原因
  - 必要ならログ保存先
  を出す

## 5. timing 設計方針
- `aeneas` の結果が有効ならそれを使う
- `aeneas` の結果が無効なら Whisper timing を使う
- 無効とみなす条件:
  - `start == end`
  - `end <= start`
  - 時刻が空

## 6. 精度改善方針
- 重い再生成はしない
- Whisper 側で次を使って精度を上げる
  - ローカル専用の歌詞向けベース prompt
  - ユーザーの `initialPrompt`
  - 辞書補正
  - 既知歌詞

## 7. 期待する効果
- タイムライン上で字幕が全部 0 秒に重ならない
- 字幕長が全部 0.1 秒などに揃わない
- `Qwen3-ASR` による歌詞の崩れを止める
- 実装と UI をシンプルに保つ
