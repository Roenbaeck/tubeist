#!/usr/bin/env python3
"""Independently decode recovered media; compare uploaded video to recording."""
import collections
import array
import math
import hashlib
import statistics
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
    assert audio["channels"] == (1 if result["scenario"] == "mono-recovery" else 2)
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


def check_recovered_audio_start(path):
    process = subprocess.run([
        "ffprobe", "-v", "error", "-show_packets", "-show_entries",
        "packet=codec_type,pts_time", "-of", "json", str(path)
    ], check=True, capture_output=True, text=True)
    packets = json.loads(process.stdout)["packets"]
    video_start = min(float(packet["pts_time"]) for packet in packets if packet["codec_type"] == "video")
    audio_start = min(float(packet["pts_time"]) for packet in packets if packet["codec_type"] == "audio")
    # Allow AAC priming and packet boundaries. Using the latest microphone
    # block instead of its buffered match would leave a 0.6-1.2 second audio gap.
    assert -0.15 < audio_start - video_start < 0.075, \
        ("Recovered segment does not start with aligned audio", path, audio_start - video_start)


def audio_packets(path):
    process = subprocess.run([
        "ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets", "-show_data",
        "-show_entries", "packet=pts_time,data", "-of", "json", str(path)
    ], check=True, capture_output=True, text=True)
    result = []
    for packet in json.loads(process.stdout)["packets"]:
        payload = bytes.fromhex("".join(line.split(":", 1)[1].split("  ")[0].strip()
            for line in packet["data"].splitlines() if ":" in line))
        if path.suffix == ".ts":
            # Our muxer writes one AAC access unit per PES, with a 7-byte ADTS header.
            assert payload[:2] == bytes([0xff, 0xf1]), "Unexpected AAC transport header"
            length = ((payload[3] & 3) << 11) | (payload[4] << 3) | (payload[5] >> 5)
            assert length == len(payload), "Transport did not contain one complete AAC packet"
            payload = payload[7:]
        result.append((hashlib.sha256(payload).digest(), float(packet["pts_time"])))
    return result


recording = folder / "recording.mp4"
recording_tick = float(Fraction(inspect(recording)["time_base"]))
recorded = hashes(recording)
available = collections.Counter(recorded)
recorded_times = collections.defaultdict(collections.deque)
for digest, pts in zip(recorded, presentation_times(recording), strict=True):
    recorded_times[digest].append(pts)
timestamp_offsets = []
uploaded = []
uploaded_audio = []
for segment in sorted(folder.glob("upload_*.ts")):
    inspect(segment)
    if result["scenario"] == "stabilization-changes":
        check_recovered_audio_start(segment)
    uploaded_audio.extend(audio_packets(segment))
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
# Match the actual AAC payload, not just overall track duration. Padding may add
# silent packets to the MP4, but every uploaded source packet must remain present
# and agree with the video clock after every recovery, including repeated ones.
recorded_audio = collections.defaultdict(list)
for digest, pts in audio_packets(recording):
    recorded_audio[digest].append(pts)
transport_offset = statistics.median(timestamp_offsets)
audio_timing_errors = []
for digest, pts in uploaded_audio:
    candidates = recorded_audio[digest]
    assert candidates, "Uploaded AAC packet is missing or changed in the recording"
    index = min(range(len(candidates)), key=lambda i: abs(pts - candidates[i] - transport_offset))
    error = pts - candidates.pop(index) - transport_offset
    audio_timing_errors.append(abs(error))
    # Recording-only silence is packet-sized; its rounding must stay bounded,
    # not accumulate with each recovery. One AAC packet is about 23 ms here.
    assert abs(error) < 1024 / 44100 + recording_tick, \
        ("Recorded audio diverged from the common video/transport timeline", error, pts)
assert uploaded_audio, "No uploaded AAC packets were checked"
print(f"AUDIO TIMING PASS: {len(uploaded_audio)} unchanged AAC packets; "
      f"maximum timing error {max(audio_timing_errors) * 1000:.3f} ms")
if result["scenario"] in ("healthy", "startup-audio-overlap", "short-gaps", "stop-boundary", "network-overflow"):
    assert len(recorded) == result["inputVideoFrames"], (len(recorded), result)
if result["scenario"] in ("healthy", "startup-audio-overlap", "short-gaps", "stop-boundary"):
    assert uploaded == recorded, "Healthy/repaired media was lost between encoding and upload"
if result["scenario"] == "processing-pressure":
    assert not result["captureRecovery"], "Processing pressure triggered capture recovery"
    assert len(recorded) == result["deliveredVideoFrames"], "Skipped timestamps created duplicate catch-up work"
    assert uploaded == recorded, "Real frames were lost between encoding and upload"
if result["scenario"] in ("short-gaps", "both-stall", "mono-recovery"):
    pcm = subprocess.run(["ffmpeg", "-v", "error", "-i", str(recording), "-map", "0:a:0",
                          "-ac", "1", "-ar", "44100", "-f", "f32le", "-"],
                         check=True, capture_output=True).stdout
    samples = array.array("f", pcm)
    def rms(start, end):
        window = samples[int(start * 44100):int(end * 44100)]
        return math.sqrt(sum(value * value for value in window) / len(window))
    if result["scenario"] == "short-gaps":
        assert rms(2.06, 2.15) < 0.01, "Missing microphone samples were not replaced by silence"
        assert rms(1.7, 1.8) > 0.1 and rms(2.4, 2.5) > 0.1, "Repair removed healthy audio"
    else:
        assert rms(5.4, 5.6) < 0.001, "The recording recovery gap did not decode as silence"
        assert rms(1.7, 1.8) > 0.1 and rms(7.4, 7.5) > 0.1, "Padding removed healthy audio"
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
