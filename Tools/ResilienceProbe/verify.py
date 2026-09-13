#!/usr/bin/env python3
"""Independently decode recovered media; compare uploaded video to recording."""
import collections
import array
import math
from fractions import Fraction
import json
import pathlib
import subprocess
import sys

folder = pathlib.Path(sys.argv[1])
result = json.loads((folder / "result.json").read_text())


def inspect(path):
    process = subprocess.run([
        "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)
    ], check=True, capture_output=True, text=True)
    streams = json.loads(process.stdout)["streams"]
    video = next(stream for stream in streams if stream["codec_type"] == "video")
    audio = next(stream for stream in streams if stream["codec_type"] == "audio")
    assert video["codec_name"] == "hevc"
    assert video["pix_fmt"] == "yuv420p10le"
    assert video["color_transfer"] == "arib-std-b67"
    assert video["color_primaries"] == "bt2020"
    assert audio["codec_name"] == "aac" and audio["sample_rate"] == "44100"
    # Decode both tracks: accepting the container alone would miss corrupt GOPs.
    decoded = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"],
                             check=True, capture_output=True, text=True)
    assert not decoded.stderr.strip(), (path, decoded.stderr)
    return video


def hashes(path):
    process = subprocess.run([
        "ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0", "-fps_mode", "passthrough",
        "-pix_fmt", "yuv420p10le", "-f", "framemd5", "-"
    ], check=True, capture_output=True, text=True)
    assert not process.stderr.strip(), (path, process.stderr)
    return [line.split(",")[-1].strip() for line in process.stdout.splitlines()
            if line and not line.startswith("#")]


def presentation_times(path):
    process = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
                              "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(path)],
                             check=True, capture_output=True, text=True)
    return [float(frame["best_effort_timestamp_time"]) for frame in json.loads(process.stdout)["frames"]]


recording = folder / "recording.mp4"
recording_tick = float(Fraction(inspect(recording)["time_base"]))
recorded = hashes(recording)
available = collections.Counter(recorded)
recorded_times = collections.defaultdict(collections.deque)
for digest, pts in zip(recorded, presentation_times(recording), strict=True):
    recorded_times[digest].append(pts)
timestamp_offsets = []
uploaded = []
for segment in sorted(folder.glob("upload_*.ts")):
    inspect(segment)
    frames = hashes(segment)
    assert frames, segment
    uploaded.extend(frames)
    for digest, pts in zip(frames, presentation_times(segment), strict=True):
        assert available[digest] > 0, "Uploaded decoded video differs from the local recording"
        available[digest] -= 1
        timestamp_offsets.append(pts - recorded_times[digest].popleft())

assert uploaded, "No live segments survived the fault"
# AVAssetWriter chooses its own video track time base (commonly 1/600),
# independently of the 90 kHz TS clock and movie timescale. Allow that measured
# quantization, while rejecting a transport epoch reset or accumulated drift.
assert max(timestamp_offsets) - min(timestamp_offsets) < recording_tick + 2 / 90_000, \
    "Recovery changed the transport timeline offset beyond container quantization"
if result["scenario"] in ("healthy", "short-gaps", "network-overflow"):
    assert len(recorded) == result["inputVideoFrames"], (len(recorded), result)
if result["scenario"] in ("healthy", "short-gaps"):
    assert uploaded == recorded, "Healthy/repaired media was lost between encoding and upload"
if result["scenario"] == "short-gaps":
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", str(recording), "-map", "0:a:0",
                          "-ac", "1", "-ar", "44100", "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    samples = array.array("f", pcm)
    def rms(start, end):
        window = samples[int(start * 44100):int(end * 44100)]
        return math.sqrt(sum(value * value for value in window) / len(window))
    assert rms(2.06, 2.15) < 0.01, "Missing microphone samples were not replaced by silence"
    assert rms(1.7, 1.8) > 0.1 and rms(2.4, 2.5) > 0.1, "Repair removed healthy audio"
if result["scenario"] == "network-overflow":
    assert len(uploaded) < len(recorded), "The overflow fixture did not discard live content"
    assert result["droppedSegments"] > 0
if result["captureRecovery"] or result["droppedSegments"]:
    playlists = [path.read_text() for path in sorted(folder.glob("playlist_*.m3u8"))]
    assert any("#EXT-X-DISCONTINUITY\n" in text for text in playlists)
    assert all("#EXT-X-TARGETDURATION:5\n" in text for text in playlists)
    assert all("#EXT-X-DISCONTINUITY-SEQUENCE:" in text for text in playlists)
print(f"DECODE PASS: {result['scenario']}: {len(recorded)} recorded frames, "
      f"{len(uploaded)} uploaded frames; matching video pixels and HLG metadata")
