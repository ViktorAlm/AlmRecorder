#!/usr/bin/env python3
"""Stable file-based bridge between AlmRecorder and mlx-audio VibeVoice-ASR."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import traceback
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1


def _write(path: str, payload: dict[str, Any]) -> None:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(temporary, destination)


def _field(segment: Any, *names: str, default: Any = None) -> Any:
    if isinstance(segment, dict):
        for name in names:
            if name in segment:
                return segment[name]
    for name in names:
        if hasattr(segment, name):
            return getattr(segment, name)
    return default


def _segments(result: Any) -> list[dict[str, Any]]:
    raw_segments = getattr(result, "segments", None)
    if not raw_segments:
        raw_text = getattr(result, "text", "") or ""
        raw_text = raw_text.strip()
        if raw_text.startswith("```"):
            raw_text = raw_text.split("\n", 1)[-1]
            raw_text = raw_text.removesuffix("```").strip()
        try:
            decoded = json.loads(raw_text)
            raw_segments = decoded.get("segments", []) if isinstance(decoded, dict) else decoded
        except (json.JSONDecodeError, TypeError):
            raw_segments = []

    normalized: list[dict[str, Any]] = []
    for segment in raw_segments or []:
        start = _field(segment, "start_time", "start", "Start")
        end = _field(segment, "end_time", "end", "End")
        speaker = _field(segment, "speaker_id", "speaker", "Speaker", default="unknown")
        text = _field(segment, "text", "content", "Content", default="")
        try:
            start_value = float(start)
            end_value = float(end)
        except (TypeError, ValueError):
            continue
        text_value = str(text).strip()
        if not text_value or end_value <= start_value:
            continue
        normalized.append(
            {
                "start": start_value,
                "end": end_value,
                "speaker": str(speaker),
                "text": text_value,
            }
        )
    return normalized


def probe(output: str) -> None:
    import mlx  # noqa: F401
    import mlx_audio  # noqa: F401

    _write(output, {"schema_version": SCHEMA_VERSION, "ok": True})


def transcribe(args: argparse.Namespace) -> None:
    import mlx.core as mx
    from mlx_audio.stt.utils import load

    # A VibeVoice helper performs one inference and exits, so retaining MLX's free allocation
    # cache cannot speed up a later request. Disable it to return transient buffers immediately.
    # The MLX memory limit is only an allocator guideline, not our primary safety boundary; the
    # parent process also monitors macOS compressor, swap, pressure, and reclaimable headroom.
    mx.set_cache_limit(0)
    if args.memory_limit_bytes:
        mx.set_memory_limit(args.memory_limit_bytes)
    mx.reset_peak_memory()

    started = time.monotonic()
    model = load(args.model)
    kwargs: dict[str, Any] = {
        "audio": args.audio,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
    }
    if args.context:
        kwargs["context"] = args.context
    result = model.generate(**kwargs)

    peak_memory_gb = None
    try:
        peak_memory_gb = float(mx.get_peak_memory()) / 1_000_000_000
    except Exception:
        pass

    segments = _segments(result)
    if not segments:
        raise RuntimeError("VibeVoice returned no parseable timestamped segments")
    _write(
        args.output,
        {
            "schema_version": SCHEMA_VERSION,
            "segments": segments,
            "language": getattr(result, "language", None),
            "processing_seconds": time.monotonic() - started,
            "peak_memory_gb": peak_memory_gb,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    probe_parser = subparsers.add_parser("probe")
    probe_parser.add_argument("--output", required=True)

    transcribe_parser = subparsers.add_parser("transcribe")
    transcribe_parser.add_argument("--audio", required=True)
    transcribe_parser.add_argument("--model", required=True)
    transcribe_parser.add_argument("--context")
    transcribe_parser.add_argument("--max-tokens", type=int, default=65536)
    transcribe_parser.add_argument("--temperature", type=float, default=0.0)
    transcribe_parser.add_argument("--memory-limit-bytes", type=int)
    transcribe_parser.add_argument("--output", required=True)

    args = parser.parse_args()
    if args.command == "probe":
        probe(args.output)
    else:
        transcribe(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(2)
