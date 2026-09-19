# Device acceptance evidence

These tools validate evidence from the physical-device and TestFlight matrix in
`PLAN.md`. They do not turn an offline or simulator run into device acceptance.

## Direct-HLS report

In a Debug build, enable **Settings → YouTube HLS Development → Record YouTube HLS diagnostics** before starting one scenario. After Stop has fully completed, retrieve
the entire shared `TubeistDirectHLSAcceptance/<session>` folder with
Finder, the Files app, or Xcode's device-container download.

Validate a successful session with:

```sh
python3 Tools/Acceptance/validate_report.py /path/to/acceptance.jsonl
```

The command fails unless the report has one schema declaration, at least one accepted segment, contiguous upload sequences,
monotonic elapsed times, parseable wall-clock timestamps, successful HTTP status
values, a clean Stop terminal event, and a matching summary. Its JSON result
contains counts and durations, not event details or credentials.

Schema 4 supports direct VideoToolbox output without an MP4 initialization
event. Schemas 2 and 3 retain the older parsed-initialization requirement.
Schema 3 or newer is required by default because it records duration with a monotonic
clock. A pre-schema-3 report can be inspected with `--minimum-schema 2`, but it
is not sufficient evidence for current duration or Stop-tail gates.

Once measured budgets are agreed, enforce them explicitly:

```sh
python3 Tools/Acceptance/validate_report.py /path/to/acceptance.jsonl \
  --max-queued-duration 4 --max-retry-count 2
```

Dropped fragments fail validation by default. `--allow-drops` is only for a
deliberate degradation test whose result will be recorded as an accepted
limitation. Expected failure and cancellation scenarios must name their outcome
with `--expected-outcome`.

The accepted-duration total proves what the uploader acknowledged before Stop;
it must still be compared with capture time, the local recording, and the
YouTube archive. Keep those media files and private URLs out of Git.

Current `segmentAccepted` events report the sink's remaining local queue in
`queuedDuration`. Their optional `detail` retains the legacy delivery fields:
`rate=unpaced`, `pacingReason=workConserving`, `pacingWait=0`, requested `videoTarget` bits/second at upload
start, and the segment's muxed `mediaMbps`. Older reports used the uploader's
already-acknowledged playlist queue, which generally reported zero even when
segments were waiting in the sink. Do not compare that older value as if it were
the full local backlog.

Uploads run continuously and serially, including while catching up. Bitrate
reductions reserve capacity to drain queued media; increases wait for a final
ACK that leaves no work queued. Waiting media is bounded by ten seconds or 30
fragments. Overflow keeps the active transaction, then resumes at the newest
complete segment with a discontinuity, preserving any Stop-tail callbacks.
ENDLIST still waits ten seconds after the final media acknowledgement. These
are local policies, not documented YouTube buffer/rate guarantees. See
[the controller and limits](../../Docs/AdaptiveBitrate.md).

## Exact upload capture and segment validation

The ingest playlist normally retains the latest 15 entries (about 30 seconds),
including both acknowledged and outstanding uploads. Only acknowledged entries
can leave the front of the playlist. Short segments can require more entries to
preserve HLS's minimum live duration of three target durations (15 seconds).
The five-outstanding-upload limit is independent of this history window.
Media and discontinuity sequence numbers advance as old entries leave; the
playlist has no EVENT tag. The same window is retained through ENDLIST.
New playlists declare version 6, matching FFmpeg's declaration when emitting
`EXT-X-INDEPENDENT-SEGMENTS`. This is a compatibility alignment, not evidence
that version 3 caused YouTube to omit media. Historical version-3 captures
remain valid inputs to these tools.

Upload filenames use `t<22-character session token>_<base36 sequence>.ts`.
The token is a URL-safe encoding of the first 128 bits of the session ID's SHA-256
hash, computed once per session. Retries reuse exactly the same names and bytes.
The validators also accept the longer decimal names in older captures.

### Manual stream-ending experiment (Debug only)

Enable **Settings → Stream Ending Test → End broadcast manually in Studio**,
then Save. Sign in to YouTube first and select **Stream and Record** so the local
MP4 provides a comparison. This setting is off by default and ignored in Release.

The next signed-in Start disables YouTube auto-stop, including on an existing
ready event, and confirms the API response if it changes that setting. Uploads
keep the same adaptive pacing and rolling playlist history. Stop drains and
acknowledges all remaining segments and finishes the local recording, but sends
neither ENDLIST nor an API completion request. There is no ENDLIST grace wait.
The YouTube indicator can remain red after Tubeist's local Stop finishes.

Record a short spoken countdown with a distinct final word. After Stop, watch
the YouTube player until that word arrives, or wait up to two minutes and record
that it did not arrive. **Then end the broadcast manually in YouTube Studio.**
Note the time of manual completion and retain the replay URL. Compare the local
MP4 and exact uploaded media with the replay again after archive processing.
This is an experiment, not a confirmed fix or a guarantee of YouTube's behavior.

