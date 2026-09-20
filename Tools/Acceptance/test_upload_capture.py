"""Corruption tests use synthetic PES payloads; isolated decoding is tested on real media separately."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from inspect_transport import TransportInspector, CaptureValidationError
from check_hevc_timing import DecodeSchedule
from validate_upload_capture import audit_requests, parse_playlist, read_capture


TABLES = bytes.fromhex((Path(__file__).parent/'Fixtures'/'transport_tables.hex').read_text())


def stamp(value):
    return bytes([0x21 | ((value >> 29) & 14), (value >> 22) & 255, ((value >> 14) & 254) | 1,
                  (value >> 7) & 255, ((value << 1) & 254) | 1])


def packet(pid, pes, pcr=None, counter=0):
    size = 183-len(pes)
    adaptation = bytes([size,16 if pcr is not None else 0])
    if pcr is not None:
        adaptation += bytes([(pcr >> 25) & 255,(pcr >> 17) & 255,(pcr >> 9) & 255,
                             (pcr >> 1) & 255,((pcr & 1) << 7) | 0x7e,0])
    adaptation += b'\xff'*(1+size-len(adaptation))
    return bytes([0x47,0x40 | (pid >> 8),pid & 255,0x30 | counter])+adaptation+pes


def sample_transport(pts=90000, key=True, aud=True, counter=0, pcr_margin_ticks=63000):
    nal_types = ([35] if aud else [])+[32,33,34,20 if key else 1]
    video = b''.join(b'\0\0\0\1'+bytes([t << 1,1,0x80]) for t in nal_types)
    audio = bytes.fromhex('fff15080015ffc')+b'abc'  # one 10-byte AAC-LC ADTS frame
    def pes(stream,payload):
        body=b'\x80\x80\x05'+stamp(pts)+payload
        return b'\0\0\1'+bytes([stream])+len(body).to_bytes(2,'big')+body
    tables = bytearray(TABLES)
    tables[3] = (tables[3] & 0xf0) | counter
    tables[191] = (tables[191] & 0xf0) | counter
    pcr = (pts-pcr_margin_ticks) % (1 << 33)
    return bytes(tables)+packet(256,pes(0xe0,video),pcr,counter)+packet(257,pes(0xc0,audio),counter=counter)


def playlist(entries, first=0, ended=False, event=False):
    lines=['#EXTM3U','#EXT-X-VERSION:6','#EXT-X-TARGETDURATION:5',f'#EXT-X-MEDIA-SEQUENCE:{first}',
           '#EXT-X-DISCONTINUITY-SEQUENCE:0','#EXT-X-INDEPENDENT-SEGMENTS']
    if event: lines += ['#EXT-X-PLAYLIST-TYPE:EVENT']
    for seq,duration in entries:
        lines += [f'#EXTINF:{duration:.6f},',f'tubeist_test_{seq}.ts']
    if ended: lines += ['#EXT-X-ENDLIST']
    return ('\n'.join(lines)+'\n').encode()


class TransportTests(unittest.TestCase):
    def test_decode_schedule_catches_eight_frame_lead_but_accepts_codec_depth(self):
        limits = {'pictureBuffers': 5, 'reorderFrames': 2}
        order = [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11]
        def samples(delay):
            return [{'pts': 1 + pts / 60, 'dts': 1 + (index-delay) / 60}
                    for index, pts in enumerate(order)]
        schedule = DecodeSchedule()
        self.assertEqual(schedule.inspect(samples(2), limits), 2)
        with self.assertRaisesRegex(CaptureValidationError, 'picture-buffer capacity'):
            DecodeSchedule().inspect(samples(8), limits)
        # Neither segment boundaries nor an unchanged SPS silently reset history.
        schedule = DecodeSchedule()
        schedule.inspect(samples(8)[:5], limits)
        with self.assertRaisesRegex(CaptureValidationError, 'picture-buffer capacity'):
            schedule.inspect(samples(8)[5:], limits)
        self.assertEqual(schedule.inspect(samples(2), limits, discontinuity=True), 2)

    def test_decoder_margin_is_checked_including_timestamp_wrap(self):
        for pts in (90000, 45000, (1 << 33)-45000):
            TransportInspector().inspect(sample_transport(pts=pts))
        for margin in (0, -63000, 62999):
            with self.assertRaisesRegex(CaptureValidationError,'decoder buffering margin'):
                TransportInspector().inspect(sample_transport(pcr_margin_ticks=margin))
        # Older evidence can still be inspected explicitly without weakening
        # the default check for newly captured streams.
        TransportInspector(pcr_margin_ticks=0).inspect(sample_transport(pcr_margin_ticks=0))

    def test_closed_gop_start_and_aud_are_required(self):
        good=TransportInspector().inspect(sample_transport())
        self.assertEqual(good['video'][0]['nalType'],20)
        for data in (sample_transport(key=False),sample_transport(aud=False)):
            with self.assertRaises(CaptureValidationError): TransportInspector().inspect(data)

    def test_repeated_final_timestamp_is_rejected_even_with_fresh_continuity_counters(self):
        inspector=TransportInspector();inspector.inspect(sample_transport())
        with self.assertRaisesRegex(CaptureValidationError,'repeated or backward'):
            inspector.inspect(sample_transport(counter=1))

    def test_truncated_packet_and_bad_crc_are_rejected(self):
        bad=bytearray(sample_transport());bad[12]^=1
        for data in (sample_transport()[:-1],bytes(bad)):
            with self.assertRaises(CaptureValidationError): TransportInspector().inspect(data)

    def test_misplaced_keyframe_and_audio_gap_are_rejected(self):
        inspector=TransportInspector();inspector.inspect(sample_transport())
        with self.assertRaisesRegex(CaptureValidationError,'audio timestamp gap'):
            inspector.inspect(sample_transport(pts=180000,counter=1))


class RequestTests(unittest.TestCase):
    def test_event_retains_full_history_and_only_appends_entries(self):
        for failure in (None, 'prefix', 'tail', 'type'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as d:
                root = Path(d); requests = []
                def add(body, name):
                    path = root/str(len(requests)); path.write_bytes(body)
                    requests.append({'filename':name, 'path':path,
                                     'sha256':hashlib.sha256(body).hexdigest(), 'httpStatus':200})
                for seq in range(12):
                    add(playlist([(n,2) for n in range(seq+1)], event=True), 'tubeist_test.m3u8')
                    add(bytes([seq]), f'tubeist_test_{seq}.ts')
                final_entries = [(n,2) for n in range(12)]
                first = 0
                if failure == 'prefix':
                    first = 7; final_entries = final_entries[7:]
                if failure == 'tail': final_entries.pop()
                add(playlist(final_entries, first=first, ended=True, event=failure != 'type'), 'tubeist_test.m3u8')
                if failure:
                    with self.assertRaises(CaptureValidationError): audit_requests(requests)
                else:
                    entries, accepted = audit_requests(requests)
                    self.assertEqual(list(entries), list(range(12)))
                    self.assertEqual(len(accepted), 12)

    def test_compact_rolling_playlists_keep_the_tail_through_endlist(self):
        prefix = 'tOyFz3FCiDGeSA1X2QM4uRA'
        def base36(n):
            return ('0123456789abcdefghijklmnopqrstuvwxyz'[n] if n < 36
                    else base36(n // 36) + base36(n % 36))
        for failure in (None, 'tail', 'sequence', 'session'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as d:
                root = Path(d); requests = []
                def add(body, name):
                    path = root/str(len(requests)); path.write_bytes(body)
                    requests.append({'filename':name, 'path':path,
                                     'sha256':hashlib.sha256(body).hexdigest(), 'httpStatus':200})
                for seq in range(50):
                    first = max(0, seq - 14)
                    body = playlist([(n,2) for n in range(first,seq+1)], first=first)
                    for n in range(first,seq+1):
                        body = body.replace(f'tubeist_test_{n}.ts'.encode(), f'{prefix}_{base36(n)}.ts'.encode())
                    add(body, prefix+'.m3u8')
                    add(bytes([seq]), f'{prefix}_{base36(seq)}.ts')
                final = body + b'#EXT-X-ENDLIST\n'
                if failure == 'tail': final = final.replace(b'#EXTINF:2.000000,\n'+prefix.encode()+b'_1d.ts\n', b'')
                if failure == 'sequence': final = final.replace(b'MEDIA-SEQUENCE:35', b'MEDIA-SEQUENCE:36')
                if failure == 'session': final = final.replace(prefix.encode(), b'tAAAAAAAAAAAAAAAAAAAAAA')
                add(final, prefix+'.m3u8')
                if failure:
                    with self.assertRaises(CaptureValidationError): audit_requests(requests)
                else:
                    entries, accepted = audit_requests(requests)
                    self.assertEqual(len(accepted), 50)
                    self.assertEqual(entries[36]['filename'], prefix+'_10.ts')

    def test_wrong_playlist_position_is_rejected(self):
        with self.assertRaisesRegex(CaptureValidationError,'wrong sequence'):
            parse_playlist(playlist([(1,2)],first=0))

    def test_manual_ending_requires_open_playlist_and_all_acknowledged_media(self):
        with tempfile.TemporaryDirectory() as d:
            requests = self.make_requests(Path(d))
            for index, entries in ((0, [(0,2)]), (2, [(0,2),(1,.9)]), (4, [(0,2),(1,.9)])):
                body = playlist(entries, event=True, ended=index == 4)
                requests[index]['path'].write_bytes(body)
                requests[index]['sha256'] = hashlib.sha256(body).hexdigest()
            with self.assertRaisesRegex(CaptureValidationError, 'unexpectedly sent ENDLIST'):
                audit_requests(requests, 'manualDiagnostic')
            open_requests = requests[:-1]
            entries, accepted = audit_requests(open_requests, 'manualDiagnostic')
            self.assertEqual(len(accepted), 2)
            self.assertEqual(entries[1]['duration'], .9)
            with self.assertRaisesRegex(CaptureValidationError, 'missing acknowledged final ENDLIST'):
                audit_requests(open_requests)
            with self.assertRaisesRegex(CaptureValidationError, 'missing media'):
                audit_requests(open_requests[:-1], 'manualDiagnostic')
            for index, items in ((0, [(0,2)]), (2, [(0,2),(1,.9)])):
                requests[index]['path'].write_bytes(playlist(items))
            _, accepted = audit_requests(open_requests, 'manualDiagnostic')
            self.assertEqual(len(accepted), 2)

    def make_requests(self,root):
        bodies=[playlist([(0,2)]),b'first',playlist([(0,2),(1,.9)]),b'last',playlist([(0,2),(1,.9)],ended=True)]
        names=['tubeist_test.m3u8','tubeist_test_0.ts','tubeist_test.m3u8','tubeist_test_1.ts','tubeist_test.m3u8']
        requests=[]
        for i,(body,name) in enumerate(zip(bodies,names)):
            path=root/str(i);path.write_bytes(body)
            requests.append({'filename':name,'path':path,'sha256':hashlib.sha256(body).hexdigest(),'httpStatus':200})
        return requests

    def test_final_partial_segment_and_identical_retry_pass(self):
        with tempfile.TemporaryDirectory() as d:
            requests=self.make_requests(Path(d))
            retry=dict(requests[1],httpStatus=500)
            requests.insert(1,retry)
            entries,accepted=audit_requests(requests)
            self.assertEqual(len(accepted),2)
            self.assertEqual(entries[1]['duration'],.9)

    def test_changed_duration_or_duplicated_body_is_rejected(self):
        for failure in ('duration','duplicate','order','endlist','retry'):
            with tempfile.TemporaryDirectory() as d:
                r=self.make_requests(Path(d))
                if failure=='duration': r[-1]['path'].write_bytes(playlist([(0,2),(1,2)],ended=True))
                if failure=='duplicate': r[3]['sha256']=r[1]['sha256']
                if failure=='order': r[1],r[3]=r[3],r[1]
                if failure=='endlist': r.pop()
                if failure=='retry': r.insert(1,dict(r[1],httpStatus=500,sha256='different'))
                with self.assertRaises(CaptureValidationError): audit_requests(r)

    def test_truncated_capture_and_body_tampering_are_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'bodies').mkdir()
            body=b'actual body';digest=hashlib.sha256(body).hexdigest();name=digest+'.ts'
            path=root/'bodies'/name;path.write_bytes(body)
            events=[{'kind':'captureStarted','schema':1},
                    {'kind':'request','id':0,'filename':'tubeist_test_0.ts','body':name,'sha256':digest,
                     'contentType':'video/mp2t','byteCount':len(body)},
                    {'kind':'response','id':0,'httpStatus':200},
                    {'kind':'captureFinished','complete':True,'requests':1,'savedBytes':len(body)}]
            def save():
                for i,e in enumerate(events): e['elapsed']=float(i)
                (root/'uploads.jsonl').write_text('\n'.join(json.dumps(e) for e in events)+'\n')
            save();self.assertEqual(len(read_capture(root)),1)
            with self.assertRaisesRegex(CaptureValidationError,'ending policy'):
                read_capture(root, 'manualDiagnostic')
            events[0]['endingPolicy'] = 'manualDiagnostic';save()
            self.assertEqual(len(read_capture(root, 'manualDiagnostic')),1)
            with self.assertRaisesRegex(CaptureValidationError,'ending policy'):
                read_capture(root)
            events[0]['endingPolicy'] = 'automatic';save()
            path.write_bytes(b'corrupt!!!!')
            with self.assertRaises(CaptureValidationError): read_capture(root)
            path.write_bytes(body);events[-1]['complete']=False;save()
            with self.assertRaisesRegex(CaptureValidationError,'incomplete'): read_capture(root)
