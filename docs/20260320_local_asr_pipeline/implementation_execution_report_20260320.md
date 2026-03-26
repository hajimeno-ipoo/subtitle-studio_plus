# 実装実行報告

## 結論
Local Pipeline を `Qwen3-ASR + Qwen3-ForcedAligner` から、`whisper.cpp + aeneas` へ置き換えた。  
最終成果物は `SRT` のみに整理した。

## 実施内容
- `LocalPipelineService` を新フローへ置き換えた
- `LocalPipelineSettings` から Qwen 設定を削除した
- `Tools/qwen` の tracked file を削除した
- `Tools/aeneas/align_subtitles.py` を追加した
- Gemini の prompt 共通化をやめて、Whisper にはローカル専用 prompt を使うようにした
- 字幕 0 件を成功扱いにしないようにした
- docs を `aeneas first` 前提へ更新した

## 変わった点
- 再判定は行わない
- alignment は `aeneas` を第一候補にした
- `aeneas` 失敗 block は Whisper timing fallback にした
- 最終成果物は `final.srt` のみ

## 確認結果
- Python script の構文チェック: 成功
- Local Pipeline 関連テスト: 実施
- build: 実施

## 残り
- 実音源での目視確認
- タイムライン上の見た目確認
- Gemini 経路との並立確認
