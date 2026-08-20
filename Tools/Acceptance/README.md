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
monotonic timestamps, successful HTTP status values, a clean Stop terminal
event, and a matching summary. Its JSON result contains counts and durations,
not event details or credentials.

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
