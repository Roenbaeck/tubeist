import json
import pathlib
import subprocess
import sys
import array

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Acceptance'))
from check_hevc_timing import DecodeSchedule, read_ordering_limits

folder = pathlib.Path(sys.argv[1])
expected = json.loads((folder / "expected.json").read_text())
for name in ("stream.ts", "recording.mp4"):
    streams = json.loads((folder / f"{name}.json").read_text())["streams"]
    video = next(s for s in streams if s["codec_name"] == "hevc")
    audio = next(s for s in streams if s["codec_name"] == "aac")
    assert video["profile"] == "Main 10", video
    assert video["pix_fmt"] == "yuv420p10le", video
    assert video["color_space"] == "bt2020nc", video
    assert video["color_transfer"] == "arib-std-b67", video
    assert video["color_primaries"] == "bt2020", video
    assert int(video["nb_read_frames"]) == expected["videoFrames"], video
    assert audio["channels"] == expected["channels"] and int(audio["sample_rate"]) == 44100, audio
    # Fragmented MP4 track duration fields can include the timestamp epoch.
    # Measure actual packet spans, and check the shared A/V timeline directly.
    packets = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_packets", "-show_entries",
        "packet=stream_index,pts_time,dts_time,duration_time", "-of", "json", str(folder / name),
    ]))["packets"]
    for index in (0, 1):
        track = [p for p in packets if p["stream_index"] == index]
        start = min(float(p["pts_time"]) for p in track)
        end = max(float(p["pts_time"]) + float(p["duration_time"]) for p in track)
        assert abs(end - start - 12.4) < (0.04 if index == 0 else 0.1), (name, index, start, end)
        if index == 0:
            assert all(float(p["dts_time"]) <= float(p["pts_time"]) for p in track), name
    # Encoder/SRC priming precedes the first real microphone sample.
    av_offset = float(video["start_time"]) - float(audio["start_time"])
    assert abs(av_offset - expected["primingSeconds"]) < 1 / 44100, (name, av_offset)
    pcm = array.array("f", subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(folder / name), "-map", "0:a:0",
        "-ac", "1", "-ar", "44100", "-f", "f32le", "-",
    ]))
    onset = next(i for i, value in enumerate(pcm) if abs(value) > 0.03) / 44100
    assert abs(onset - av_offset - 0.25) < 0.01, (name, "audible A/V offset", onset - av_offset)

# The two containers must decode to exactly the same 10-bit video pixels.
def hashes(name):
    output = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(folder / name), "-map", "0:v:0",
        "-f", "framemd5", "-",
    ], text=True)
    return [line.split(",")[-1].strip() for line in output.splitlines() if not line.startswith("#")]

assert hashes("stream.ts") == hashes("recording.mp4"), "Streaming and recording video differs"
for path in sorted(folder.glob("segment_*.ts")):
    subprocess.run(["ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"], check=True)
print("PASS: independent TS segments, identical decoded frames in TS/MP4, Main10 HLG/BT.2020, AAC, and aligned duration")

# Independent timestamp reference: the relay ignores input DTS and lets FFmpeg
# reconstruct decode timing from PTS. Do the same without any re-encoding.
reference = folder / 'ffmpeg-igndts.ts'
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-copyts', '-fflags', '+igndts',
                '-i', str(folder/'recording.mp4'), '-map', '0:v:0', '-c', 'copy',
                '-fps_mode', 'passthrough', '-f', 'mpegts', str(reference)], check=True)

def video_packets(path):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_packets',
        '-show_entries', 'packet=pts_time,dts_time', '-of', 'json', str(path)
    ]))['packets']

actual = video_packets(folder/'stream.ts')
oracle = video_packets(reference)
assert len(actual) == len(oracle) == expected['videoFrames']
offset = float(actual[0]['pts_time']) - float(oracle[0]['pts_time'])
for key in ('pts_time', 'dts_time'):
    # The recording writer uses a coarser timescale than 90 kHz transport ticks.
    error = max(abs(float(a[key]) - float(b[key]) - offset) for a, b in zip(actual, oracle))
    assert error <= .001, (key, 'FFmpeg timing mismatch', error)
limits = read_ordering_limits(folder/'stream.ts')
video = [{'pts': float(p['pts_time']), 'dts': float(p['dts_time'])} for p in actual]
peak = DecodeSchedule().inspect(video, limits)
print(f'PASS: DTS/PTS match FFmpeg within 1 ms; {peak} pictures awaiting display, '
      f'SPS reorder depth {limits["reorderFrames"]}, capacity {limits["pictureBuffers"]}')
