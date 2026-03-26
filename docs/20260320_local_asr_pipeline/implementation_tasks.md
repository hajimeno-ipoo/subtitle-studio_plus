# 実装タスク

## 1. Swift 側の置き換え
- [x] `LocalPipelineSettings` から Qwen 関連項目を削除する
- [x] `LocalPipelinePhase` から Qwen 前提の段階を削除する
- [x] `LocalPipelineModels` を block 単位モデルへ置き換える
- [x] `LocalPipelineService` を `whisper.cpp + aeneas` 前提へ置き換える
- [x] `LocalPipelineCorrectionService` を block timing 前提へ置き換える
- [x] 最終出力を `final.srt` のみにする

## 2. prompt
- [x] Gemini の prompt 共通化をやめる
- [x] Whisper 側でローカル専用の歌詞向けベース prompt を使う
- [x] `initialPrompt` は後ろに連結する
- [x] 字幕 0 件は成功扱いにしない

## 3. UI と設定
- [x] `LOCAL SRT` 設定から Qwen 項目を削除する
- [x] `aeneasPythonPath` と `aeneasScriptPath` を追加する
- [x] 進捗表示を Gemini に近い流れへ寄せる

## 4. Python 補助層
- [x] `Tools/aeneas/align_subtitles.py` を追加する
- [x] `Tools/qwen/transcribe.py` を削除する
- [x] `Tools/qwen/align.py` を削除する
- [x] `Tools/qwen/requirements-local-pipeline.txt` を削除する

## 5. fallback
- [x] `aeneas` が block 単位で失敗しても Whisper timing へ戻す
- [x] 無効 timing を fallback 条件として扱う

## 6. docs
- [x] 要件定義を `aeneas first` に更新する
- [x] 設計資料を `Qwen` 非採用前提へ更新する
- [x] JSON スキーマを block 単位へ更新する
- [x] 実装報告を更新する

## 7. 手動確認
- [ ] Local Pipeline で `final.srt` が生成される
- [ ] タイムライン上で字幕が 0 秒位置に重ならない
- [ ] クリップ長が全部ほぼ同じ短さに揃わない
- [ ] Gemini 経路が壊れていない
