# ディレクトリ構成

## 1. ルート
```text
SubtitleStudioPlus/
├── Sources/
├── Tests/
├── Tools/
├── docs/
└── Work/
```

## 2. Tools
```text
Tools/
├── aeneas/
│   └── align_subtitles.py
└── dictionaries/
    ├── default_ja_corrections.json
    └── sample_known_lyrics.txt
```

`Tools/qwen/` は削除対象。

## 3. docs
```text
docs/20260320_local_asr_pipeline/
├── requirements_spec.md
├── basic_design.md
├── detailed_design.md
├── swift_interface_design.md
├── python_helper_script_design.md
├── json_schema.md
├── execution_order_and_architecture.md
├── directory_structure.md
├── implementation_tasks.md
├── implementation_execution_report_20260320.md
└── architecture.mmd
```

## 4. Work
```text
Work/
└── run-YYYYMMDD-HHMMSS-xxxxxxxx/
    ├── input/
    │   └── normalized.wav
    ├── chunks/
    │   ├── chunk-00001.wav
    │   └── index.json
    ├── base_json/
    │   └── chunk-00001.json
    ├── draft_json/
    │   └── draft_segments.json
    ├── alignment_input/
    │   └── segments.json
    ├── aligned_json/
    │   └── segment_alignment.json
    ├── final/
    │   └── final.srt
    └── logs/
        ├── run.jsonl
        └── aeneas.stderr.log
```

## 5. 役割
- `base_json/`
  - whisper.cpp の下書き
- `draft_json/`
  - 字幕 block に整形した中間結果
- `alignment_input/`
  - `aeneas` に渡す入力
- `aligned_json/`
  - `aeneas` が返した時間合わせ結果
- `final/`
  - ユーザー向け最終成果物
- `logs/`
  - 進行と失敗原因の確認用
