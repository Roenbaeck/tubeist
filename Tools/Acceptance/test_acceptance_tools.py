from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parent))

from scan_canary import CHUNK_SIZE, scan_paths  # noqa: E402
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
    ) -> list[dict[str, object]]:
        timestamp = datetime(2026, 8, 20, tzinfo=timezone.utc)
        events: list[dict[str, object]] = []

        def append(kind: str, **values: object) -> None:
            nonlocal timestamp
            events.append({"timestamp": timestamp.isoformat(), "kind": kind, **values})
            timestamp += timedelta(seconds=1)

        append("prepared", detail="schema=2")
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


if __name__ == "__main__":
    unittest.main()