This mode automatically records diagnostics, even if the separate recording
toggle is off. The first `uploads.jsonl` event records
`"endingPolicy":"manualDiagnostic"`. Validate it explicitly with:

```sh
python3 Tools/Acceptance/validate_upload_capture.py /path/to/session \
  --ending-policy manualDiagnostic > /path/to/validation.json
```

The validator requires a complete capture, full EVENT history, every advertised
segment acknowledged, and **no ENDLIST at all**. The normal validator still
requires ENDLIST; omitting it accidentally cannot pass as a normal stream.
The capture proves upload behavior, not when YouTube finished processing it.

Turn the test off and Save afterward. The next normal signed-in Start restores
auto-stop; normal Stop waits ten seconds from the final media acknowledgement,
sends ENDLIST, waits another ten seconds after its acknowledgement, and attempts
API completion. Changing the setting cannot end an
already-open diagnostic broadcast: complete that broadcast in Studio first.

### Capture contents

The same Debug-only switch also records `uploads.jsonl` and a `bodies/` directory.
The capture wraps the HTTP transport and saves the exact body passed to it for
every playlist and media request, including retries and the final ENDLIST.
SHA-256 filenames deduplicate identical retry bodies; the journal retains each
attempt's order, destination filename, body hash/size, elapsed time, and HTTP
result. It does not save endpoint URLs, stream keys, headers, response bodies,
or error descriptions. Media bodies contain the actual video and sound.

Capture writes run on a utility queue, awaited by the uploader, with no unbounded
media queue. This adds disk I/O to diagnostic runs and can affect measured upload
speed. It is absent from Release builds and disabled in normal Debug use. Each
session saves at most 512 MiB of unique request bodies and 10,000 requests. A
limit, storage failure, or unfinished request marks the evidence incomplete;
streaming continues. Old sessions are not deleted automatically. Delete test
captures in Files afterward to reclaim space.

Copy the **whole session directory** to the Mac, install FFmpeg/ffprobe, and run:

```sh
python3 Tools/Acceptance/validate_upload_capture.py /path/to/session \
  > /path/to/validation.json
```

The validator rejects incomplete captures and verifies:

- saved body hashes/sizes, request/response pairing, and byte-identical retries;
- unique segment filenames/content, ordered media sequences, stable playlist
  entries, advertised durations, and an acknowledged final playlist containing
  every segment for an EVENT playlist (historical rolling captures retain their
  previous five-entry requirement);
- 188-byte TS structure, PAT/PMT and CRCs, stream types, continuity counters, PCR,
  complete PES packets, and per-track PTS/DTS progression;
- one leading AUD per HEVC access unit, a random-access first picture, in-band
  VPS/SPS/PPS, no RASL pictures, and AAC ADTS framing;
- SPS ordering limits independently read by FFmpeg, and a lower-bound check
  that decoded pictures awaiting display do not exceed the declared picture
  buffer capacity (displayed reference pictures are not counted by this check);
- agreement between parsed video boundaries and EXTINF (2 ms tolerance), audio
  continuity (2 ms), and the final A/V end;
- decoding **each segment separately** using FFmpeg, with no reported decoding
  errors and no lost video frames.

YouTube requires closed GOPs. Tubeist starts each segment at a random-access
picture, so a keyframe somewhere later in a segment does not suffice. A final
short segment need not end with another keyframe. This validator checks the
structure and independent decodability of Tubeist's HEVC/AAC output; it is not a
complete H.265 reference-picture/conformance verifier and cannot certify what
YouTube ultimately includes in its replay.

`--skip-decode` runs the quicker structural/timing checks and explicitly reports
`independentlyDecoded: false`. Use the default full decode for the next countdown
test. Parsing/probing still requires ffprobe and FFmpeg for SPS inspection. Do not mistake reconstructed
recording segments for exact captured upload bodies.

PCR must precede each video DTS by the 700 ms receiver buffering margin. This
changes only the transport clock: compressed media, media PTS/DTS, segment
durations, and upload scheduling stay unchanged. The JSON result records
`pcrMarginSeconds`. For captures made before this margin was introduced, pass
`--pcr-margin-ms 0`; new captures should use the default 700 ms check. This is a
YouTube compatibility experiment, not a confirmed fix for missing replay sections.

Earlier captures used `#EXT-X-PLAYLIST-TYPE:EVENT`, with every playlist starting
at sequence zero and retaining all entries through ENDLIST. The validator still
checks that older EVENT captures never remove or change advertised entries.
Current streams use the rolling window described above to avoid continually
growing playlist uploads. This changes neither media timestamps nor the PCR
margin. Compare a new countdown's local recording and YouTube replay to verify
the smaller playlist still preserves playback under recovery conditions.

