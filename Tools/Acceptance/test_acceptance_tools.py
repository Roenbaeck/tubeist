from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from scan_canary import CHUNK_SIZE, scan_paths  # noqa: E402
from compare_media import (  # noqa: E402
    MediaValidationError,
    analyze_media_probe,
    compare_evidence,
)
from validate_report import (  # noqa: E402
    ReportValidationError,
    load_report,
    validate_report,
)


class AcceptanceReportTests(unittest.TestCase):
    def make_report(
        self,
        *,
        sequences: tuple[int, ...] = (0, 1),
        include_drop: bool = False,
        outcome: str = "stopped",
        schema: int = 3,
    ) -> list[dict[str, object]]:
        timestamp = datetime(2026, 8, 20, tzinfo=timezone.utc)
        events: list[dict[str, object]] = []

        def append(kind: str, **values: object) -> None:
            nonlocal timestamp
            event: dict[str, object] = {
                "timestamp": timestamp.isoformat(),
                "kind": kind,
                **values,
            }
            if schema == 3:
                event["elapsed"] = float(len(events))
            events.append(event)
            timestamp += timedelta(seconds=1)

        append("prepared", detail=f"schema={schema}")
        append("initializationParsed")
        for sequence in sequences:
            append(
                "segmentAccepted",
                sequence=sequence,
                duration=2.0,
                queuedDuration=0.25,
                retryCount=0,
                httpStatus=200,
            )
        if include_drop:
            append("segmentDropped", sequence=9, droppedFragments=1)
        append(outcome)
        append("summary", detail=f"outcome={outcome};events={len(events)}")
        return events

    def test_valid_stopped_report_returns_redacted_summary(self) -> None:
        summary = validate_report(self.make_report())
        self.assertEqual(summary["outcome"], "stopped")
        self.assertEqual(summary["acceptedSegmentCount"], 2)
        self.assertEqual(summary["acceptedDurationSeconds"], 4.0)
        self.assertEqual(summary["elapsedDurationSeconds"], 4.0)
        self.assertNotIn("detail", summary)

    def test_load_report_rejects_malformed_json_without_echoing_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "acceptance.jsonl")
            secret_marker = "do-not-repeat-this-marker"
            path.write_text(f'{{"kind":"prepared"}}\n{secret_marker}\n', encoding="utf-8")
            with self.assertRaises(ReportValidationError) as context:
                load_report(path)
        self.assertNotIn(secret_marker, str(context.exception))

    def test_sequence_gap_is_rejected(self) -> None:
        with self.assertRaisesRegex(ReportValidationError, "not contiguous"):
            validate_report(self.make_report(sequences=(0, 2)))

    def test_drop_requires_explicit_acceptance(self) -> None:
        report = self.make_report(include_drop=True)
        with self.assertRaisesRegex(ReportValidationError, "dropped fragments"):
            validate_report(report)
        summary = validate_report(report, allow_drops=True)
        self.assertEqual(summary["droppedFragmentEvents"], 1)

    def test_queue_and_retry_budgets_are_enforced(self) -> None:
        report = self.make_report()
        report[2]["queuedDuration"] = 2.5
        report[2]["retryCount"] = 3
        with self.assertRaises(ReportValidationError) as context:
            validate_report(
                report,
                maximum_queued_duration=2.0,
                maximum_retry_count=2,
            )
        self.assertIn("queued duration", str(context.exception))
        self.assertIn("retry count", str(context.exception))

    def test_accepted_segment_requires_a_successful_http_status(self) -> None:
        report = self.make_report()
        report[2]["httpStatus"] = None
        with self.assertRaisesRegex(ReportValidationError, "successful HTTP status"):
            validate_report(report)

    def test_non_success_outcome_requires_explicit_expectation(self) -> None:
        report = self.make_report(outcome="failed")
        with self.assertRaisesRegex(ReportValidationError, "not stopped"):
            validate_report(report)
        summary = validate_report(report, expected_outcome="failed")
        self.assertEqual(summary["outcome"], "failed")

    def test_monotonic_elapsed_time_is_required_for_current_evidence(self) -> None:
        report = self.make_report()
        report[3]["elapsed"] = 0.5
        with self.assertRaisesRegex(ReportValidationError, "out of order"):
            validate_report(report)

    def test_legacy_schema_requires_explicit_opt_in(self) -> None:
        report = self.make_report(schema=2)
        with self.assertRaisesRegex(ReportValidationError, "older than required"):
            validate_report(report)
        summary = validate_report(report, minimum_schema=2)
        self.assertEqual(summary["schema"], 2)
        self.assertIsNone(summary["elapsedDurationSeconds"])


