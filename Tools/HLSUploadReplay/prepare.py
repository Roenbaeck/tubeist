#!/usr/bin/env python3
"""Prepare a bounded, credential-free iPhone upload replay from a captured session."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Acceptance'))
from validate_upload_capture import read_capture, audit_requests

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('capture', type=Path)
parser.add_argument('destination', type=Path)
parser.add_argument('--broadcast-id', required=True)
args = parser.parse_args()
requests = read_capture(args.capture)
entries, accepted = audit_requests(requests)
segments = []
for sequence, request in accepted.items():
    # Match A's segment availability schedule: the original playlist request
    # immediately preceding that media upload. The real uploader handles both.
    index = requests.index(request)
    playlist = requests[index - 1]
    assert playlist['filename'].endswith('.m3u8')
    data = request['path'].read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == request['sha256']
    segments.append({'filename': digest + '.ts', 'sha256': digest,
                     'duration': entries[sequence]['duration'], 'availableAt': playlist['elapsed']})
args.destination.mkdir(parents=True, exist_ok=False)
for segment, request in zip(segments, accepted.values()):
    shutil.copyfile(request['path'], args.destination / segment['filename'])
(args.destination / 'plan.json').write_text(json.dumps({'broadcastID': args.broadcast_id, 'segments': segments}, indent=2))
print(f'Prepared {len(segments)} segments. No credentials copied; nothing uploaded.')