Shutdown now waits until ten seconds after the final media acknowledgement before
sending ENDLIST. After ENDLIST is acknowledged, the normal signed-in Stop path
waits another ten seconds before requesting completion of the broadcast captured
at Start, when the same YouTube authorization is still available. This API step
has an eight-second budget starting after the second wait, bounded by the overall
shutdown deadline. If the full second wait cannot fit, explicit completion is
skipped; the wait is never shortened to force an earlier transition. Cancellation
also prevents that request. Failure leaves auto-stop and status polling in place.
Completion is shown only after API confirmation. The upload journal records the
last media response and the ENDLIST request/response separately. The app's debug
log marks the start of the additional completion wait and confirmed completion.
The HTTP capture ends with ingestion and does not capture the later API request.
This experiment does not establish that YouTube preserves the whole ending;
compare the captured media, local recording, and processed replay again.

The current decode-timing correction uses the codec's declared picture-reordering
depth instead of the encoder's eight-frame processing window. The latest original
countdown capture failed the new buffer-capacity check: eight pictures awaited
display despite five declared picture buffers and a reorder depth of two.
Older captures can consequently fail this stronger validation even when every
segment decodes in FFmpeg. The hardware encoder probe compares the corrected
timestamps with FFmpeg's `+igndts` reconstruction. This corrects a demonstrated
timing inconsistency, but a new physical-phone/YouTube test is still needed to
establish whether it resolves the replay gaps. EVENT history, PCR margin, and
the final-acknowledgement grace period remain unchanged for that comparison.

The subsequent phone capture confirmed the corrected decode depth but exposed
a separate Stop-boundary failure. The assembler now waits for an audio packet
starting at or beyond a split before publishing the preceding segment. An AAC
packet that merely overlaps the split still belongs to the preceding segment.
On Stop, a short video-only remainder stays in the same final muxed segment.
This avoids losing a completed pending GOP when finalization encounters an
unmatched tail. Stream packaging errors now preserve a valid local recording
and expose their detailed error message. This fixes a reproduced local failure;
it does not establish the cause of YouTube's remaining replay omissions.

Requirements: [YouTube HLS ingestion](https://developers.google.com/youtube/v3/live/guides/hls-ingestion),
[RFC 8216](https://www.rfc-editor.org/rfc/rfc8216.html).

## Recording and YouTube archive comparison

Download the processed YouTube HDR archive to a local file and export the local
recording. Compare them with the acceptance report using explicit, agreed budgets:

```sh
python3 Tools/Acceptance/compare_media.py \
  --report /path/to/acceptance.jsonl \
  --recording /path/to/recording.mp4 \
  --youtube-archive /path/to/archive.webm \
  --expected-width 1920 --expected-height 1080 \
  --expected-frame-rate 30 --expected-audio-channels 2 \
  --max-duration-delta 2.25 --max-av-skew 0.1
```

Choose and record budgets before running the matrix; the example numbers are not
project policy. The comparator requires Tubeist's recording to be HEVC Main10
HLG/BT.2020 with AAC-LC, permits YouTube's HDR transcode codecs, checks expected
resolution/frame rate/channels, measures start/end A/V skew, and compares each
media duration with the uploader-accepted duration. It emits no paths, tags,
titles, URLs, or event details.

If YouTube intentionally changes the source channel layout, specify the observed
archive layout separately with `--expected-archive-audio-channels`; otherwise the
source channel count is required for both files. A/V sync passes only when each
audio and video stream has its own start and duration evidence—container duration
is not substituted for missing stream timing.

`--allow-archive-sdr` exists only for a deliberately documented YouTube
transcoding limitation; it must not silently convert an HDR acceptance row into
an HDR pass.

## Canary scan

Use a dedicated non-production HLS key containing a unique canary. Store the
exact canary in a file outside the exported app container and collected logs;
do not put it directly on a command line. Then run:

```sh
python3 Tools/Acceptance/scan_canary.py \
  --needle-file /path/outside/evidence/canary.txt \
  /path/to/exported-app-container /path/to/redacted-logs
```

The scanner reads files in bounded chunks, including large recordings, and
never prints the canary. A match or unreadable file makes the command fail. The
canary file itself may be among the roots only when it is passed through
`--needle-file`; it is excluded by resolved path.

Keychain contents are intentionally outside the app container and should hold
the test key. The scan is intended to prove that the key did not leak into
preferences, journals, acceptance reports, recordings, caches, or exported
diagnostics.

## Evidence record

For each row in the Phase 10 matrix, retain outside the repository:

- commit and build identifiers;
- iPhone model and iOS version;
- mode, preset, frame rate, microphone/channel configuration, and duration;
- validator JSON and whether diagnostics were enabled;
- YouTube health and archive metadata;
- recording/archive/capture durations and A/V sync observations;
- Instruments trace identifiers and measured memory, CPU, energy, thermal,
  dropped-frame, and queue peaks;
- exercised interruption/failure conditions, result, and accepted limitations.

Only check a `PLAN.md` gate after its complete evidence set exists.
