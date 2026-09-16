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

HEVC stays Main10, HLG, BT.2020 with closed GOPs and frame reordering. An
eight-frame encoder window bounds work retained during compression. Decode
timing instead uses the highest temporal layer's `sps_max_num_reorder_pics`,
read from the emitted HEVC configuration, as its lead along the actual input
presentation timeline. This separates encoder lookahead from decoder buffering
and follows the relay's PTS-based FFmpeg reconstruction. A reordering-depth
change requires a fresh encoder/timeline, as capture recovery already provides.
The recording video track uses a 90 kHz timescale to avoid rounding this timing
and the shared A/V epoch to AVAssetWriter's default 600 Hz. PTS and encoded payload are unchanged;
video is never presented late merely to remove negative composition offsets.
AAC priming is represented on the same timeline, in the converter's input
sample units. Recent microphone timestamp anchors keep the encoded audio
aligned to the capture clock rather than accumulating drift over a long event.
Playlist durations follow video segment boundaries rather than overlapping
AAC packet extents.

## Congestion policy

The selected bitrate is a ceiling. Decisions occur no more often than once
per two seconds and are applied at the next video segment boundary.

- Effective throughput includes playlist upload, segment upload, and retries.
  A five-sample median and exponential smoothing reject isolated outliers.
- Queue accounting includes waiting TS bytes and the in-flight segment once.
  One normal segment is excluded from backlog. For backlog Q, capacity C,
  and catch-up horizon T, the intended wire rate is `0.92*C - Q/T`; audio
  and an overhead allowance are then removed to obtain a video target.
- Normal reductions require three congested observations and are limited to
  10% per decision. Recovery immediately selects the sustainable bitrate, up
  to the selected ceiling, without an additional hold or gradual upward steps.
  It requires a fresh completed upload and uses the lower of its throughput
  and the filtered estimate. Old measurements and unfinished uploads cannot
  trigger recovery. The same capacity margin and backlog calculation applies
  in both directions, so quality can recover while the queue is still draining.
- If projected lag exhausts the allowance within six seconds, two observations
  permit a larger correction. Even before the first ACK, a long unfinished
  upload supplies an optimistic capacity bound (`segment bits / elapsed`).
  This guards against a vastly excessive starting preset without a separate
  bandwidth-test upload. It cannot shrink already encoded segments.
- The quality floor is the smaller of the selected bitrate and
  `max(250 kbps, width * height * fps * 0.015)`. This is a tuning guardrail,
  not a guarantee for every scene. The monitor and journal report when
  capacity falls below it; choose a lower resolution for the next stream.

The default buffer allowance assumes 12 seconds and reserves four. This is
an explicit engineering assumption, **not measured YouTube buffer credit**.
YouTube's public HLS ingestion API does not give the encoder an exact server
or viewer buffer level. The controller therefore cannot promise gap-free
playback through arbitrary outages. It never drops camera frames to regulate
bandwidth. The existing bounded queue may still discard a whole segment as a
last resort during a prolonged outage, and marks that discontinuity.

Unit tests replay isolated delays, sustained congestion, an excessive initial
preset before its first ACK, the quality floor, and immediate recovery with
capacity and backlog limits. Physical
phone/YouTube acceptance remains necessary to tune the allowance and floor
against real networks. Native HEVC hardware is not assumed to exist on hosted
CI runners; deterministic controller/assembler/muxer tests run in the unit suite.

References: [Apple's bitrate target](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate),
[YouTube HLS requirements](https://developers.google.com/youtube/v3/live/guides/hls-ingestion),
[Apple's segmented writer discussion](https://developer.apple.com/videos/play/wwdc2020/10011/).
