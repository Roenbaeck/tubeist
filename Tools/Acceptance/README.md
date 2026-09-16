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

## Exact upload capture and segment validation

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
test. Parsing/probing still requires ffprobe. Do not mistake reconstructed
recording segments for exact captured upload bodies.

PCR must precede each video DTS by the 700 ms receiver buffering margin. This
changes only the transport clock: compressed media, media PTS/DTS, segment
durations, and upload scheduling stay unchanged. The JSON result records
`pcrMarginSeconds`. For captures made before this margin was introduced, pass
`--pcr-margin-ms 0`; new captures should use the default 700 ms check. This is a
YouTube compatibility experiment, not a confirmed fix for missing replay sections.

The current experiment uses `#EXT-X-PLAYLIST-TYPE:EVENT`. Every playlist starts at
sequence zero and retains all previously advertised entries, including their
durations and discontinuity markers, through the final ENDLIST. Acknowledgement
still releases uploaded media and the five-outstanding-segment limit remains;
only playlist metadata grows. The validator rejects an EVENT playlist that
removes or changes earlier entries. This isolates playlist retention from the
existing PCR margin and unchanged media timestamps. Compare the next countdown's
local recording and YouTube replay before treating it as a confirmed fix.

Shutdown now waits until ten seconds after the final media acknowledgement before
sending ENDLIST. The normal Stop path then requests completion of the broadcast
captured at Start, when the same YouTube authorization is still available. This
API step has an eight-second budget within the overall shutdown deadline; failure
leaves auto-stop and status polling in place. Completion is shown only after API
confirmation. The upload journal records the last media response and the ENDLIST
request separately, so their elapsed-time difference verifies the grace period.
This experiment does not establish that YouTube preserves the whole ending;
compare the captured media, local recording, and processed replay again.

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
