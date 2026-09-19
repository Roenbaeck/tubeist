#!/usr/bin/env python3
"""Validate exact Debug HLS request bodies; decode every segment independently by default."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys

from inspect_transport import CaptureValidationError, TransportInspector, require, signed_delta
from check_hevc_timing import DecodeSchedule, read_ordering_limits
from validate_report import load_report, validate_report, ReportValidationError


MEDIA_NAME = re.compile(r'tubeist_([A-Za-z0-9_-]+)_([0-9]+)\.ts')
PLAYLIST_NAME = re.compile(r'(?:tubeist_[A-Za-z0-9_-]+|t[A-Za-z0-9_-]{22})\.m3u8')
COMPACT_MEDIA_NAME = re.compile(r'(t[A-Za-z0-9_-]{22})_([0-9a-z]+)\.ts')
BODY_NAME = re.compile(r'([0-9a-f]{64})\.(ts|m3u8)')


def media_identity(filename):
    """Read compact base-36 names and legacy decimal names in older evidence."""
    match = COMPACT_MEDIA_NAME.fullmatch(filename)
    if match:
        return match[1], int(match[2], 36)
    match = MEDIA_NAME.fullmatch(filename)
    require(match is not None, 'invalid media filename')
    return 'tubeist_' + match[1], int(match[2])


def parse_playlist(data):
    try:
        lines = data.decode('utf-8').splitlines()
    except UnicodeError as error:
        raise CaptureValidationError('playlist is not UTF-8') from error
    require(lines and lines[0] == '#EXTM3U', 'invalid playlist header')
    tags = {}; entries = []; duration = None; discontinuity = False; ended = False
    for line in lines[1:]:
        require(not ended, 'content follows ENDLIST')
        if line.startswith('#EXTINF:'):
            require(duration is None, 'two durations before a segment URI')
            duration = float(line.split(':',1)[1].split(',')[0])
            require(math.isfinite(duration) and 0 < duration <= 5, 'invalid EXTINF duration')
        elif line == '#EXT-X-DISCONTINUITY':
            require(not discontinuity, 'repeated discontinuity tag')
            discontinuity = True
        elif line == '#EXT-X-ENDLIST':
            ended = True
        elif line.startswith('#'):
            tag, _, value = line.partition(':')
            require(tag not in tags, 'repeated playlist header tag')
            tags[tag] = value
        elif line:
            require(duration is not None and (MEDIA_NAME.fullmatch(line) or COMPACT_MEDIA_NAME.fullmatch(line)), 'invalid playlist URI or missing EXTINF')
            entries.append({'filename':line, 'duration':duration, 'discontinuity':discontinuity})
            duration = None; discontinuity = False
    require(entries and duration is None and not discontinuity, 'incomplete playlist entry')
    require('#EXT-X-INDEPENDENT-SEGMENTS' in tags, 'missing independent-segments declaration')
    sequence = int(tags['#EXT-X-MEDIA-SEQUENCE'])
    disc_sequence = int(tags['#EXT-X-DISCONTINUITY-SEQUENCE'])
    target = int(tags['#EXT-X-TARGETDURATION'])
    require(sequence >= 0 and disc_sequence >= 0 and target == 5, 'invalid Tubeist playlist sequence or target')
    require(tags.get('#EXT-X-VERSION') == '3', 'unexpected playlist version')
    playlist_type = tags.get('#EXT-X-PLAYLIST-TYPE')
    require(playlist_type in (None, 'EVENT'), 'unexpected playlist type')
    if playlist_type == 'EVENT':
        require(sequence == disc_sequence == 0, 'EVENT playlist removed its history')
    for i, entry in enumerate(entries):
        session, number = media_identity(entry['filename'])
        require(number == sequence + i, 'playlist places a segment at the wrong sequence')
        entry['sequence'] = sequence + i
        entry['session'] = session
    return {'sequence':sequence, 'discontinuitySequence':disc_sequence, 'target':target,
            'playlistType':playlist_type, 'entries':entries, 'endList':ended}


def read_capture(directory, ending_policy='automatic'):
    journal = directory / 'uploads.jsonl'
    require(journal.stat().st_size <= 16 * 1024 * 1024, 'upload journal exceeds its size limit')
    events = [json.loads(l) for l in journal.read_text().splitlines() if l.strip()]
    require(2 <= len(events) <= 20010, 'invalid upload event count')
    require(events[0].get('kind') == 'captureStarted' and events[0].get('schema') == 1, 'missing capture schema')
    require(ending_policy in ('automatic', 'manualDiagnostic'), 'unknown expected ending policy')
    require(events[0].get('endingPolicy', 'automatic') == ending_policy, 'capture ending policy differs from expected policy')
    require(events[-1].get('kind') == 'captureFinished' and events[-1].get('complete') is True,
            'request capture is incomplete or did not finish')
    requests = []; pending = None; last_elapsed = -1
    for e in events:
        elapsed = e.get('elapsed')
        require(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed >= last_elapsed,
                'invalid or decreasing capture elapsed time')
        last_elapsed = elapsed
    for e in events[1:-1]:
        if e.get('kind') == 'request':
            require(pending is None and e.get('id') == len(requests), 'requests overlap or have repeated/missing IDs')
            name = e.get('filename',''); body_name = e.get('body','')
            match = BODY_NAME.fullmatch(body_name)
            require(match and (MEDIA_NAME.fullmatch(name) or COMPACT_MEDIA_NAME.fullmatch(name) or PLAYLIST_NAME.fullmatch(name)), 'invalid captured filename')
            require(name.endswith('.'+match[2]) and e.get('sha256') == match[1], 'body metadata disagrees')
            expected_type = 'video/mp2t' if match[2] == 'ts' else 'application/vnd.apple.mpegurl'
            require(e.get('contentType') == expected_type, 'wrong request content type')
            path = directory / 'bodies' / body_name
            require(path.resolve().parent == (directory/'bodies').resolve(), 'body leaves capture directory')
            require(path.stat().st_size == e.get('byteCount') and path.stat().st_size <= 128 * 1024 * 1024,
                    'missing, truncated, or oversized request body')
            # Hash incrementally so validation does not retain every video segment.
            with path.open('rb') as source:
                hasher = hashlib.sha256()
                for chunk in iter(lambda: source.read(1024*1024), b''):
                    hasher.update(chunk)
                digest = hasher.hexdigest()
            require(digest == match[1], 'request body checksum does not match')
            pending = dict(e, path=path)
        elif e.get('kind') == 'response':
            require(pending is not None and e.get('id') == pending['id'], 'response is missing its request')
            status = e.get('httpStatus')
            require(status is None or (type(status) is int and 100 <= status <= 599), 'invalid recorded HTTP status')
            pending['httpStatus'] = status
            requests.append(pending); pending = None
        else:
            raise CaptureValidationError('request capture is incomplete or contains unknown events')
    require(pending is None and requests and events[-1].get('requests') == len(requests), 'request/response count mismatch')
    unique = {r['body']:r['byteCount'] for r in requests}
    require(events[-1].get('savedBytes') == sum(unique.values()), 'capture byte total does not match')
    return requests


def audit_requests(requests, ending_policy='automatic'):
    require(ending_policy in ('automatic', 'manualDiagnostic'), 'unknown expected ending policy')
    entries = {}; accepted = {}; media_hashes = set(); last_playlist = None
    previous_failed = None; playlist_name = None; minimum_sequence = 0; disc_sequence = 0
    for r in requests:
        if previous_failed:
            require((r['filename'],r['sha256']) == previous_failed, 'retry changed filename or request body')
        previous_failed = None if r['httpStatus'] in (200,202) else (r['filename'],r['sha256'])
        if r['filename'].endswith('.m3u8'):
            require(playlist_name in (None,r['filename']), 'playlist filename changed')
            playlist_name = r['filename']
            playlist = parse_playlist(r['path'].read_bytes())
            if ending_policy == 'manualDiagnostic':
                require(not playlist['endList'], 'manual ending test unexpectedly sent ENDLIST')
            if last_playlist is not None:
                require(playlist['playlistType'] == last_playlist['playlistType'], 'playlist type changed')
                if playlist['playlistType'] == 'EVENT':
                    require(playlist['entries'][:len(last_playlist['entries'])] == last_playlist['entries'],
                            'EVENT playlist changed or removed previously advertised entries')
            require(last_playlist is None or not last_playlist['endList'] or playlist == last_playlist,
                    'playlist changed after ENDLIST')
            require(playlist['sequence'] >= minimum_sequence and playlist['discontinuitySequence'] >= disc_sequence,
                    'playlist sequence moved backward')
            require(last_playlist is not None or playlist['sequence'] == 0, 'first playlist does not start at zero')
            # An entry keeps the same timing even when it appears in later snapshots.
            for entry in playlist['entries']:
                require(playlist_name == entry['session']+'.m3u8', 'playlist references another session')
                seq = entry['sequence']
                require(seq not in entries or entries[seq] == entry, 'playlist changed a segment duration or identity')
                entries[seq] = entry
            require(all(n in accepted for n in entries if n < playlist['sequence']),
                    'playlist removed unacknowledged media')
            expected_disc = sum(e['discontinuity'] for n,e in entries.items() if n < playlist['sequence'])
            require(expected_disc == playlist['discontinuitySequence'], 'wrong discontinuity-sequence header')
            require(sum(e['sequence'] not in accepted for e in playlist['entries']) <= 5, 'too many outstanding playlist entries')
            if playlist['endList']:
                require(all(e['sequence'] in accepted for e in entries.values()), 'ENDLIST precedes acknowledged media')
            minimum_sequence = playlist['sequence']; disc_sequence = playlist['discontinuitySequence']
            last_playlist = playlist
        else:
            _, seq = media_identity(r['filename'])
            require(last_playlist and not last_playlist['endList'], 'media sent without a playlist or after ENDLIST')
            require(any(e['filename'] == r['filename'] for e in last_playlist['entries']), 'media not advertised in the preceding playlist')
            require(seq == len(accepted), 'media uploaded out of order or duplicated after acknowledgement')
            if r['httpStatus'] in (200,202):
                require(r['sha256'] not in media_hashes, 'identical TS body uploaded under another sequence')
                media_hashes.add(r['sha256']); accepted[seq] = r
    require(previous_failed is None, 'last HTTP operation did not succeed')
    require(last_playlist and (last_playlist['endList'] or ending_policy == 'manualDiagnostic'),
            'missing acknowledged final ENDLIST playlist')
    require(set(entries) == set(accepted) and accepted, 'playlist references missing media')
    compact_names = COMPACT_MEDIA_NAME.fullmatch(last_playlist['entries'][0]['filename']) is not None
    retained_count = 15 if compact_names else 5  # Older rolling captures used five.
    first_retained = 0 if last_playlist['playlistType'] == 'EVENT' else max(0,len(accepted)-retained_count)
    if compact_names:
        retained_duration = sum(entries[n]['duration'] for n in range(first_retained, len(accepted)))
        while first_retained > 0 and retained_duration < 3 * last_playlist['target']:
            first_retained -= 1
            retained_duration += entries[first_retained]['duration']
    require([e['sequence'] for e in last_playlist['entries']] == list(range(first_retained,len(accepted))),
            'final playlist does not retain the required segment history in order')
    return entries, accepted


def probe_segment(path, decode):
    command = ['ffprobe','-v','error','-show_packets','-show_streams','-of','json',str(path)]
    result = subprocess.run(command, capture_output=True, timeout=60)
    require(result.returncode == 0 and not result.stderr.strip(), 'ffprobe reported an invalid segment')
    data = json.loads(result.stdout)
    video = [s for s in data['streams'] if s['codec_type'] == 'video']
    audio = [s for s in data['streams'] if s['codec_type'] == 'audio']
    require(len(video) == len(audio) == 1 and video[0]['codec_name'] == 'hevc' and audio[0]['codec_name'] == 'aac',
            'decoder did not identify exactly HEVC and AAC')
    packets = [p for p in data['packets'] if p['stream_index'] == video[0]['index']]
    require(packets and 'K' in packets[0].get('flags',''), 'decoder does not identify the first video packet as a keyframe')
    durations = [float(p.get('duration_time',0)) for p in packets]
    require(all(d > 0 and math.isfinite(d) for d in durations), 'video frame durations could not be determined')
    if decode:
        command = ['ffmpeg','-v','error','-xerror','-err_detect','explode','-threads','2','-i',str(path),
                   '-map','0:v:0','-map','0:a:0','-fps_mode','passthrough','-progress','pipe:1','-nostats','-f','null','-']
        result = subprocess.run(command, capture_output=True, timeout=180)
        require(result.returncode == 0 and not result.stderr.strip(), 'segment fails independent decoding')
        frames = re.findall(rb'^frame=([0-9]+)',result.stdout,re.M)
        require(frames and int(frames[-1]) == len(packets), 'independent decoder lost video frames')
    return packets, durations


def validate_capture(directory, decode=True, pcr_margin_ms=700, ending_policy='automatic'):
    requests = read_capture(directory, ending_policy)
    entries, accepted = audit_requests(requests, ending_policy)
    report_events = load_report(directory/'acceptance.jsonl')
    report = validate_report(report_events, allow_drops=True)
    accepted_events = [e for e in report_events if e['kind'] == 'segmentAccepted']
    require(len(accepted_events) == len(accepted), 'acceptance report and captured upload counts disagree')
    inspector = TransportInspector(pcr_margin_ticks=pcr_margin_ms*90); rows = []
    schedule = DecodeSchedule()
    for seq,r in accepted.items():
        try:
            entry = entries[seq]
            require(abs(accepted_events[seq]['duration']-entry['duration']) <= .000001, 'acceptance duration differs from EXTINF')
            units = inspector.inspect(r['path'].read_bytes(), entry['discontinuity'])
            packets, durations = probe_segment(r['path'],decode)
            video = units['video']; audio = units['audio']
            ordering = read_ordering_limits(r['path'])
            pending_pictures = schedule.inspect(video, ordering, entry['discontinuity'])
            require(len(packets) == len(video), 'PES picture count differs from decoder packet count')
            require(all(abs(signed_delta(round(float(p['pts_time'])*90000),round(v['pts']*90000))) <= 2
                        for p,v in zip(packets,video)),
                    'independent timestamp parsers disagree')
            end = max(max(v['pts']+d for v,d in zip(video,durations)), max(a['pts']+a['duration'] for a in audio))
            rows.append({'sequence':seq,'videoFrames':len(video),'audioPackets':len(audio),
                         'keyframes':sum(v['keyframe'] for v in video),'firstPictureNALType':video[0]['nalType'],
                         'videoStart':video[0]['pts'],'mediaEnd':end,'playlistDuration':entry['duration'],
                         'firstVideoDTS':video[0]['dts'],'lastVideoDTS':video[-1]['dts'],
                         'hevcOrdering':ordering, 'maximumPicturesAwaitingDisplay':pending_pictures,
                         'audioStart':audio[0]['pts'],'audioEnd':audio[-1]['pts']+audio[-1]['duration'],
                         'maximumVideoFrameInterval':max((b-a for a,b in zip(
                             sorted(v['pts'] for v in video), sorted(v['pts'] for v in video)[1:])),default=0),
                         'discontinuity':entry['discontinuity']})
        except CaptureValidationError as error:
            raise CaptureValidationError(f'segment {seq}: {error}') from error
    for i,row in enumerate(rows):
        following = rows[i+1] if i+1 < len(rows) else None
        if following and not following['discontinuity']:
            expected = following['videoStart']-row['videoStart']
            require(abs(expected-row['playlistDuration']) <= .002, f'segment {i}: EXTINF does not match next video boundary')
        else:
            expected = row['mediaEnd']-row['videoStart']
            # AAC can overlap a normal GOP boundary by one packet; finalization
            # uses the complete A/V end, and has only clock-conversion rounding.
            tolerance = .03 if following else .002
            require(abs(expected-row['playlistDuration']) <= tolerance, f'segment {i}: EXTINF does not match media end')
    return {'status':'pass','independentlyDecoded':decode,'segmentCount':len(rows),'requestAttempts':len(requests),
            'endingPolicy':ending_policy,
            'pcrMarginSeconds':pcr_margin_ms/1000,
            'acceptedDurationSeconds':report['acceptedDurationSeconds'], 'segments':rows,
            'scope':'Tubeist HEVC/AAC structural, timing, playlist and optional isolated-decoder checks; not a complete H.265 conformance certification.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path,help='one complete TubeistDirectHLSAcceptance session folder')
    parser.add_argument('--skip-decode',action='store_true',help='inspect structure/timing only; not a decoding pass')
    parser.add_argument('--ending-policy',choices=('automatic','manualDiagnostic'),default='automatic',
                        help='manualDiagnostic requires a marked capture with all media acknowledged and no ENDLIST')
    parser.add_argument('--pcr-margin-ms',type=int,choices=(0,700),default=700,
                        help='expected PCR-to-DTS margin; use 0 only for historical captures (default: 700)')
    args = parser.parse_args()
    try:
        require(shutil.which('ffprobe') and shutil.which('ffmpeg'), 'ffprobe and ffmpeg must be installed')
        result = validate_capture(args.directory,not args.skip_decode,args.pcr_margin_ms,args.ending_policy)
    except (CaptureValidationError,ReportValidationError) as error:
        print(f'Upload capture validation failed: {error}',file=sys.stderr); return 1
    except (OSError,ValueError,KeyError,TypeError,IndexError,subprocess.TimeoutExpired):
        print('Upload capture validation failed: unreadable or malformed evidence, or decoder timeout',file=sys.stderr); return 1
    print(json.dumps(result,indent=2,sort_keys=True)); return 0


if __name__ == '__main__':
    raise SystemExit(main())
