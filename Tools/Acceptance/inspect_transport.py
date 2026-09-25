"""Independent checks for Tubeist's HEVC/AAC MPEG-TS output (not a full H.265 verifier)."""
from __future__ import annotations

import re


class CaptureValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise CaptureValidationError(message)


def crc32_mpeg(data):
    crc = 0xffffffff
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04c11db7 if crc & 0x80000000 else 0)) & 0xffffffff
    return crc


def section(payload):
    require(bool(payload), 'missing PSI pointer')
    start = 1 + payload[0]
    require(start + 3 <= len(payload), 'truncated PSI header')
    length = ((payload[start+1] & 15) << 8) | payload[start+2]
    data = payload[start:start+3+length]
    require(len(data) == 3 + length and len(data) >= 12, 'truncated PSI section')
    require(crc32_mpeg(data) == 0, 'invalid PSI CRC')
    return data


def timestamp(data):
    require(len(data) == 5 and all(data[i] & 1 for i in (0, 2, 4)), 'invalid PES timestamp marker')
    return ((data[0] & 14) << 29) | (data[1] << 22) | ((data[2] & 254) << 14) | (data[3] << 7) | (data[4] >> 1)


def signed_delta(a, b):
    return ((a - b + (1 << 32)) % (1 << 33)) - (1 << 32)


def validate_sdt(data, transport_id, program_id):
    require(len(data) >= 20 and data[0] == 0x42 and data[1] & 0xf0 == 0xf0, 'invalid SDT header')
    require(crc32_mpeg(data) == 0, 'invalid SDT CRC')
    require(data[3:5] == transport_id and data[5] & 1 and data[6:8] == b'\0\0', 'SDT transport mismatch')
    require(data[11:13] == program_id, 'SDT service does not match PAT program')
    length = ((data[14] & 15) << 8) | data[15]
    require(16 + length == len(data) - 4, 'invalid SDT service loop')
    pos = 16
    services = 0
    while pos < len(data) - 4:
        require(pos + 2 <= len(data) - 4, 'truncated SDT descriptor')
        end = pos + 2 + data[pos+1]
        require(end <= len(data) - 4, 'truncated SDT descriptor data')
        if data[pos] == 0x48:
            services += 1
            require(end >= pos + 5, 'truncated SDT service descriptor')
            name_length_at = pos + 4 + data[pos+3]
            require(name_length_at < end and name_length_at + 1 + data[name_length_at] == end,
                    'invalid SDT service name length')
            for text in (data[pos+4:name_length_at], data[name_length_at+1:end]):
                if text[:1] == b'\x15':
                    try:
                        text[1:].decode('utf-8')
                    except UnicodeDecodeError:
                        raise CaptureValidationError('invalid SDT UTF-8') from None
        pos = end
    require(services == 1, 'expected one SDT service descriptor')


