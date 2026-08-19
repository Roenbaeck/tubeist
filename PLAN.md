# Direct YouTube HLS plan

- Status: implementation complete; 1080p30 real-ingest passed; full device matrix pending
- Last reviewed: 2026-08-19
- Starting point: `main` at `3cabdba`
- Reference only: `transport-stream` at `fdd21f0`

## Outcome

Tubeist will be able to send its existing HEVC/AAC stream directly to YouTube's
HLS ingest endpoint without the `hls-relay` service. The app will encode each
audio/video sample once with `AVAssetWriter`, keep the existing fragmented MP4
output for local recording and relay uploads, and remux the encoded media into
MPEG-2 Transport Stream segments for direct YouTube uploads.

This is a remux, not a transcode. Direct streaming must not create a second HEVC
or AAC encoder.

The implementation starts from `main`. The two commits on `transport-stream`
remain available as reference, but they will not be merged or cherry-picked as
a unit.

## Why restart from `main`

`transport-stream` branched from `b91ef9a`; `main` has fourteen later commits,
including media-buffering, timestamp, YouTube, microphone, and startup fixes.
The prototype also takes a different path from the desired remux:

- `VideoEncoder`, `AudioEncoder`, and `TSContentPackager` encode the raw camera
  and microphone samples a second time.
- Streaming plus recording can therefore run two video encoders and two audio
  encoders, with separate timestamp origins and failure modes.
- `TSSegmenter` recreates segment boundaries even though `AVAssetWriter` already
  emits keyframe-aligned segments.
- It emits only `.ts` data to the existing relay uploader. It does not create or
  upload the rolling media playlist required by YouTube.
- Its fixed assumptions (including four-byte HEVC NAL lengths and audio settings
  taken from app configuration) are not derived from the actual ISOBMFF codec
  configuration.
- The packet writer has no automated tests or fixture-based validation.
- The branch's second commit is explicitly a bug-fixing experiment and still
  contains inconsistent audio setup and actor changes.

### What may be reused

| Prototype item | Decision |
| --- | --- |
| `TSMuxer.swift` | Use the constants and PAT/PMT, PES, CRC, and packetization algorithms as reference. Reimplement behind unit tests; do not copy wholesale. |
| `hevcToAnnexB` | Keep the idea, but obtain the NAL length field size from `hvcC` and reject malformed input. |
| `adtsHeader` | Keep the idea, but derive Audio Object Type, sample rate, and channel configuration from the AAC `AudioSpecificConfig`. |
| `TSSegmenter.swift` | Do not reuse. One separable `AVAssetWriter` fragment will map to one `.ts` segment. |
| `VideoEncoder.swift`, `AudioEncoder.swift`, `TSContentPackager.swift` | Do not reuse. They implement a second encoding pipeline. |
| `ContentPackager` branching | Replace it with routing after the existing asset writer has encoded the media. |
| `UseTransportStream` toggle | Replace it with an explicit delivery destination; container choice is an implementation detail. |
| `SoundGrabber` and `AudioActor` changes | Do not reuse; remuxing happens after encoding and requires no capture-path change. |

## Open-source implementation references

These projects are design and conformance references, not vendored dependencies.
Tubeist's implementation is original, deliberately narrower, and covered by its
own packet/fixture tests.

