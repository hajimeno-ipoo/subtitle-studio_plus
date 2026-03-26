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
  - 中身は `whisper.cpp + Kotoba-Whisper + aeneas` です。
- `Keychain`
  - API キーを安全に保存します。
- `Resolve 連携`
  - `.srt` や字幕データを Resolve 側へ渡します。

## Local Pipeline の考え方
- まず `whisper.cpp` で歌詞の下書きを作ります。
- 次に、下書きを短い字幕ブロックにまとめます。
- その小さいブロックごとに `aeneas` で時間を合わせます。
- `aeneas` が失敗した所だけ、`whisper.cpp` が持っている時間に戻します。
- 最後に `final.srt` を作ります。

## もう使わないもの
- `Qwen3-ASR`
- `Qwen3-ForcedAligner`
- `Tools/qwen`
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
- `docs/20260320_local_asr_pipeline`
  - ローカル字幕生成の正式資料です。
- `Work/run-...`
  - 実行ごとのログと中間ファイルを保存する場所です。

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
- `whisper-cli` が見つからない
  - 症状: `Local Pipeline` の開始前に止まります。
  - 修正: `LOCAL SRT` の `whisperCLIPath` を確認します。
- whisper model が見つからない
  - 症状: `Local Pipeline` の開始前に止まります。
  - 修正: `whisperModelPath` を確認します。
- `aeneas` が見つからない
  - 症状: `Local Pipeline` の時間合わせで止まります。
  - 修正: `aeneasPythonPath` と `aeneasScriptPath` を確認します。
- `aeneas` が入っているのに時間が合わない
  - 症状: ローカル字幕の時間が粗く、クリップ位置と長さが波形に合いません。
  - 修正: `aeneas` の存在確認だけでなく、NumPy 互換パッチと `macOS TTS` で実行できているか確認します。
- `aeneas` が 1 件も timing を返さない
  - 症状: 以前は Whisper timing に黙って戻っていました。今はエラーで止まります。
  - 修正: `logs/aeneas.stderr.log` を見て、`exit=1` だけでなく、その直後に出る `aeneas stdout` / `aeneas stderr` / `command` を確認します。
- 字幕が全部 0 秒に重なる
  - 症状: タイムラインの左端に固まります。
  - 修正: `aeneas` の timing が無効な時に Whisper timing fallback が効いているか確認します。
- 字幕の長さが全部短すぎる
  - 症状: どのクリップもほぼ同じ短さです。
  - 修正: `end <= start` の block が fallback されているか確認します。
- 文字起こしが崩れる
  - 症状: 歌詞らしくない文になります。
  - 修正: `initialPrompt`、辞書、既知歌詞を見直します。
- ローカル字幕の数が少なすぎる
  - 症状: Gemini よりかなり少ない数のクリップになります。
  - 修正: 字幕 block をまとめすぎていないか確認します。今は `6〜8秒 / 1行` を目安にしています。

## 落とし穴
- `Gemini` 用の prompt を勝手に要約すると、精度が崩れやすいです。
- ただし、`Gemini` 用の長い命令文をそのまま `whisper.cpp` に渡すのも逆効果です。
- そのため、`whisper.cpp` には **歌詞向けの短い専用 prompt** を使います。
- 長い音声を一気に時間合わせするとズレやすいです。
- そのため、`aeneas` は短い block ごとに実行します。
- `aeneas` が全部うまくいく前提で作ると、また 0 秒固定に戻ります。
- 一部 block の失敗だけ Whisper timing に戻す前提が必要です。
- 逆に、`aeneas` が全部失敗している時は続行せず止めた方が原因を追いやすいです。
- 字幕が 0 件なのに成功扱いにすると、空の `SRT` ができてしまいます。
- そのため、字幕 0 件はエラーとして止めます。

## ベストプラクティス
- `Gemini` と `Local Pipeline` は同じ UI で切り替える。
- 最終成果物は `SRT` に絞る。
- 中間 JSON はデバッグ用だけにする。
- 失敗時は、どの段階で止まったかをログに残す。
- タイムライン表示を直す前に、まず `SubtitleItem.startTime / endTime` が正しいかを見る。
- 手動調整しやすい形で `SubtitleItem[]` を作る。
