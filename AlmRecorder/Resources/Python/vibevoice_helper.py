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


def _strip_code_fence(raw_text: str) -> str:
    raw_text = raw_text.strip()
    if raw_text.startswith("```"):
        raw_text = raw_text.split("\n", 1)[-1]
        raw_text = raw_text.removesuffix("```").strip()
    return raw_text


def _segment_candidates(payload: Any) -> list[Any]:
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("segments", "transcription", "results", "utterances"):
        nested = payload.get(key)
        if isinstance(nested, list):
            return nested
    timestamp_keys = {
        "start_time",
        "start",
        "Start",
        "Start time",
        "start time",
        "startTime",
    }
    if timestamp_keys.intersection(payload):
        return [payload]
    return []


def _decode_model_text(raw_text: str) -> tuple[list[Any], bool]:
    """Decode a complete response or salvage complete objects from truncated JSON.

    VibeVoice occasionally reaches its token ceiling before emitting the final array bracket. The
    mlx-audio parser then returns zero segments, even though most segment objects are complete. Keep
    the complete objects for diagnostics/recovery instead of turning the entire pass into an opaque
    empty result.
    """
    raw_text = _strip_code_fence(raw_text)
    if not raw_text:
        return [], False
    try:
        return _segment_candidates(json.loads(raw_text)), True
    except (json.JSONDecodeError, TypeError):
        pass

    decoder = json.JSONDecoder()
    recovered: list[Any] = []
    cursor = 0
    while cursor < len(raw_text):
        object_start = raw_text.find("{", cursor)
        if object_start < 0:
            break
        try:
            payload, object_end = decoder.raw_decode(raw_text, object_start)
        except json.JSONDecodeError:
            cursor = object_start + 1
            continue
        recovered.extend(_segment_candidates(payload))
        cursor = max(object_end, object_start + 1)
    return recovered, False


def _parse_timestamp(value: Any) -> float:
    if isinstance(value, bool):
        raise ValueError("boolean is not a timestamp")
    try:
        return float(value)
    except (TypeError, ValueError):
        pass
    text = str(value).strip().lower().removesuffix("s").strip()
    parts = text.split(":")
    if len(parts) not in (2, 3):
        raise ValueError("unsupported timestamp")
    numbers = [float(part) for part in parts]
    if len(numbers) == 2:
        minutes, seconds = numbers
        return minutes * 60 + seconds
    hours, minutes, seconds = numbers
    return hours * 3600 + minutes * 60 + seconds


def _segments_with_diagnostics(result: Any) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    native_segments = getattr(result, "segments", None)
    raw_text = str(getattr(result, "text", "") or "")
    complete_json = True
    recovered_from_text = False
    raw_segments = native_segments
    if not raw_segments:
        raw_segments, complete_json = _decode_model_text(raw_text)
        recovered_from_text = bool(raw_segments)

    normalized: list[dict[str, Any]] = []
    for segment in raw_segments or []:
        start = _field(
            segment,
            "start_time",
            "start",
            "Start",
            "Start time",
            "start time",
            "startTime",
        )
        end = _field(
            segment,
            "end_time",
            "end",
            "End",
            "End time",
            "end time",
            "endTime",
        )
        speaker = _field(
            segment,
            "speaker_id",
            "speaker",
            "Speaker",
            "Speaker ID",
            "speaker id",
            "speakerId",
            default="unknown",
        )
        text = _field(segment, "text", "content", "Content", default="")
        try:
            start_value = _parse_timestamp(start)
            end_value = _parse_timestamp(end)
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
    diagnostics = {
        "native_segment_count": len(native_segments or []),
        "candidate_segment_count": len(raw_segments or []),
        "text_chars": len(raw_text),
        "complete_json": complete_json,
        "recovered_from_text": recovered_from_text,
        "generation_tokens": getattr(result, "generation_tokens", None),
    }
    return normalized, diagnostics


def _segments(result: Any) -> list[dict[str, Any]]:
    return _segments_with_diagnostics(result)[0]


def _failure_detail(diagnostics: dict[str, Any], max_tokens: int) -> str:
    generated_tokens = diagnostics.get("generation_tokens")
    likely_token_limit = (
        isinstance(generated_tokens, int)
        and generated_tokens >= max(0, max_tokens - 1)
    )
    return (
        "ALMREC_VIBEVOICE_RECOVERABLE_OUTPUT "
        f"generation_tokens={generated_tokens!r} max_tokens={max_tokens} "
        f"text_chars={diagnostics['text_chars']} "
        f"candidate_segments={diagnostics['candidate_segment_count']} "
        f"complete_json={diagnostics['complete_json']} "
        f"likely_token_limit={likely_token_limit}"
    )


