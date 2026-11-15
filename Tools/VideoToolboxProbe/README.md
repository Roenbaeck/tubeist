# VideoToolbox streaming validation

Run `zsh Tools/VideoToolboxProbe/validate.sh` on a Mac with a hardware HEVC
Main10 encoder, Xcode, and FFmpeg. This is an offline media correctness check;
it does not use a phone, publish to YouTube, or benchmark performance.

The tool compiles the production HEVC/AAC encoders, segment assembler, TS
muxer, and passthrough recording writer. It exercises 30 fps/stereo and
60 fps/mono, plus 48 kHz microphone input resampled to 44.1 kHz AAC, changing
the bitrate target twice within one encoding session.
It verifies all submitted frames return, each TS segment decodes on its own,
TS and MP4 decode to identical video pixels, HDR metadata survives, and
packet timestamps preserve A/V synchronization, including AAC priming. An
audible marker checks decoded sound timing independently of packet metadata.
The probe also compares DTS/PTS against a passthrough FFmpeg `+igndts` remux
and checks that pictures awaiting display cannot exceed the SPS buffer capacity.

## Streaming architecture

Camera HLG pixel buffers go directly to `HEVCVideoEncoder`; microphone PCM
goes to `AACAudioEncoder`. Compressed samples feed `EncodedSegmentAssembler`
and `MPEGTransportStreamMuxer`, then the existing HLS queue and HTTPS uploader.
No MP4 is generated or parsed for live delivery. The existing MP4 reader and
sink compatibility adapter remain for archived fixtures and regression tests.

When recording is enabled, the same encoded samples also go to
`RecordingAssetWriter` with `outputSettings: nil`. Both streams are passthrough,
so the writer uses manual fragment flushing. The existing recording file and
delegate delivery code save those fragments. Recording quality consequently
follows adaptive streaming bitrate. Recording-only sessions keep the selected
bitrate. Debug fMP4 fixture capture now requires recording to be enabled.

HEVC uses Main42210 for delivered 10-bit 4:2:2 camera buffers when hardware
configuration and preparation succeed; otherwise it uses Main10 4:2:0. Selection
happens once per session, on the first camera buffer, and remains fixed through
capture recovery. Both profiles retain HLG, BT.2020, closed GOPs and frame reordering. An
eight-frame encoder window bounds work retained during compression. Decode
timing instead uses the highest temporal layer's `sps_max_num_reorder_pics`,
read from the emitted HEVC configuration, as its lead along the actual input
presentation timeline. This separates encoder lookahead from decoder buffering
and follows FFmpeg's PTS-based timestamp reconstruction. A reordering-depth
change requires a fresh encoder/timeline, as capture recovery already provides.
The recording video track uses a 90 kHz timescale to avoid rounding this timing
and the shared A/V epoch to AVAssetWriter's default 600 Hz. PTS and encoded payload are unchanged;
video is never presented late merely to remove negative composition offsets.
AAC priming is represented on the same timeline, in AAC output frames (2112
at every input rate; the converter compensates for its own resampling delay).
Recent microphone timestamp anchors keep the encoded audio
aligned to the capture clock rather than accumulating drift over a long event.
Playlist durations follow video segment boundaries rather than overlapping
AAC packet extents.

## Congestion policy and encoder overshoot

The current [adaptive delivery design](../../Docs/AdaptiveBitrate.md) describes
startup, congestion, preservation-mode emergency rates, retry wake-ups, and
quality recovery. The network controller measures actual uploaded bytes;
encoder feedback separately corrects sustained output above the requested rate.
Feedback uses average-bitrate requests, not hard DataRateLimits, because the
hardware can enforce hard limits by dropping pictures.

Run `TUBEIST_PROBE_OVERSHOOT=1 zsh Tools/VideoToolboxProbe/validate.sh`
to exercise changing bitrate targets with deterministic spatial/temporal noise.
The probe requires feedback correction to occur and every input frame to survive,
then performs the same independent decode, timing, HDR and audio checks as the
normal probe. Add `TUBEIST_PROBE_NOISE_RANGE=877` for full-range noise; such
incompressible content can exceed a requested bitrate even at maximum compression.
`TUBEIST_PROBE_UNREGULATED=1` disables feedback in the offline probe for comparison.
An optional scenario argument, e.g. `30:2:44100`, runs only that configuration.
Per-frame sizes/timestamps and correction counts are saved with the artifacts.
After matching regulated/unregulated runs, use
`python3 Tools/VideoToolboxProbe/verify_overshoot_comparison.py <regulated-media-directory> <unregulated-media-directory>`
to check measured reduction after correction and a later bitrate increase,
without losing frames or excessively reducing output.

Physical phone/YouTube acceptance remains necessary for network handovers and
playback behavior. An ingest acknowledgement does not establish playback health.
The probe does not stream externally.

## Encoder-error recovery

Run `zsh Tools/VideoToolboxProbe/validate_recovery.sh` to inject failed
VideoToolbox callbacks at the initial keyframe, a reordered reference picture,
a regular GOP boundary, during recovery, and at Stop. The script instruments
only the callback boundary in a temporary source copy; the production app has
no failure-injection option. It exercises the real hardware encoder and the
production recovery gate, decode timeline, TS muxer and MP4 writer.

Every emitted segment and recording must decode without error-level FFmpeg
diagnostics, even if FFmpeg exits successfully. Emitted frame counts must
account for failed and deliberately withheld pictures, and TS/MP4 pixels must
match. The ordinary `validate.sh` still requires every healthy input frame.
Simulator tests separately check bounded recovery and persistent failures.