class TransportInspector:
    def __init__(self, pcr_margin_ticks=63000):
        self.pcr_margin_ticks = pcr_margin_ticks
        self.counters = {}
        self.last_dts = {}
        self.last_audio_end = None
        self.previous_video_max = None

    def inspect(self, data, discontinuity=False):
        require(data and len(data) % 188 == 0, 'TS is not whole 188-byte packets')
        if discontinuity:
            self.counters.clear()
            self.last_audio_end = None
            self.previous_video_max = None
        streams = {}
        pmt_pid = None
        transport_id = program_id = None
        sdt = bytearray()
        pes = {}
        units = {'video': [], 'audio': []}
        pcrs = []

        def finish_pes(pid):
            raw = bytes(pes.pop(pid))
            kind = streams[pid]
            require(len(raw) >= 14 and raw[:3] == b'\0\0\1', 'invalid PES start')
            require(raw[3] == (0xe0 if kind == 'video' else 0xc0), 'unexpected PES stream ID')
            size = int.from_bytes(raw[4:6], 'big')
            require(size == 0 or size + 6 == len(raw), 'truncated or oversized PES')
            require(raw[6] & 0xc0 == 0x80, 'invalid PES flags')
            flags = raw[7] >> 6
            require(flags in (2, 3) and raw[8] >= (10 if flags == 3 else 5), 'PES has no timing')
            require(9 + raw[8] <= len(raw), 'truncated PES optional header')
            require(raw[9] >> 4 == flags, 'invalid PTS prefix')
            pts_raw = timestamp(raw[9:14])
            if flags == 3:
                require(raw[14] >> 4 == 1, 'invalid DTS prefix')
            dts_raw = timestamp(raw[14:19]) if flags == 3 else pts_raw
            previous = self.last_dts.get(kind)
            dts = dts_raw if previous is None else previous + signed_delta(dts_raw, previous % (1 << 33))
            require(previous is None or dts > previous, 'repeated or backward decode timestamp')
            pts = dts + signed_delta(pts_raw, dts_raw)
            require(pts >= dts, 'presentation timestamp precedes decoding timestamp')
            self.last_dts[kind] = dts
            payload = raw[9 + raw[8]:]
            item = {'pts': pts / 90000, 'dts': dts / 90000}
            if kind == 'video':
                require(payload.startswith((b'\0\0\1', b'\0\0\0\1')), 'missing Annex-B start code')
                nals = re.split(b'\x00\x00(?:\x00)?\x01', payload)[1:]
                require(all(len(n) >= 2 and not n[0] & 128 and n[1] & 7 for n in nals), 'invalid HEVC NAL header')
                types = [(n[0] >> 1) & 63 for n in nals]
                require(types[0] == 35 and types.count(35) == 1, 'HEVC access unit lacks one leading AUD')
                vcl = [n for n in nals if (n[0] >> 1) & 63 <= 31]
                require(vcl and all(len(n) >= 3 for n in vcl), 'HEVC access unit has no picture')
                require(sum(bool(n[2] & 128) for n in vcl) == 1 and vcl[0][2] & 128,
                        'HEVC PES does not contain exactly one complete access unit')
                picture_type = (vcl[0][0] >> 1) & 63
                require(not any(t in (8, 9) for t in types), 'RASL picture may reference an earlier GOP')
                random_access = 16 <= picture_type <= 21
                if not units['video']:
                    require(random_access, 'segment does not start at an HEVC random-access picture')
                    first_vcl = next(i for i,t in enumerate(types) if t <= 31)
                    require({32, 33, 34}.issubset(types[:first_vcl]), 'first picture lacks VPS/SPS/PPS')
                item.update(keyframe=random_access, nalType=picture_type)
            else:
                require(len(payload) >= 7 and payload[0] == 255 and payload[1] & 0xf6 == 0xf0, 'invalid AAC ADTS header')
                length = ((payload[3] & 3) << 11) | (payload[4] << 3) | (payload[5] >> 5)
                rates = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
                frequency = (payload[2] >> 2) & 15
                require(frequency < len(rates) and length == len(payload), 'invalid AAC ADTS length or sample rate')
                require(payload[2] >> 6 == 1 and payload[6] & 3 == 0, 'expected one AAC-LC block per PES')
                channels = ((payload[2] & 1) << 2) | (payload[3] >> 6)
                require(channels in (1, 2), 'unexpected AAC channel configuration')
                item['duration'] = 1024 / rates[frequency]
                if self.last_audio_end is not None:
                    require(abs(item['pts'] - self.last_audio_end) <= .002, 'audio timestamp gap or overlap exceeds 2 ms')
                self.last_audio_end = item['pts'] + item['duration']
            units[kind].append(item)

        for offset in range(0, len(data), 188):
            packet = data[offset:offset+188]
            require(packet[0] == 0x47 and not packet[1] & 128 and not packet[3] & 192, 'invalid TS sync, error, or scrambling flags')
            pid = ((packet[1] & 31) << 8) | packet[2]
            start = bool(packet[1] & 64)
            control = (packet[3] >> 4) & 3
            require(control != 0, 'invalid TS adaptation control')
            pos = 4
            if control & 2:
                size = packet[4]
                require(size <= 183, 'invalid adaptation field length')
                pos += 1 + size
                if size:
                    flags = packet[5]
                    if flags & 128:
                        require(discontinuity, 'transport discontinuity is absent from the playlist')
                        self.counters.pop(pid, None)
                    if flags & 16:
                        require(size >= 7, 'truncated PCR')
                        pcr = (packet[6] << 25) | (packet[7] << 17) | (packet[8] << 9) | (packet[9] << 1) | (packet[10] >> 7)
                        pcrs.append((pid, pcr))
            if not control & 1:
                continue
            require(pos < 188, 'empty TS payload')
            cc = packet[3] & 15
            require(pid not in self.counters or cc == (self.counters[pid] + 1) % 16, 'TS continuity-counter discontinuity')
            self.counters[pid] = cc
            payload = packet[pos:]
            if offset == 0:
                require(pid == 0 and start, 'first TS packet is not PAT')
            if offset == 188:
                require(pid == pmt_pid and start, 'second TS packet is not PMT')
            if pid == 0:
                require(start, 'split PAT is unsupported by this Tubeist validator')
                pat = section(payload)
                require(pat[0] == 0 and len(pat) == 16 and pat[8:10] != b'\0\0', 'expected a single-program PAT')
                found = ((pat[10] & 31) << 8) | pat[11]
                transport_id, program_id = pat[3:5], pat[8:10]
                require(pmt_pid in (None, found), 'PMT PID changed')
                pmt_pid = found
            elif pid == pmt_pid:
                require(start, 'split PMT is unsupported by this Tubeist validator')
                pmt = section(payload)
                require(pmt[0] == 2 and len(pmt) >= 16, 'invalid PMT')
                at = 12 + (((pmt[10] & 15) << 8) | pmt[11]); found = {}
                while at < len(pmt) - 4:
                    require(at + 5 <= len(pmt) - 4, 'truncated PMT stream entry')
                    typ = pmt[at]; spid = ((pmt[at+1] & 31) << 8) | pmt[at+2]
                    require(typ in (0x24, 0x0f) and spid not in found, 'unexpected PMT stream type or repeated PID')
                    found[spid] = 'video' if typ == 0x24 else 'audio'
                    at += 5 + (((pmt[at+3] & 15) << 8) | pmt[at+4])
                require(at == len(pmt)-4 and sorted(found.values()) == ['audio','video'], 'expected exactly HEVC and AAC')
                require(not streams or found == streams, 'PMT changed inside a segment')
                streams = found
                require(found.get(((pmt[8] & 31) << 8) | pmt[9]) == 'video', 'PCR PID is not the video PID')
            elif pid == 0x11:
                # SDT is optional for older captures. When present, validate
                # its complete section, including names spanning TS packets.
                if start:
                    require(not sdt and payload[0] == 0, 'unexpected SDT section start')
                    payload = payload[1:]
                else:
                    require(bool(sdt), 'SDT continuation without start')
                sdt.extend(payload)
                require(len(sdt) >= 3, 'truncated SDT header')
                length = 3 + (((sdt[1] & 15) << 8) | sdt[2])
                require(length <= 1024, 'SDT exceeds section length limit')
                if len(sdt) >= length:
                    require(all(b == 255 for b in sdt[length:]), 'invalid SDT stuffing')
                    validate_sdt(bytes(sdt[:length]), transport_id, program_id)
                    sdt.clear()
            elif pid in streams:
                if start:
                    if pid in pes:
                        finish_pes(pid)
                    pes[pid] = bytearray()
                require(pid in pes, 'PES continuation without start')
                pes[pid].extend(payload)
            else:
                require(pid == 0x1fff, 'unexpected PID')
        require(not sdt, 'truncated SDT section')
        for pid in list(pes):
            finish_pes(pid)
        require(units['video'] and units['audio'] and pcrs, 'segment is missing video, audio, or PCR')
        video = units['video']
        # Tubeist writes one PCR at every video access-unit start, earlier than
        # DTS by the receiver buffering margin. Compare modulo 33 bits because
        # DTS can wrap before PCR does. Historical captures used zero margin.
        require(len(pcrs) == len(video), 'missing or extra video PCR')
        require(all(streams.get(pid) == 'video' and signed_delta(round(v['dts']*90000), pcr) == self.pcr_margin_ticks
                    for (pid,pcr),v in zip(pcrs,video)), 'PCR does not match the expected decoder buffering margin')
        require(video[0]['pts'] == min(x['pts'] for x in video), 'pictures precede the segment random-access picture')
        require(self.previous_video_max is None or video[0]['pts'] > self.previous_video_max, 'video presentation ranges overlap across segments')
        self.previous_video_max = max(x['pts'] for x in video)
        return units
