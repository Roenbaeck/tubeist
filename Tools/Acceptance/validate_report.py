#!/usr/bin/env python3
"""Validate a Debug-build Tubeist direct-HLS acceptance report."""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Iterable


MAXIMUM_EVENTS = 10_000
SUCCESS_HTTP_STATUSES = {200, 202}
KNOWN_KINDS = {
    "prepared",
    "initializationParsed",
    "segmentAccepted",
    "segmentDropped",
    "failed",
    "stopped",
    "cancelled",
    "summary",
}
TERMINAL_KINDS = {"failed", "stopped", "cancelled"}
SUMMARY_PATTERN = re.compile(r"outcome=(failed|stopped|cancelled);events=([0-9]+)")


class ReportValidationError(ValueError):
    """Raised with redacted structural errors for an invalid report."""

    def __init__(self, errors: Iterable[str]) -> None:
        self.errors = tuple(errors)
        super().__init__("; ".join(self.errors))


def _is_finite_number(value: Any) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(float(value))
    )


def _is_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _parse_timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def load_report(path: Path) -> list[dict[str, Any]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ReportValidationError(["the report could not be read as UTF-8 JSONL"]) from error

    nonempty_lines = [line for line in lines if line.strip()]
    if not nonempty_lines:
        raise ReportValidationError(["the report is empty"])
    if len(nonempty_lines) > MAXIMUM_EVENTS:
        raise ReportValidationError([f"the report exceeds {MAXIMUM_EVENTS} events"])

    events: list[dict[str, Any]] = []
    errors: list[str] = []
    for line_number, line in enumerate(nonempty_lines, start=1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            errors.append(f"line {line_number} is not valid JSON")
            continue
        if not isinstance(event, dict):
            errors.append(f"line {line_number} is not a JSON object")
            continue
        events.append(event)
    if errors:
        raise ReportValidationError(errors)
    return events


def validate_report(
    events: list[dict[str, Any]],
    *,
    expected_outcome: str = "stopped",
    allow_drops: bool = False,
    maximum_queued_duration: float | None = None,
    maximum_retry_count: int | None = None,
) -> dict[str, Any]:
    """Return a redacted evidence summary or raise ReportValidationError."""

    errors: list[str] = []
    kinds: list[str | None] = []
    timestamps: list[datetime | None] = []

    for index, event in enumerate(events, start=1):
        kind = event.get("kind")
        if not isinstance(kind, str) or kind not in KNOWN_KINDS:
            errors.append(f"event {index} has an unknown or missing kind")
            kinds.append(None)
        else:
            kinds.append(kind)

        timestamp = _parse_timestamp(event.get("timestamp"))
        if timestamp is None:
            errors.append(f"event {index} has an invalid timestamp")
        timestamps.append(timestamp)

    valid_timestamps = [timestamp for timestamp in timestamps if timestamp is not None]
    if any(later < earlier for earlier, later in zip(valid_timestamps, valid_timestamps[1:])):
        errors.append("event timestamps are not monotonic")

    if not kinds or kinds[0] != "prepared":
        errors.append("the first event is not prepared")
    if kinds.count("prepared") != 1:
        errors.append("the report must contain exactly one prepared event")
    elif events[0].get("detail") != "schema=2":
        errors.append("the prepared event does not declare schema=2")

    if kinds.count("initializationParsed") != 1:
        errors.append("the report must contain exactly one initializationParsed event")

    terminal_positions = [index for index, kind in enumerate(kinds) if kind in TERMINAL_KINDS]
    terminal_kind = kinds[terminal_positions[0]] if len(terminal_positions) == 1 else None
    if len(terminal_positions) != 1:
        errors.append("the report must contain exactly one terminal event")
    elif terminal_positions[0] != len(events) - 2:
        errors.append("the terminal event must immediately precede the summary")

    if not kinds or kinds[-1] != "summary" or kinds.count("summary") != 1:
        errors.append("the report must end with exactly one summary event")
    else:
        detail = events[-1].get("detail")
        match = SUMMARY_PATTERN.fullmatch(detail) if isinstance(detail, str) else None
        if match is None:
            errors.append("the summary detail is malformed")
        else:
            summary_outcome, reported_event_count = match.groups()
            if terminal_kind is not None and summary_outcome != terminal_kind:
                errors.append("the summary outcome does not match the terminal event")
            if int(reported_event_count) != len(events) - 1:
                errors.append("the summary event count does not match the report")

    if expected_outcome != "any" and terminal_kind != expected_outcome:
        errors.append(f"the terminal outcome is not {expected_outcome}")

    accepted: list[dict[str, Any]] = []
    drops: list[dict[str, Any]] = []
    for index, (kind, event) in enumerate(zip(kinds, events), start=1):
        if kind == "segmentAccepted":
            accepted.append(event)
            sequence = event.get("sequence")
            duration = event.get("duration")
            queued_duration = event.get("queuedDuration")
            retry_count = event.get("retryCount")
            http_status = event.get("httpStatus")
            if not _is_integer(sequence) or sequence < 0:
                errors.append(f"accepted event {index} has an invalid sequence")
            if not _is_finite_number(duration) or float(duration) <= 0:
                errors.append(f"accepted event {index} has an invalid duration")
            if not _is_finite_number(queued_duration) or float(queued_duration) < 0:
                errors.append(f"accepted event {index} has an invalid queued duration")
            if not _is_integer(retry_count) or retry_count < 0:
                errors.append(f"accepted event {index} has an invalid retry count")
            if not _is_integer(http_status) or http_status not in SUCCESS_HTTP_STATUSES:
                errors.append(f"accepted event {index} lacks a successful HTTP status")
        elif kind == "segmentDropped":
            drops.append(event)
            sequence = event.get("sequence")
            dropped_fragments = event.get("droppedFragments")
            if not _is_integer(sequence) or sequence < 0:
                errors.append(f"drop event {index} has an invalid sequence")
            if not _is_integer(dropped_fragments) or dropped_fragments <= 0:
                errors.append(f"drop event {index} has an invalid cumulative drop count")

    if not accepted:
        errors.append("the report contains no accepted media segments")
    accepted_sequences = [event.get("sequence") for event in accepted]
    if accepted_sequences and all(_is_integer(sequence) for sequence in accepted_sequences):
        if accepted_sequences != list(range(len(accepted_sequences))):
            errors.append("accepted media sequences are not contiguous from zero")

    initialization_index = kinds.index("initializationParsed") if "initializationParsed" in kinds else None
    first_accepted_index = kinds.index("segmentAccepted") if "segmentAccepted" in kinds else None
    if (
        initialization_index is not None
        and first_accepted_index is not None
        and initialization_index > first_accepted_index
    ):
        errors.append("media was accepted before initialization was parsed")

    cumulative_drop_counts = [event.get("droppedFragments") for event in drops]
    if cumulative_drop_counts and all(_is_integer(count) for count in cumulative_drop_counts):
        if any(later <= earlier for earlier, later in zip(cumulative_drop_counts, cumulative_drop_counts[1:])):
            errors.append("cumulative drop counts are not strictly increasing")
    if drops and not allow_drops:
        errors.append("the report contains dropped fragments")

    numeric_queued_durations = [
        float(event["queuedDuration"])
        for event in accepted
        if _is_finite_number(event.get("queuedDuration"))
    ]
    observed_maximum_queue = max(numeric_queued_durations, default=0.0)
    if (
        maximum_queued_duration is not None
        and observed_maximum_queue > maximum_queued_duration
    ):
        errors.append("the observed queued duration exceeds the configured budget")

    retry_counts = [
        int(event["retryCount"])
        for event in accepted
        if _is_integer(event.get("retryCount")) and event["retryCount"] >= 0
    ]
    observed_maximum_retries = max(retry_counts, default=0)
    if maximum_retry_count is not None and observed_maximum_retries > maximum_retry_count:
        errors.append("the observed retry count exceeds the configured budget")

    if errors:
        raise ReportValidationError(errors)

    total_duration = sum(float(event["duration"]) for event in accepted)
    return {
        "status": "pass",
        "schema": 2,
        "outcome": terminal_kind,
        "eventCount": len(events),
        "acceptedSegmentCount": len(accepted),
        "acceptedDurationSeconds": round(total_duration, 6),
        "droppedFragmentEvents": len(drops),
        "maximumQueuedDurationSeconds": round(observed_maximum_queue, 6),
        "maximumRetryCount": observed_maximum_retries,
    }


def _nonnegative_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number")
    return parsed


def _nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path, help="acceptance.jsonl from the app container")
    parser.add_argument(
        "--expected-outcome",
        choices=("stopped", "failed", "cancelled", "any"),
        default="stopped",
    )
    parser.add_argument(
        "--allow-drops",
        action="store_true",
        help="report drops in the summary instead of failing validation",
    )
    parser.add_argument("--max-queued-duration", type=_nonnegative_float)
    parser.add_argument("--max-retry-count", type=_nonnegative_int)
    arguments = parser.parse_args()

    try:
        events = load_report(arguments.report)
        summary = validate_report(
            events,
            expected_outcome=arguments.expected_outcome,
            allow_drops=arguments.allow_drops,
            maximum_queued_duration=arguments.max_queued_duration,
            maximum_retry_count=arguments.max_retry_count,
        )
    except ReportValidationError as error:
        print("Acceptance report validation failed:", file=sys.stderr)
        for message in error.errors:
            print(f"- {message}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