def _plain_text(result: Any) -> str:
    segments = _segments(result)
    text = " ".join(segment["text"] for segment in segments).strip()
    if not text:
        raise RuntimeError("VibeVoice returned no parseable speech")
    return text


def _configure_mlx(memory_limit_bytes: int | None) -> Any:
    import mlx.core as mx

    # Each normal helper invocation exits after one pass, while realtime serve mode keeps model
    # weights resident across multiple pause-delimited chunks. In both cases, transient generation
    # buffers should be returned immediately instead of accumulating in MLX's allocation cache.
    mx.set_cache_limit(0)
    if memory_limit_bytes:
        mx.set_memory_limit(memory_limit_bytes)
    mx.reset_peak_memory()
    return mx


def probe(output: str) -> None:
    import mlx  # noqa: F401
    import mlx_audio  # noqa: F401

    _write(output, {"schema_version": SCHEMA_VERSION, "ok": True})


def transcribe(args: argparse.Namespace) -> None:
    from mlx_audio.stt.utils import load

    # The MLX limit is an allocator guideline; the Swift parent also monitors macOS memory pressure.
    mx = _configure_mlx(args.memory_limit_bytes)

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

    segments, diagnostics = _segments_with_diagnostics(result)
    if not segments:
        raise RuntimeError(
            "VibeVoice returned no parseable timestamped segments; "
            + _failure_detail(diagnostics, args.max_tokens)
        )
    generation_tokens = diagnostics.get("generation_tokens")
    likely_token_limit = (
        isinstance(generation_tokens, int)
        and generation_tokens >= max(0, args.max_tokens - 1)
    )
    likely_truncated = diagnostics["recovered_from_text"] and (
        not diagnostics["complete_json"] or likely_token_limit
    )
    _write(
        args.output,
        {
            "schema_version": SCHEMA_VERSION,
            "segments": segments,
            "language": getattr(result, "language", None),
            "processing_seconds": time.monotonic() - started,
            "peak_memory_gb": peak_memory_gb,
            "generation_tokens": generation_tokens,
            "output_recovered": diagnostics["recovered_from_text"],
            "output_likely_truncated": likely_truncated,
        },
    )


def _emit_protocol(stream: Any, payload: dict[str, Any]) -> None:
    stream.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    stream.flush()


def serve(args: argparse.Namespace) -> None:
    """Keep the full MLX model warm and serve newline-delimited JSON requests over stdio."""
    protocol_output = sys.stdout
    # Third-party model loaders occasionally print progress to stdout. Keep stdout exclusively for
    # protocol messages and route every incidental print to the stderr log owned by the Swift app.
    sys.stdout = sys.stderr

    _emit_protocol(
        protocol_output,
        {
            "type": "status",
            "message": "Loading VibeVoice ASR 4-bit into Metal (5.7 GB)…",
        },
    )

    from mlx_audio.stt.utils import load

    mx = _configure_mlx(args.memory_limit_bytes)
    model = load(args.model)
    _emit_protocol(protocol_output, {"type": "ready"})

    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        request_id = None
        try:
            request = json.loads(raw_line)
            if request.get("type") == "exit":
                break
            if request.get("type") != "transcribe":
                raise ValueError("Unsupported realtime request")

            request_id = str(request.get("id", ""))
            audio = str(request["audio"])
            context = request.get("context")
            max_tokens = int(request.get("max_tokens", args.max_tokens))
            _emit_protocol(
                protocol_output,
                {
                    "type": "status",
                    "id": request_id,
                    "message": "Transcribing with VibeVoice ASR 4-bit…",
                },
            )

            mx.reset_peak_memory()
            started = time.monotonic()
            result = model.generate(
                audio=audio,
                context=context,
                max_tokens=max_tokens,
                temperature=0.0,
            )
            text = _plain_text(result)
            peak_memory_gb = None
            try:
                peak_memory_gb = float(mx.get_peak_memory()) / 1_000_000_000
            except Exception:
                pass
            mx.clear_cache()
            _emit_protocol(
                protocol_output,
                {
                    "type": "result",
                    "id": request_id,
                    "text": text,
                    "processing_seconds": time.monotonic() - started,
                    "peak_memory_gb": peak_memory_gb,
                },
            )
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            _emit_protocol(
                protocol_output,
                {
                    "type": "error",
                    "id": request_id,
                    "message": str(error),
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

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--model", required=True)
    serve_parser.add_argument("--max-tokens", type=int, default=768)
    serve_parser.add_argument("--memory-limit-bytes", type=int)

    args = parser.parse_args()
    if args.command == "probe":
        probe(args.output)
    elif args.command == "transcribe":
        transcribe(args)
    else:
        serve(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        traceback.print_exc(file=sys.stderr)
        raise SystemExit(2)