class CanaryScanTests(unittest.TestCase):
    def test_canary_is_found_across_chunk_boundary_without_returning_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            needle = b"tubeist-canary-value"
            target = root / "journal.bin"
            target.write_bytes(b"x" * (CHUNK_SIZE - 5) + needle + b"tail")
            result = scan_paths(needle, (root,))
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["matchingFileCount"], 1)
        self.assertNotIn(needle.decode(), json.dumps(result))

    def test_canary_in_matching_filename_is_not_returned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            needle = b"canary-in-name"
            target = root / needle.decode()
            target.write_bytes(needle)
            result = scan_paths(needle, (root,))
        self.assertEqual(result["matchingFileCount"], 1)
        self.assertNotIn(needle.decode(), json.dumps(result))

    def test_canary_file_can_be_excluded_from_clean_scan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            needle_file = root / "needle.txt"
            needle = b"separate-secret-canary"
            needle_file.write_bytes(needle)
            (root / "clean.log").write_text("redacted output", encoding="utf-8")
            result = scan_paths(needle, (root,), excluded_paths=(needle_file,))
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["matchingFileCount"], 0)

    def test_empty_scan_is_not_accepted_as_clean(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "no files"):
                scan_paths(b"canary", (Path(directory),))


class MediaComparisonTests(unittest.TestCase):
    def make_probe(
        self,
        *,
        video_codec: str = "hevc",
        video_profile: str = "Main 10",
        audio_codec: str = "aac",
        audio_profile: str = "LC",
        color_transfer: str = "arib-std-b67",
        audio_start: str = "0.02",
        audio_duration: str = "2.98",
    ) -> dict[str, object]:
        return {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": video_codec,
                    "profile": video_profile,
                    "width": 1920,
                    "height": 1080,
                    "pix_fmt": "yuv420p10le",
                    "color_space": "bt2020nc",
                    "color_transfer": color_transfer,
                    "color_primaries": "bt2020",
                    "avg_frame_rate": "30000/1001",
                    "start_time": "0.0",
                    "duration": "3.0",
                },
                {
                    "codec_type": "audio",
                    "codec_name": audio_codec,
                    "profile": audio_profile,
                    "channels": 2,
                    "sample_rate": "48000",
                    "start_time": audio_start,
                    "duration": audio_duration,
                },
            ],
            "format": {"duration": "3.0"},
        }

    def analyze(self, probe: dict[str, object], *, recording: bool = True) -> dict[str, object]:
        return analyze_media_probe(
            probe,
            role="recording" if recording else "youtubeArchive",
            require_tubeist_recording=recording,
            allow_archive_sdr=False,
            expected_width=1920,
            expected_height=1080,
            expected_frame_rate=30000 / 1001,
            expected_audio_channels=2,
        )

    def test_tubeist_recording_reports_hdr_and_av_skew(self) -> None:
        summary = self.analyze(self.make_probe())
        self.assertTrue(summary["isTenBitHLGBT2020"])
        self.assertAlmostEqual(summary["frameRate"], 29.97003, places=5)
        self.assertEqual(summary["avStartSkewSeconds"], 0.02)
        self.assertEqual(summary["avEndSkewSeconds"], 0.0)

    def test_sdr_recording_is_rejected(self) -> None:
        with self.assertRaisesRegex(MediaValidationError, "HLG/BT.2020"):
            self.analyze(self.make_probe(color_transfer="bt709"))

    def test_hdr_youtube_transcode_may_use_vp9_and_opus(self) -> None:
        summary = self.analyze(
            self.make_probe(
                video_codec="vp9",
                video_profile="Profile 2",
                audio_codec="opus",
                audio_profile="unknown",
            ),
            recording=False,
        )
        self.assertEqual(summary["videoCodec"], "vp9")
        self.assertEqual(summary["audioCodec"], "opus")

    def test_missing_per_stream_timing_is_rejected(self) -> None:
        probe = self.make_probe()
        video = probe["streams"][0]
        assert isinstance(video, dict)
        del video["start_time"]
        del video["duration"]
        with self.assertRaisesRegex(MediaValidationError, "per-stream timing"):
            self.analyze(probe)

    def test_tagged_stream_duration_is_accepted(self) -> None:
        probe = self.make_probe()
        audio = probe["streams"][1]
        assert isinstance(audio, dict)
        del audio["duration"]
        audio["tags"] = {"DURATION": "00:00:02.980000000"}
        summary = self.analyze(probe)
        self.assertEqual(summary["avEndSkewSeconds"], 0.0)

    def test_duration_and_av_budgets_are_enforced(self) -> None:
        media = self.analyze(
            self.make_probe(audio_start="0.2", audio_duration="2.8")
        )
        report = {
            "acceptedDurationSeconds": 2.5,
            "elapsedDurationSeconds": 3.1,
        }
        with self.assertRaises(MediaValidationError) as context:
            compare_evidence(
                report,
                [media],
                maximum_duration_delta=0.25,
                maximum_av_skew=0.1,
            )
        self.assertIn("accepted-tail budget", str(context.exception))
        self.assertIn("A/V skew", str(context.exception))

    def test_comparison_returns_redacted_measurements(self) -> None:
        media = self.analyze(self.make_probe())
        report = {
            "acceptedDurationSeconds": 3.0,
            "elapsedDurationSeconds": 3.05,
        }
        summary = compare_evidence(
            report,
            [media],
            maximum_duration_delta=0.1,
            maximum_av_skew=0.05,
        )
        self.assertEqual(summary["status"], "pass")
        self.assertEqual(summary["acceptedVersusElapsedDeltaSeconds"], 0.05)
        self.assertNotIn("path", json.dumps(summary).lower())


if __name__ == "__main__":
    unittest.main()
