# 基本設計書

## 1. 文書の目的
本書は、`requirements_spec.md` を実装へ落とすための基本設計を定義する。  
対象は Subtitle Studio Plus における SRT 生成エンジンの並立構成である。  
本書では、Gemini 経路を維持したまま、Local Pipeline を本番運用可能な形で追加するための責務分離、主要コンポーネント、実行経路、保存方針を固定する。

## 2. 設計方針

### 2.1 全体方針
- 本体は既存の SwiftUI macOS アプリ `Subtitle Studio Plus` とする。
- SRT 生成エンジンは `Gemini` と `Local Pipeline` の二系統を並立させる。
- 利用者は UI で生成方式を選択する。
- ローカル経路は `whisper.cpp + Kotoba`、`Qwen3-ASR`、`Qwen3-ForcedAligner`、補正、出力の多段構成とする。
- Swift は司令塔に徹し、重い推論は外部プロセスで実行する。
- すべての経路は最終的に共通の字幕モデルへ正規化してから編集・出力に進む。

### 2.2 本番前提の方針
- 実行失敗時は、アプリ全体を落とさず、どの段で失敗したかを利用者へ返す。
- 外部プロセス呼び出しは、標準出力・標準エラー・終了コードを必ず収集する。
- 中間成果物を `Work/` に保存し、途中再開可能な構造にする。
- 設定は永続化し、次回起動時に同じ選択を復元する。
- 生成結果はエンジン差を吸収して共通の `SubtitleItem` 系モデルへ統一する。
- 既存の手動編集、UTO-ALIGN、SRT 出力、Resolve 連携は壊さない。

## 3. システム構成

### 3.1 論理構成
- Presentation Layer
  - 生成方式切替 UI
  - 設定画面
  - 進捗表示
  - エラー表示
- Orchestration Layer
  - `AppViewModel`
  - 解析ジョブ制御
  - 字幕モデル統合
- Engine Layer
  - `Gemini SRT Engine`
  - `Local Pipeline Engine`
- Tool Execution Layer
  - `whisper.cpp CLI`
  - `Python transcribe.py`
  - `Python align.py`
- Persistence Layer
  - 設定保存
  - 中間 JSON 保存
  - 最終出力保存
  - ログ保存

### 3.2 コンポーネント責務

#### SwiftUI / ViewModel
- 利用者入力を受ける。
- 生成方式を切り替える。
- 設定値を読み書きする。
- 解析開始、進捗表示、完了反映を制御する。
- 共通字幕モデルへ統合して編集画面へ渡す。

#### Gemini Engine
- 現行の Gemini API を利用した SRT 生成を担当する。
- 既存の `AudioAnalysisService` を基礎に維持する。
- 出力は共通字幕モデルへ変換する。

#### Local Pipeline Engine
- 音声の正規化、分割、ベースASR、疑わしい区間抽出、再判定、時刻合わせ、補正、出力を担当する。
- `Work/` へ中間成果物を段階保存する。
- 結果統合後に共通字幕モデルを返す。

#### Tool Execution Layer
- 外部実行ファイルの存在確認を行う。
- 実行コマンドを生成する。
- タイムアウト、終了コード、標準出力、標準エラーを収集する。
- JSON の妥当性を検証する。

## 4. 実行経路

### 4.1 Gemini 経路
1. 音声入力
2. 設定読み込み
3. Gemini API Key 検証
4. 既存の Gemini SRT 生成
5. SRT 解析
6. 共通字幕モデルへ変換
7. 編集画面へ反映

### 4.2 Local Pipeline 経路
1. 音声入力
2. 設定読み込み
3. ローカルツール存在確認
4. 入力音声正規化
5. チャンク分割
6. `whisper.cpp + Kotoba` ベース転写
7. 疑わしい区間抽出
8. `Qwen3-ASR` 再判定
9. 再判定結果統合
10. `Qwen3-ForcedAligner` 実行
11. 辞書補正・歌詞照合・表記統一
12. 共通字幕モデルへ変換
13. 編集画面へ反映
14. LRC / SRT / JSON / TXT 出力

## 5. 主要データフロー

### 5.1 入力
- UI で音声ファイルを選択する。
- UI で `Gemini` または `Local Pipeline` を選択する。
- 設定画面でモデルとパラメータを指定する。

### 5.2 Local Pipeline 中間データ
- `normalized.wav`
- `chunks/*.wav`
- `base_json/*.json`
- `qwen_json/*.json`
- `aligned_json/*.json`
- `final/*.json`
- `logs/*.jsonl`

### 5.3 共通出力
- `SubtitleItem` 配列
- 編集画面用状態
- `final.txt`
- `final.json`
- `final.lrc`
- `final.srt`

## 6. 画面設計の基本方針

### 6.1 生成方式切替
- `AUTO GENERATE` 実行前に生成方式を選ぶ。
- 選択肢は `Gemini` と `Local Pipeline` の二択とする。
- 最後に使った方式を既定値として保持する。

### 6.2 設定画面
- 既存の `API`、`UTO-ALIGN` に加えてローカル生成用タブを追加する。
- ローカル設定タブでは次を扱う。
  - ベースモデル
  - 言語
  - chunk length
  - overlap
  - temperature
  - beam size
  - no speech threshold
  - logprob threshold
  - suspicious threshold
  - correction dictionary path
  - known lyrics path
  - tool path

### 6.3 進捗表示
- Gemini と Local Pipeline で進捗文言を分ける。
- Local Pipeline は段階表示とチャンク進捗を両方見せる。

## 7. 障害時の基本動作
- 入力不正は開始前に弾く。
- 必須ツールが見つからない場合は解析開始前に停止する。
- 1 チャンク失敗時は再試行可能なら再試行する。
- 再試行後も失敗したチャンクはログへ残し、ジョブ全体を中断する。
- JSON 不正、空出力、アライメント失敗は利用者へ具体的に返す。
- 編集画面へは部分的に壊れた字幕を流し込まない。

## 8. 永続化方針
- Gemini API Key は Keychain を使う。
- 生成方式、ローカル設定、最後に使ったモデルは UserDefaults へ保存する。
- `Work/` はプロジェクトルート配下に置き、実行単位でサブフォルダを切る。
- 実行単位は `run-YYYYMMDD-HHMMSS-<uuid8>` 命名とする。

## 9. 既存機能との整合
- 既存の `AUTO GENERATE` 導線を活かす。
- 出力後の字幕編集、UTO-ALIGN、Resolve 連携は共通字幕モデル以降で同じ処理を通す。
- ローカル経路の結果も既存の Undo、Redo、SRT 出力へそのまま流せる構造にする。

## 10. 採用しない設計
- Swift から PyTorch / Transformers を直接組み込む構成は採用しない。
- Gemini を Local Pipeline の fallback として自動発火させる構成は採用しない。
- 全チャンクを無条件で Qwen3-ASR に通す構成は採用しない。
- 中間成果物を保存しない構成は採用しない。
