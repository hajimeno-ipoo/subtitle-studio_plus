#!/usr/bin/env python3
import argparse
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import traceback
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-audio", required=True)
    parser.add_argument("--segments-json", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--language", required=True)
    return parser.parse_args()


def map_language(language: str) -> str:
    normalized = language.strip().lower()
    if normalized in {"ja", "jpn", "japanese"}:
        return "jpn"
    if normalized in {"en", "eng", "english"}:
        return "eng"
    return normalized or "jpn"


def load_manifest(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def aeneas_available() -> bool:
    return importlib.util.find_spec("aeneas.tools.execute_task") is not None


def patch_aeneas_runtime() -> bool:
    try:
        import numpy  # noqa: PLC0415
        import aeneas.wavfile as wavfile  # noqa: PLC0415
    except Exception as error:  # pragma: no cover - runtime environment specific
        print(f"[ERROR] Failed to import aeneas runtime: {error}", file=sys.stderr)
        return False

    def compat_fromstring(data, dtype=None):
        return numpy.frombuffer(data, dtype=dtype)

    wavfile.numpy.fromstring = compat_fromstring
    return True


def parse_alignment_json(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    fragments = payload.get("fragments") or []
    if not fragments:
        return None

    starts = []
    ends = []
    for fragment in fragments:
        try:
            starts.append(float(fragment["begin"]))
            ends.append(float(fragment["end"]))
        except (KeyError, TypeError, ValueError):
            continue

    if not starts or not ends:
        return None

    start = min(starts)
    end = max(ends)
    if end <= start:
        return None
    return start, end


def parse_alignment_fragments(path: Path):
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    fragments = payload.get("fragments") or []
    aligned = []
    for fragment in fragments:
        try:
            start = float(fragment["begin"])
            end = float(fragment["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if end <= start:
            continue
        aligned.append((start, end))
    return aligned or None


def align_segment(segment: dict, language: str):
    text = (segment.get("text") or "").strip()
    audio_path = (segment.get("audioPath") or "").strip()
    if not text or not audio_path:
        return None

    clip_start = float(segment.get("clipStartTime") or 0.0)
    audio_file = Path(audio_path)
    if not audio_file.exists():
        print(f"[WARN] Missing block audio: {audio_file}", file=sys.stderr)
        return None

    with tempfile.TemporaryDirectory(prefix="subtitle-aeneas-") as temporary_dir:
        temp_dir = Path(temporary_dir)
        text_file = temp_dir / "segment.txt"
        output_file = temp_dir / "alignment.json"
        text_file.write_text(text, encoding="utf-8")

        config = f"task_language={language}|is_text_type=plain|os_task_file_format=json"
        try:
            from aeneas.tools.execute_task import ExecuteTaskCLI  # noqa: PLC0415
        except Exception as error:  # pragma: no cover - runtime environment specific
            print(f"[ERROR] Failed to load aeneas CLI: {error}", file=sys.stderr)
            return None

        command = [
            "align_subtitles.py",
            "-r=tts=macos",
            str(audio_file),
            str(text_file),
            config,
            str(output_file),
        ]

        command_stdout = io.StringIO()
        command_stderr = io.StringIO()
        try:
            with contextlib.redirect_stdout(command_stdout), contextlib.redirect_stderr(command_stderr):
                result_code = ExecuteTaskCLI(use_sys=False).run(arguments=command, show_help=False)
        except Exception as error:  # pragma: no cover - runtime environment specific
            print(
                f"[WARN] aeneas failed for {segment.get('segmentId')}: {error}",
                file=sys.stderr,
            )
            print(
                f"[WARN] context: cwd={Path.cwd()} python={sys.executable} temp={temp_dir}",
                file=sys.stderr,
            )
            print(f"[WARN] command: {' '.join(command)}", file=sys.stderr)
            details_stdout = command_stdout.getvalue().strip()
            details_stderr = command_stderr.getvalue().strip()
            if details_stdout:
                print("[WARN] aeneas stdout:", file=sys.stderr)
                print(details_stdout, file=sys.stderr)
            if details_stderr:
                print("[WARN] aeneas stderr:", file=sys.stderr)
                print(details_stderr, file=sys.stderr)
            print(traceback.format_exc(), file=sys.stderr)
            return None

        if result_code != 0:
            print(
                f"[WARN] aeneas failed for {segment.get('segmentId')}: exit={result_code}",
                file=sys.stderr,
            )
            print(
                f"[WARN] context: cwd={Path.cwd()} python={sys.executable} temp={temp_dir}",
                file=sys.stderr,
            )
            print(f"[WARN] command: {' '.join(command)}", file=sys.stderr)
            details_stdout = command_stdout.getvalue().strip()
            details_stderr = command_stderr.getvalue().strip()
            if details_stdout:
                print("[WARN] aeneas stdout:", file=sys.stderr)
                print(details_stdout, file=sys.stderr)
            if details_stderr:
                print("[WARN] aeneas stderr:", file=sys.stderr)
                print(details_stderr, file=sys.stderr)
            return None

        line_segment_ids = segment.get("lineSegmentIDs") or []
        line_texts = segment.get("lineTexts") or []
        line_start_times = segment.get("lineStartTimes") or []
        line_end_times = segment.get("lineEndTimes") or []
        line_search_start_times = segment.get("lineSearchStartTimes") or []
        line_search_end_times = segment.get("lineSearchEndTimes") or []
        if line_segment_ids and line_texts:
            fragments = parse_alignment_fragments(output_file)
            if fragments is None or len(fragments) != len(line_segment_ids):
                return None
            aligned_segments = []
            if len(line_start_times) == len(line_segment_ids) and len(line_end_times) == len(line_segment_ids):
                boundaries = []
                for index, (start, end) in enumerate(fragments[:-1]):
                    next_start, _ = fragments[index + 1]
                    boundaries.append(clip_start + ((end + next_start) / 2.0))

                for index, (segment_id, line_text) in enumerate(zip(line_segment_ids, line_texts)):
                    start = float(line_start_times[index]) if index == 0 else boundaries[index - 1]
                    end = float(line_end_times[index]) if index == len(line_segment_ids) - 1 else boundaries[index]

                    if len(line_search_start_times) == len(line_segment_ids):
                        start = max(start, float(line_search_start_times[index]))
                    if len(line_search_end_times) == len(line_segment_ids):
                        end = min(end, float(line_search_end_times[index]))

                    if end <= start:
                        start = clip_start + fragments[index][0]
                        end = clip_start + fragments[index][1]
                    aligned_segments.append(
                        {
                            "segmentId": segment_id,
                            "start": start,
                            "end": end,
                            "text": line_text,
                        }
                    )
                return aligned_segments

            for (start, end), segment_id, line_text in zip(fragments, line_segment_ids, line_texts):
                aligned_segments.append(
                    {
                        "segmentId": segment_id,
                        "start": clip_start + start,
                        "end": clip_start + end,
                        "text": line_text,
                    }
                )
            return aligned_segments

        aligned = parse_alignment_json(output_file)
        if aligned is None:
            return None

        start, end = aligned
        return {
            "segmentId": segment["segmentId"],
            "start": clip_start + start,
            "end": clip_start + end,
            "text": text,
        }


def main():
    args = parse_args()
    manifest = load_manifest(Path(args.segments_json))
    segments = manifest.get("segments") or []
    total = len(segments)
    language = map_language(args.language)
    available = aeneas_available()

    if not available:
        print("[ERROR] aeneas is not installed.", file=sys.stderr)
        return 2
    if not patch_aeneas_runtime():
        return 3

    aligned_segments = []
    for index, segment in enumerate(segments, start=1):
        segment_id = segment.get("segmentId", f"segment-{index:04d}")
        print(f"Aligning block {index}/{max(total, 1)}: {segment_id}", file=sys.stderr)
        if available:
            aligned = align_segment(segment, language)
            if aligned is not None:
                if isinstance(aligned, list):
                    aligned_segments.extend(aligned)
                else:
                    aligned_segments.append(aligned)

    payload = {
        "runId": manifest.get("runId", ""),
        "engineType": "localPipeline",
        "modelName": "aeneas",
        "segments": aligned_segments,
    }

    output_path = Path(args.output_json)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(payload, ensure_ascii=False), file=sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
