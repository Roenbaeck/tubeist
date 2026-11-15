"""Reject corrupted reference chains even when FFmpeg exits successfully."""
import json
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Acceptance'))
from check_hevc_timing import DecodeSchedule, read_ordering_limits

folder = pathlib.Path(sys.argv[1])
expected = json.loads((folder / 'expected.json').read_text())
segments = sorted(folder.glob('segment_*.ts'))
stream = folder / 'stream.ts'
stream.write_bytes(b''.join(segment.read_bytes() for segment in segments))


def checked(*arguments):
    result = subprocess.run(arguments, check=True, capture_output=True, text=True)
    assert not result.stderr.strip(), (arguments, result.stderr)
    return result.stdout


for artifact in [*segments, stream, folder / 'recording.mp4']:
    checked('ffmpeg', '-v', 'error', '-xerror', '-i', str(artifact), '-f', 'null', '-')

hashes = []
timelines = []
for artifact in [stream, folder / 'recording.mp4']:
    decoded = checked('ffmpeg', '-v', 'error', '-i', str(artifact), '-map', '0:v:0',
                      '-fps_mode', 'passthrough', '-f', 'framemd5', '-')
    frames = [line.split(',')[-1].strip() for line in decoded.splitlines() if not line.startswith('#')]
    assert len(frames) == expected['videoFrames'], (artifact, len(frames), expected)
    hashes.append(frames)
    packets = json.loads(checked('ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_packets',
        '-show_entries', 'packet=pts_time,dts_time', '-of', 'json', str(artifact)))['packets']
    assert all(float(packet['dts_time']) <= float(packet['pts_time']) for packet in packets)
    assert all(float(a['dts_time']) < float(b['dts_time']) for a, b in zip(packets, packets[1:]))
    timelines.append(packets)
assert hashes[0] == hashes[1], 'Recovered TS and MP4 video differ'
offset = float(timelines[0][0]['pts_time']) - float(timelines[1][0]['pts_time'])
assert all(abs(float(a['pts_time']) - float(b['pts_time']) - offset) <= 0.001
           for a, b in zip(*timelines)), 'Recovery changed presentation timing between containers'
DecodeSchedule().inspect([{'pts': float(packet['pts_time']), 'dts': float(packet['dts_time'])}
                          for packet in timelines[0]], read_ordering_limits(stream))
print(f"PASS: {expected['videoFrames']} recovered frames; every segment and MP4 decode without errors")
