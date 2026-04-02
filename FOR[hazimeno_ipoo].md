# Subtitle Studio Plus について

## これは何をするアプリ？
- 音声や動画を読み込みます。
- `Gemini` または `Local Pipeline` で字幕を作ります。
- 波形を見ながら字幕を直せます。
- 最後に `.srt` を書き出します。

## 今の全体の作り
- `SwiftUI`
  - 画面を作る土台です。
- `AVFoundation`
  - 音を読む仕組みです。
- `Gemini API`
  - 既存のクラウド字幕生成です。
- `Local Pipeline`
  - 新しいローカル字幕生成です。
  - 中身は `whisper.spm + whisper.cpp C API + Kotoba-Whisper + aeneas` です。
- `Keychain`
  - API キーを安全に保存します。
- `Resolve 連携`
  - `.srt` や字幕データを Resolve 側へ渡します。

## Local Pipeline の考え方
- まず `whisper.cpp C API` を **2通り** で使います。
- 1つ目は「自然な歌詞本文」を作る役です。
- 2つ目は「どこで歌っているかの時間」を取る役です。
- 参照歌詞がない時は、本文用と時間用の両方を使います。
- `TXT` 参照の時は、本文は参照歌詞を使い、時間だけ `whisper.cpp` から取ります。
- `SRT` 参照の時は、元の `SRT` の時間を主に使います。
- 最後に `aeneas` は時間の微調整だけをします。
- 最後に `final.srt` を作ります。

## もう使わないもの
- `Qwen3-ASR`
- `Qwen3-ForcedAligner`
- `Tools/qwen`
- 旧Web版 (`React / Vite / TypeScript`)
- 最終成果物としての `TXT / JSON / LRC`

## フォルダの意味
- `Sources/App`
  - アプリの入口です。
- `Sources/Models`
  - 字幕や設定の型です。
- `Sources/ViewModels`
  - 画面の状態をまとめる司令塔です。
- `Sources/Views`
  - 実際に見える UI です。
- `Sources/Services`
  - 音声処理、AI 呼び出し、字幕組み立ての仕事役です。
- `Sources/Persistence`
  - 設定保存です。
- `Tools/aeneas`
  - `aeneas` を呼ぶ Python 補助スクリプトです。
- `Tools/dictionaries`
  - 辞書補正や既知歌詞の補助ファイルです。
- `Support`
  - Resolve 連携やアプリ設定の補助ファイルです。
- `Tests`
  - 主要ロジックが壊れていないか確かめる自動テストです。
- `docs/20260320_local_asr_pipeline`
  - ローカル字幕生成の正式資料です。
- `Work/run-...`
  - 実行ごとのログと中間ファイルを保存する場所です。
  - 成功時は `manifest.json`、`logs/`、`final/final.srt` が残ります。
  - `TXT` 参照の成功時は、調査用に `alignment_input/` も残ることがあります。

## なぜこの技術を選んだ？
- `SwiftUI`
  - macOS アプリとして自然に作れるからです。
- `AVFoundation`
  - Apple 標準で音声処理に強いからです。
- `whisper.cpp`
  - Apple Silicon で動かしやすいからです。
- `aeneas`
  - 行単位や短いブロック単位の `SRT` 作成と相性が良いからです。
- `Gemini` は残す
  - 既存機能を壊さず、用途で切り替えられるからです。

## よくあるバグと直し方
- API キー未設定
  - 症状: `Gemini` 生成が止まります。
  - 修正: `Settings` の `API` タブでキーを入れます。
- whisper model が見つからない
  - 症状: `Local Pipeline` の開始前に止まります。
  - 修正: `whisperModelPath` を確認します。空なら `Models` 配下の自動検出名を確認します。
- `aeneas` が見つからない
  - 症状: `Local Pipeline` の時間合わせで止まります。
  - 修正: `aeneasPythonPath` と `aeneasScriptPath` を確認します。
