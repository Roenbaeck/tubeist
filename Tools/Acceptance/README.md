# Device acceptance evidence

These tools validate evidence from the physical-device and TestFlight matrix in
`PLAN.md`. They do not turn an offline or simulator run into device acceptance.

## Direct-HLS report

In a Debug build, enable **Settings → Diagnostics → Record YouTube HLS acceptance
events** before starting one scenario. After Stop has fully completed, retrieve
the app's shared `TubeistDirectHLSAcceptance/<session>/acceptance.jsonl` file with
Finder, the Files app, or Xcode's device-container download.

Validate a successful session with:

```sh
python3 Tools/Acceptance/validate_report.py /path/to/acceptance.jsonl
```

The command fails unless the report has one schema declaration, parsed
initialization, at least one accepted segment, contiguous upload sequences,
monotonic elapsed times, parseable wall-clock timestamps, successful HTTP status
values, a clean Stop terminal event, and a matching summary. Its JSON result
contains counts and durations, not event details or credentials.

Schema 3 is required by default because it records duration with a monotonic
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

## Recording and YouTube archive comparison

Download the processed YouTube HDR archive to a local file and export the local
recording. Compare them with the schema-3 report using explicit, agreed budgets:

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
