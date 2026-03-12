# Subtitle Studio Plus

macOS 向けの SwiftUI 字幕エディタです。  
音声を読み込み、Gemini で字幕を作り、波形タイムラインで時間を直して `.srt` を書き出します。

## 使い方

1. `swift run` を実行します。
2. 右上の `Settings` で Gemini API Key を保存します。
3. 音声ファイルを読み込みます。
4. `AUTO GENERATE` で字幕を作ります。
5. 必要なら `AUTO-ALIGN` とタイムライン編集で微調整します。
6. `EXPORT .SRT` で保存します。

## 動作要件

- macOS 14 以上
- Swift 6.2
- Xcode 26 以上

## テスト

```bash
swift test
```
