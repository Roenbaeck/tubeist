"""Independent FFmpeg SPS inspection and a necessary (not sufficient) DPB check."""
import re
import subprocess

from inspect_transport import CaptureValidationError, require


def read_ordering_limits(path):
    result = subprocess.run([
        'ffmpeg', '-v', 'verbose', '-i', str(path), '-map', '0:v:0',
        '-c', 'copy', '-frames:v', '1', '-bsf:v', 'trace_headers', '-f', 'null', '-'
    ], capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, 'FFmpeg could not inspect HEVC ordering metadata')
    def field(name):
        matches = re.findall(r'\b'+name+r'\[(\d+)\].*= (\d+)\s*$', result.stderr, re.M)
        require(matches, 'missing HEVC SPS ordering limits')
        highest = max(int(layer) for layer, _ in matches)
        values = {int(value) for layer, value in matches if int(layer) == highest}
        require(len(values) == 1, 'conflicting HEVC SPS ordering limits')
        return values.pop()
    buffers = field('sps_max_dec_pic_buffering_minus1') + 1
    reorder = field('sps_max_num_reorder_pics')
    require(1 <= buffers <= 16 and 0 <= reorder < buffers, 'invalid HEVC SPS ordering limits')
    return {'pictureBuffers': buffers, 'reorderFrames': reorder}


class DecodeSchedule:
    def __init__(self):
        self.pending = []
        self.last_dts = None

    def inspect(self, video, limits, discontinuity=False):
        if discontinuity:
            self.pending = []
            self.last_dts = None
        peak = 0
        for sample in video:
            # Integer transport ticks avoid treating equal rounded timestamps
            # as another picture still waiting for presentation.
            pts, dts = (round(sample[key] * 90000) for key in ('pts', 'dts'))
            require(pts >= dts and (self.last_dts is None or dts > self.last_dts),
                    'invalid HEVC decode schedule')
            self.pending = [p for p in self.pending if p > dts]
            if pts > dts:
                self.pending.append(pts)
            peak = max(peak, len(self.pending))
            require(len(self.pending) <= limits['pictureBuffers'],
                    'HEVC decode schedule exceeds declared picture-buffer capacity')
            self.last_dts = dts
        # Already displayed reference pictures also occupy the DPB. We do not
        # parse reference-picture sets here; passing this lower-bound check is
        # not proof of full H.265 buffer-model conformance.
        return peak