- `aeneas` が入っているのに時間が合わない
  - 症状: ローカル字幕の時間が粗く、クリップ位置と長さが波形に合いません。
  - 修正: `aeneas` の存在確認だけでなく、`whisper.cpp` の timing guide が取れているかも確認します。
  - 修正: `alignment_input/segments.json` と `segment_alignment.json` を見て、行が検索箱いっぱいの長さになっていないか確認します。
- `TXT` 参照なのに左端へ固まる
  - 症状: たくさんの字幕が数秒の範囲へ密集します。
  - 修正: `run.jsonl` に `coarse sequential timing fallback used` が出ていないか確認します。出ている時は、`timing guide` が弱くて仮 timing に落ちています。
- `AUTO-ALIGN` で合っていた所まで崩れる
  - 症状: ずれていた字幕は直るが、正しかった字幕まで動きます。
  - 修正: 今は「元のまま / 全体ずれ補正 / 端点補正 / 幅補正」の候補を比べて、一番自然なものだけを採用します。
  - 修正: それでも崩れる時は、音声の無音区間が少ないか、BGM が強すぎる可能性があります。
- 字幕が全部 0 秒に重なる
  - 症状: タイムラインの左端に固まります。
  - 修正: `aeneas` の補正結果を採用せず、draft timing に戻せているか確認します。
- 字幕の長さが全部短すぎる
  - 症状: どのクリップもほぼ同じ短さです。
  - 修正: `end <= start` の block が fallback されているか確認します。
- 文字起こしが崩れる
  - 症状: 歌詞らしくない文になります。
  - 修正: `initialPrompt`、辞書、補助歌詞入力を見直します。
- ローカル字幕の数が少なすぎる
  - 症状: Gemini よりかなり少ない数のクリップになります。
  - 修正: 字幕 block をまとめすぎていないか確認します。今は `2〜6秒 / 1〜2行` を目安にしています。

## 落とし穴
- `Gemini` 用の prompt を勝手に要約すると、精度が崩れやすいです。
- ただし、`Gemini` 用の長い命令文をそのまま `whisper.cpp` に渡すのも逆効果です。
- そのため、`whisper.cpp` には **歌詞向けの短い専用 prompt** を使います。
- `LOCAL SRT` で選べるモデルは `Kotoba-Whisper v2.0 / Bilingual` です。
- 長い音声を一気に時間合わせするとズレやすいです。
- そのため、`aeneas` は短い block ごとに実行します。
- `aeneas` に位置探しを全部やらせると、違う歌詞の所へ吸われやすいです。
- `TXT` を 1 行ずつ `aeneas` に渡すと、行の中の位置合わせが効かず、切り出した箱の長さそのままになることがあります。
- 先に `whisper.cpp` の timing guide を作っておかないと、後ろをいくら直しても崩れます。
- ただし、その `timing guide` で各行を直接ぐいっと動かしすぎると、前半の歌詞が後ろへ飛ぶことがあります。
- そのため、`timing guide` はまず「歌っている区間を見つける補助」に使い、行の最終位置は無理に引っ張りすぎない方が安全です。
- `aeneas` は「最後の微調整だけ」にして、変な補正は採用しない方が安全です。
- 2 行まとめて `aeneas` に渡した時も、行と行のあいだに本来ある無音は潰さない方が、見た目が自然になりやすいです。
- 字幕が 0 件なのに成功扱いにすると、空の `SRT` ができてしまいます。
- そのため、字幕 0 件はエラーとして止めます。

## ベストプラクティス
- `Gemini` と `Local Pipeline` は同じ UI で切り替える。
- 補助歌詞は常設欄にせず、必要な時だけ小さなボタンから開く。
- 最終成果物は `SRT` に絞る。
- 中間 JSON はデバッグ用だけにする。
- 失敗時は、どの段階で止まったかをログに残す。
- `TXT` 参照では、本文と timing を同じ Whisper に任せず、役割を分ける。
- タイムライン表示を直す前に、まず `SubtitleItem.startTime / endTime` が正しいかを見る。
- 手動調整しやすい形で `SubtitleItem[]` を作る。
- `AUTO-ALIGN` は本文を作り直さず、時間候補と幅候補だけ比べて採用する方が壊れにくい。
