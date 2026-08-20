#!/usr/bin/env python3
"""Compare a Tubeist acceptance report with exported recording/archive media."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
from typing import Any

from validate_report import ReportValidationError, load_report, validate_report


class MediaValidationError(ValueError):
    def __init__(self, errors: list[str]) -> None:
        self.errors = tuple(errors)
        super().__init__("; ".join(errors))


def _finite_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def _positive_float(value: Any) -> float | None:
    parsed = _finite_float(value)
    return parsed if parsed is not None and parsed > 0 else None


def _rate(value: Any) -> float | None:
    if not isinstance(value, str) or not value or value == "0/0":
        return None
    if "/" not in value:
        return _positive_float(value)
    numerator, denominator = value.split("/", maxsplit=1)
    numerator_value = _finite_float(numerator)
    denominator_value = _finite_float(denominator)
    if numerator_value is None or denominator_value in (None, 0):
        return None
    result = numerator_value / denominator_value
    return result if math.isfinite(result) and result > 0 else None


def probe_media(path: Path, *, ffprobe: str = "ffprobe") -> dict[str, Any]:
    try:
        result = subprocess.run(
            (
                ffprobe,
                "-v",
                "error",
                "-show_streams",
                "-show_format",
                "-of",
                "json",
                str(path),
            ),
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise MediaValidationError(["FFprobe could not be executed"]) from error
    if result.returncode != 0:
        raise MediaValidationError(["FFprobe could not inspect a media input"])
    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise MediaValidationError(["FFprobe returned malformed JSON"]) from error
    if not isinstance(probe, dict):
        raise MediaValidationError(["FFprobe returned an invalid result"])
    return probe


def _seconds(value: Any) -> float | None:
    direct = _finite_float(value)
    if direct is not None:
        return direct
    if not isinstance(value, str):
        return None
    components = value.split(":")
    if len(components) != 3:
        return None
    hours = _finite_float(components[0])
    minutes = _finite_float(components[1])
    seconds = _finite_float(components[2])
    if hours is None or minutes is None or seconds is None:
        return None
    result = hours * 3600 + minutes * 60 + seconds
    return result if math.isfinite(result) else None


def _scaled_timestamp(stream: dict[str, Any], key: str) -> float | None:
    units = _finite_float(stream.get(key))
    time_base = stream.get("time_base")
    if units is None or not isinstance(time_base, str) or "/" not in time_base:
        return None
    numerator, denominator = time_base.split("/", maxsplit=1)
    numerator_value = _finite_float(numerator)
    denominator_value = _finite_float(denominator)
    if numerator_value is None or denominator_value in (None, 0):
        return None
    result = units * numerator_value / denominator_value
    return result if math.isfinite(result) else None


def _stream_start(stream: dict[str, Any]) -> float | None:
    direct = _seconds(stream.get("start_time"))
    return direct if direct is not None else _scaled_timestamp(stream, "start_pts")


def _stream_duration(stream: dict[str, Any]) -> float | None:
    direct = _positive_float(stream.get("duration"))
    if direct is not None:
        return direct
    tags = stream.get("tags")
    if isinstance(tags, dict):
        tagged = _seconds(tags.get("DURATION"))
        if tagged is not None and tagged > 0:
            return tagged
    scaled = _scaled_timestamp(stream, "duration_ts")
    return scaled if scaled is not None and scaled > 0 else None


def analyze_media_probe(
    probe: dict[str, Any],
    *,
    role: str,
    require_tubeist_recording: bool,
    allow_archive_sdr: bool,
    expected_width: int,
    expected_height: int,
    expected_frame_rate: float,
    expected_audio_channels: int,
) -> dict[str, Any]:
    errors: list[str] = []
    streams = probe.get("streams")
    format_data = probe.get("format")
    if not isinstance(streams, list) or not isinstance(format_data, dict):
        raise MediaValidationError([f"the {role} probe is missing streams or format metadata"])

    video = next(
        (stream for stream in streams if isinstance(stream, dict) and stream.get("codec_type") == "video"),
        None,
    )
    audio = next(
        (stream for stream in streams if isinstance(stream, dict) and stream.get("codec_type") == "audio"),
        None,
    )
    if video is None:
        errors.append(f"the {role} has no video stream")
    if audio is None:
        errors.append(f"the {role} has no audio stream")
    format_duration = _positive_float(format_data.get("duration"))
    if format_duration is None:
        errors.append(f"the {role} has no finite positive duration")
    if errors:
        raise MediaValidationError(errors)
    assert video is not None and audio is not None and format_duration is not None

    width = video.get("width")
    height = video.get("height")
    frame_rate = _rate(video.get("avg_frame_rate")) or _rate(video.get("r_frame_rate"))
    channels = audio.get("channels")
    if width != expected_width or height != expected_height:
        errors.append(f"the {role} resolution does not match the expected preset")
    if frame_rate is None or not math.isclose(frame_rate, expected_frame_rate, abs_tol=0.05):
        errors.append(f"the {role} frame rate does not match the expected preset")
    if channels != expected_audio_channels:
        errors.append(f"the {role} audio channel count does not match the expected configuration")

    color_space = video.get("color_space")
    color_transfer = video.get("color_transfer")
    color_primaries = video.get("color_primaries")
    pixel_format = video.get("pix_fmt")
    is_hlg = (
        color_space == "bt2020nc"
        and color_transfer == "arib-std-b67"
        and color_primaries == "bt2020"
        and isinstance(pixel_format, str)
        and "10" in pixel_format
    )
    if require_tubeist_recording:
        if video.get("codec_name") != "hevc" or video.get("profile") != "Main 10":
            errors.append("the recording is not HEVC Main 10")
        if pixel_format != "yuv420p10le":
            errors.append("the recording is not 10-bit 4:2:0 video")
        if audio.get("codec_name") != "aac" or audio.get("profile") != "LC":
            errors.append("the recording is not AAC-LC audio")
        if not is_hlg:
            errors.append("the recording is missing HLG/BT.2020 metadata")
    elif not allow_archive_sdr and not is_hlg:
        errors.append("the YouTube archive is missing 10-bit HLG/BT.2020 metadata")

    video_start = _stream_start(video)
    audio_start = _stream_start(audio)
    video_duration = _stream_duration(video)
    audio_duration = _stream_duration(audio)
    if video_start is None or video_duration is None:
        errors.append(f"the {role} video stream lacks per-stream timing evidence")
    if audio_start is None or audio_duration is None:
        errors.append(f"the {role} audio stream lacks per-stream timing evidence")
    if errors:
        raise MediaValidationError(errors)
    assert video_start is not None and audio_start is not None
    assert video_duration is not None and audio_duration is not None
    start_skew = abs(video_start - audio_start)
    end_skew = abs((video_start + video_duration) - (audio_start + audio_duration))

    if errors:
        raise MediaValidationError(errors)
    return {
        "role": role,
        "durationSeconds": round(format_duration, 6),
        "videoCodec": video.get("codec_name"),
        "videoProfile": video.get("profile"),
        "width": width,
        "height": height,
        "frameRate": round(frame_rate, 6) if frame_rate is not None else None,
        "pixelFormat": pixel_format,
        "colorSpace": color_space,
        "colorTransfer": color_transfer,
        "colorPrimaries": color_primaries,
        "audioCodec": audio.get("codec_name"),
        "audioProfile": audio.get("profile"),
        "audioChannels": channels,
        "audioSampleRate": audio.get("sample_rate"),
        "avStartSkewSeconds": round(start_skew, 6),
        "avEndSkewSeconds": round(end_skew, 6),
        "isTenBitHLGBT2020": is_hlg,
    }


def compare_evidence(
    report_summary: dict[str, Any],
    media_summaries: list[dict[str, Any]],
    *,
    maximum_duration_delta: float,
    maximum_av_skew: float,
) -> dict[str, Any]:
    accepted_duration = _positive_float(report_summary.get("acceptedDurationSeconds"))
    elapsed_duration = _positive_float(report_summary.get("elapsedDurationSeconds"))
    if accepted_duration is None or elapsed_duration is None:
        raise MediaValidationError(["the acceptance report lacks current duration evidence"])

    errors: list[str] = []
    compared_media: list[dict[str, Any]] = []
    for media in media_summaries:
        duration = float(media["durationSeconds"])
        duration_delta = abs(duration - accepted_duration)
        maximum_observed_skew = max(
            float(media["avStartSkewSeconds"]),
            float(media["avEndSkewSeconds"]),
        )
        if duration_delta > maximum_duration_delta:
            errors.append(f"the {media['role']} duration exceeds the accepted-tail budget")
        if maximum_observed_skew > maximum_av_skew:
            errors.append(f"the {media['role']} A/V skew exceeds the configured budget")
        compared_media.append(
            {
                **media,
                "acceptedDurationDeltaSeconds": round(duration_delta, 6),
                "maximumObservedAVSkewSeconds": round(maximum_observed_skew, 6),
            }
        )

    if errors:
        raise MediaValidationError(errors)
    return {
        "status": "pass",
        "acceptance": report_summary,
        "acceptedVersusElapsedDeltaSeconds": round(
            abs(accepted_duration - elapsed_duration),
            6,
        ),
        "maximumDurationDeltaBudgetSeconds": maximum_duration_delta,
        "maximumAVSkewBudgetSeconds": maximum_av_skew,
        "media": compared_media,
    }


def _nonnegative_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed < 0:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number")
    return parsed


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _positive_float_argument(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--recording", type=Path)
    parser.add_argument("--youtube-archive", type=Path)
    parser.add_argument("--expected-width", required=True, type=_positive_int)
    parser.add_argument("--expected-height", required=True, type=_positive_int)
    parser.add_argument("--expected-frame-rate", required=True, type=_positive_float_argument)
    parser.add_argument("--expected-audio-channels", required=True, type=_positive_int)
    parser.add_argument(
        "--expected-archive-audio-channels",
        type=_positive_int,
        help="expected YouTube archive channels when its transcode differs from the recording",
    )
    parser.add_argument("--max-duration-delta", required=True, type=_nonnegative_float)
    parser.add_argument("--max-av-skew", required=True, type=_nonnegative_float)
    parser.add_argument(
        "--allow-archive-sdr",
        action="store_true",
        help="accept an SDR YouTube archive only as an explicitly recorded limitation",
    )
    arguments = parser.parse_args()

    if arguments.recording is None and arguments.youtube_archive is None:
        parser.error("at least one of --recording or --youtube-archive is required")

    try:
        report_summary = validate_report(load_report(arguments.report))
        media_summaries: list[dict[str, Any]] = []
        if arguments.recording is not None:
            media_summaries.append(
                analyze_media_probe(
                    probe_media(arguments.recording),
                    role="recording",
                    require_tubeist_recording=True,
                    allow_archive_sdr=False,
                    expected_width=arguments.expected_width,
                    expected_height=arguments.expected_height,
                    expected_frame_rate=arguments.expected_frame_rate,
                    expected_audio_channels=arguments.expected_audio_channels,
                )
            )
        if arguments.youtube_archive is not None:
            archive_audio_channels = (
                arguments.expected_archive_audio_channels
                or arguments.expected_audio_channels
            )
            media_summaries.append(
                analyze_media_probe(
                    probe_media(arguments.youtube_archive),
                    role="youtubeArchive",
                    require_tubeist_recording=False,
                    allow_archive_sdr=arguments.allow_archive_sdr,
                    expected_width=arguments.expected_width,
                    expected_height=arguments.expected_height,
                    expected_frame_rate=arguments.expected_frame_rate,
                    expected_audio_channels=archive_audio_channels,
                )
            )
        summary = compare_evidence(
            report_summary,
            media_summaries,
            maximum_duration_delta=arguments.max_duration_delta,
            maximum_av_skew=arguments.max_av_skew,
        )
    except (ReportValidationError, MediaValidationError) as error:
        messages = error.errors
        print("Media evidence validation failed:", file=sys.stderr)
        for message in messages:
            print(f"- {message}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
