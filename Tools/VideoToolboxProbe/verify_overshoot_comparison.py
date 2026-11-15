"""Compare matching regulated/unregulated overshoot probe artifacts."""
import json
import pathlib
import sys

regulated, unregulated = [pathlib.Path(value) for value in sys.argv[1:]]
metadata = [json.loads((path / 'expected.json').read_text()) for path in (regulated, unregulated)]
assert all(item['overshootProbe'] for item in metadata)
assert metadata[0]['regulatesBitrate'] and not metadata[1]['regulatesBitrate']
assert metadata[0]['submittedFrames'] == metadata[1]['submittedFrames']
assert all(item['videoFrames'] == item['submittedFrames'] for item in metadata)
frames = [json.loads((path / 'encoded-frames.json').read_text()) for path in (regulated, unregulated)]

# Measure settled output after a correction and after the next bitrate increase.
# Include two seconds of pictures in presentation order; retain every picture.
for start, target in [(14, 300_000), (22, 700_000)]:
    rates = [sum(frame['bytes'] * 8 for frame in trace if start <= frame['pts'] < start + 2) / 2
             for trace in frames]
    corrected, baseline = rates
    assert corrected < baseline * 0.9, (target, rates, 'No material overshoot reduction')
    assert corrected >= target * 0.65, (target, corrected, 'Correction reduced output excessively')
    print(f'PASS: {target / 1e6:.2f} Mbps target: {baseline / 1e6:.3f} -> '
          f'{corrected / 1e6:.3f} Mbps, {(1 - corrected / baseline) * 100:.1f}% fewer bytes; no lost frames')
