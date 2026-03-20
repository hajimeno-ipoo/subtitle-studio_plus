# ディレクトリ構成案

## 1. 目的
本書は、本番運用を前提にした配置を固定する。  
実行コード、外部ツール、モデル、中間成果物、最終成果物、設計資料を混ぜないことを目的とする。

## 2. ルート構成
```text
subtitle-studio_plus/
├── SubtitleStudioPlus.xcodeproj
├── Sources/
├── Tests/
├── Support/
├── Tools/
├── Work/
├── docs/
└── Docs2/
```

## 3. Sources 配下
```text
Sources/
├── App/
├── Models/
├── Persistence/
├── Services/
│   ├── AudioAnalysisService.swift
│   ├── LocalPipelineService.swift
│   ├── ExternalProcessRunner.swift
│   ├── LocalPipelineAssembler.swift
│   ├── LocalPipelineCorrectionService.swift
│   ├── SubtitleAlignmentService.swift
│   └── WaveformService.swift
├── Utilities/
├── ViewModels/
└── Views/
```

## 4. Tools 配下
```text
Tools/
├── whisper/
│   ├── whisper-cli
│   └── models/
│       ├── ggml-kotoba-v2.bin
│       ├── ggml-kotoba-bilingual.bin
│       └── ggml-base.en-encoder.mlmodelc
├── qwen/
│   ├── transcribe.py
│   ├── align.py
│   └── requirements-local-pipeline.txt
└── dictionaries/
    ├── default_ja_corrections.json
    └── sample_known_lyrics.txt
```

## 5. Work 配下
```text
Work/
└── run-20260320-120000-ab12cd34/
    ├── manifest.json
    ├── input/
    │   └── normalized.wav
    ├── chunks/
    │   ├── index.json
    │   ├── chunk-00001.wav
    │   └── chunk-00002.wav
    ├── base_json/
    │   ├── chunk-00001.json
    │   └── suspicious_index.json
    ├── qwen_json/
    │   └── chunk-00001.json
    ├── aligned_json/
    │   ├── pre_alignment.json
    │   └── phrase_alignment.json
    ├── final/
    │   ├── final.json
    │   ├── final.txt
    │   ├── final.lrc
    │   └── final.srt
    └── logs/
        ├── run.jsonl
        ├── whisper.stderr.log
        ├── qwen.stderr.log
        └── align.stderr.log
```

## 6. docs 配下
```text
docs/
├── 20260319_resolve_bridge/
└── 20260320_local_asr_pipeline/
    ├── requirements_spec.md
    ├── execution_order_and_architecture.md
    ├── architecture.mmd
    ├── architecture.png
    ├── basic_design.md
    ├── detailed_design.md
    ├── swift_interface_design.md
    ├── python_helper_script_design.md
    ├── json_schema.md
    └── directory_structure.md
```

## 7. 配置ルール
- `Sources/` はアプリ本体コードのみ置く。
- `Tools/` は外部実行物と補助スクリプトのみ置く。
- `Work/` は実行時生成物のみ置く。
- `docs/` は設計資料のみ置く。
- `Docs2/` は元資料として残し、実装の正式参照先にはしない。

## 8. 本番運用ルール
- 本番で使うモデル path は `Tools/` 配下の絶対パスとして解決する。
- `Work/` はジョブごとに新規 run directory を切る。
- run directory は 30 日以上経過したものを運用で削除可能とする。
- 設計資料は `docs/20260320_local_asr_pipeline/` に集約する。