| Project | License / use | What informed Tubeist | Why it is not ported wholesale |
| --- | --- | --- | --- |
| [FFmpeg](https://ffmpeg.org/) | LGPL/GPL depending on build; development oracle only | Mature ISOBMFF and MPEG-TS behavior, `ffprobe` metadata, decode/timestamp validation | Its muxer is broad C code with licensing/build implications unnecessary for Tubeist's fixed HEVC/AAC path. No FFmpeg source is copied into the app. |
| [swift-hls-kit](https://github.com/atelier-socle/swift-hls-kit) | Apache-2.0; Swift design reference | Swift byte-writing, PAT/PMT/PES organization, Annex B and ADTS concepts | Its MP4 path is oriented toward progressive files, assumes four-byte NAL lengths, resets TS continuity per segment, schedules sparse PCR, and its generic URL pusher does not implement YouTube's raw `file=` contract. |
| [oxideav-workspace](https://github.com/OxideAV/oxideav-workspace) | MIT; format-semantics reference | `tfhd`/`tfdt`/`trun` defaults, signed composition offsets, box-bound checking, TS packet concepts | Rust workspace and general media model are much broader than the post-`AVAssetWriter` seam needed here. |
| [tsMuxer](https://github.com/justdan96/tsMuxer) | Apache-2.0; timing/conformance reference | Long-running PCR/PTS/DTS and transport-stream edge cases | Legacy C++ multiplexer scope is far beyond a two-track mobile HLS remuxer. |
| [muxide](https://github.com/Michael-A-Kuykendall/muxide) | Reference only | Useful comparison of container transformation boundaries | Its focus and data flow do not match Tubeist's live fMP4-to-TS direction. |

Any future code-level borrowing must be isolated, attributed, and reviewed for
license compatibility first. The current implementation uses none.

## YouTube contract to satisfy

The following requirements are implementation inputs, not optional polish:

- Send one muxed audio/video stream over HTTPS using POST or PUT and a persistent
  connection.
- Use a media playlist, not a master playlist.
- Use `.ts` media segments in MPEG-2 TS/M2TS format. Each segment should begin
  with PAT and PMT packets and contain one MPEG-2 Program.
- Use HEVC for the current HDR path, AAC for its single audio track, a closed GOP,
  and no more than 60 fps.
- Preserve 10-bit 4:2:0 HLG, Rec. 2020 primaries, and Rec. 2020 non-constant
  luminance matrix signaling.
- Keep segment duration between one and four seconds and never above five
  seconds.
- Start the playlist at media sequence zero, update it for every segment, and
  keep no more than five unacknowledged segments in the advertised window.
- Give every `.ts` filename a value that remains unique across app restarts and
  stream restarts, and use exactly the same name in the request URL and playlist.
- Append the filename directly to the endpoint's `file=` value without URL
  encoding it. Construct filenames from YouTube's allowed characters only.
- Treat HTTP 200 and 202 according to the ingest contract; retry transient
  failures with bounded exponential backoff, and surface permanent failures.
- Set a non-secret `User-Agent` containing the manufacturer, model, and version.
- Never log the stream key or a complete ingestion URL containing it.

Authoritative references:

- [YouTube HLS ingestion guide](https://developers.google.com/youtube/v3/live/guides/hls-ingestion)
- [YouTube Live HDR requirements](https://support.google.com/youtube/answer/10265272)
- [YouTube `liveStreams` resource](https://developers.google.com/youtube/v3/live/docs/liveStreams)
- [Apple segmented `AVAssetWriter` callback](https://developer.apple.com/documentation/avfoundation/avassetwriterdelegate/assetwriter%28_%3Adidoutputsegmentdata%3Asegmenttype%3Asegmentreport%3A%29)

## Scope

### In scope

- Direct YouTube HLS delivery for the current HEVC Main10 HLG plus AAC output.
- ISOBMFF initialization and media-fragment parsing sufficient for the output
  produced by Tubeist's `AVAssetWriter` configuration.
- MPEG-2 TS muxing without decoding or re-encoding.
- Rolling HLS media-playlist generation and YouTube-specific HTTP delivery.
- Existing stream-only, stream-and-record, and record-only modes.
- Existing fMP4 relay delivery for YouTube and Twitch as a fallback.
- Unit, fixture, HTTP-contract, device, and real YouTube verification.

### Out of scope for the first release

- RTMP/RTMPS output.
- Multiple HLS renditions or a master playlist.
- Direct Twitch ingestion.
- Primary plus backup YouTube ingestion in parallel. The design must leave room
  for it, but the primary endpoint ships first.
- H.264, AC-3, E-AC-3, captions, and encryption beyond HTTPS.
- Background streaming after iOS suspends the capture session.
- Replacing the capture, overlay, effects, or camera-control pipeline.

## Architecture

The encoded fMP4 fragments remain the single source of truth:

```text
camera + microphone
        |
        v
existing AVAssetWriter (HEVC Main10 HLG + AAC; exactly one encode)
        |
        +-- initialization + fMP4 media fragments --> local MP4 recording
        |
        +-- initialization + fMP4 media fragments --> existing hls-relay uploader
        |
        `-- initialization config + each media fragment
                                      |
                                      v
                           ISOBMFF-to-MPEG-TS remuxer
                                      |
                                      v
                              .ts segment + duration
                                      |
                                      v
                       rolling playlist + YouTube uploader
```

Destination selection occurs after encoding:

- `recordOnly`: write the original fMP4 fragments; do not initialize an uploader.
- `relay`: upload original fMP4 fragments using the current relay protocol and
  optionally write those same fragments to the recording.
- `youTubeDirect`: feed the initialization data to the remuxer, remux each media
  fragment to TS, upload playlist/segments to YouTube, and optionally write the
  original fMP4 fragments to the recording.

The direct path must run on an ordered, dedicated actor. Parsing and muxing a 4K
fragment must not block the capture actor. The actor owns parser configuration,
TS continuity state, playlist state, and upload ordering for one stream session.
Its queue is bounded; overload changes stream health and applies the documented
drop/discontinuity policy instead of growing memory without limit.

## Core data model and responsibilities

Names below are proposed and may be refined during implementation, but the
responsibility boundaries should remain.

### `StreamDestination`

An explicit persisted setting such as:

```swift
enum StreamDestination: String, Codable {
    case relay
    case youTubeDirect
}
```

The UI exposes a destination, not a transport-container toggle. Direct mode is
available only when the platform is YouTube and a stream key is present. Relay
remains the default during rollout, so existing settings migrate safely.

### `ISOBMFFReader`

A bounds-checked, big-endian byte reader and box walker. It must reject invalid
sizes, truncated boxes, integer overflow, unsupported required fields, duplicate
track IDs, and media data outside `mdat`; no force unwraps or unchecked offsets.

From the initialization segment (`ftyp` + `moov`) it extracts:

- video and audio track IDs;
- each track's media timescale;
- HEVC sample-entry type and `hvcC` data, including NAL-length size and VPS/SPS/PPS;
- AAC `AudioSpecificConfig`, including Audio Object Type, sample-rate index or
  explicit rate, and channel configuration;
- `mvex`/`trex` sample defaults needed to interpret later fragments.

From every media fragment (`moof` + `mdat`) it handles the fields Tubeist can
legitimately emit, including:

- `mfhd`, `traf`, `tfhd`, `tfdt`, and one or more `trun` boxes;
- explicit and default sample duration, size, flags, and composition offsets;
- signed composition offsets for version 1 `trun`;
- `base-data-offset`, `default-base-is-moof`, and `data-offset` addressing;
- multiple audio and video access units and B-frame DTS/PTS ordering.

It returns typed access units with payload ranges, DTS, PTS, duration, track type,
and random-access flags. Unknown optional boxes are skipped; an unknown construct
needed to locate or time media is a typed error.

### `MPEGTransportStreamMuxer`

A pure Swift, stateful muxer. It:

- emits 188-byte packets with sync byte `0x47`;
- emits PAT and PMT as the first two packets of every segment with valid MPEG-2
  CRC-32 values and a single program;
- declares HEVC stream type `0x24` and AAC/ADTS stream type `0x0f` on stable PIDs;
- converts HEVC access units from length-prefixed form to Annex B using the
  `hvcC` length size;
- ensures the first random-access unit has the required VPS/SPS/PPS without
  duplicating parameter sets already present;
- wraps raw AAC access units in ADTS based on the parsed codec configuration;
- writes PES packets with correct PTS and DTS in the 90 kHz clock domain;
- schedules PCR on the video PID often enough for a conforming stream and marks
  random-access packets correctly;
- interleaves audio and video access units by decode time;
- establishes one common session timestamp offset for both tracks if the first
  decode time needs shifting; it never normalizes audio and video independently;
- pads adaptation fields correctly and advances continuity counters only for
  packets containing payload;
- preserves continuity across adjacent segments, resetting only at a declared
  stream discontinuity;
- applies the required 33-bit timestamp wrap rather than overflowing signed
  integers during a long stream.

One separable fMP4 fragment produces one TS segment. The remuxer verifies that
the segment begins at a video random-access point and refuses to upload a segment
that is not independently decodable. Playlist duration comes from the complete
parsed audio/video timeline. Steady-state fragments are cross-checked against
`AVAssetSegmentReport`; the final fragment permits a shorter first-track report
because AVAssetWriter may drain a longer audio tail during shutdown.

### `HLSMediaPlaylist`

A deterministic value type that owns:

- session-unique playlist and segment filenames;
- the required `EXTM3U`, version, target-duration, media-sequence, `EXTINF`, and
  discontinuity tags, with target duration rounded up and never decreased;
- media sequence, exact `EXTINF` durations, and target duration;
- acknowledged and outstanding segment state;
- a rolling window containing a small acknowledged tail plus at most five
  outstanding segments;
- `EXT-X-DISCONTINUITY` when the local buffer policy drops media or the timestamp
  timeline restarts.

The initial media sequence is zero. A new stream session gets a filesystem/URL-
safe identifier such as `yyyyMMdd_HHmmss_<random suffix>` so filenames cannot
collide when two sessions start in the same second.

### `YouTubeHLSUploader`

A YouTube-specific actor, separate from the existing relay uploader. It:

- owns one ephemeral `URLSession` reused for the whole stream;
- serializes playlist and segment requests so advertised order is predictable;
- uploads a refreshed playlist for every segment, then the referenced `.ts` file;
- accepts 200 and 202, distinguishes fatal 400/401/405 responses, and retries
  network/5xx failures with bounded exponential backoff and jitter;
- never advances acknowledged state until the segment response is accepted;
- caps outstanding work at five segments and exposes queued duration, not only
  item count, to stream-health reporting;
- drains accepted work during a bounded graceful shutdown;
- redacts the `cid`/stream key from all logs and user-facing diagnostics.

The endpoint should come from `cdn.ingestionInfo.ingestionAddress` when the
signed-in YouTube API can identify the matching HLS stream. Manual-key operation
may construct the documented primary URL. In both cases the final URL is formed
by appending the safe filename to the existing `file=` value without applying
URL encoding to the filename.

The first real-ingest spike must determine whether an ending playlist should
contain `EXT-X-ENDLIST`; YouTube's ingest guide does not currently prescribe stop
signaling. Until verified, shutdown must not depend on an undocumented tag.

### Existing components

- `ContentPackager` remains responsible for configuring `AVAssetWriter` and
  receiving its segmented output. Its delegate forwards immutable events to an
  ordered output router instead of doing remux/upload work on `PipelineActor`.
- `RecordingActor` continues to receive the original initialization and media
  fragments, never remuxed data.
- `FragmentPusher` remains the relay transport initially. Once behavior is
  covered by tests, it may be renamed to `RelayFragmentUploader` in a separate
  mechanical change.
- `YouTubeService` returns the matching stream's ingestion type, primary address,
  backup address, stream ID, and stream name rather than discarding all but ID
  and name. It validates that direct mode uses an HLS stream key.
- `Streamer` prepares exactly one streaming sink for the selected destination
  and coordinates bounded shutdown. Recording is an independent sink.

## Implementation sequence

Each phase ends with passing tests and a reviewable commit. Do not combine all
phases into a single large transport-stream change.

### Implementation evidence (2026-08-19)

- Work is isolated on `codex/direct-youtube-hls`, based on `main` at `3cabdba`.
- The complete app and unit-test targets compile with Swift 6, including
  `Kernels.metal`, after installing Xcode's Metal Toolchain 17F109 component.
  A device/simulator test loads every configured style, effect, and imprint
  function from the app's default library and creates its compute pipeline.
- The full `TubeistTests` target passes on an iOS 26.5 simulator and a physical
  iPhone 16 Pro running iOS 26.6, including the direct-sink integration path.
  Its sustained-network-stall regression verifies
  the six-fragment bound (five queued plus one in flight), oldest-media drops,
  the queued-duration bound, deadline-based shutdown, and queue cleanup. The
  standalone core runner also passes, including stop/cancellation races during
  an HTTP request.
- `Tools/YouTubeHLSMock/validate_uploader_socket.sh` passes against the production
  `URLSession` transport over loopback HTTPS. It verifies exact request bytes and
  order, raw filename suffixes, persistent HTTP/1.1 connection reuse, reconnect,
  timeout recovery, stop, and Swift task cancellation.
- The pure Swift core suite executes on macOS as a development smoke runner and
  also compiles in the iOS test target. It covers truncated input, codec config,
  defaults/offsets, signed CTS, PAT/PMT/CRC, continuity, PCR, stuffing boundaries,
  33-bit wrap, Annex B, ADTS, playlist state, request ordering, retries, and fatal
  HTTP classifications.
- `Tools/RemuxFixture/validate_generated_hlg.sh` generates three adjacent HEVC
  Main10 HLG/BT.2020 plus AAC-LC fMP4 fragments, remuxes them with Tubeist code,
  checks the concatenated output with `ffprobe`, and decodes both tracks to a null
  sink. The check passes with 10-bit 4:2:0, ARIB STD-B67, BT.2020 primaries,
  BT.2020 non-constant matrix, and 48 kHz stereo AAC intact.
- `Tools/AppleFMP4Fixture/validate_apple_writer.sh` passes 30 fps/stereo and
  60 fps/mono Main10 HLG plus 44.1 kHz AAC through Apple's `mpeg4AppleHLS`
  fragment writer, remuxes three adjacent fragments per variant, records the
  box tree/full-box flags, and decode-checks both the TS result and the exact
  fragmented-MP4 byte stream written by `RecordingActor`. The observed Apple
  media layout has two `traf` boxes, two `trun` boxes per track, 64-bit `tfdt`,
  video `tfhd` flags `0x020038`, audio `tfhd` flags `0x02001a`, version-1 video
  `trun` flags `0x000e01`, and version-0 audio `trun` flags `0x000301`.
- A Debug-only, opt-in capture hook writes original Apple `AVAssetWriter`
  initialization/media fragments and a manifest to the app Documents folder,
  then disables itself after six media fragments. The exported-capture validator
  probes and decodes both the local-recording byte stream and Tubeist's remuxed
  output while comparing frame rate, sample rate, and channel count.
- A physical iPhone 16 Pro running iOS 26.6 produced a 1920x1080 30 fps capture
  with HEVC Main10/yuv420p10le, HLG (ARIB STD-B67), BT.2020 primaries and
  non-constant matrix, plus 44.1 kHz stereo AAC-LC. Both the exact fragmented-MP4
  byte stream and six remuxed TS segments probe and decode successfully. The
  device layout includes optional `sgpd`/`sbgp`, two `traf` boxes, multiple
  `trun` boxes per track, 64-bit `tfdt`, video `tfhd` flags `0x020038`, and audio
  `tfhd` flags `0x02001a`. The first random-access access units contain prefix
  SEI plus IRAP NAL types 20 or 21 but no in-band VPS/SPS/PPS, so the muxer
  correctly prepends parameter sets from `hvcC`.
- The record/relay/direct matrix is an executable `StreamOutputPlan` contract.
  `Streamer` passes that immutable startup snapshot into `ContentPackager`, so
  settings cannot change recording and delivery decisions independently during
  writer setup. Fixture tests also cover YouTube stream-key matching, retained
  primary/backup HLS metadata, RTMP rejection, HTTPS, and the raw `file=` suffix.
  Endpoint-validation and public-error tests use a canary stream key and verify
  that neither it nor a key-bearing URL can escape through diagnostics.
- A real direct-HLS session from the same phone delivered media sequences 0
  through 17 to YouTube with HTTP 200 for every segment, zero retries, zero
  queued duration, zero drops, and a clean `stopped` outcome. The last physical
  fragment exposed that AVAssetWriter's first-track report can be shorter than
  the complete audio/video timeline; final-fragment `EXTINF` now uses the parsed
  remux timeline, with a physical-device regression test. The Debug acceptance
  report contains status/queue counters only and passed a key/URL scan. This
  proves the upload contract and graceful stop, but Live Control Room rendering,
  archive HDR, the remaining preset matrix, and the long-run gates remain open.
- Shutdown now closes the pipeline's media-intake gate before touching
  `AVAssetWriter`, drains its bounded pending audio/video samples before marking
  either input finished, and waits for ordered routing plus upload completion.
  Apple may deliver the last audio and video as separate final callbacks; the
  direct sink now coalesces those samples into one YouTube-compliant muxed TS
  segment. An unmatched single-track tail is reported without poisoning or
  deleting earlier complete media. Regression tests reproduce both final-track
  layouts and the former misleading `not prepared` shutdown error. The full iOS
  suite, static analyzer, and generic-device test build pass; a physical stop and
  archive-tail replay remains pending while the test phone is offline.

### Phase 0 - Freeze the contract and collect fixtures

- [x] Create a fresh feature branch from current `main`; keep
  `transport-stream` unchanged as historical reference.
- [ ] Get a clean baseline build/test run on a development machine with the iOS
  and Metal toolchains installed.
- [x] Add a debug-only hook that saves one initialization segment and several
  separable fragments from the existing asset writer, automatically stopping
  capture after the bounded fixture set.
- [x] Generate reproducible synthetic Apple `mpeg4AppleHLS` layout fixtures for
  30 fps/stereo and 60 fps/mono HEVC Main10 HLG/AAC with B-frames. The macOS
  writer uses keyframe-aligned manual flushes and encoded-track passthrough, so
  this proves Apple container compatibility without claiming iPhone encoder
  equivalence.
- [ ] Capture small, redistributable on-device fixtures for at least 30 fps and 60 fps,
  B-frames, mono and stereo AAC, and a 10-bit HLG sample. Prefer generated/test
  imagery and silence over user camera content.
- [x] Record each generated host fixture's box tree, full-box flags, and
  `ffprobe` output as validation artifacts.
- [x] Confirm the host fixture's `tfhd`/`trun` variants. Its first random-access
  samples contain only IRAP NAL types 20 or 21, not in-band VPS/SPS/PPS or HDR
  SEI; Tubeist therefore prepends the parameter sets from `hvcC`.
- [ ] Record and confirm the same metadata, flags, parameter-set placement, and
  HDR SEI behavior for the physical-iPhone fixtures.

Exit gate: fixture provenance and expected codec/timestamp metadata are documented,
and `main` has a reproducible baseline result.

### Phase 1 - Parse ISOBMFF safely

- [x] Implement the byte reader, box headers (32-bit, 64-bit, and to-end sizes),
  recursive box traversal, and typed errors.
- [x] Parse initialization metadata from `moov`, `trak`, `mdia`, `stsd`, `hvcC`,
  and the AAC descriptor in `esds`.
- [x] Parse media samples from `moof`/`mdat` with all applicable `tfhd`, `tfdt`,
  and `trun` default/override rules.
- [x] Convert track timestamps with rational integer arithmetic; avoid cumulative
  floating-point rounding.
- [x] Add fixture tests plus malformed/truncated/fuzz-style input tests.

Exit gate: every captured fragment produces the expected ordered video/audio
access units, DTS/PTS/duration values, keyframe flags, and codec configuration;
malformed data fails without a trap or out-of-bounds access.

### Phase 2 - Produce independently valid TS segments

- [x] Implement and unit-test MPEG-2 CRC, PAT, PMT, PES timestamps, PCR, adaptation
  fields, stuffing, and continuity counters.
- [x] Implement configuration-aware HEVC Annex B and AAC ADTS conversion.
- [x] Interleave access units by decode time and produce one TS segment per fMP4
  media fragment.
- [x] Add exact packet-level tests, including boundary payload sizes and the
  33-bit timestamp wrap.
- [x] Write fixture outputs to the test-results directory and validate them with
  `ffprobe`/`ffmpeg` in a development-only integration script.
- [x] Concatenate at least three adjacent segments and verify decode continuity,
  monotonic DTS/PTS, A/V sync, HEVC Main10, HLG/BT.2020 tags, and AAC properties.

Exit gate: every output size is divisible by 188, every packet syncs, every
segment starts PAT/PMT then a decodable closed GOP, CRC/continuity/PCR checks pass,
and FFmpeg decodes the fixture sequence with no structural or timestamp errors.

### Phase 3 - Integrate remuxing after the single encoder

- [x] Introduce destination-neutral encoded-fragment events and an ordered output
  router outside the capture actor.
- [x] Cache initialization metadata for the direct session; do not upload an fMP4
  initialization segment to YouTube.
- [x] Remux separable and final media fragments on the dedicated actor.
- [x] Preserve current recording behavior with original fMP4 bytes.
- [x] Preserve relay behavior with original fMP4 bytes and headers.
- [x] Propagate typed packaging errors to the journal and stream-health state;
  stop direct output rather than uploading partial/corrupt TS.
- [x] Add bounded queues, queued-duration metrics, and explicit discontinuity
  handling for any media drop.

Exit gate: an instrumented stream-and-record session creates only one asset-writer
encode path, produces a playable MP4 recording, and produces valid TS fixtures
without changing camera/audio capture code.

### Phase 4 - Generate the playlist and upload to a mock endpoint

- [x] Implement deterministic playlist rendering and rolling-window state.
- [x] Implement safe, globally unique `.m3u8` and `.ts` names.
- [x] Implement the persistent, sequential YouTube uploader and redacted logging.
- [x] Add a local mock HTTP server test that asserts method, URL, raw `file=`
  suffix, filename equality, body bytes, request order, playlist contents, and
  persistent-session reuse.
- [x] Exercise 200, 202, 400, 401, 405, 500, injected network failure,
  cancellation, retry exhaustion, and graceful-stop paths through the mock
  transport.
- [x] Exercise real socket timeout, reconnect, cancellation, and persistent
  connection reuse through the local mock HTTP server.
- [x] Verify that retrying never renames/resequences a segment and never advertises
  more than five outstanding segments.

Exit gate: a simulated long stream remains bounded, preserves segment order under
fault injection, recovers from transient failures, and terminates promptly on
permanent authentication/protocol errors.

### Phase 5 - Add YouTube endpoint discovery and product UI

- [x] Extend `YouTubeService` to retain `cdn.ingestionType` and ingestion URLs for
  the matching stream.
- [x] Reject or clearly explain a non-HLS YouTube stream key in direct mode.
- [x] Add the destination control and validation. Keep relay as the migrated
  default and hide/disable direct mode for Twitch.
- [x] Build the manual-key endpoint only from the official primary URL template;
  never persist a second copy of the key in a generated URL.
- [x] Make startup transactional: validate settings, initialize remux state and
  uploader, then start capture/output. Roll back prepared components on failure.
- [x] Show actionable errors for invalid key, wrong protocol, packaging failure,
  upload backlog, and YouTube rejection without exposing secrets.

Exit gate: all record/stream/destination combinations select exactly the intended
sinks, and settings migration leaves existing users on the working relay path.

### Phase 6 - Device and YouTube validation

- [ ] Test on a physical supported iPhone at 1080p30, 1080p60, and at least one
  4K preset; include mono and stereo presets where available.
- [ ] Run stream-only and stream-and-record for relay and direct destinations.
- [ ] Use an unlisted/private YouTube broadcast and verify ingest health, audio,
  A/V sync, frame rate, resolution, closed-GOP behavior, and absence of dropped
  segments.
- [ ] Verify HLG/BT.2020 signaling in the uploaded TS and the processed YouTube
  archive. The Live Control Room preview itself is not an HDR-color test.
- [ ] Exercise a stop/restart in the same second, network loss and recovery,
  server 5xx responses, app interruption, thermal pressure, and a session long
  enough to expose timestamp drift or queue growth.
- [ ] Repeat a physical direct-HLS stop after the final-drain fix and confirm the
  YouTube archive contains the complete buffered tail with no shutdown error.
- [ ] Compare CPU, energy, memory, and thermal behavior against relay streaming.
  Investigate any evidence of a second encoder or unbounded copying.
- [ ] Decide and document final-playlist behavior from observed YouTube results.

Exit gate: a continuous 60-minute direct stream completes with good YouTube
health, synchronized audio/video, stable bounded memory, a valid optional local
recording, and no stream key in diagnostics.

### Phase 7 - Rollout and cleanup

- [x] Ship direct mode behind a development feature flag first.
- [x] Keep relay mode as an immediate user-selectable fallback through at least
  one TestFlight cycle.
- [x] Add concise diagnostics for current destination, last accepted media
  sequence, queued duration, retry count, and redacted HTTP status.
- [x] Update `README.md` with YouTube HLS stream-key setup and limitations.
- [ ] Remove the feature flag only after device and TestFlight acceptance gates
  pass.
- [ ] Archive/delete the old `transport-stream` branch only as a separate,
  explicit repository-maintenance decision after useful history is preserved.

## Test plan

### Unit tests

- Big-endian reads, four-character codes, box size variants, nesting, and bounds.
- `hvcC` arrays and NAL length sizes 1 through 4.
- AAC AudioSpecificConfig and ADTS for supported sample rates/channels.
- `tfhd`/`trun` defaults, multiple runs, signed composition offsets, B-frames,
  missing optional fields, and invalid data offsets.
- 33-bit PTS/DTS encoding and wrap; PCR encoding; PES length behavior.
- PAT/PMT bytes and CRC; PID selection; continuity rules; adaptation stuffing for
  every boundary size from an empty payload through a full packet.
- Playlist target-duration rounding, rolling windows, discontinuities, unique
  names, acknowledgements, and restart behavior.
- Error classification, redaction, retry/backoff limits, and cancellation.

### Offline integration tests

- Remux captured Apple-generated fMP4 initialization/media pairs.
- Inspect each TS packet and run `ffprobe` over individual and concatenated
  segments.
- Decode to a null sink with `ffmpeg` to catch missing parameter sets, invalid
  timestamp ordering, and A/V decode errors.
- Compare the first/last decoded timestamps and media duration with the source
  fragment within one video frame and one AAC access unit.
- Verify HEVC Main10, 10-bit 4:2:0, HLG transfer, BT.2020 primaries/matrix, AAC
  sample rate, and channel count.
- Probe and decode the byte-for-byte fragmented MP4 assembled by the recording
  sink from the same Apple fragments, and compare its media properties with TS.

FFmpeg is a development/test oracle only; it is not an app dependency.

### HTTP contract tests

- Assert the first playlist starts at sequence zero.
- Assert a playlist update exists for every segment and names match request URLs.
- Assert only allowed filename characters are used and the `file=` suffix is not
  percent encoded.
- Assert no more than five outstanding segments are advertised.
- Assert accepted tails roll off while a small acknowledged tail remains.
- Assert sequential ordering, stable retry identities, persistent session use,
  response-code handling, bounded shutdown, and secret redaction.

### Regression matrix

| Mode | Original fMP4 recording | Relay upload | Remux | Direct upload |
| --- | ---: | ---: | ---: | ---: |
| Record only | yes | no | no | no |
| Relay stream only | no | yes | no | no |
| Relay + record | yes | yes | no | no |
| YouTube direct only | no | no | yes | yes |
| YouTube direct + record | yes | no | yes | yes |

## Failure and backpressure policy

- Parser/configuration error: mark the stream unusable and stop the direct sink;
  never upload bytes whose validity is unknown.
- Permanent HTTP error (400, 401, 405): stop direct delivery and show an
  actionable message. A 401 specifically asks the user to refresh/check the HLS
  stream key.
- Transient network/5xx error: retry the same filename and bytes with bounded
  exponential backoff and jitter.
- Five outstanding segments: stop accepting more direct-upload work until space
  opens. If the capture pipeline cannot be backpressured safely, drop a complete
  oldest segment, advance the local window, mark discontinuity, and report
  degraded/unusable health. The exact threshold is based on queued duration.
- Local recording must continue when the direct network sink fails, provided
  recording itself remains healthy.
- Shutdown has a finite drain deadline. It must be cancellable and must never
  recurse indefinitely while offline.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Apple changes the emitted fMP4 box layout | Parse flags/defaults rather than one captured layout; keep fixtures from multiple OS/device combinations; fail closed on unsupported required constructs. |
| HDR signaling is lost outside MP4 | Carry VPS/SPS/PPS into Annex B, preserve in-band SEI, validate HLG/BT.2020 with FFmpeg and a real YouTube archive. |
| B-frame timestamps become invalid in PES | Derive DTS from `tfdt` plus durations and PTS from composition offsets using track timescales; test reordered frames and wrap. |
| Audio and video drift | Do not invent a second clock; preserve both tracks' fMP4 timing and use rational conversion to 90 kHz. |
| A segment is not a closed GOP | Verify the first video sample's sync flags/NAL type and refuse upload; align keyframe and fragment intervals in the existing writer settings. |
| Packet continuity fails at segment boundaries | Maintain muxer continuity state across segments and test concatenated segments, restarts, and declared discontinuities. |
| 4K remuxing causes capture stalls or memory spikes | Work off the capture actor, use `Data` slices/ranges where safe, serialize bounded work, and profile on device. |
| Generic relay retries violate YouTube playlist semantics | Use a dedicated direct-HLS uploader rather than adapting concurrent `FragmentPusher` behavior. |
| Stream key leaks through URL logging | Central redaction, no request interpolation in logs, and tests that scan diagnostics for the test key. |
| YouTube behavior differs from documentation | Mock the documented contract first, then gate release on an unlisted/private real-ingest matrix and record observed stop/202 behavior. |

## Definition of done

- [x] Direct mode reaches YouTube without `hls-relay`.
- [x] Only one HEVC/AAC encoding path runs in every mode.
- [x] Every uploaded media file is a self-initializing `.ts` segment beginning
  with PAT/PMT, containing muxed HEVC/AAC, and accepted by the offline validators.
- [x] Playlists and request ordering meet YouTube's documented HLS contract.
- [ ] A 60-minute physical-device stream passes YouTube health and A/V/HDR checks.
- [ ] Stream-and-record produces a locally playable MP4 without affecting direct
  output correctness.
- [ ] Existing relay and record-only behavior pass the regression matrix.
- [x] Buffers and shutdown time are bounded under sustained network failure.
- [x] No stream key or key-bearing ingestion URL appears in logs.
- [x] Unit, fixture, HTTP-contract, and app tests pass in developer builds.
- [x] README setup and troubleshooting documentation is complete.
