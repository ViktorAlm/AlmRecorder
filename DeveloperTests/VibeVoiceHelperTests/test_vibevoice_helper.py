#!/usr/bin/env python3
"""Contract tests for the bundled VibeVoice helper without loading MLX or model weights."""

from __future__ import annotations

import importlib.util
import types
import unittest
from pathlib import Path


HELPER_PATH = (
    Path(__file__).resolve().parents[2]
    / "AlmRecorder"
    / "Resources"
    / "Python"
    / "vibevoice_helper.py"
)
SPEC = importlib.util.spec_from_file_location("almrec_vibevoice_helper", HELPER_PATH)
assert SPEC and SPEC.loader
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


def result(*, segments=None, text="", generation_tokens=None):
    return types.SimpleNamespace(
        segments=segments or [],
        text=text,
        generation_tokens=generation_tokens,
    )


class VibeVoiceHelperContractTests(unittest.TestCase):
    def test_accepts_mlx_audio_normalized_segments(self):
        parsed = HELPER._segments(
            result(
                segments=[
                    {
                        "start": 0.25,
                        "end": 1.5,
                        "speaker_id": 3,
                        "text": "hello",
                    }
                ]
            )
        )
        self.assertEqual(parsed[0]["speaker"], "3")
        self.assertEqual(parsed[0]["start"], 0.25)

    def test_accepts_the_exact_canonical_keys_requested_by_vibevoice(self):
        parsed = HELPER._segments(
            result(
                text="""[
                  {"Start time":"00:01.250","End time":"00:03.5",
                   "Speaker ID":7,"Content":"canonical output"}
                ]"""
            )
        )
        self.assertEqual(parsed, [
            {
                "start": 1.25,
                "end": 3.5,
                "speaker": "7",
                "text": "canonical output",
            }
        ])

    def test_accepts_a_top_level_segments_wrapper(self):
        parsed = HELPER._segments(
            result(
                text="""{"segments":[
                  {"Start time":0,"End time":2,"Speaker ID":"A","Content":"wrapped"}
                ]}"""
            )
        )
        self.assertEqual([item["text"] for item in parsed], ["wrapped"])

    def test_salvages_every_complete_turn_from_truncated_json(self):
        parsed, diagnostics = HELPER._segments_with_diagnostics(
            result(
                text="""[
                  {"Start time":0,"End time":2,"Speaker ID":0,"Content":"one"},
                  {"Start time":2,"End time":4,"Speaker ID":1,"Content":"two"},
                  {"Start time":4,"End time":
                """,
                generation_tokens=8192,
            )
        )
        self.assertEqual([item["text"] for item in parsed], ["one", "two"])
        self.assertFalse(diagnostics["complete_json"])
        self.assertTrue(diagnostics["recovered_from_text"])

    def test_failure_diagnostics_expose_shape_not_private_transcript_text(self):
        _, diagnostics = HELPER._segments_with_diagnostics(
            result(text="not json private words", generation_tokens=768)
        )
        detail = HELPER._failure_detail(diagnostics, 768)
        self.assertIn("ALMREC_VIBEVOICE_RECOVERABLE_OUTPUT", detail)
        self.assertIn("likely_token_limit=True", detail)
        self.assertNotIn("private words", detail)

    def test_drops_invalid_or_empty_turns(self):
        parsed = HELPER._segments(
            result(
                segments=[
                    {"start": 1, "end": 1, "speaker_id": 0, "text": "zero"},
                    {"start": 0, "end": 1, "speaker_id": 0, "text": "   "},
                    {"start": "bad", "end": 2, "speaker_id": 0, "text": "bad"},
                ]
            )
        )
        self.assertEqual(parsed, [])


if __name__ == "__main__":
    unittest.main()
